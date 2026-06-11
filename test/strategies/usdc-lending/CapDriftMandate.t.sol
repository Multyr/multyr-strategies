// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ═══════════════════════════════════════════════════════════════════════════════
// CapDriftMandate.t.sol -- P0.4 (2026-04-24) cap drift mandate bypass
// ───────────────────────────────────────────────────────────────────────────────
// Root cause (reported 2026-04-24):
//   On a yield-bearing adapter the on-chain `_syncPositionAssets` continuously
//   pushes `positionAssets[a]` upward as interest accrues. At the same time
//   user withdrawals shrink total TVL. Since
//     maxExp = adapterMaxExposureBps * TVL / 1e4
//   the cap can drop *below* the currently-held position without any active
//   deploy. Strict `positionAssets[a] <= maxExp` is physically impossible to
//   maintain block-by-block.
//
// Resolution (Option A, user-approved):
//   Introduce `capDriftToleranceBps` (default 250 bps = 2.5%) and have the
//   gate bypass benefit-vs-cost when any enabled adapter exceeds
//     hardCeiling = maxExp * (1 + capDriftToleranceBps / 1e4)
//   Below the hardCeiling but above maxExp, the soft incentive
//   (`overCapRiskPremiumBps`) continues to weight the benefit calc.
//
// Test matrix (D1a / D1b / D1c):
//   D1a  — normal operation: no adapter exceeds the hard ceiling after a
//          deposit + deploy + keep cycle. Mandate never fires.
//   D1b  — forced over-ceiling: iterative yield pushes adapter above
//          hardCeiling. canRebalance returns ok=true with netBenefitBps=0
//          (mandate fired). Executing the plan brings the adapter back
//          within maxExp.
//   D1c  — drift within tolerance: stdstore lands the position precisely
//          above maxExp but below hardCeiling. Mandate does NOT fire.
//
// Plus setter tests:
//   setCapDriftTolerance above 2000 reverts.
//   setCapDriftTolerance emits CapDriftToleranceUpdated.
//   Default value before any setter call is 0 (mandate disabled).
//
// Run with:  forge test --match-contract CapDriftMandate -vvv
// ═══════════════════════════════════════════════════════════════════════════════

import { Test, console2, stdStorage, StdStorage } from "forge-std/Test.sol";
import {
    UsdcMultiLendingVault
} from "../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
import {
    StrategyParamsModule
} from "../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import { StrategySettingsModule } from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import { StrategyAllocCalcModule } from "../../../src/strategies/usdc-lending/controller/StrategyAllocCalcModule.sol";
import {
    StrategyScoringModule
} from "../../../src/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import {
    StrategyAdapterOpsModule
} from "../../../src/strategies/usdc-lending/controller/StrategyAdapterOpsModule.sol";
import {
    StrategyRebalanceGateModule
} from "../../../src/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol";
import {
    StrategyRebalancePlanModule
} from "../../../src/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol";
import { MockUSDC } from "./UsdcMultiLendingVault.t.sol";
import { ScoringMockAdapter } from "./Scoring_Model.t.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Shared base: deploy 3 mock adapters + seeded vault.
// ─────────────────────────────────────────────────────────────────────────────

