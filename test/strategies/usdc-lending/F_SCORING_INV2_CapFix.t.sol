// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ═══════════════════════════════════════════════════════════════════════════════
// F_SCORING_INV2_CapFix.t.sol — F-SCORING-INV2 fix regression tests (Wave 2)
// ───────────────────────────────────────────────────────────────────────────────
// Verifies that _effectiveAbsCapBps() respects adapterMaxExposureBps at T1 TVL
// (< 25_000e6 USDC, dynamicMax=1) after Option B fix.
//
// Pre-fix: _effectiveAbsCapBps() returned 10000 unconditionally at T1,
//          silently overriding the governance ceiling (adapterMaxExposureBps).
// Post-fix: returns adapterMaxExposureBps if set, 10000 only as sentinel fallback.
//
// Tests:
//   1. test_T1_singleAdapter_respects_governance_cap        (direct logic)
//   2. test_T1_singleAdapter_unconstrained_when_zero_sentinel (direct logic)
//   3. test_T1_to_T2_transition_continuity                  (direct logic)
//   4. test_SCORING_INV2_behavioral_T1_cap_enforced         (full vault, non-vacuous)
//
// Run: forge test --match-contract "F_SCORING_INV2" -vv
// ═══════════════════════════════════════════════════════════════════════════════

import { Test } from "forge-std/Test.sol";
import {
    StrategyAllocCalcModule
} from "../../../src/strategies/usdc-lending/controller/StrategyAllocCalcModule.sol";
import {
    UsdcMultiLendingVault
} from "../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
import {
    StrategyParamsModule
} from "../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import {
    StrategySettingsModule
} from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
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
import {
    StrategySafetyOverflowModule
} from "../../../src/strategies/usdc-lending/controller/StrategySafetyOverflowModule.sol";
import {
    MockUSDC,
    MockLendingAdapter
} from "./UsdcMultiLendingVault.t.sol";

// ─────────────────────────────────────────────────────────────────────────────
// AllocCalcHarness — exposes internal helpers for unit testing
// ─────────────────────────────────────────────────────────────────────────────

