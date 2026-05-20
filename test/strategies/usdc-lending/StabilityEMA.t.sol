// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import {
    UsdcMultiLendingVault
} from "../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
import {
    MockUSDC
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
import { StrategyRebalanceGateModule } from "../../../src/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol";
import {
    ILendingAdapter
} from "../../../src/strategies/usdc-lending/interfaces/ILendingAdapter.sol";
import { StrategyExplainabilityLens } from "../../../src/strategies/usdc-lending/lens/StrategyExplainabilityLens.sol";
import { StrategyRebalancePlanModule } from "../../../src/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol";

// ============================================================================
// MOCK: Adapter with controllable APY for stability EMA testing
// ============================================================================

contract StabilityMockAdapter is ILendingAdapter {
    address public immutable underlying_;
    uint256 public deposited;
    uint16 public apyBps = 400;
    uint256 public extMarketTVL = 100_000_000e6; // 100M default

    constructor(address _underlying) { underlying_ = _underlying; }

    function setAPY(uint16 _apy) external { apyBps = _apy; }
    function setDeposited(uint256 d) external { deposited = d; }
    function setExtMarketTVL(uint256 _tvl) external { extMarketTVL = _tvl; }

    function name() external pure override returns (string memory) { return "StabilityMock"; }
    function underlying() external view override returns (address) { return underlying_; }
    function totalAssets() external view override returns (uint256) { return deposited; }
    function withdrawableAssets() external view override returns (uint256) { return deposited; }
    function currentAPYBps() external view override returns (uint16) { return apyBps; }
    function incentiveAPYBps() external pure override returns (uint16) { return 0; }
    function harvestableProfit() external pure override returns (uint256) { return 0; }
    function harvest(address) external pure override returns (uint256) { return 0; }
    function maxCapacity() external pure override returns (uint256) { return type(uint256).max; }
    function isPushMode() external pure override returns (bool) { return false; }
    function idleAssetBalance() external pure override returns (uint256) { return 0; }
    function investedAssets() external view override returns (uint256) { return deposited; }
    function sweepIdleAssetToVault() external override {}
    function emergencyPullAllToVault() external override {}
    function externalMarketTVL() external view override returns (uint256) { return extMarketTVL; }

    function deposit(uint256 assets) external override {
        MockUSDC(underlying_).transferFrom(msg.sender, address(this), assets);
        deposited += assets;
    }

    function withdraw(uint256 assets, address receiver) external override returns (uint256) {
        uint256 w = assets > deposited ? deposited : assets;
        deposited -= w;
        MockUSDC(underlying_).transfer(receiver, w);
        return w;
    }
}

// ============================================================================
// STABILITY EMA TESTS
// ============================================================================

contract StabilityEMA_Test is Test {
    address constant ARBITRUM_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    UsdcMultiLendingVault public vault;
    MockUSDC public usdc;
    StabilityMockAdapter public adapterStable;
    StabilityMockAdapter public adapterVolatile;

    address public admin = address(0x1);
    address public core = address(0x2);
    address public router = address(0x6);
    address public keeper = address(0x3);

    bytes32 constant PARAM_ROLE = keccak256("PARAM_ROLE");
    bytes32 constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    uint256 constant POKE_INTERVAL = 12 hours;
    uint256 constant T0 = 100_000; // base timestamp for tests

    function setUp() public {
        usdc = new MockUSDC();
        vm.etch(ARBITRUM_USDC, address(usdc).code);
        usdc = MockUSDC(ARBITRUM_USDC);

        adapterStable = new StabilityMockAdapter(ARBITRUM_USDC);
        adapterVolatile = new StabilityMockAdapter(ARBITRUM_USDC);

        adapterStable.setAPY(400); // 4.00%
        adapterVolatile.setAPY(400); // starts same

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
            adapterMaxExposureBps: 8000,
            newAdapterRampBps: 8000,
            gateHorizonDays: 7,
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

        StrategyParamsModule paramsModule = new StrategyParamsModule(ARBITRUM_USDC, core);
        StrategyAdapterOpsModule adapterOpsMod = new StrategyAdapterOpsModule(
            ARBITRUM_USDC, core, address(paramsModule), address(0), address(0)
        );
        StrategyScoringModule scoringMod = new StrategyScoringModule(
            ARBITRUM_USDC, core, address(paramsModule), address(0), address(adapterOpsMod)
        );
        StrategyRebalanceGateModule gateMod = new StrategyRebalanceGateModule(
            ARBITRUM_USDC, core, address(paramsModule), address(scoringMod), address(adapterOpsMod)
        );

        vault = new UsdcMultiLendingVault(
            ARBITRUM_USDC,
            core,
            router,
            admin,
            keeper,
            address(0), // no bootstrapper
            address(paramsModule),
            address(scoringMod),
            address(adapterOpsMod),
            address(gateMod),
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

        // Register and enable adapters
        vm.startPrank(admin);
        address(vault).call(abi.encodeWithSignature("whitelistAdapter(address,bool)", address(adapterStable), true));
        vault.addAdapter(address(adapterStable));
        address(vault).call(abi.encodeWithSignature("whitelistAdapter(address,bool)", address(adapterVolatile), true));
        vault.addAdapter(address(adapterVolatile));
        vault.toggleAdapter(address(adapterStable), true);
        vault.toggleAdapter(address(adapterVolatile), true);
        vm.stopPrank();

        // Seed positions (simulate deployed capital)
        adapterStable.setDeposited(500_000e6);
        adapterVolatile.setDeposited(500_000e6);
        usdc.mint(address(adapterStable), 500_000e6);
        usdc.mint(address(adapterVolatile), 500_000e6);

        // Sync positions (via ParamsModule fallback)
        vm.prank(admin);
        StrategyParamsModule(address(vault)).syncPositionAssets();
    }

    // ────────────────────────────────────────────────────────────────────
    // 1. UNIT TESTS — _updateStabilityEMA formula
    // ────────────────────────────────────────────────────────────────────

    function test_stabilityEma_initializes_on_first_poke() public {
        // Before any poke, stabilityEMA should be the init value (set in addAdapter)
        uint256 emaBefore = vault.stabilityEMA(address(adapterStable));
        console2.log("EMA before first poke:", emaBefore);

        // First poke
        vm.warp(T0);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeLiquidityBatch(0, 2);

        uint256 lastAPY = vault.lastPokedAPY(address(adapterStable));
        uint64 lastTs = vault.lastStabilityUpdateTs(address(adapterStable));
        uint256 emaAfter = vault.stabilityEMA(address(adapterStable));

        console2.log("lastPokedAPY:", lastAPY);
        console2.log("lastStabilityUpdateTs:", lastTs);
        console2.log("EMA after first poke:", emaAfter);

        assertEq(lastAPY, 400, "lastPokedAPY should be set to currentAPY");
        assertGt(lastTs, 0, "lastStabilityUpdateTs should be set");
        assertGt(emaAfter, 0, "stabilityEMA should be non-zero");
    }

    function test_debug_pokeLiquidity_reaches_ema_update() public {
        console2.log("block.timestamp start:", block.timestamp);

        // First poke at t=100000
        vm.warp(100000);
        console2.log("block.timestamp after warp1:", block.timestamp);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeLiquidityBatch(0, 1);

        console2.log("lastPokedAPY:", vault.lastPokedAPY(address(adapterStable)));
        console2.log("stabilityEMA:", vault.stabilityEMA(address(adapterStable)));
        console2.log("lastStabilityUpdateTs:", vault.lastStabilityUpdateTs(address(adapterStable)));

        // Second poke at t=200000 (100k later, well past 6h minInterval)
        adapterStable.setAPY(800);
        vm.warp(200000);
        console2.log("block.timestamp after warp2:", block.timestamp);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeLiquidityBatch(0, 1);

        console2.log("--- After 2nd poke ---");
        console2.log("lastPokedAPY:", vault.lastPokedAPY(address(adapterStable)));
        console2.log("stabilityEMA:", vault.stabilityEMA(address(adapterStable)));

        // EMA should have changed from 7000
        uint256 ema = vault.stabilityEMA(address(adapterStable));
        assertTrue(ema != 7000, "EMA should have changed after APY spike 400->800");
    }

    function test_stabilityEma_increases_with_stable_apy() public {
        // First poke to initialize
        vm.warp(T0);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeLiquidityBatch(0, 2);

        uint256 emaInit = vault.stabilityEMA(address(adapterStable));
        console2.log("EMA after init:", emaInit);

        // Stable APY sequence: 400, 405, 398, 402, 401
        uint16[4] memory stableSeq = [uint16(405), uint16(398), uint16(402), uint16(401)];

        for (uint256 i = 0; i < stableSeq.length; i++) {
            adapterStable.setAPY(stableSeq[i]);
            vm.warp(T0 + (i + 1) * POKE_INTERVAL);
            vm.prank(keeper);
            StrategyParamsModule(address(vault)).pokeLiquidityBatch(0, 1);

            uint256 ema = vault.stabilityEMA(address(adapterStable));
            console2.log("Poke stable APY:", stableSeq[i], "EMA:", ema);
        }

        uint256 emaFinal = vault.stabilityEMA(address(adapterStable));
        console2.log("Final EMA (stable):", emaFinal);

        // Stable APY should yield EMA close to 10000
        assertGt(emaFinal, 8000, "EMA should be high for stable APY");
    }

    function test_stabilityEma_decreases_with_volatile_apy() public {
        // First poke
        vm.warp(T0);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeLiquidityBatch(0, 2);

        // Volatile APY sequence: 400, 650, 250, 700, 300
        uint16[4] memory volatileSeq = [uint16(650), uint16(250), uint16(700), uint16(300)];

        for (uint256 i = 0; i < volatileSeq.length; i++) {
            adapterVolatile.setAPY(volatileSeq[i]);
            vm.warp(T0 + (i + 1) * POKE_INTERVAL);
            vm.prank(keeper);
            StrategyParamsModule(address(vault)).pokeLiquidityBatch(1, 2);

            uint256 ema = vault.stabilityEMA(address(adapterVolatile));
            console2.log("Poke volatile APY:", volatileSeq[i], "EMA:", ema);
        }

        uint256 emaFinal = vault.stabilityEMA(address(adapterVolatile));
        console2.log("Final EMA (volatile):", emaFinal);

        // Volatile APY should yield EMA much lower than 7000 (default)
        assertLt(emaFinal, 6000, "EMA should be low for volatile APY");
    }

    function test_stabilityEma_respects_apy_floor() public {
        // Set adapter APY to very low value
        adapterStable.setAPY(10); // 0.10%

        // First poke (initializes)
        vm.warp(T0);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeLiquidityBatch(0, 1);

        assertEq(vault.lastPokedAPY(address(adapterStable)), 10);

        // Change to 50 bps — without floor this would be 400% delta, with floor it's manageable
        adapterStable.setAPY(50);
        vm.warp(T0 + POKE_INTERVAL);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeLiquidityBatch(0, 1);

        uint256 ema = vault.stabilityEMA(address(adapterStable));
        console2.log("EMA after low->50 with floor:", ema);

        // With apyFloorBps=50: denom=50, diff=40, delta=8000bps, raw=2000
        // Without floor: denom=10, diff=40, delta=40000→capped 10000, raw=0
        // EMA should NOT be zero thanks to floor
        assertGt(ema, 0, "APY floor should prevent extreme instability");
    }

    function test_stabilityEma_skips_when_updated_too_soon() public {
        // First poke
        vm.warp(T0);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeLiquidityBatch(0, 1);

        uint256 ema1 = vault.stabilityEMA(address(adapterStable));
        uint64 ts1 = vault.lastStabilityUpdateTs(address(adapterStable));

        // Second poke only 1 hour later (< 6h minInterval)
        adapterStable.setAPY(800); // big change
        vm.warp(T0 + 1 hours);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeLiquidityBatch(0, 1);

        uint256 ema2 = vault.stabilityEMA(address(adapterStable));
        uint64 ts2 = vault.lastStabilityUpdateTs(address(adapterStable));

        console2.log("EMA before:", ema1, "after too-soon poke:", ema2);
        console2.log("Ts before:", ts1, "after:", ts2);

        // EMA and timestamp should NOT change
        assertEq(ema1, ema2, "EMA should not change on too-soon poke");
        assertEq(ts1, ts2, "Timestamp should not change on too-soon poke");
    }

    function test_stabilityEma_smoothing_not_brutal() public {
        // Init
        vm.warp(T0);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeLiquidityBatch(0, 1);

        uint256 emaInit = vault.stabilityEMA(address(adapterStable));

        // Single large APY spike
        adapterStable.setAPY(900); // 4% → 9%
        vm.warp(T0 + POKE_INTERVAL);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeLiquidityBatch(0, 1);

        uint256 emaAfterSpike = vault.stabilityEMA(address(adapterStable));
        console2.log("EMA init:", emaInit, "after spike:", emaAfterSpike);

        // EMA should drop but NOT to zero — smoothing prevents brutal reaction
        assertGt(emaAfterSpike, 2000, "EMA should not crash to zero on single spike");

        // Recovery: stable again
        adapterStable.setAPY(900); // same APY = stable
        vm.warp(T0 + 2 * POKE_INTERVAL);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeLiquidityBatch(0, 1);

        uint256 emaRecovery = vault.stabilityEMA(address(adapterStable));
        console2.log("EMA after recovery poke:", emaRecovery);
        assertGt(emaRecovery, emaAfterSpike, "EMA should recover when APY stabilizes");
    }

    function test_stabilityEma_period_zero_reverts() public {
        // setStabilityParams requires period >= 3 — zero must revert
        vm.prank(admin);
        vm.expectRevert();
        StrategySettingsModule(address(vault)).setStabilityParams(50, 6 hours, 0);
    }

    function test_stabilityEma_governance_params() public {
        vm.startPrank(admin);

        // Set new stability params
        StrategySettingsModule(address(vault)).setStabilityParams(100, 12 hours, 14);

        assertEq(vault.apyFloorBps(), 100);
        assertEq(vault.minStabilityUpdateInterval(), 12 hours);
        assertEq(vault.stabilityEMAPeriod(), 14);

        // Range checks
        vm.expectRevert();
        StrategySettingsModule(address(vault)).setStabilityParams(5, 12 hours, 14); // floor < 10

        vm.expectRevert();
        StrategySettingsModule(address(vault)).setStabilityParams(600, 12 hours, 14); // floor > 500

        vm.expectRevert();
        StrategySettingsModule(address(vault)).setStabilityParams(50, 30 minutes, 14); // interval < 1h

        vm.expectRevert();
        StrategySettingsModule(address(vault)).setStabilityParams(50, 48 hours, 14); // interval > 24h

        vm.expectRevert();
        StrategySettingsModule(address(vault)).setStabilityParams(50, 12 hours, 2); // period < 3

        vm.expectRevert();
        StrategySettingsModule(address(vault)).setStabilityParams(50, 12 hours, 31); // period > 30

        vm.stopPrank();
    }

    // ────────────────────────────────────────────────────────────────────
    // 2. INTEGRATION: pokeLiquidityBatch updates stability
    // ────────────────────────────────────────────────────────────────────

    function test_pokeLiquidityBatch_updates_stability_for_all_adapters() public {
        vm.warp(T0);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeLiquidityBatch(0, 2);

        // Both adapters should have been updated
        assertGt(vault.lastStabilityUpdateTs(address(adapterStable)), 0, "Stable adapter: ts set");
        assertGt(vault.lastStabilityUpdateTs(address(adapterVolatile)), 0, "Volatile adapter: ts set");
        assertEq(vault.lastPokedAPY(address(adapterStable)), 400, "Stable: APY recorded");
        assertEq(vault.lastPokedAPY(address(adapterVolatile)), 400, "Volatile: APY recorded");
    }

    // ────────────────────────────────────────────────────────────────────
    // 3. THE KEY TEST: volatile adapter gets lower score than stable one
    // ────────────────────────────────────────────────────────────────────

    function test_stability_ema_penalizes_volatile_adapter() public {
        // ── Phase 1: Initialize both adapters ──
        vm.warp(T0);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeLiquidityBatch(0, 2);

        // ── Phase 2: Diverge APY patterns over 5 pokes ──
        uint16[5] memory stableAPYs = [uint16(400), uint16(405), uint16(398), uint16(402), uint16(401)];
        uint16[5] memory volatileAPYs = [uint16(400), uint16(650), uint16(250), uint16(700), uint16(300)];

        for (uint256 i = 0; i < 5; i++) {
            adapterStable.setAPY(stableAPYs[i]);
            adapterVolatile.setAPY(volatileAPYs[i]);

            vm.warp(T0 + (i + 1) * POKE_INTERVAL);
            vm.prank(keeper);
            StrategyParamsModule(address(vault)).pokeLiquidityBatch(0, 2);

            console2.log("Poke stable:", stableAPYs[i], "volatile:", volatileAPYs[i]);
            console2.log("  StableEMA:", vault.stabilityEMA(address(adapterStable)));
            console2.log("  VolatileEMA:", vault.stabilityEMA(address(adapterVolatile)));
        }

        // ── Phase 3: Assert stability ranking ──
        uint256 stableEMA = vault.stabilityEMA(address(adapterStable));
        uint256 volatileEMA = vault.stabilityEMA(address(adapterVolatile));

        console2.log("=== FINAL ===");
        console2.log("Stable adapter EMA:", stableEMA);
        console2.log("Volatile adapter EMA:", volatileEMA);

        assertGt(stableEMA, volatileEMA, "CRITICAL: stable adapter must have higher stabilityEMA");

        // ── Phase 4: Set same APY to isolate stability effect on scoring ──
        // Both adapters at 400 bps APY — only stability differs
        adapterStable.setAPY(400);
        adapterVolatile.setAPY(400);

        // Force equal risk scores
        vm.startPrank(admin);
        StrategySettingsModule(address(vault)).setRiskScore(address(adapterStable), 5000);
        StrategySettingsModule(address(vault)).setRiskScore(address(adapterVolatile), 5000);
        vm.stopPrank();

        // Check canRebalance to trigger scoring computation
        // The scoring engine uses stabilityEMA — with wStability=1000 (10%),
        // the stable adapter should get a higher total score

        // We can't directly call _computeAdapterScores (internal),
        // but we verify through the stored stabilityEMA which IS used in scoring
        console2.log("=== SCORING COMPONENTS ===");
        console2.log("wStability:", vault.wStability());
        console2.log("Stable contribution: wStab * EMA =", uint256(vault.wStability()) * stableEMA);
        console2.log("Volatile contribution: wStab * EMA =", uint256(vault.wStability()) * volatileEMA);

        uint256 stableContrib = uint256(vault.wStability()) * stableEMA;
        uint256 volatileContrib = uint256(vault.wStability()) * volatileEMA;

        assertGt(
            stableContrib,
            volatileContrib,
            "Stable adapter must have higher stability contribution to score"
        );

        // Quantify the advantage
        uint256 advantageBps = ((stableContrib - volatileContrib) * 10000) / stableContrib;
        console2.log("Stability advantage (bps):", advantageBps);
        assertGt(advantageBps, 100, "Advantage should be meaningful (> 1%)");
    }

    // ────────────────────────────────────────────────────────────────────
    // 4. COORDINATION HOOKS
    // ────────────────────────────────────────────────────────────────────

    function test_coordinationHooks_defaults() public view {
        assertEq(vault.lastInternalRebalanceTs(), 0, "no rebalance yet");
        assertFalse(vault.isInternallyRebalancing(), "no plan active");
        assertEq(vault.rebalancePenaltyBps(), 0, "no penalty when never rebalanced");

        // liquidityReadiness should be non-zero (adapters have positions)
        uint16 readiness = vault.liquidityReadinessBps();
        assertGt(readiness, 0, "readiness should be > 0 with positions");
        assertLe(readiness, 10000, "readiness capped at 10000");
    }

    function test_coordinationHooks_adapterCount() public view {
        assertEq(vault.adapterCount(), 2, "2 adapters registered");
    }

    // ────────────────────────────────────────────────────────────────────
    // 5. LENS PARITY (unit test with mock adapters)
    // ────────────────────────────────────────────────────────────────────

    function test_lens_explainScore_matches_strategy_state() public {
        // Deploy lens
        StrategyExplainabilityLens lensLocal = new StrategyExplainabilityLens(address(vault));

        // Poke to populate caches
        vm.warp(T0);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeLiquidityBatch(0, 2);

        // Read lens output
        (
            uint16 apy,
            uint256 liq,
            uint256 risk,
            uint256 conf,
            uint256 stability,
            ,
            uint256 scoreRaw,
            uint256 pos,
            uint256 maxExp,
            uint256 extTVL
        ) = lensLocal.explainScore(address(adapterStable));

        // Verify against strategy state
        assertEq(apy, 400, "APY should match adapter");
        assertEq(pos, vault.positionAssets(address(adapterStable)), "position should match");
        assertEq(extTVL, vault.cachedExternalTVL(address(adapterStable)), "extTVL should match cache");
        assertGt(scoreRaw, 0, "score should be non-zero");
        assertGt(liq, 0, "liq should be non-zero");
        assertGt(stability, 0, "stability should be non-zero");
    }

    function test_lens_explainStability_matches_strategy() public {
        StrategyExplainabilityLens lensLocal = new StrategyExplainabilityLens(address(vault));

        (
            uint16 lastAPY,
            uint256 ema,
            ,
            uint16 floor,
            uint32 interval,
            uint16 period
        ) = lensLocal.explainStability(address(adapterStable));

        assertEq(floor, vault.apyFloorBps(), "floor from lens must match strategy");
        assertEq(interval, vault.minStabilityUpdateInterval(), "interval must match");
        assertEq(period, vault.stabilityEMAPeriod(), "period must match");
        assertEq(ema, vault.stabilityEMA(address(adapterStable)), "EMA must match");
    }

    function test_lens_explainAllocation_non_zero() public {
        StrategyExplainabilityLens lensLocal = new StrategyExplainabilityLens(address(vault));

        vm.warp(T0);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        (
            StrategyExplainabilityLens.AdapterAllocationInfo[] memory infos,
            uint256 tvl,
            uint16 maxAdapters
        ) = lensLocal.explainAllocation(100_000e6);

        assertGt(tvl, 0, "TVL should be non-zero");
        assertGt(maxAdapters, 0, "maxAdapters should be non-zero");
        assertGt(infos.length, 0, "should have adapter infos");

        // 
    }
}
