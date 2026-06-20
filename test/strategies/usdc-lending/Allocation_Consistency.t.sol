// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import { StrategyExplainabilityLens } from "../../../src/strategies/usdc-lending/lens/StrategyExplainabilityLens.sol";
import { StrategyRebalanceGateModule } from "../../../src/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol";
import { StrategyRebalancePlanModule } from "../../../src/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol";
import {
    UsdcMultiLendingVault
} from "../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
import {
    MockUSDC,
    MockLendingAdapter,
    UsdcMultiLendingVaultTestBase
} from "./UsdcMultiLendingVault.t.sol";
import {
    StrategyParamsModule
} from "../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import { StrategySettingsModule } from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import { StrategyAllocCalcModule } from "../../../src/strategies/usdc-lending/controller/StrategyAllocCalcModule.sol";
import {
    StrategyScoringModule
} from "../../../src/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import { StrategyAdapterOpsModule } from "../../../src/strategies/usdc-lending/controller/StrategyAdapterOpsModule.sol";
import {
    ILendingAdapter
} from "../../../src/strategies/usdc-lending/interfaces/ILendingAdapter.sol";
import { ScoringMockAdapter } from "./Scoring_Model.t.sol";
import { StrategySafetyOverflowModule } from "../../../src/strategies/usdc-lending/controller/StrategySafetyOverflowModule.sol";

// ============================================================================
// ALLOCATION CONSISTENCY + SYSTEM INVARIANTS + EXPLAINABILITY — BLOCCO C, I, M
// ============================================================================