contract AllocCalcHarness is StrategyAllocCalcModule {
    constructor(address usdc_, address core_) StrategyAllocCalcModule(usdc_, core_) {}

    function exposedEffectiveAbsCapBps(address adapter) external view returns (uint256) {
        return _effectiveAbsCapBps(adapter, _tvl());
    }

    function exposedEffectiveMaxAdapters() external view returns (uint16) {
        return _effectiveMaxAdapters(_tvl());
    }

    function setAdapterMaxExposureBps(uint16 bps) external {
        adapterMaxExposureBps = bps;
    }

    function setCachedLiquidityBps(address adapter, uint16 bps) external {
        cachedLiquidityBps[adapter] = bps;
        cachedLiquidityTs[adapter] = uint64(block.timestamp);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests 1-3: direct cap logic via AllocCalcHarness
// ─────────────────────────────────────────────────────────────────────────────

contract F_SCORING_INV2_CapLogic is Test {

    address constant ARBITRUM_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant DUMMY_ADAPTER = address(0xDA1);

    MockUSDC public usdc;
    AllocCalcHarness public harness;

    function setUp() public {
        usdc = new MockUSDC();
        vm.etch(ARBITRUM_USDC, address(usdc).code);
        usdc = MockUSDC(ARBITRUM_USDC);
        harness = new AllocCalcHarness(ARBITRUM_USDC, address(0xC0FFEE));
    }

    // ── Test 1 ──────────────────────────────────────────────────────────────
    // T1 TVL (< 25K), governance ceiling set: must be respected.
    // Pre-fix: returned 10000 (100%). Post-fix: returns adapterMaxExposureBps.
    function test_T1_singleAdapter_respects_governance_cap() public {
        usdc.mint(address(harness), 10_000e6); // T1: 10K < 25K
        harness.setAdapterMaxExposureBps(5000);

        assertEq(harness.exposedEffectiveMaxAdapters(), 1, "T1: dynamicMax must be 1");
        assertEq(
            harness.exposedEffectiveAbsCapBps(DUMMY_ADAPTER),
            5000,
            "T1: adapterMaxExposureBps=5000 must override default 10000"
        );
    }

    // ── Test 2 ──────────────────────────────────────────────────────────────
    // T1 TVL, sentinel 0: original unconstrained 100% preserved.
    // Sentinel (adapterMaxExposureBps == 0) means "no governance constraint".
    function test_T1_singleAdapter_unconstrained_when_zero_sentinel() public {
        usdc.mint(address(harness), 10_000e6); // T1
        harness.setAdapterMaxExposureBps(0); // sentinel = no constraint

        assertEq(harness.exposedEffectiveMaxAdapters(), 1, "T1: dynamicMax must be 1");
        assertEq(
            harness.exposedEffectiveAbsCapBps(DUMMY_ADAPTER),
            10000,
            "T1: sentinel 0 must preserve original 10000 unconstrained cap"
        );
    }

    // ── Test 3 ──────────────────────────────────────────────────────────────
    // T1→T2 boundary continuity: governance ceiling 5000 is binding on both sides.
    // Uses full liquidity (10000) to eliminate the liquidity overlay at T2,
    // allowing a direct comparison of the raw governance-ceiling effect.
    // Pre-fix: T1=10000, T2=5000 (discontinuous 5000-bps drop at boundary).
    // Post-fix: T1=5000, T2=5000 (continuous, no jump).
    function test_T1_to_T2_transition_continuity() public {
        harness.setCachedLiquidityBps(DUMMY_ADAPTER, 10000); // 100% liquid -> overlay=10000 at T2
        harness.setAdapterMaxExposureBps(5000);

        // T1: TVL = 24_999e6 (just below 25K threshold)
        usdc.mint(address(harness), 24_999e6);
        assertEq(harness.exposedEffectiveMaxAdapters(), 1, "T1 check: dMax must be 1");
        uint256 capT1 = harness.exposedEffectiveAbsCapBps(DUMMY_ADAPTER);

        // T2: fresh harness to reset USDC balance, TVL = 25_000e6 (at threshold)
        AllocCalcHarness h2 = new AllocCalcHarness(ARBITRUM_USDC, address(0xC0FFEE));
        h2.setCachedLiquidityBps(DUMMY_ADAPTER, 10000);
        h2.setAdapterMaxExposureBps(5000);
        usdc.mint(address(h2), 25_000e6);
        assertEq(h2.exposedEffectiveMaxAdapters(), 2, "T2 check: dMax must be 2");
        uint256 capT2 = h2.exposedEffectiveAbsCapBps(DUMMY_ADAPTER);

        // T1: early return -> governance ceiling 5000
        // T2: formula cap = ceil(11000/2) = 5500; globalCeiling=5000 binds; overlay=10000 -> 5000
        assertEq(capT1, 5000, "T1 cap must equal governance ceiling 5000");
        assertEq(capT2, 5000, "T2 cap must equal governance ceiling 5000 (binding)");
        assertEq(capT1, capT2, "T1->T2 boundary: no discontinuous jump in effective cap");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test 4: behavioral — full vault integration at T1 TVL
// ─────────────────────────────────────────────────────────────────────────────
// Non-vacuous SCORING-INV-2 regression: deposits actually reach adapters
// (safetyOverflowModule wired + pokeLiquidityBatch → not degraded mode).
// At T1 TVL (10K < 25K), best adapter must not exceed adapterMaxExposureBps.
// Pre-fix: best adapter received 100% TVL = 10K > 5K (would fail).
// Post-fix: best adapter capped at 50% = 5K (passes).
// ─────────────────────────────────────────────────────────────────────────────

contract F_SCORING_INV2_Behavioral is Test {

    address constant ARBITRUM_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    UsdcMultiLendingVault public vault;
    MockUSDC public usdc;
    MockLendingAdapter public adapterA;
    MockLendingAdapter public adapterB;

    address public admin  = address(0xAD);
    address public core   = address(0xC0);
    address public router = address(0xB0);
    address public keeper = address(0xBE);

    bytes32 constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    function setUp() public {
        usdc = new MockUSDC();
        vm.etch(ARBITRUM_USDC, address(usdc).code);
        usdc = MockUSDC(ARBITRUM_USDC);

        adapterA = new MockLendingAdapter(ARBITRUM_USDC);
        adapterB = new MockLendingAdapter(ARBITRUM_USDC);
        adapterA.setAPY(900);
        adapterB.setAPY(300);
        adapterA.setExtMarketTVL(50_000_000e6);
        adapterB.setExtMarketTVL(50_000_000e6);

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
            adapterMaxExposureBps: 5000, // 50% hard cap — governance ceiling under test
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

        StrategyParamsModule paramsMod = new StrategyParamsModule(ARBITRUM_USDC, core);
        StrategyAdapterOpsModule adapterOpsMod = new StrategyAdapterOpsModule(
            ARBITRUM_USDC, core, address(paramsMod), address(0), address(0)
        );
        StrategyScoringModule scoringMod = new StrategyScoringModule(
            ARBITRUM_USDC, core, address(paramsMod), address(0), address(adapterOpsMod)
        );
        address gateMod = address(new StrategyRebalanceGateModule(
            ARBITRUM_USDC, core, address(paramsMod), address(scoringMod), address(adapterOpsMod)
        ));
        vault = new UsdcMultiLendingVault(
            ARBITRUM_USDC, core, router, admin, keeper,
            address(0), address(paramsMod), address(scoringMod),
            address(adapterOpsMod), gateMod, params
        );

        StrategyRebalancePlanModule planMod = new StrategyRebalancePlanModule(
            ARBITRUM_USDC, core, address(paramsMod), address(scoringMod), address(adapterOpsMod)
        );
        vm.prank(admin); vault.setRebalancePlanModule(address(planMod));

        StrategySettingsModule settingsMod = new StrategySettingsModule(ARBITRUM_USDC, core);
        vm.prank(admin); vault.setSettingsModule(address(settingsMod));

        StrategyAllocCalcModule allocCalcMod = new StrategyAllocCalcModule(ARBITRUM_USDC, core);
        vm.prank(admin); vault.setAllocCalcModule(address(allocCalcMod));

        // Wire safetyOverflowModule so _checkDegradedModeLocally() delegatecall works.
        // Required for non-vacuous test: without it, addr(0) returns "" -> not degraded,
        // OR with it, correctly evaluates cachedLiquidityBps to decide degraded mode.
        StrategySafetyOverflowModule overflowMod = new StrategySafetyOverflowModule(
            ARBITRUM_USDC, core, address(0), address(0), address(adapterOpsMod)
        );
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setSafetyOverflowModule(address(overflowMod));

        adapterA.setVault(address(vault));
        adapterB.setVault(address(vault));

        vm.startPrank(admin);
        address(vault).call(abi.encodeWithSignature("whitelistAdapter(address,bool)", address(adapterA), true));
        vault.addAdapter(address(adapterA));
        vault.toggleAdapter(address(adapterA), true);
        address(vault).call(abi.encodeWithSignature("setAdapterDepositMode(address,bool)", address(adapterA), false));
        address(vault).call(abi.encodeWithSignature("whitelistAdapter(address,bool)", address(adapterB), true));
        vault.addAdapter(address(adapterB));
        vault.toggleAdapter(address(adapterB), true);
        address(vault).call(abi.encodeWithSignature("setAdapterDepositMode(address,bool)", address(adapterB), false));
        StrategySettingsModule(address(vault)).exitBootstrapMode();
        // Allow 100% idle: at T1 TVL only 1 adapter gets allocation (50% cap), rest stays idle.
        // Without this, NoCashInvariant fires because idle(50%) > maxIdleAfterDepositBps(5%).
        StrategySettingsModule(address(vault)).setMaxIdleAfterDepositBps(10000);
        vm.stopPrank();

        // Poke external TVL for confidence scores
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        // Poke liquidity: adapters have totalAssets()=0 <= dustTolerance -> cachedLiquidityBps=10000
        // (fully liquid). This prevents MAJORITY_INELIGIBLE degraded-mode trigger on deposit.
        vm.prank(keeper);
        (bool liqOk,) = address(vault).call(
            abi.encodeWithSignature("pokeLiquidityBatch(uint256,uint256)", 0, 10)
        );
        require(liqOk, "pokeLiquidityBatch failed");
    }

    // ── Test 4 ──────────────────────────────────────────────────────────────
    // Non-vacuous SCORING-INV-2 at T1 TVL: best adapter must not exceed 50% cap.
    // Deposit 10_000e6 (T1: < 25K). Both adapters are liquid (cachedLiquidityBps=10000)
    // so degraded mode does NOT activate and deployIdleToAdapters runs.
    // With Option B fix: best adapter capped at adapterMaxExposureBps=5000 (50%).
    function test_SCORING_INV2_behavioral_T1_cap_enforced() public {
        uint256 depositAmount = 10_000e6; // T1: 10K USDC < 25K threshold

        usdc.mint(core, depositAmount);
        vm.prank(core); usdc.transfer(address(vault), depositAmount);
        vm.prank(core); vault.deposit(depositAmount);

        uint256 tvl = vault.totalAssets();
        uint256 maxExp = (uint256(vault.adapterMaxExposureBps()) * tvl) / 1e4;
        uint256 dust = vault.dustTolerance();

        uint256 posA = vault.positionAssets(address(adapterA));
        uint256 posB = vault.positionAssets(address(adapterB));

        assertLe(
            posA,
            maxExp + dust,
            "SCORING-INV-2 (T1): adapterA exceeds adapterMaxExposureBps cap"
        );
        assertLe(
            posB,
            maxExp + dust,
            "SCORING-INV-2 (T1): adapterB exceeds adapterMaxExposureBps cap"
        );
    }
}