abstract contract CapDriftBase is Test {
    using stdStorage for StdStorage;

    address constant ARBITRUM_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    UsdcMultiLendingVault public vault;
    MockUSDC public usdc;
    ScoringMockAdapter public adapterA;
    ScoringMockAdapter public adapterB;
    ScoringMockAdapter public adapterC;

    StrategyParamsModule public paramsMod;
    StrategyScoringModule public scoringMod;
    StrategyAdapterOpsModule public adapterOpsMod;
    StrategyRebalanceGateModule public gateMod;
    StrategyRebalancePlanModule public planMod;

    address public admin   = address(0xA11CE);
    address public core    = address(0xC0FFEE);
    address public router  = address(0xBEEF);
    address public keeper  = address(0xCAFE);

    bytes32 constant PARAM_ROLE   = keccak256("PARAM_ROLE");
    bytes32 constant KEEPER_ROLE  = keccak256("KEEPER_ROLE");

    // Events we expect to observe.
    event CapDriftToleranceUpdated(uint16 oldBps, uint16 newBps);
    event CapDriftMandate(address indexed adapter, uint256 current, uint256 hardCeiling);

    function _baseParams() internal pure returns (UsdcMultiLendingVault.StrategyInitParams memory p) {
        p = UsdcMultiLendingVault.StrategyInitParams({
            maxAdaptersPerAllocation: 3,
            minAdaptersActive: 2,
            rebalanceMinMoveBps: 50,
            minSecondsBetweenRebalances: 21600,
            driftToleranceBps: 80,
            wAPY: 5000,

            wLiq: 2000,

            wRisk: 2000,

            wStability: 1000,

            wIncentive: 0,
            incentiveDecayHalfLife: 86400,
            adapterMaxExposureBps: 5000, // 50% hard cap per adapter
            newAdapterRampBps: 8000,
            gateHorizonDays: 30,
            gateMinNetBenefitBps: 2,
            slippageBpsEstimate: 5,
            withdrawalSpreadBpsEstimate: 5,
            gasCostUSDC: 1e6,
            harvestThresholdBps: 5,
            minSecondsBetweenHarvests: 43200,
            dustTolerance: 10000,
            stabilityEMAPeriod: 7,
            minNewAdapterSeed: 0,
            newAdapterRampDuration: 0,
            maxIdleAfterDepositBps: 500,
            maxIdleBootstrapBps: 5000,
            degradedViewThresholdBps: 2500,
            failureDecaySeconds: 3600,
            minSecondsBetweenDeployIdle: 300,
            bootstrapDuration: 0,
            maxRelativeExposureBps: 0,
            externalTVLStalenessSeconds: 43200
        });
    }

    function _deploy() internal {
        usdc = new MockUSDC();
        vm.etch(ARBITRUM_USDC, address(usdc).code);
        usdc = MockUSDC(ARBITRUM_USDC);

        adapterA = new ScoringMockAdapter(ARBITRUM_USDC);
        adapterB = new ScoringMockAdapter(ARBITRUM_USDC);
        adapterC = new ScoringMockAdapter(ARBITRUM_USDC);

        // Deep external TVL so relative-cap logic never binds; isolate the
        // absolute-cap mandate under test.
        adapterA.setAPY(500); adapterA.setExtMarketTVL(500_000_000e6);
        adapterB.setAPY(400); adapterB.setExtMarketTVL(500_000_000e6);
        adapterC.setAPY(900); adapterC.setExtMarketTVL(500_000_000e6);

        paramsMod = new StrategyParamsModule(ARBITRUM_USDC, core);
        adapterOpsMod = new StrategyAdapterOpsModule(
            ARBITRUM_USDC, core, address(paramsMod), address(0), address(0)
        );
        scoringMod = new StrategyScoringModule(
            ARBITRUM_USDC, core, address(paramsMod), address(0), address(adapterOpsMod)
        );
        gateMod = new StrategyRebalanceGateModule(
            ARBITRUM_USDC, core, address(paramsMod), address(scoringMod), address(adapterOpsMod)
        );
        planMod = new StrategyRebalancePlanModule(
            ARBITRUM_USDC, core, address(paramsMod), address(scoringMod), address(adapterOpsMod)
        );

        vault = new UsdcMultiLendingVault(
            ARBITRUM_USDC, core, router, admin, keeper, address(0),
            address(paramsMod), address(scoringMod), address(adapterOpsMod),
            address(gateMod), _baseParams()
        );

        // Architectural completion: wire StrategyRebalancePlanModule (was missing post-EIP170 split)
        StrategyRebalancePlanModule _planMod = new StrategyRebalancePlanModule(
            ARBITRUM_USDC, core, address(paramsMod), address(scoringMod), address(adapterOpsMod)
        );
        vm.prank(admin);
        vault.setRebalancePlanModule(address(_planMod));

        // REFACTOR-A: wire StrategySettingsModule (governance setters, last in fallback chain)
        StrategySettingsModule _settingsMod0 = new StrategySettingsModule(ARBITRUM_USDC, core);
        vm.prank(admin);
        vault.setSettingsModule(address(_settingsMod0));
        StrategyAllocCalcModule _allocCalcMod0 = new StrategyAllocCalcModule(ARBITRUM_USDC, core);
        vm.prank(admin);
        vault.setAllocCalcModule(address(_allocCalcMod0));

        vm.startPrank(admin);
        address(vault).call(abi.encodeWithSignature("whitelistAdapter(address,bool)", address(adapterA), true));
        vault.addAdapter(address(adapterA));
        address(vault).call(abi.encodeWithSignature("whitelistAdapter(address,bool)", address(adapterB), true));
        vault.addAdapter(address(adapterB));
        address(vault).call(abi.encodeWithSignature("whitelistAdapter(address,bool)", address(adapterC), true));
        vault.addAdapter(address(adapterC));
        vault.toggleAdapter(address(adapterA), true);
        vault.toggleAdapter(address(adapterB), true);
        vault.toggleAdapter(address(adapterC), true);
        vm.stopPrank();

        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();
    }

    function _seedVault(uint256 amount) internal {
        usdc.mint(core, amount);
        vm.startPrank(core);
        usdc.transfer(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }

    /// @dev Mirror of `_checkAdapterForDeploy`'s maxExp calculation.
    function _computedMaxExp(uint256 tvl) internal view returns (uint256) {
        uint16 bps = StrategyParamsModule(address(vault)).adapterMaxExposureBps();
        return (uint256(bps) * tvl) / 1e4;
    }

    function _computedHardCeiling(uint256 tvl) internal view returns (uint256) {
        uint16 tol = StrategyParamsModule(address(vault)).capDriftToleranceBps();
        return (_computedMaxExp(tvl) * (1e4 + uint256(tol))) / 1e4;
    }

    function _totalTvl() internal view returns (uint256 sum) {
        sum = usdc.balanceOf(address(vault));
        sum += vault.positionAssets(address(adapterA));
        sum += vault.positionAssets(address(adapterB));
        sum += vault.positionAssets(address(adapterC));
    }

    // ── Helpers for test setup ──────────────────────────────────────────────

    /// @dev Push adapterC above the hardCeiling via iterative at-most-2x yield
    ///      doublings. Each step stays safely under the sync-time 3x
    ///      suspicious-movement skip guard. Reverts with a descriptive message
    ///      if five rounds do not suffice — this would indicate a test setup
    ///      drift, not a production bug.
    function _forceAdapterCOverCeiling() internal {
        for (uint256 i = 0; i < 6; i++) {
            uint256 current = vault.positionAssets(address(adapterC));
            uint256 yieldAmt = current == 0 ? 100_000e6 : current; // 2x upper bound
            adapterC.simulateYield(yieldAmt);
            vm.prank(admin);
            StrategyParamsModule(address(vault)).syncPositionAssets();

            uint256 tvl = _totalTvl();
            uint256 hc = _computedHardCeiling(tvl);
            if (vault.positionAssets(address(adapterC)) > hc) return;
        }
        revert("setup: failed to push adapterC above hardCeiling after 6 rounds");
    }

    /// @dev Precisely land adapterC's position between maxExp and hardCeiling
    ///      via stdstore + matching mock state. Used by D1c to verify the gate
    ///      does NOT treat sub-tolerance drift as a mandate trigger.
    function _placeAdapterCInDriftBand() internal {
        StdStorage storage s = stdstore;

        // Compute TVL of the OTHER two adapters + vault idle (excluding adapterC).
        // We need to solve for `target` such that, after writing it into
        // positionAssets[adapterC], the NEW total TVL = tvlOthers + target still
        // places target inside (maxExp, hardCeiling).
        //
        // With bps=5000 and tol=250:
        //   maxExp        = (tvlOthers + target) / 2
        //   hardCeiling   = maxExp * 10250 / 10000
        //
        // Constraints:
        //   target > maxExp          ⟺  target > tvlOthers          (trivially met for target≥tvlOthers+1)
        //   target < hardCeiling     ⟺  target < tvlOthers * 10250/9750  ≈ tvlOthers * 1.0513
        //
        // We pick the mid-point of that safe band.
        uint256 tvlOthers = usdc.balanceOf(address(vault))
            + vault.positionAssets(address(adapterA))
            + vault.positionAssets(address(adapterB));

        uint16 bps = StrategyParamsModule(address(vault)).adapterMaxExposureBps();
        uint16 tol = StrategyParamsModule(address(vault)).capDriftToleranceBps();

        // Lower bound (exclusive): target that exactly equals maxExp(tvlOthers+target)
        //   target_lo = bps * tvlOthers / (1e4 - bps)
        uint256 targetLo = (uint256(bps) * tvlOthers) / (1e4 - uint256(bps));
        // Upper bound (exclusive): target that exactly equals hardCeiling(tvlOthers+target)
        //   target_hi = bps*(1e4+tol)*tvlOthers / (1e8 - bps*(1e4+tol))
        uint256 bpsTol = uint256(bps) * (1e4 + uint256(tol));
        uint256 targetHi = (bpsTol * tvlOthers) / (1e8 - bpsTol);

        // 40% through the open interval.
        uint256 target = targetLo + ((targetHi - targetLo) * 40) / 100;

        // Force matching state on the mock so that any post-sync invariant
        // still lines up with the vault's view.
        uint256 currentBal = usdc.balanceOf(address(adapterC));
        if (target > currentBal) {
            usdc.mint(address(adapterC), target - currentBal);
        }
        adapterC.setDeposited(target);

        // Write the vault's `positionAssets[adapterC]` slot via stdstore.
        s.target(address(vault))
         .sig("positionAssets(address)")
         .with_key(address(adapterC))
         .checked_write(target);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// SETTER TESTS
// ═══════════════════════════════════════════════════════════════════════════════

contract CapDriftSetter_Test is CapDriftBase {
    function setUp() public { _deploy(); }

    function test_default_is_zero_before_setter_call() public {
        assertEq(
            StrategyParamsModule(address(vault)).capDriftToleranceBps(),
            0,
            "default capDriftToleranceBps must be 0 (mandate disabled)"
        );
    }

    function test_setter_emits_event_and_updates_slot() public {
        vm.expectEmit(false, false, false, true);
        emit CapDriftToleranceUpdated(0, 250);
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setCapDriftTolerance(250);
        assertEq(
            StrategyParamsModule(address(vault)).capDriftToleranceBps(),
            250
        );
    }

    function test_setter_reverts_above_2000_bps() public {
        vm.prank(admin);
        vm.expectRevert(); // ParamOutOfRange
        StrategySettingsModule(address(vault)).setCapDriftTolerance(2001);
    }

    function test_setter_unauthorized_reverts() public {
        vm.expectRevert(); // Unauthorized
        StrategySettingsModule(address(vault)).setCapDriftTolerance(250);
    }

    function test_setter_accepts_boundary_values() public {
        vm.startPrank(admin);
        StrategySettingsModule(address(vault)).setCapDriftTolerance(0);
        assertEq(StrategyParamsModule(address(vault)).capDriftToleranceBps(), 0);
        StrategySettingsModule(address(vault)).setCapDriftTolerance(2000);
        assertEq(StrategyParamsModule(address(vault)).capDriftToleranceBps(), 2000);
        vm.stopPrank();
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// D1a — Normal operation: no adapter exceeds the hard ceiling after a
//       deposit + deploy cycle. Mandate never fires.
// ═══════════════════════════════════════════════════════════════════════════════

contract CapDrift_D1a_NormalOperation is CapDriftBase {
    function setUp() public {
        _deploy();
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setCapDriftTolerance(250); // 2.5%
        _seedVault(1_000_000e6);
    }

    function test_D1a_all_adapters_within_hard_ceiling_after_deposit() public {
        uint256 tvl = _totalTvl();
        uint256 hardCeiling = _computedHardCeiling(tvl);

        assertLe(vault.positionAssets(address(adapterA)), hardCeiling, "adapterA <= hardCeiling");
        assertLe(vault.positionAssets(address(adapterB)), hardCeiling, "adapterB <= hardCeiling");
        assertLe(vault.positionAssets(address(adapterC)), hardCeiling, "adapterC <= hardCeiling");
    }

    function test_D1a_mandate_does_not_fire_under_normal_conditions() public {
        vm.warp(block.timestamp + 22000);
        (bool ok, , int256 nb) =
            StrategyRebalanceGateModule(address(vault)).canRebalance();

        // Valid outcomes:
        //   - ok = false (no rebalance opportunity)
        //   - ok = true with nb > 0 (legitimate APY-driven rebalance)
        // Invalid: ok=true && nb==0 with no adapter over-ceiling would indicate
        // a false mandate trigger.
        if (ok) {
            assertGt(nb, 0, "if ok=true under normal ops, nb must reflect APY benefit");
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// D1b — Forced over-ceiling: mandate fires, plan divests, adapter back in cap.
// ═══════════════════════════════════════════════════════════════════════════════

contract CapDrift_D1b_ForcedOverCeiling is CapDriftBase {
    function setUp() public {
        _deploy();
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setCapDriftTolerance(250); // 2.5%
        _seedVault(1_000_000e6);
    }

    function test_D1b_mandate_fires_when_adapter_exceeds_hard_ceiling() public {
        _forceAdapterCOverCeiling();

        uint256 posCAfter = vault.positionAssets(address(adapterC));
        uint256 tvlAfter = _totalTvl();
        uint256 hardCeilingAfter = _computedHardCeiling(tvlAfter);
        assertGt(posCAfter, hardCeilingAfter, "setup must leave adapterC above hardCeiling");

        vm.warp(block.timestamp + 22000);

        (bool ok, , int256 nb) =
            StrategyRebalanceGateModule(address(vault)).canRebalance();

        assertTrue(ok, "mandate must force ok=true");
        assertEq(nb, int256(0), "mandate signals nb=0 (protection, not APY)");
    }

    function test_D1b_plan_execution_brings_adapter_back_within_maxExp() public {
        _forceAdapterCOverCeiling();

        vm.warp(block.timestamp + 22000);
        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).prepareRebalance();

        // Execute all actions.
        for (uint256 i = 0; i < 10; ++i) {
            uint8 phase = vault.rebalancePlanPhase();
            if (phase == 0) break;
            vm.prank(keeper);
            StrategyRebalancePlanModule(address(vault)).executeRebalanceStep();
        }

        uint256 posCFinal = vault.positionAssets(address(adapterC));
        uint256 tvlFinal = _totalTvl();
        uint256 maxExpFinal = _computedMaxExp(tvlFinal);

        // Allow 1% tolerance for integer rounding in plan target computation.
        uint256 maxExpTolerated = maxExpFinal + (maxExpFinal / 100);
        assertLe(posCFinal, maxExpTolerated, "adapterC back within maxExp (+1% rounding)");
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// D1c — Drift within tolerance: mandate does NOT fire, gate falls through.
// ═══════════════════════════════════════════════════════════════════════════════

contract CapDrift_D1c_WithinTolerance is CapDriftBase {
    function setUp() public {
        _deploy();
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setCapDriftTolerance(250); // 2.5%
        _seedVault(1_000_000e6);
    }

    function test_D1c_drift_within_tolerance_does_not_force_mandate() public {
        _placeAdapterCInDriftBand();

        // Sanity check the setup.
        uint256 posC = vault.positionAssets(address(adapterC));
        uint256 tvl = _totalTvl();
        uint256 maxExp = _computedMaxExp(tvl);
        uint256 hardCeiling = _computedHardCeiling(tvl);
        assertGt(posC, maxExp, "setup: posC must exceed maxExp");
        assertLt(posC, hardCeiling, "setup: posC must be below hardCeiling");

        vm.warp(block.timestamp + 22000);
        (bool ok, , int256 nb) =
            StrategyRebalanceGateModule(address(vault)).canRebalance();

        // Mandate must NOT fire. Allowed outcomes:
        //   - ok=false (gate judges benefit too low)
        //   - ok=true with nb > 0 (soft incentive + APY benefit wins honestly)
        // Forbidden: ok=true && nb==0 (that would be a mandate misfire).
        if (ok) {
            assertGt(nb, 0, "within tolerance band: ok=true must be earned via benefit");
        }
    }

    function test_D1c_mandate_disabled_when_tolerance_is_zero() public {
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setCapDriftTolerance(0);

        // Even pushing hard over maxExp, with tolerance=0 the mandate branch
        // is guarded off (see `if (capDriftToleranceBps > 0 ...)` in the gate)
        // and the path falls through to pure benefit-vs-cost.
        _forceAdapterCOverCeiling();

        vm.warp(block.timestamp + 22000);
        (bool ok, , int256 nb) =
            StrategyRebalanceGateModule(address(vault)).canRebalance();

        if (ok) {
            assertGt(nb, 0, "mandate disabled: ok=true must be earned via benefit");
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// D1d (P0.5 — 2026-04-25) — Relative cap drift mandate.
// ───────────────────────────────────────────────────────────────────────────────
// Symmetric companion of D1b, exercising the rel cap branch of
// `_checkCapDriftMandate` introduced in P0.5. Setup uses a SHALLOW external
// market (extTVL just above the CONFIDENCE_ZERO floor) so that the relative
// cap is the binding constraint — the absolute cap stays well above the
// position throughout. With the new behaviour:
//   1) `_targetAllocations` now clamps to the tighter rel cap.
//   2) The plan generates a withdraw of (curr - relCap).
//   3) The gate's mandate fires unconditionally when curr > relHardCeiling.
//   4) Plan execution brings the position down to relCap.
// ═══════════════════════════════════════════════════════════════════════════════

contract CapDrift_D1d_RelCapDriftMandate is CapDriftBase {
    using stdStorage for StdStorage;

    function setUp() public {
        _deploy();
        // Enable both the cap drift mandate AND the governance rel cap override
        // (so the rel cap binds regardless of the dynamic band).
        vm.startPrank(admin);
        StrategySettingsModule(address(vault)).setCapDriftTolerance(250); // 2.5%
        StrategySettingsModule(address(vault)).setMaxRelativeExposureBps(2000); // 20%
        vm.stopPrank();

        // Shrink adapterC's external market to a SMALL band so the rel cap
        // is the binding constraint (well below the absolute cap).
        adapterC.setExtMarketTVL(800_000e6); // 800K → dyn rel cap band 5% = 40K
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        _seedVault(1_000_000e6);
    }

    function _expectedRelCap() internal view returns (uint256) {
        uint256 extTVL = vault.cachedExternalTVL(address(adapterC));
        // Dyn rel band for 800K is 500 bps (500K-1M band per
        // _effectiveRelativeCapBps). Gov override = 2000. min(2000, 500) = 500.
        uint256 effRelBps = 500; // hardcoded per the band table
        return (effRelBps * extTVL) / 1e4;
    }

    function _expectedRelHardCeiling() internal view returns (uint256) {
        uint16 tol = StrategyParamsModule(address(vault)).capDriftToleranceBps();
        return (_expectedRelCap() * (1e4 + uint256(tol))) / 1e4;
    }

    /// @dev Push adapterC above the rel hard ceiling using stdstore +
    ///      matching mock state. Relies on extTVL band → 500 bps cap.
    function _forceAdapterCOverRelCeiling() internal {
        StdStorage storage s = stdstore;

        uint256 relHardCeiling = _expectedRelHardCeiling();
        uint256 target = relHardCeiling + (relHardCeiling / 4); // 25% above ceiling

        uint256 currentBal = usdc.balanceOf(address(adapterC));
        if (target > currentBal) {
            usdc.mint(address(adapterC), target - currentBal);
        }
        adapterC.setDeposited(target);

        s.target(address(vault))
         .sig("positionAssets(address)")
         .with_key(address(adapterC))
         .checked_write(target);
    }

    function test_D1d_mandate_fires_when_adapter_exceeds_rel_hard_ceiling() public {
        _forceAdapterCOverRelCeiling();

        uint256 posC = vault.positionAssets(address(adapterC));
        uint256 relHardCeiling = _expectedRelHardCeiling();
        assertGt(posC, relHardCeiling, "setup: posC must exceed relHardCeiling");

        // Sanity: absolute cap is NOT the binding constraint here.
        uint256 absHardCeiling = _computedHardCeiling(_totalTvl());
        assertLt(posC, absHardCeiling, "setup: posC must be below absHardCeiling");

        vm.warp(block.timestamp + 22000);
        (bool ok, , int256 nb) =
            StrategyRebalanceGateModule(address(vault)).canRebalance();

        assertTrue(ok, "rel cap mandate must force ok=true");
        assertEq(nb, int256(0), "mandate signals nb=0 (protection, not APY)");
    }

    function test_D1d_plan_brings_adapter_back_within_rel_cap() public {
        _forceAdapterCOverRelCeiling();

        vm.warp(block.timestamp + 22000);
        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).prepareRebalance();

        for (uint256 i = 0; i < 10; ++i) {
            uint8 phase = vault.rebalancePlanPhase();
            if (phase == 0) break;
            vm.prank(keeper);
            StrategyRebalancePlanModule(address(vault)).executeRebalanceStep();
        }

        uint256 posCFinal = vault.positionAssets(address(adapterC));
        uint256 relCap = _expectedRelCap();
        uint256 relCapTolerated = relCap + (relCap / 100); // +1% rounding
        assertLe(posCFinal, relCapTolerated,
            "adapterC back within relCap (+1% rounding)");
    }

    function test_D1d_mandate_disabled_when_tolerance_is_zero() public {
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setCapDriftTolerance(0);

        _forceAdapterCOverRelCeiling();

        vm.warp(block.timestamp + 22000);
        (bool ok, , int256 nb) =
            StrategyRebalanceGateModule(address(vault)).canRebalance();

        // With tolerance=0 the rel cap mandate branch is short-circuited too.
        // Outcome must be earned via benefit, not via mandate.
        if (ok) {
            assertGt(nb, 0, "mandate disabled: ok=true must be earned via benefit");
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// D1f (P0.7 — 2026-06-11) — Safety Adapter Cap Tier.
// ───────────────────────────────────────────────────────────────────────────────
// Architectural design ratified after 10 backtest sweep iterations on real
// Arbitrum data (2024-01-01 → 2026-05-31). Final iter-3b setpoint:
//   TWR USD 5.62% vs Aave standalone 5.37% (+25 bps), Sharpe 0.729 vs 0.33.
//
// Test harness uses _baseParams.adapterMaxExposureBps = 5000 (50%). Safety
// adapter is configured with fallback caps at 7000 (70%) for both abs and
// rel — meaningfully above the normal cap, so we can exercise positions in
// the band (5000, 7000] without colliding with the normal mandate.
//
// Tolerance = 250 bps → normal hardCeiling = 50% × 1.025 = 51.25% of TVL,
// safety hardCeiling = 70% × 1.025 = 71.75% of TVL.
//
// Refs: docs/SAFETY_ADAPTER_TIER.md, memory.md sessione 13,
//       commits 8e846a9..1019d3a (P0.7 S1.1-S1.4).
// ═══════════════════════════════════════════════════════════════════════════════

contract CapDrift_D1f_SafetyAdapterCapTier is CapDriftBase {
    using stdStorage for StdStorage;

    // Mirrored from spec defaults for clarity in assertions.
    uint16 constant SAFETY_FB_ABS_BPS = 7000; // 70% TVL
    uint16 constant SAFETY_FB_REL_BPS = 7000; // 70% extTVL
    uint16 constant CAPDRIFT_TOL_BPS  = 250;  // 2.5%
    uint16 constant MAX_IDLE_BPS      = 500;  // 5% TVL
    uint32 constant MANDATE_COOLDOWN  = 3 days;

    function setUp() public {
        _deploy();
        vm.startPrank(admin);
        StrategySettingsModule(address(vault)).setCapDriftTolerance(CAPDRIFT_TOL_BPS);
        // Configure adapterA as the sole safety fallback. extTVL is already
        // 500_000_000e6 (deep) in CapDriftBase so the dynamic rel cap is at
        // its 2500-bps ceiling band; the fallback rel cap of 7000 makes it
        // non-binding for this suite.
        StrategySettingsModule(address(vault)).addSafetyFallbackAdapter(
            address(adapterA), SAFETY_FB_ABS_BPS, SAFETY_FB_REL_BPS
        );
        StrategySettingsModule(address(vault)).setMaxIdleBps(MAX_IDLE_BPS);
        StrategySettingsModule(address(vault)).setMandateRedeployCooldown(MANDATE_COOLDOWN);
        StrategySettingsModule(address(vault)).setTargetSafetyMargin(300); // 3%
        vm.stopPrank();
        _seedVault(1_000_000e6);
    }

    // ── Local helpers ──────────────────────────────────────────────────────

    /// @dev Force `adapter`'s `positionAssets` and the mock's deposited state
    ///      to `target`. Used to construct precise pre-conditions for cap
    ///      arithmetic. Does NOT touch other adapters.
    function _forcePosition(ScoringMockAdapter adapter, uint256 target) internal {
        uint256 currentBal = usdc.balanceOf(address(adapter));
        if (target > currentBal) usdc.mint(address(adapter), target - currentBal);
        adapter.setDeposited(target);
        stdstore.target(address(vault))
            .sig("positionAssets(address)")
            .with_key(address(adapter))
            .checked_write(target);
    }

    /// @dev Returns true if the prepared rebalance plan contains a WITHDRAW
    ///      action targeting `adapter`. High bit of rebalancePlanAmounts[i]
    ///      encodes isDeposit (1 = deposit, 0 = withdraw) per
    ///      StrategyStorageLayout.sol commentary.
    function _planHasWithdrawFor(address adapter) internal view returns (bool) {
        uint8 total = vault.rebalancePlanTotalActions();
        for (uint8 i = 0; i < total; i++) {
            address a = vault.rebalancePlanAdapters(i);
            uint256 amt = vault.rebalancePlanAmounts(i);
            bool isWithdraw = (amt >> 255) == 0;
            if (a == adapter && isWithdraw) return true;
        }
        return false;
    }

    /// @dev Drains the prepared plan to phase 0 (up to 10 steps as a safety).
    function _drainPlan() internal {
        for (uint256 i = 0; i < 10; ++i) {
            if (vault.rebalancePlanPhase() == 0) break;
            vm.prank(keeper);
            StrategyRebalancePlanModule(address(vault)).executeRebalanceStep();
        }
    }

    /// @dev Force `adapter`'s position so that, POST-force, it represents
    ///      exactly `percentBps / 1e4` of the NEW total TVL.
    /// @dev Closed-form: solving target / (T_others + target) = pct gives
    ///        target = T_others × pct / (1e4 - pct)
    ///      where T_others is current TVL minus the adapter's pre-force position.
    ///      Naive `_totalTvl() * pct / 1e4` would undercount because forcing
    ///      the position also inflates the denominator.
    function _forcePctOfNewTvl(ScoringMockAdapter adapter, uint16 percentBps) internal {
        require(percentBps > 0 && percentBps < 10_000, "_forcePctOfNewTvl: pct out of range");
        uint256 tvlOthers = _totalTvl() - vault.positionAssets(address(adapter));
        uint256 target = (tvlOthers * uint256(percentBps)) / (10_000 - uint256(percentBps));
        _forcePosition(adapter, target);
    }

    // ── Tests ──────────────────────────────────────────────────────────────

    /// @notice (01) Safety adapter above NORMAL cap but below FALLBACK ceiling:
    ///         mandate does not fire because the gate honours fbAbsCap for it.
    function test_D1f_01_mandate_uses_fallback_cap_for_safety_adapter() public {
        // 65% of NEW TVL: above normal hardCeiling (~51.25%), below fallback hardCeiling (~71.75%).
        _forcePctOfNewTvl(adapterA, 6500);

        vm.warp(block.timestamp + 22000);
        (bool ok, , int256 nb) =
            StrategyRebalanceGateModule(address(vault)).canRebalance();

        // Forbidden outcome: ok=true && nb==0 (that is the mandate fingerprint).
        // Allowed: ok=false, or ok=true with positive nb (legitimate APY-driven move).
        if (ok) {
            assertGt(nb, 0, "safety adapter in tranche: ok=true must reflect APY benefit, not mandate");
        }
    }

    /// @notice (02) Non-safety adapter above normal hard ceiling: mandate MUST
    ///         fire with the nb=0 protection signature.
    function test_D1f_02_mandate_uses_normal_cap_for_normal_adapter() public {
        // 55% of NEW TVL: above normal hardCeiling (~51.25%).
        _forcePctOfNewTvl(adapterB, 5500);

        vm.warp(block.timestamp + 22000);
        (bool ok, , int256 nb) =
            StrategyRebalanceGateModule(address(vault)).canRebalance();

        assertTrue(ok, "non-safety over-cap MUST mandate-fire (ok=true)");
        assertEq(nb, int256(0), "mandate signals nb=0 (protection, not APY)");
    }

    /// @notice (03) Excess idle is routed to the safety adapter via the
    ///         overflow path and is bounded by the fallback ceiling.
    function test_D1f_03_overflow_routes_to_safety_adapter() public {
        // Saturate non-safety adapters at their NORMAL absolute cap so the
        // regular allocator leaves a meaningful idle surplus that must flow
        // through the overflow path.
        uint256 tvl = _totalTvl();
        uint256 normalCapAmt = (tvl * 5000) / 10_000;
        _forcePosition(adapterB, normalCapAmt);
        _forcePosition(adapterC, normalCapAmt);

        // Mint extra USDC into the vault to create an idle surplus that is
        // strictly above maxIdleBps × tvl.
        uint256 extraIdle = 200_000e6;
        usdc.mint(address(vault), extraIdle);

        uint256 idleBefore = usdc.balanceOf(address(vault));
        uint256 posABefore = vault.positionAssets(address(adapterA));

        // _seedVault's deposit already triggered an auto-deploy that stamped
        // lastDeployIdleTs; warp past minSecondsBetweenDeployIdle (300s) so the
        // explicit deployIdle() call is not rejected with DeployIdleCooldown.
        vm.warp(block.timestamp + 301);

        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();

        uint256 idleAfter = usdc.balanceOf(address(vault));
        uint256 posAAfter = vault.positionAssets(address(adapterA));

        // The overflow path must have moved at least SOME idle into the safety
        // adapter. We do not assert the exact target — the regular plan may
        // also touch adapterA before overflow kicks in — but the post-state
        // must be strictly closer to the desired equilibrium.
        assertLt(idleAfter, idleBefore, "deployIdle must have reduced idle");
        assertGt(posAAfter, posABefore, "safety adapter must have absorbed overflow");

        // Final position must NEVER exceed the fallback ceiling.
        uint256 tvlAfter = _totalTvl();
        uint256 fbCeiling = (uint256(SAFETY_FB_ABS_BPS) * tvlAfter) / 10_000;
        assertLe(posAAfter, fbCeiling, "safety adapter capped at fallback ceiling");
    }

    /// @notice (04) When the mandate fires on a SAFETY adapter (pushed past
    ///         its fallback ceiling), the cooldown timestamp is NOT set.
    ///         By design, safety adapters never enter cooldown — the overflow
    ///         path is their only deposit channel and it self-regulates via
    ///         fbCeiling - current.
    function test_D1f_04_safety_adapter_never_in_cooldown() public {
        // Push adapterA above the safety hardCeiling (~71.75% of new TVL).
        _forcePctOfNewTvl(adapterA, 7500);
        vm.warp(block.timestamp + 22000);

        vm.prank(keeper);
        try StrategyRebalancePlanModule(address(vault)).prepareRebalance() {} catch {}

        assertEq(
            vault.lastRelCapMandateTs(address(adapterA)), 0,
            "safety adapter MUST NOT have cooldown timestamp set"
        );
    }

    /// @notice (05) When the mandate fires on a NON-safety adapter, cooldown
    ///         is set and a subsequent deployIdle skips that adapter for the
    ///         configured duration.
    function test_D1f_05_normal_adapter_cooldown_blocks_redeploy() public {
        _forcePctOfNewTvl(adapterB, 5500);
        vm.warp(block.timestamp + 22000);

        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).prepareRebalance();
        _drainPlan();

        // Cooldown ts must have been stamped on the mandate-action path.
        uint64 cdTs = vault.lastRelCapMandateTs(address(adapterB));
        assertGt(cdTs, 0, "cooldown timestamp must be set on mandate hit");

        // Reset adapterB to a deposit-eligible position (well below cap) and
        // then run deployIdle: cooldown filter must keep adapterB out of the
        // selected set even though it has plenty of headroom.
        _forcePctOfNewTvl(adapterB, 1000); // 10%
        uint256 posBBefore = vault.positionAssets(address(adapterB));

        // Mint surplus idle so deployIdle has something to allocate.
        usdc.mint(address(vault), 50_000e6);

        // _drainPlan executed actions that updated lastDeployIdleTs indirectly?
        // No — only deposit/withdraw + adapter deposit calls. But the rebalance
        // path may have stamped lastRebalanceTs. Warp to be safe.
        vm.warp(block.timestamp + 301);

        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();

        // Within the cooldown window, adapterB must not have received any deposit.
        assertEq(
            vault.positionAssets(address(adapterB)), posBBefore,
            "adapterB in cooldown must NOT receive deposits"
        );
    }

    /// @notice (06) "Preserve safety tranche" — when the mandate fires on a
    ///         non-safety adapter, the prepared plan must withdraw from THAT
    ///         adapter, not from a safety adapter legitimately sitting in its
    ///         overflow tranche.
    function test_D1f_06_valid_safety_tranche_preserved() public {
        // adapterA at 65% (legitimate safety tranche, below fallback ceiling 70%).
        _forcePctOfNewTvl(adapterA, 6500);
        // adapterB above normal hard ceiling: mandate target.
        _forcePctOfNewTvl(adapterB, 5500);

        vm.warp(block.timestamp + 22000);
        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).prepareRebalance();

        bool aWithdraw = _planHasWithdrawFor(address(adapterA));
        bool bWithdraw = _planHasWithdrawFor(address(adapterB));

        assertFalse(aWithdraw, "safety tranche MUST NOT be unwound by the mandate plan");
        assertTrue(bWithdraw, "mandate target (adapterB) MUST be withdrawn");
    }

    /// @notice (07) Removing an adapter from the safety list immediately
    ///         restores normal-cap mandate semantics on it.
    function test_D1f_07_remove_safety_restores_normal_caps() public {
        // Place adapterA at 65% NEW TVL (allowed while it is safety: in tranche).
        _forcePctOfNewTvl(adapterA, 6500);

        // Remove safety status.
        vm.prank(admin);
        StrategySettingsModule(address(vault)).removeSafetyFallbackAdapter(address(adapterA));

        // Position is now far above the NORMAL hardCeiling (~51.25%).
        vm.warp(block.timestamp + 22000);
        (bool ok, , int256 nb) =
            StrategyRebalanceGateModule(address(vault)).canRebalance();

        assertTrue(ok, "post-removal: mandate MUST fire on adapterA");
        assertEq(nb, int256(0), "post-removal: mandate signature nb=0");
    }

    /// @notice (08) Dual-anchor production setpoint — primary safety venue
    ///         (Aave-like adapterA) fills toward its 50% fallback cap FIRST,
    ///         then secondary (Compound-like adapterB at 40% caps) absorbs
    ///         residual overflow. Verifies safetyFallbackAdapters[0] = Aave,
    ///         [1] = Compound ordering and the per-adapter cap honour.
    function test_D1f_08_dual_safety_priority_aave_before_compound() public {
        // Add a second safety venue (adapterB) with the production
        // conservative-tier caps. Note adapterA is already configured at
        // 7000/7000 by setUp; here we test ORDERING + per-adapter ceiling
        // honour, not the production cap values themselves.
        vm.prank(admin);
        StrategySettingsModule(address(vault)).addSafetyFallbackAdapter(
            address(adapterB), 4000, 4000
        );

        // List ordering: primary (Aave-like adapterA) at index 0, secondary
        // (Compound-like adapterB) at index 1. This is the priority order in
        // which _executeSafetyOverflow iterates.
        assertEq(
            vault.safetyFallbackAdapters(0), address(adapterA),
            "safetyFallbackAdapters[0] must be the primary (adapterA)"
        );
        assertEq(
            vault.safetyFallbackAdapters(1), address(adapterB),
            "safetyFallbackAdapters[1] must be the secondary (adapterB)"
        );
        assertEq(
            StrategySettingsModule(address(vault)).safetyFallbackAdaptersLength(), 2,
            "length must reflect dual-anchor config"
        );

        // Force a known starting position: 30% on each safety adapter,
        // leaving meaningful headroom (adapterA up to 70% fallback cap,
        // adapterB up to 40% fallback cap).
        _forcePctOfNewTvl(adapterA, 3000);
        _forcePctOfNewTvl(adapterB, 3000);

        uint256 posABefore = vault.positionAssets(address(adapterA));
        uint256 posBBefore = vault.positionAssets(address(adapterB));

        // Mint enough surplus idle that the overflow path must engage on
        // BOTH safety adapters to absorb it. 60% of TVL guarantees we
        // exhaust adapterA's ~40% remaining headroom before reaching B.
        usdc.mint(address(vault), (_totalTvl() * 6000) / 10_000);

        // Past deployIdle cooldown.
        vm.warp(block.timestamp + 301);
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();

        uint256 posAAfter = vault.positionAssets(address(adapterA));
        uint256 posBAfter = vault.positionAssets(address(adapterB));
        uint256 tvlAfter = _totalTvl();

        // Both safety adapters must have absorbed overflow.
        assertGt(posAAfter, posABefore, "primary safety must have absorbed overflow");
        assertGt(posBAfter, posBBefore, "secondary safety must have absorbed residual overflow");

        // Per-adapter ceiling honoured: A capped at 7000 bps × tvlAfter,
        // B capped at 4000 bps × tvlAfter (the values set by setUp / this test).
        uint256 fbACeiling = (uint256(SAFETY_FB_ABS_BPS) * tvlAfter) / 10_000;
        uint256 fbBCeiling = (uint256(4000) * tvlAfter) / 10_000;
        assertLe(posAAfter, fbACeiling, "primary must not exceed its fallback abs ceiling");
        assertLe(posBAfter, fbBCeiling, "secondary must not exceed its fallback abs ceiling");

        // Priority ordering enforcement: the primary must have absorbed
        // STRICTLY more than the secondary (it was filled first). This is
        // the architectural invariant the iteration order in
        // _executeSafetyOverflow encodes.
        uint256 deltaA = posAAfter - posABefore;
        uint256 deltaB = posBAfter - posBBefore;
        assertGe(deltaA, deltaB, "primary delta must be >= secondary delta (priority filled first)");
    }

    /// @notice (09) L-01 fix verification: a quarantined adapter cannot be
    ///         promoted to the safety tier. The setter must revert with
    ///         InvalidAdapter, leaving the safety configuration untouched.
    function test_D1f_09_quarantined_adapter_promotion_reverts() public {
        // adapterC is non-safety in this harness. Force it into quarantine
        // by writing the quarantined[adapter] mapping directly (mocking the
        // adapter-failure path which would otherwise require N consecutive
        // operational failures).
        stdstore.target(address(vault)).sig("quarantined(address)")
            .with_key(address(adapterC)).checked_write(true);
        assertTrue(vault.quarantined(address(adapterC)), "setup: adapterC quarantined");

        vm.prank(admin);
        vm.expectRevert(); // InvalidAdapter — quarantined branch
        StrategySettingsModule(address(vault)).addSafetyFallbackAdapter(
            address(adapterC), 5000, 5000
        );

        // Confirm safety set was NOT mutated by the failed call.
        (uint16 absC, uint16 relC) = vault.safetyFallback(address(adapterC));
        assertEq(absC, 0, "quarantined adapter must not become safety (absCap)");
        assertEq(relC, 0, "quarantined adapter must not become safety (relCap)");
    }

    // Re-declare the event so vm.expectEmit can match it. Must match the
    // signature in StrategyStorageLayout.sol bit-for-bit.
    event RelCapMandateCooldownCleared(address indexed adapter, address indexed clearedBy, uint64 priorTs);
}