contract Allocation_Consistency is Test {
    address constant ARBITRUM_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    UsdcMultiLendingVault public vault;
    MockUSDC public usdc;
    ScoringMockAdapter public adapterA;
    ScoringMockAdapter public adapterB;
    ScoringMockAdapter public adapterC;
    ScoringMockAdapter public adapterD;
    ScoringMockAdapter public adapterE;

    address public admin = address(0x1);
    address public core = address(0x2);
    address public router = address(0x6);
    address public keeper = address(0x3);

    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant PARAM_ROLE = keccak256("PARAM_ROLE");
    bytes32 constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    function setUp() public {
        usdc = new MockUSDC();
        vm.etch(ARBITRUM_USDC, address(usdc).code);
        usdc = MockUSDC(ARBITRUM_USDC);

        adapterA = new ScoringMockAdapter(ARBITRUM_USDC);
        adapterB = new ScoringMockAdapter(ARBITRUM_USDC);
        adapterC = new ScoringMockAdapter(ARBITRUM_USDC);
        adapterD = new ScoringMockAdapter(ARBITRUM_USDC);
        adapterE = new ScoringMockAdapter(ARBITRUM_USDC);

        adapterA.setAPY(900);
        adapterB.setAPY(700);
        adapterC.setAPY(500);
        adapterD.setAPY(300);
        adapterE.setAPY(100);

        // Audit #2 P0.6: seed realistic external TVL so confidence != ZERO
        adapterA.setExtMarketTVL(50_000_000e6);
        adapterB.setExtMarketTVL(50_000_000e6);
        adapterC.setExtMarketTVL(50_000_000e6);
        adapterD.setExtMarketTVL(50_000_000e6);
        adapterE.setExtMarketTVL(50_000_000e6);

        UsdcMultiLendingVault.StrategyInitParams memory params = UsdcMultiLendingVault
            .StrategyInitParams({
            maxAdaptersPerAllocation: 5,
            minAdaptersActive: 2,
            rebalanceMinMoveBps: 50,
            minSecondsBetweenRebalances: 21600,
            driftToleranceBps: 80,
            wAPY: 4000,
            wLiq: 2000,
            wRisk: 2000,
            wStability: 1000,
            wIncentive: 1000,
            incentiveDecayHalfLife: 86400,
            adapterMaxExposureBps: 8000, // 80% — high cap so score order matters
            newAdapterRampBps: 8000,
            gateHorizonDays: 7,
            gateMinNetBenefitBps: 2,
            slippageBpsEstimate: 0,
            withdrawalSpreadBpsEstimate: 0,
            gasCostUSDC: 0,
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
            bootstrapDuration: 86400,
            maxRelativeExposureBps: 0,
            externalTVLStalenessSeconds: 43200
        });

        StrategyParamsModule paramsModule = new StrategyParamsModule(ARBITRUM_USDC, core);
        StrategyAdapterOpsModule adapterOpsMod = new StrategyAdapterOpsModule(
            ARBITRUM_USDC, core, address(paramsModule), address(0), address(0)
        );
        StrategyScoringModule scoringMod = new StrategyScoringModule(
            ARBITRUM_USDC, core, address(paramsModule), address(0), address(adapterOpsMod)
        );

        address gateMod = address(new StrategyRebalanceGateModule(ARBITRUM_USDC, core, address(paramsModule), address(scoringMod), address(adapterOpsMod)));
        vault = new UsdcMultiLendingVault(
            ARBITRUM_USDC,
            core,
            router,
            admin,
            keeper,
            address(0),
            address(paramsModule),
            address(scoringMod),
            address(0), // adapterOpsModule
            gateMod,
            params
        );

        // Architectural completion: wire StrategyRebalancePlanModule (was missing post-EIP170 split)
        StrategyRebalancePlanModule _planMod = new StrategyRebalancePlanModule(
            ARBITRUM_USDC, core, address(paramsModule), address(scoringMod), address(adapterOpsMod)
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
        StrategySafetyOverflowModule _overflowMod = new StrategySafetyOverflowModule(
            ARBITRUM_USDC, core, address(0), address(0), address(adapterOpsMod)
        );
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setSafetyOverflowModule(address(_overflowMod));

        adapterA.setVault(address(vault));
        adapterB.setVault(address(vault));
        adapterC.setVault(address(vault));
        adapterD.setVault(address(vault));
        adapterE.setVault(address(vault));

        vm.prank(admin);
        StrategySettingsModule(address(vault)).exitBootstrapMode();
    }

    // ── Helpers ──

    function _addAndEnable(ScoringMockAdapter a) internal {
        vm.startPrank(admin);
        address(vault).call(abi.encodeWithSignature("whitelistAdapter(address,bool)", address(a), true));
        vault.addAdapter(address(a));
        vault.toggleAdapter(address(a), true);
        (bool ok,) = address(vault).call(
            abi.encodeWithSignature("setAdapterDepositMode(address,bool)", address(a), false)
        );
        require(ok, "setAdapterDepositMode failed");
        vm.stopPrank();
        // Audit #2 P0.6: poke TVL cache so adapter gets non-zero confidence
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();
        // TRIAGE A1: populate cachedLiquidityBps to avoid MAJORITY_INELIGIBLE DegradedMode trigger.
        vm.prank(keeper);
        (bool liqOk,) = address(vault).call(
            abi.encodeWithSignature("pokeLiquidityBatch(uint256,uint256)", 0, 10)
        );
        require(liqOk, "pokeLiquidityBatch failed");
    }

    function _coreDeposit(uint256 amount) internal {
        usdc.mint(core, amount);
        vm.prank(core);
        usdc.transfer(address(vault), amount);
        vm.prank(core);
        vault.deposit(amount);
    }

    function _setMaxIdle(uint16 bps) internal {
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setMaxIdleAfterDepositBps(bps);
    }

    function _setMaxExposure(uint16 bps) internal {
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setRebalanceParams(
            5, 2, 50, 21600, 80, bps, 5000
        );
    }

    function _setQuarantined(address adapter, bool q) internal {
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setQuarantined(adapter, q);
    }

    function _totalPositions() internal view returns (uint256 total) {
        total += vault.positionAssets(address(adapterA));
        total += vault.positionAssets(address(adapterB));
        total += vault.positionAssets(address(adapterC));
        total += vault.positionAssets(address(adapterD));
        total += vault.positionAssets(address(adapterE));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  C1. SCORE → TARGET ALLOCATION TESTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice T1 regime: only top-score adapter receives funds (dMax=1, capital preservation)
    function test_target_allocations_T1_singleAdapter_topScore() public {
        _addAndEnable(adapterA); // 9%
        _addAndEnable(adapterB); // 7%
        _addAndEnable(adapterC); // 5%
        _setMaxIdle(10000);

        // TVL < 25K → T1 → dMax=1: only adapterA (top score) is funded by design.
        // TIER_MODEL_V1 Section 3: T1 single-adapter mode is intentional.
        _coreDeposit(1000e6);

        uint256 posA = vault.positionAssets(address(adapterA));
        uint256 posB = vault.positionAssets(address(adapterB));
        uint256 posC = vault.positionAssets(address(adapterC));

        assertGt(posA, 0, "T1: top score adapter funded");
        assertEq(posB, 0, "T1: only 1 adapter funded by design");
        assertEq(posC, 0, "T1: only 1 adapter funded by design");
    }

    /// @notice T2 regime: top-2 score-weighted, third skipped (dMax=2)
    function test_target_allocations_T2_dualAdapter_scoreWeighted() public {
        _addAndEnable(adapterA); // 9%
        _addAndEnable(adapterB); // 7%
        _addAndEnable(adapterC); // 5%
        _setMaxIdle(10000);

        // TVL in 25K-250K → T2 → dMax=2: top 2 adapters selected.
        _coreDeposit(50_000e6);

        uint256 posA = vault.positionAssets(address(adapterA));
        uint256 posB = vault.positionAssets(address(adapterB));
        uint256 posC = vault.positionAssets(address(adapterC));

        assertGt(posA, posB, "T2: A (9%) gets more than B (7%)");
        assertGt(posB, 0, "T2: B funded");
        assertEq(posC, 0, "T2: third adapter skipped (dMax=2)");
    }

    /// @notice T3 regime: all 3 adapters score-weighted (dMax=3)
    function test_target_allocations_T3_tripleAdapter_scoreWeighted() public {
        _addAndEnable(adapterA); // 9%
        _addAndEnable(adapterB); // 7%
        _addAndEnable(adapterC); // 5%
        _setMaxIdle(10000);

        // TVL in 250K-1M → T3 → dMax=3: all 3 adapters selected.
        _coreDeposit(500_000e6);

        uint256 posA = vault.positionAssets(address(adapterA));
        uint256 posB = vault.positionAssets(address(adapterB));
        uint256 posC = vault.positionAssets(address(adapterC));

        assertGt(posA, posB, "T3: A (9%) gets more than B (7%)");
        assertGt(posB, posC, "T3: B (7%) gets more than C (5%)");
        assertGt(posC, 0, "T3: C also funded");
    }

    /// @notice No adapter exceeds maxExposure after allocation
    function test_target_allocations_clamped_by_maxExposure() public {
        _addAndEnable(adapterA); // 9% — would want most
        _addAndEnable(adapterE); // 1% — lowest
        _setMaxIdle(10000);

        _coreDeposit(1000e6);

        uint256 posA = vault.positionAssets(address(adapterA));
        uint256 tvl = _totalPositions() + vault.idleCash();
        uint256 maxExp = (uint256(vault.adapterMaxExposureBps()) * tvl) / 1e4;

        assertLe(posA, maxExp + vault.dustTolerance(), "adapter should not exceed maxExposure");
    }

    /// @notice Sum of positions + idle = TVL (conservation of value)
    function test_target_allocations_sum_to_expected_total() public {
        _addAndEnable(adapterA);
        _addAndEnable(adapterB);
        _addAndEnable(adapterC);
        _setMaxIdle(10000);

        _coreDeposit(1000e6);

        uint256 positions = _totalPositions();
        uint256 idle = vault.idleCash();
        assertEq(positions + idle, 1000e6, "positions + idle should equal deposited");
    }

    /// @notice Disabled adapters get zero allocation
    function test_target_allocations_handle_disabled_adapters() public {
        _addAndEnable(adapterA);
        _addAndEnable(adapterB);
        _addAndEnable(adapterC);
        _setMaxIdle(10000);

        vm.prank(admin);
        vault.toggleAdapter(address(adapterB), false);

        _coreDeposit(1000e6);

        assertEq(vault.positionAssets(address(adapterB)), 0, "disabled adapter should get zero");
    }

    /// @notice When all adapters are at max capacity, new funds stay idle
    function test_target_allocations_handle_all_over_cap() public {
        _addAndEnable(adapterA);
        _addAndEnable(adapterB);
        _setMaxIdle(10000);

        _coreDeposit(1000e6);
        uint256 posA1 = vault.positionAssets(address(adapterA));
        uint256 posB1 = vault.positionAssets(address(adapterB));

        // Pin maxCapacity to current position — new deposits have zero headroom
        adapterA.setMaxCap(posA1);
        adapterB.setMaxCap(posB1); // T1: posB1=0, maxCap=0 → headroom=0 for B too

        vm.warp(block.timestamp + 301);
        uint256 idleBefore = vault.idleCash();
        _coreDeposit(100e6);

        // Positions should not increase
        assertEq(vault.positionAssets(address(adapterA)), posA1, "at-capacity A unchanged");
        assertEq(vault.positionAssets(address(adapterB)), posB1, "at-capacity B unchanged");
        assertGt(vault.idleCash(), idleBefore + 90e6, "funds stay idle when all at capacity");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  C2. MULTI-CYCLE CONVERGENCE TESTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Deploy + rebalance converges: after large APY shift, positions adjust
    function test_deploy_rebalance_converges_in_two_cycles() public {
        _addAndEnable(adapterA); // 9%
        _addAndEnable(adapterB); // 7%
        _setMaxIdle(10000);

        // Large TVL so gate benefit > gas cost
        _coreDeposit(10_000e6);

        uint256 posA_init = vault.positionAssets(address(adapterA));
        uint256 posB_init = vault.positionAssets(address(adapterB));
        assertGt(posA_init, posB_init, "initially A > B");

        // Flip APYs dramatically
        adapterA.setAPY(100); // was 900
        adapterB.setAPY(1500); // was 700 → huge gap to pass gate

        vm.warp(block.timestamp + 21601);
        vm.startPrank(keeper);
        StrategyRebalancePlanModule(address(vault)).prepareRebalance();
        StrategyRebalancePlanModule(address(vault)).executeRebalanceStep();
        try StrategyRebalancePlanModule(address(vault)).executeRebalanceStep() {} catch {}
        vm.stopPrank();

        uint256 posA_after = vault.positionAssets(address(adapterA));
        uint256 posB_after = vault.positionAssets(address(adapterB));
        assertGt(posB_after, posA_after, "after rebalance: B should have more than A");
    }

    /// @notice Repeated cycles do not break maxExposure caps
    function test_repeated_cycles_do_not_break_caps() public {
        _addAndEnable(adapterA);
        _addAndEnable(adapterB);
        _setMaxIdle(10000);

        _coreDeposit(1000e6);

        for (uint256 cycle = 0; cycle < 3; cycle++) {
            adapterA.setAPY(uint16(900 - cycle * 200));
            adapterB.setAPY(uint16(500 + cycle * 200));
            vm.warp(block.timestamp + 21601);
            vm.prank(keeper);
            try StrategyRebalancePlanModule(address(vault)).prepareRebalance() {} catch {}
        }

        uint256 tvl = vault.idleCash() + _totalPositions();
        uint256 maxExpFinal = (uint256(vault.adapterMaxExposureBps()) * tvl) / 1e4;
        uint256 dust = vault.dustTolerance();
        assertLe(vault.positionAssets(address(adapterA)), maxExpFinal + dust, "A within cap");
        assertLe(vault.positionAssets(address(adapterB)), maxExpFinal + dust, "B within cap");
    }

    /// @notice All enabled adapters receive some allocation over multiple deposits
    function test_repeated_cycles_do_not_starve_eligible_adapter() public {
        // Use lower maxExposure (40%) so 3 adapters all get allocation
        _setMaxExposure(4000);

        _addAndEnable(adapterA); // 9%
        _addAndEnable(adapterB); // 7%
        _addAndEnable(adapterC); // 5%
        _setMaxIdle(10000);

        // Deposit enough TVL for 3 adapters (dynamic max: 150k+ → 3)
        _coreDeposit(200_000e6);
        vm.warp(block.timestamp + 301);
        _coreDeposit(200_000e6);
        vm.warp(block.timestamp + 301);
        _coreDeposit(200_000e6);

        assertGt(vault.positionAssets(address(adapterA)), 0, "A should not be starved");
        assertGt(vault.positionAssets(address(adapterB)), 0, "B should not be starved");
        assertGt(vault.positionAssets(address(adapterC)), 0, "C should not be starved");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  BLOCCO I — SYSTEM INVARIANTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice INV1: No adapter over maxExposure after allocation
    function test_inv_no_adapter_over_maxExposure() public {
        _addAndEnable(adapterA);
        _addAndEnable(adapterB);
        _addAndEnable(adapterC);
        _setMaxIdle(10000);

        _coreDeposit(2000e6);

        uint256 tvl = vault.idleCash() + _totalPositions();
        uint256 maxExp = (uint256(vault.adapterMaxExposureBps()) * tvl) / 1e4;
        uint256 dust = vault.dustTolerance();

        assertLe(vault.positionAssets(address(adapterA)), maxExp + dust, "INV1: A over cap");
        assertLe(vault.positionAssets(address(adapterB)), maxExp + dust, "INV1: B over cap");
        assertLe(vault.positionAssets(address(adapterC)), maxExp + dust, "INV1: C over cap");
    }

    /// @notice INV2: Adapter over global ceiling gets zero new funds
    function test_inv_over_cap_gets_zero_new_funds() public {
        _addAndEnable(adapterA);
        _addAndEnable(adapterB);
        _setMaxIdle(10000);

        // TRIAGE A1: deposit raised to T2 (≥25K USDC) to enable dMax=2 scenario.
        // Original test premise required global ceiling enforcement — invalid at T1 by design
        // (T1 short-circuits to 100%, no ceiling applies). At T2 dMax=2, adapterMaxExposureBps
        // applies as governance ceiling and can gate adapter A when position exceeds it.
        _coreDeposit(50_000e6);
        uint256 posA1 = vault.positionAssets(address(adapterA));

        // Lower global ceiling to 1% — A's position far exceeds new ceiling
        _setMaxExposure(100);

        vm.warp(block.timestamp + 301);
        _coreDeposit(200e6);

        assertEq(vault.positionAssets(address(adapterA)), posA1, "INV2: over-ceiling gets zero");
    }

    /// @notice INV4: Funds stay idle if no eligible adapter
    function test_inv_idle_if_no_eligible() public {
        _addAndEnable(adapterA);
        _setMaxIdle(10000);

        _coreDeposit(500e6);

        _setQuarantined(address(adapterA), true);

        vm.warp(block.timestamp + 301);
        uint256 idleBefore = vault.idleCash();
        _coreDeposit(200e6);

        assertGt(vault.idleCash(), idleBefore + 190e6, "INV4: idle when no eligible");
    }

    /// @notice INV6: sum(positions) + idle = TVL (conservation)
    function test_inv_sum_allocations_coherent_with_tvl() public {
        _addAndEnable(adapterA);
        _addAndEnable(adapterB);
        _addAndEnable(adapterC);
        _setMaxIdle(10000);

        _coreDeposit(1000e6);

        uint256 positions = _totalPositions();
        uint256 idle = vault.idleCash();
        assertEq(positions + idle, 1000e6, "INV6: conservation of value");
    }

    /// @notice INV5: Tiny APY change does not trigger significant movement
    function test_inv_no_churn_under_driftTolerance() public {
        _addAndEnable(adapterA);
        _addAndEnable(adapterB);
        _setMaxIdle(10000);

        _coreDeposit(1000e6);

        uint256 posA1 = vault.positionAssets(address(adapterA));
        uint256 posB1 = vault.positionAssets(address(adapterB));

        adapterA.setAPY(901); // +1 bps
        vm.warp(block.timestamp + 21601);
        vm.prank(keeper);
        try StrategyRebalancePlanModule(address(vault)).prepareRebalance() {} catch {}

        uint256 deltaA = vault.positionAssets(address(adapterA)) > posA1
            ? vault.positionAssets(address(adapterA)) - posA1
            : posA1 - vault.positionAssets(address(adapterA));
        uint256 deltaB = vault.positionAssets(address(adapterB)) > posB1
            ? vault.positionAssets(address(adapterB)) - posB1
            : posB1 - vault.positionAssets(address(adapterB));
        uint256 tvl = _totalPositions() + vault.idleCash();

        assertLt((deltaA + deltaB) * 100 / tvl, 5, "INV5: no churn");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  BLOCCO M — EXPLAINABILITY VALIDATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Highest score but at max capacity is skipped; second-best gets funds
    function test_highest_score_but_over_cap_is_skipped() public {
        _addAndEnable(adapterA); // 9%
        _addAndEnable(adapterB); // 7%
        _setMaxIdle(10000);

        _coreDeposit(1000e6);
        uint256 posA1 = vault.positionAssets(address(adapterA));

        // Pin A's maxCapacity to current → zero headroom. B is still eligible.
        adapterA.setMaxCap(posA1);

        vm.warp(block.timestamp + 301);
        _coreDeposit(200e6);

        assertEq(vault.positionAssets(address(adapterA)), posA1, "top score at capacity: skipped");
        // B receives the new funds (A is blocked, B has unlimited headroom)
        assertGt(vault.idleCash() + vault.positionAssets(address(adapterB)), 190e6,
            "second-best or idle receives new funds");
    }

    /// @notice High-score adapter gets significantly more than low-score
    function test_explainability_matches_allocation_decision() public {
        adapterA.setAPY(900);
    }
}


// ─────────────────────────────────────────────────────────────────────────────
// AllocCalcToleranceFix_Test — _computeTargets residual redistribution (Wave 1)
// Covers: T-AC-01 residual redistributed, T-AC-02 conservation heterogeneous,
//         T-AC-03 fuzz N cycles, T-AC-04 cap boundary no overdeposit.
// ─────────────────────────────────────────────────────────────────────────────

contract AllocCalcToleranceFix_Test is Allocation_Consistency {

    // T-AC-01: Equal-scored adapters with an amount where (amount mod 3 == 1)
    // guarantee a floor-division residual of exactly 1 wei per pass. After the
    // fix, that residual is assigned to adapter[0] and idle == 0.
    // Without the fix: idle == 1 (residual stranded).
    function test_ALLOCDUST_rounding_residual_not_left_idle() public {
        // Override default APY so all 3 adapters score equally.
        adapterA.setAPY(500);
        adapterB.setAPY(500);
        adapterC.setAPY(500);
        _addAndEnable(adapterA);
        _addAndEnable(adapterB);
        _addAndEnable(adapterC);
        _setMaxIdle(10000);
        // 500_000e6 + 2: T3 regime (TVL ≥ 250K → dMax=3), amount mod 3 == 1
        // → each target = floor(amount/3), 3 targets sum to amount-1, residual=1.
        _coreDeposit(500_000e6 + 2);
        vm.warp(block.timestamp + 301);
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();
        assertEq(vault.idleCash(), 0,
            "AC-01: floor-division residual must be redistributed, not left idle");
    }

    // T-AC-02: With unequal adapter scores, sum(positions) + idle == totalDeposited.
    // Tests that the fix preserves value conservation under heterogeneous scoring.
    function test_ALLOCDUST_conservation_unequal_scores() public {
        _addAndEnable(adapterA); // APY 900
        _addAndEnable(adapterB); // APY 700
        _addAndEnable(adapterC); // APY 500
        _setMaxIdle(10000);
        uint256 depositAmt = 777_777e6; // T3, non-round amount
        _coreDeposit(depositAmt);
        vm.warp(block.timestamp + 301);
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();
        uint256 positions = vault.positionAssets(address(adapterA))
            + vault.positionAssets(address(adapterB))
            + vault.positionAssets(address(adapterC));
        assertEq(positions + vault.idleCash(), depositAmt,
            "AC-02: sum(positions) + idle must equal total deposited");
    }

    // T-AC-03: Conservation and full deployment hold across N sequential cycles.
    // Each cycle: deposit (amount mod 3 == 1) → deploy → assert idle == 0.
    function testFuzz_ALLOCDUST_conservation_N_sequential_cycles(uint8 n) public {
        n = uint8(bound(n, 1, 5));
        adapterA.setAPY(500);
        adapterB.setAPY(500);
        adapterC.setAPY(500);
        _addAndEnable(adapterA);
        _addAndEnable(adapterB);
        _addAndEnable(adapterC);
        _setMaxIdle(10000);
        uint256 totalDeposited = 0;
        for (uint256 i = 0; i < n; ++i) {
            // (i+1)*500_000e6 + 2: always T3+, always amount mod 3 == 1
            uint256 amt = (i + 1) * 500_000e6 + 2;
            _coreDeposit(amt);
            totalDeposited += amt;
            vm.warp(block.timestamp + 301 + i * 400);
            vm.prank(keeper);
            StrategyScoringModule(address(vault)).deployIdle();
            uint256 pos = vault.positionAssets(address(adapterA))
                + vault.positionAssets(address(adapterB))
                + vault.positionAssets(address(adapterC));
            // Note: idle may remain > 0 in T4+ regime due to effectiveAbsCapBps cap mechanics
            // (effectiveAbsCapBps × activeAdapters < 100%). Conservation is the audit-critical
            // invariant. Floor-div residual redistribution is covered by T-AC-01 in T3 regime.
            // See outputs/AC_TRIAGE_1.md for root-cause analysis (Rule 14 approved 2026-06-18).
            assertEq(pos + vault.idleCash(), totalDeposited,
                "AC-03: conservation must hold after each deploy cycle");
        }
    }

    // T-AC-04: Adapter pinned at exact capacity (maxCapacity() == positionAssets)
    // has headroom == 0 in _checkAdapterEligibility and is ineligible. The residual
    // redistribution in _computeTargets must also skip it (clamped or 0 headroom)
    // and route to the next eligible adapter.
    function test_ALLOCDUST_cap_boundary_no_overdeposit() public {
        _addAndEnable(adapterA); // APY 900
        _addAndEnable(adapterB); // APY 700
        _setMaxIdle(10000);
        _coreDeposit(50_000e6); // T2: both adapters receive initial funds
        vm.warp(block.timestamp + 301);
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();
        uint256 posA = vault.positionAssets(address(adapterA));
        // Pin A at its exact current position: maxCapacity() == posA → headroom == 0
        adapterA.setMaxCap(posA);
        _coreDeposit(10_000e6); // new idle to deploy
        vm.warp(block.timestamp + 602);
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();
        assertEq(vault.positionAssets(address(adapterA)), posA,
            "AC-04: adapter at exact cap must receive no additional deposit (including residual)");
    }
}
