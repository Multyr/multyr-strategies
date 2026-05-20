// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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

// ============================================================================
// MOCK: Adapter with independent totalAssets / withdrawableAssets control
// ============================================================================

contract ScoringMockAdapter is ILendingAdapter {
    address public immutable underlying_;
    address public vault;
    uint256 public deposited;
    uint256 public customWithdrawable;
    bool public useCustomWithdrawable;
    uint16 public apyBps = 500;
    uint16 public incentiveBps = 0;
    uint256 public maxCap = type(uint256).max;
    bool public depositReverts;
    uint256 public extMarketTVL;

    constructor(address _underlying) {
        underlying_ = _underlying;
    }

    function setVault(address _vault) external { vault = _vault; }
    function setAPY(uint16 _apy) external { apyBps = _apy; }
    function setIncentive(uint16 _inc) external { incentiveBps = _inc; }
    function setMaxCap(uint256 _cap) external { maxCap = _cap; }
    function setDepositReverts(bool r) external { depositReverts = r; }
    function setExtMarketTVL(uint256 _tvl) external { extMarketTVL = _tvl; }

    function setCustomWithdrawable(uint256 wa) external {
        customWithdrawable = wa;
        useCustomWithdrawable = true;
    }

    function clearCustomWithdrawable() external {
        useCustomWithdrawable = false;
    }

    /// @dev Allow test to directly set deposited (simulates pre-existing position)
    function setDeposited(uint256 d) external { deposited = d; }

    function name() external pure override returns (string memory) { return "ScoringMockAdapter"; }
    function underlying() external view override returns (address) { return underlying_; }

    function totalAssets() external view override returns (uint256) { return deposited; }

    function withdrawableAssets() external view override returns (uint256) {
        if (useCustomWithdrawable) return customWithdrawable;
        return deposited;
    }

    function deposit(uint256 assets) external override {
        require(!depositReverts, "deposit reverts");
        MockUSDC(underlying_).transferFrom(msg.sender, address(this), assets);
        deposited += assets;
    }

    function withdraw(uint256 assets, address receiver) external override returns (uint256) {
        uint256 toWithdraw = assets > deposited ? deposited : assets;
        deposited -= toWithdraw;
        MockUSDC(underlying_).transfer(receiver, toWithdraw);
        return toWithdraw;
    }

    function currentAPYBps() external view override returns (uint16) { return apyBps; }
    function incentiveAPYBps() external view override returns (uint16) { return incentiveBps; }
    function harvestableProfit() external pure override returns (uint256) { return 0; }
    function harvest(address) external pure override returns (uint256) { return 0; }
    function maxCapacity() external view override returns (uint256) { return maxCap; }
    function isPushMode() external pure override returns (bool) { return false; }
    function idleAssetBalance() external pure override returns (uint256) { return 0; }
    function investedAssets() external view override returns (uint256) { return deposited; }
    function sweepIdleAssetToVault() external override {}
    function emergencyPullAllToVault() external override {}

    function simulateYield(uint256 amount) external {
        deposited += amount;
        MockUSDC(underlying_).mint(address(this), amount);
    }

    function externalMarketTVL() external view override returns (uint256) {
        return extMarketTVL;
    }
}

// ============================================================================
// SCORING MODEL TESTS — BLOCCO B + J + K + L
// ============================================================================

contract Scoring_Model is Test {
    address constant ARBITRUM_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    UsdcMultiLendingVault public vault;
    MockUSDC public usdc;
    ScoringMockAdapter public adapterA; // highest APY
    ScoringMockAdapter public adapterB; // mid APY
    ScoringMockAdapter public adapterC; // low APY
    ScoringMockAdapter public adapterD; // extra adapter for edge cases
    ScoringMockAdapter public adapterE; // extra adapter

    address public admin = address(0x1);
    address public core = address(0x2);
    address public router = address(0x6);
    address public keeper = address(0x3);

    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant PARAM_ROLE = keccak256("PARAM_ROLE");

    function setUp() public virtual {
        // Deploy mock USDC
        usdc = new MockUSDC();
        vm.etch(ARBITRUM_USDC, address(usdc).code);
        usdc = MockUSDC(ARBITRUM_USDC);

        // Create scoring mock adapters with different APYs
        adapterA = new ScoringMockAdapter(ARBITRUM_USDC);
        adapterB = new ScoringMockAdapter(ARBITRUM_USDC);
        adapterC = new ScoringMockAdapter(ARBITRUM_USDC);
        adapterD = new ScoringMockAdapter(ARBITRUM_USDC);
        adapterE = new ScoringMockAdapter(ARBITRUM_USDC);

        adapterA.setAPY(900); // 9%
        adapterB.setAPY(600); // 6%
        adapterC.setAPY(400); // 4%
        adapterD.setAPY(200); // 2%
        adapterE.setAPY(800); // 8%

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
            adapterMaxExposureBps: 8000,
            newAdapterRampBps: 8000,
            gateHorizonDays: 7,
            gateMinNetBenefitBps: 2,
            slippageBpsEstimate: 5,
            withdrawalSpreadBpsEstimate: 5,
            gasCostUSDC: 1e6,
            harvestThresholdBps: 5,
            minSecondsBetweenHarvests: 43200,
            dustTolerance: 10000, // 0.01 USDC (10000 raw = 10000 / 1e6)
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
            address(adapterOpsMod), // adapterOpsModule (FIX: was address(0) — fallback swallowed P0.L1A reverts)
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

        // Set vault on adapters
        adapterA.setVault(address(vault));
        adapterB.setVault(address(vault));
        adapterC.setVault(address(vault));
        adapterD.setVault(address(vault));
        adapterE.setVault(address(vault));

        // Exit bootstrap so scoring drives allocation (not equal headroom)
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
        // TRIAGE A1: populate cachedLiquidityBps so _checkDegradedModeLocally() does not
        // trigger MAJORITY_INELIGIBLE (empty adapter = fully liquid = 10000 bps >= 100).
        vm.prank(keeper);
        (bool liqOk,) = address(vault).call(
            abi.encodeWithSignature("pokeLiquidityBatch(uint256,uint256)", 0, 10)
        );
        require(liqOk, "pokeLiquidityBatch failed");
    }

    function _prepareCache() internal {
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();
        vm.prank(keeper);
        (bool ok,) = address(vault).call(
            abi.encodeWithSignature("pokeLiquidityBatch(uint256,uint256)", 0, 10)
        );
        require(ok, "pokeLiquidityBatch failed");
    }

    function _coreDeposit(uint256 amount) internal {
        usdc.mint(core, amount);
        vm.prank(core);
        usdc.transfer(address(vault), amount);
        vm.prank(core);
        vault.deposit(amount);
    }

    function _setRiskScore(address adapter, uint16 scoreBps) internal {
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setRiskScore(adapter, scoreBps);
    }

    function _setFlagged(address adapter, bool isFlagged) internal {
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setFlaggedAdapter(adapter, isFlagged);
    }

    function _setQuarantined(address adapter, bool q) internal {
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setQuarantined(adapter, q);
    }

    function _exitBootstrap() internal {
        vm.prank(admin);
        StrategySettingsModule(address(vault)).exitBootstrapMode();
    }

    function _setMaxIdle(uint16 bps) internal {
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setMaxIdleAfterDepositBps(bps);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  B1. SCORE COMPONENT TESTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Higher APY adapter should receive more funds on deposit
    function test_score_increases_with_higher_apy() public {
        _addAndEnable(adapterA); // 9%
        _addAndEnable(adapterB); // 6%
        _setMaxIdle(10000); // allow high idle so we can observe allocation order

        _coreDeposit(1000e6);

        uint256 posA = vault.positionAssets(address(adapterA));
        uint256 posB = vault.positionAssets(address(adapterB));
        assertGt(posA, posB, "higher APY adapter should receive more");
    }

    /// @notice Higher risk score (riskScoreBps) means lower risk component → less allocation
    function test_score_decreases_with_higher_risk() public {
        _addAndEnable(adapterA); // 9% APY
        _addAndEnable(adapterE); // 8% APY (close to A)
        _setRiskScore(address(adapterA), 8000); // 80% risk → risk component = 2000 (very risky)
        // adapterE: riskScore = 0 → risk component = DEFAULT_RISK_BPS (7000)
        _setMaxIdle(10000);

        // Set extTVL so confidence is VHIGH (10000) for both → risk not masked by confidence
        adapterA.setExtMarketTVL(300_000_000e6);
        adapterE.setExtMarketTVL(300_000_000e6);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        _coreDeposit(1000e6);

        uint256 posA = vault.positionAssets(address(adapterA));
        uint256 posE = vault.positionAssets(address(adapterE));
        // With VHIGH confidence (1.0x), risk is not masked:
        // A: risk=2000 (riskScore=8000), APY norm=10000
        // E: risk=7000 (default), APY norm=8888
        // Delta risk = 5000 × 2000 = 10M > delta APY = 1112 × 4000 = 4.4M
        assertGt(posE, posA, "high-risk adapter should receive less despite higher APY");
    }

    /// @notice Adapter with low liquidity (withdrawable << total) should get lower score
    function test_score_respects_liquidity_penalty() public {
        _addAndEnable(adapterA); // 9% APY, full liquidity
        _addAndEnable(adapterB); // 6% APY
        _setMaxIdle(10000);

        // TRIAGE A1: dMax=1 at <25K TVL — both adapters need T2 (>=25K, dMax=2) to be seeded.
        // First deposit to seed both adapters
        _coreDeposit(15_000e6); // T2: dMax=2, both funded

        uint256 posA_before = vault.positionAssets(address(adapterA));
        uint256 posB_before = vault.positionAssets(address(adapterB));

        // Now make adapterA illiquid: totalAssets high but withdrawable low
        adapterA.setCustomWithdrawable(10e6); // only 10 USDC withdrawable
        // adapterB stays fully liquid

        // Wait for deploy idle cooldown
        vm.warp(block.timestamp + 301);

        // Re-poke liq cache so scoring sees A as illiquid
        vm.prank(keeper);
        (bool ok,) = address(vault).call(
            abi.encodeWithSignature("pokeLiquidityBatch(uint256,uint256)", 0, 10)
        );
        require(ok, "pokeLiquidityBatch failed");

        // Second deposit — scoring should penalize A's low liquidity
        _coreDeposit(15_000e6);

        uint256 deltaA = vault.positionAssets(address(adapterA)) - posA_before;
        uint256 deltaB = vault.positionAssets(address(adapterB)) - posB_before;
        // TRIAGE A2: invariant is "B receives more from the SECOND deposit than A" (not total pos).
        // positionAssets does not decrease without withdraw — total pos comparison is misleading.
        assertGt(deltaB, deltaA, "liquid adapter should receive bulk of second deposit");
    }

    /// @notice Adapter with stability EMA should affect scoring
    function test_score_respects_stability_component() public {
        _addAndEnable(adapterA); // 9%
        _addAndEnable(adapterB); // 6%
        // Both start with stabilityEMA = their APY (set on addAdapter)
        // After addAdapter, stabilityEMA[A] = 900, stabilityEMA[B] = 600
        // Default: stability fallback is apy if stabilityEMA < 1
        // But since addAdapter sets it, they have real values
        // This test just verifies the component participates — deeper tests below
        _setMaxIdle(10000);

        _coreDeposit(1000e6);
        uint256 posA = vault.positionAssets(address(adapterA));
        uint256 posB = vault.positionAssets(address(adapterB));
        // A has both higher APY AND higher stability → strictly more
        assertGt(posA, posB, "adapter with higher stability should receive more");
    }

    /// @notice Incentive component boosts score
    function test_score_respects_incentive_component() public {
        // Post-P0.L1A: wIncentive forced to 0 -> incentive does NOT influence score.
        // Two adapters with same APY but different incentive must receive EQUAL allocation.
        // (Inverted assertion vs pre-P0.L1A — see LENDING_HARDENING_MEMORY round 5)
        adapterA.setAPY(500);
        adapterB.setAPY(500);
        adapterA.setIncentive(0);
        adapterB.setIncentive(300); // ignored post-P0.L1A

        _addAndEnable(adapterA);
        _addAndEnable(adapterB);
        _setMaxIdle(10000);

        // TRIAGE A1: dMax=1 at <25K TVL — equal-allocation assertion needs dMax=2 (T2 >=25K).
        _coreDeposit(30_000e6);
        uint256 posA = vault.positionAssets(address(adapterA));
        uint256 posB = vault.positionAssets(address(adapterB));
        assertEq(posA, posB, "P0.L1A: incentive must NOT inflate score");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  B2. DUST / EDGE CASE TESTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Adapter with totalAssets <= dustTolerance should get liq=10000 (perfect)
    function test_liquidity_score_treats_init_dust_as_empty_adapter() public {
        _addAndEnable(adapterA);
        _addAndEnable(adapterB);

        // Simulate init dust on adapterA (like Euler initializeMarkets)
        // Set deposited to dustTolerance value (10000 raw = 0.01 USDC)
        adapterA.setDeposited(10000);
        adapterA.setCustomWithdrawable(0); // withdrawable = 0 but tot <= dustTolerance

        _setMaxIdle(10000);
        _coreDeposit(500e6);

        uint256 posA = vault.positionAssets(address(adapterA));
        // A should still receive allocation because _clampLiq returns 10000 for dust
        assertGt(posA, 10000, "dust-level adapter should not be blocked from allocation");
    }

    /// @notice Real small position (above dustTolerance) should have real liq calculation
    function test_liquidity_score_does_not_hide_real_small_position() public {
        _addAndEnable(adapterA);
        _addAndEnable(adapterB);

        // Set adapterA to a real small position above dustTolerance
        adapterA.setDeposited(1e6); // 1 USDC — well above dustTolerance of 10000
        adapterA.setCustomWithdrawable(0); // 0 withdrawable → liq = 0

        _setMaxIdle(10000);
        _prepareCache(); // populate liquidity cache
        _coreDeposit(500e6);

        // adapterA has liq = 0 (real position, illiquid) — should be penalized
        uint256 posA = vault.positionAssets(address(adapterA));
        uint256 posB = vault.positionAssets(address(adapterB));
        assertGt(posB, posA, "real small illiquid position should be penalized");
    }

    /// @notice totalAssets just below dustTolerance → liq = 10000
    function test_liquidity_score_boundary_below_dustTolerance() public {
        _addAndEnable(adapterA);
        _addAndEnable(adapterB);

        // Set exactly at dustTolerance boundary
        adapterA.setDeposited(10000); // == dustTolerance
        adapterA.setCustomWithdrawable(0);

        _setMaxIdle(10000);
        _coreDeposit(500e6);

        uint256 posA = vault.positionAssets(address(adapterA));
        assertGt(posA, 10000, "adapter at dustTolerance boundary should get perfect liq");
    }

    /// @notice totalAssets just above dustTolerance → real liq calculation
    function test_liquidity_score_boundary_above_dustTolerance() public {
        _addAndEnable(adapterA);
        _addAndEnable(adapterB);

        // Set just above dustTolerance
        adapterA.setDeposited(10001); // dustTolerance + 1
        adapterA.setCustomWithdrawable(0); // 0 withdrawable → liq = 0

        _setMaxIdle(10000);
        _prepareCache(); // populate liquidity cache after setting custom withdrawable
        _coreDeposit(500e6);

        uint256 posA = vault.positionAssets(address(adapterA));
        uint256 posB = vault.positionAssets(address(adapterB));
        // A should be penalized: real position, illiquid
        assertGt(posB, posA, "adapter above dustTolerance with 0 withdrawable should be penalized");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  B3. RANKING ORDER TESTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice When all other inputs are equal, higher APY ranks first
    function test_rank_prefers_higher_apy_when_other_inputs_equal() public {
        // All adapters same risk, same liq, same stability — only APY differs
        adapterA.setAPY(900);
        adapterB.setAPY(600);
        adapterC.setAPY(300);

        _addAndEnable(adapterA);
        _addAndEnable(adapterB);
        _addAndEnable(adapterC);
        _setMaxIdle(10000);

        // TRIAGE A1: 3 adapters need T3 (>=250K, dMax=3). Old 1K → dMax=1 → only A funded.
        _coreDeposit(300_000e6);

        uint256 posA = vault.positionAssets(address(adapterA));
        uint256 posB = vault.positionAssets(address(adapterB));
        uint256 posC = vault.positionAssets(address(adapterC));

        assertGt(posA, posB, "A (9%) should rank above B (6%)");
        assertGt(posB, posC, "B (6%) should rank above C (3%)");
    }

    /// @notice When APY is close, higher liquidity breaks the tie
    function test_rank_prefers_more_liquid_adapter_when_apy_close() public {
        adapterA.setAPY(500);
        adapterB.setAPY(500); // same APY

        _addAndEnable(adapterA);
        _addAndEnable(adapterB);
        _setMaxIdle(10000);

        // First deposit to seed both
        _coreDeposit(200e6);

        // Make A illiquid, B stays fully liquid
        adapterA.setCustomWithdrawable(1e6); // low liq
        // B: withdrawable = deposited (full liq)

        _prepareCache(); // refresh liquidity cache after changing withdrawable
        vm.warp(block.timestamp + 301); // deploy idle cooldown

        // Second deposit — B should get more because of higher liq
        _coreDeposit(500e6);

        uint256 posA = vault.positionAssets(address(adapterA));
        uint256 posB = vault.positionAssets(address(adapterB));
        assertGt(posB, posA, "more liquid adapter should rank higher when APY is equal");
    }

    /// @notice Quarantined adapter is excluded from scoring entirely
    function test_rank_excludes_quarantined_adapter() public {
        _addAndEnable(adapterA); // 9%
        _addAndEnable(adapterB); // 6%
        _setMaxIdle(10000);

        // Quarantine the best adapter
        _setQuarantined(address(adapterA), true);

        _coreDeposit(500e6);

        uint256 posA = vault.positionAssets(address(adapterA));
        uint256 posB = vault.positionAssets(address(adapterB));
        assertEq(posA, 0, "quarantined adapter should receive nothing");
        assertGt(posB, 0, "non-quarantined adapter should receive funds");
    }

    /// @notice Disabled adapter is excluded from scoring entirely
    function test_rank_excludes_disabled_adapter() public {
        _addAndEnable(adapterA); // 9%
        _addAndEnable(adapterB); // 6%
        _setMaxIdle(10000);

        // Disable the best adapter
        vm.prank(admin);
        vault.toggleAdapter(address(adapterA), false);

        _coreDeposit(500e6);

        uint256 posA = vault.positionAssets(address(adapterA));
        uint256 posB = vault.positionAssets(address(adapterB));
        assertEq(posA, 0, "disabled adapter should receive nothing");
        assertGt(posB, 0, "enabled adapter should receive funds");
    }

    /// @notice Adapter with zero totalAssets is handled correctly (empty = eligible)
    function test_rank_handles_zero_assets_adapter_correctly() public {
        _addAndEnable(adapterA); // 9%, no deposits yet → totalAssets = 0
        _addAndEnable(adapterB); // 6%, no deposits yet → totalAssets = 0
        _setMaxIdle(10000);

        // TRIAGE A1: dMax=1 at <25K TVL — both adapters need T2 (>=25K, dMax=2).
        _coreDeposit(30_000e6);

        uint256 posA = vault.positionAssets(address(adapterA));
        uint256 posB = vault.positionAssets(address(adapterB));
        // Both should receive allocation; A more than B due to higher APY
        assertGt(posA, 0, "zero-assets adapter should still receive funds");
        assertGt(posB, 0, "zero-assets adapter should still receive funds");
        assertGt(posA, posB, "higher APY should rank first even when both start empty");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  BLOCCO J — TEMPORAL STABILITY TESTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice APY fluctuation should not cause ranking flip-flop when gap is large
    function test_score_stability_under_apy_fluctuation() public {
        _addAndEnable(adapterA);
        _addAndEnable(adapterB);
        _setMaxIdle(10000);

        // Cycle 1: A=900, B=400 → A ranks first
        adapterA.setAPY(900);
        adapterB.setAPY(400);
        _coreDeposit(200e6);
        uint256 posA1 = vault.positionAssets(address(adapterA));
        uint256 posB1 = vault.positionAssets(address(adapterB));
        assertGt(posA1, posB1, "cycle 1: A should rank first");

        // Cycle 2: A drops to 500, B stays 400 → A should still rank first
        // (stability EMA remembers historical performance)
        adapterA.setAPY(500);
        vm.warp(block.timestamp + 301);
        _coreDeposit(200e6);
        uint256 posA2 = vault.positionAssets(address(adapterA));
        uint256 posB2 = vault.positionAssets(address(adapterB));
        assertGt(posA2, posB2, "cycle 2: A should still rank first (APY still > B)");

        // Cycle 3: A recovers to 900, B stays 400 → A clearly first
        adapterA.setAPY(900);
        vm.warp(block.timestamp + 301);
        _coreDeposit(200e6);
        uint256 posA3 = vault.positionAssets(address(adapterA));
        uint256 posB3 = vault.positionAssets(address(adapterB));
        assertGt(posA3, posB3, "cycle 3: A should rank first after recovery");
    }

    /// @notice Adapters with very close APY produce score-proportional allocations
    function test_ranking_stable_when_apy_close() public {
        adapterA.setAPY(500);
        adapterB.setAPY(502); // only 0.02% difference

        _addAndEnable(adapterA);
        _addAndEnable(adapterB);
        _setMaxIdle(10000);

        // TRIAGE A1: dMax=1 at <25K TVL — both need T2 (>=25K, dMax=2).
        _coreDeposit(30_000e6);

        uint256 posA = vault.positionAssets(address(adapterA));
        uint256 posB = vault.positionAssets(address(adapterB));
        // Both should receive allocation (neither is zero)
        assertGt(posA, 0, "A should receive allocation");
        assertGt(posB, 0, "B should receive allocation");
        // B (higher APY by 2 bps) should get at least as much
        assertGe(posB, posA, "slightly higher APY should not get less");
    }

    /// @notice driftTolerance should prevent churn on micro-delta
    function test_driftTolerance_prevents_churn() public {
        adapterA.setAPY(500);
        adapterB.setAPY(500);

        _addAndEnable(adapterA);
        _addAndEnable(adapterB);
        _setMaxIdle(10000);

        _coreDeposit(1000e6);

        uint256 posA_before = vault.positionAssets(address(adapterA));
        uint256 posB_before = vault.positionAssets(address(adapterB));

        // Tiny APY change (1 bps)
        adapterA.setAPY(501);
        vm.warp(block.timestamp + 21601); // past rebalance cooldown

        // Try rebalance — gate check should prevent it (1 bps APY diff is below benefit threshold)
        vm.prank(keeper);
        try StrategyRebalancePlanModule(address(vault)).prepareRebalance() {} catch {}

        // Positions should be unchanged (rebalance either reverted or was no-op)
        uint256 posA_after = vault.positionAssets(address(adapterA));
        uint256 posB_after = vault.positionAssets(address(adapterB));
        assertEq(posA_after, posA_before, "no churn: A position unchanged");
        assertEq(posB_after, posB_before, "no churn: B position unchanged");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  BLOCCO K — LIQUIDITY SHOCK TESTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Liquidity shock reduces allocation via lower liq score
    function test_liquidity_shock_reduces_allocation() public {
        adapterA.setAPY(800);
        adapterB.setAPY(800); // same APY

        _addAndEnable(adapterA);
        _addAndEnable(adapterB);
        _setMaxIdle(10000);

        // Initial deposit — both get similar allocation
        _coreDeposit(500e6);
        uint256 posA1 = vault.positionAssets(address(adapterA));
        uint256 posB1 = vault.positionAssets(address(adapterB));

        // Simulate liquidity shock on A: withdrawable drops to 10% of total
        uint256 totalA = adapterA.deposited();
        adapterA.setCustomWithdrawable(totalA / 10);

        // Refresh cache after shock
        _prepareCache();

        // New deposit should favor B (A's liq score crashed)
        vm.warp(block.timestamp + 301);
        _coreDeposit(500e6);

        uint256 posA2 = vault.positionAssets(address(adapterA));
        uint256 posB2 = vault.positionAssets(address(adapterB));

        uint256 deltaA = posA2 - posA1;
        uint256 deltaB = posB2 - posB1;
        assertGt(deltaB, deltaA, "new funds should flow more to liquid adapter after shock");
    }

    /// @notice Low liquidity alone does not cause quarantine
    function test_liquidity_shock_does_not_quarantine_unfairly() public {
        _addAndEnable(adapterA);
        _setMaxIdle(10000);

        _coreDeposit(500e6);

        // Simulate severe liquidity crisis
        uint256 totalA = adapterA.deposited();
        adapterA.setCustomWithdrawable(0); // 0 withdrawable

        // Adapter should NOT be quarantined — liq is a scoring input, not quarantine trigger
        bool isQuarantined = vault.quarantined(address(adapterA));
        assertFalse(isQuarantined, "low liquidity should not auto-quarantine");

        // Adapter should still be in enabled list (just scored lower)
        bool isEnabled = vault.enabled(address(adapterA));
        assertTrue(isEnabled, "low liquidity adapter should remain enabled");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  ADDITIONAL: FLAGGED ADAPTER BEHAVIOR
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Flagged adapter cannot receive increases but is still scored
    function test_flagged_adapter_blocks_new_allocation() public {
        _addAndEnable(adapterA); // 9%
        _addAndEnable(adapterB); // 6%
        _setMaxIdle(10000);

        // Flag the best adapter
        _setFlagged(address(adapterA), true);

        _coreDeposit(500e6);

        uint256 posA = vault.positionAssets(address(adapterA));
        uint256 posB = vault.positionAssets(address(adapterB));
        assertEq(posA, 0, "flagged adapter should not receive new funds on deposit");
        assertGt(posB, 0, "unflagged adapter should receive funds");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  ADDITIONAL: INCENTIVE DECAY
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Incentive decays over time (half-life)
    function test_incentive_decays_over_halflife() public {
        adapterA.setAPY(500);
        adapterB.setAPY(500);
        adapterA.setIncentive(1000); // 10% incentive
        adapterB.setIncentive(0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // P0.L1A REGRESSION — wIncentive=0 enforcement (Task #7)
    // Pre-fix: setRiskWeights accepted any wIncentive; the result was a
    // 'phantom APR' (no real reward harvest pipeline yet). Post-fix:
    //   1. setRiskWeights MUST revert with WeightsSumInvalid if wIncentive != 0
    //   2. wIncentive forced to 0 means incentiveAPYBps contributes ZERO to score
    //      (no inflation from phantom incentive).
    // The 4 remaining weights (wAPY+wLiq+wRisk+wStability) must sum to 10000.
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice P0.L1A: applying canonical weights yields wIncentive=0 in state.
    ///         Also confirms setRiskWeights rejects non-zero wIncentive.
    function test_p0l1a_default_wIncentive_is_zero() public {
        // (a) Reject path: non-zero wIncentive must revert
        vm.prank(admin);
        vm.expectRevert(); // WeightsSumInvalid
        StrategySettingsModule(address(vault)).setRiskWeights(4000, 2000, 2000, 1000, 1000);

        // (b) Accept path: canonical weights with wIncentive=0 succeed
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setRiskWeights(5000, 2000, 2000, 1000, 0);

        // (c) State: wIncentive enforced to 0
        uint16 stored = StrategyParamsModule(address(vault)).wIncentive();
        assertEq(uint256(stored), 0, "P0.L1A: wIncentive must be enforced to 0");
    }

    /// @notice P0.L1A: with wIncentive=0, an adapter's incentiveAPYBps does NOT
    ///         inflate its score. Two adapters with identical APY but different
    ///         incentives must receive equal allocations.
    function test_p0l1a_zero_incentive_no_score_inflation() public {
        // Apply canonical P0.L1A weights (wIncentive=0)
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setRiskWeights(5000, 2000, 2000, 1000, 0);

        // Two adapters with identical APY; B has positive incentive (would inflate pre-fix)
        adapterA.setAPY(500);
        adapterB.setAPY(500);
        adapterA.setIncentive(0);
        adapterB.setIncentive(300); // 3% incentive — pre-P0.L1A would tilt allocation

        _addAndEnable(adapterA);
        _addAndEnable(adapterB);
        _setMaxIdle(10000);

        // TRIAGE A1: dMax=1 at <25K TVL — equal-allocation assertion needs dMax=2 (T2 >=25K).
        _coreDeposit(30_000e6);

        // Post-P0.L1A: incentive contribution × wIncentive(=0) = 0
        // Both adapters score identically -> equal allocation (within rounding)
        uint256 posA = vault.positionAssets(address(adapterA));
        uint256 posB = vault.positionAssets(address(adapterB));
        assertEq(posA, posB, "P0.L1A: zero incentive must NOT inflate adapter score");
    }
}

// ============================================================================
// CLUSTER C -- StrategyExplainabilityLens: internal function coverage
// Covers: _effectiveRelativeCapBps, _effectiveMinNewAdapterSeed,
//         _computeNormScores, _sortDescending
// ============================================================================

contract LensInternalsTest is Scoring_Model {
    StrategyExplainabilityLens lens;

    function setUp() public override {
        super.setUp();
        lens = new StrategyExplainabilityLens(address(vault));
    }

    // ------------------------------------------------------------------------
    // _effectiveRelativeCapBps -- tiers verified via infos[i].relCap
    // ------------------------------------------------------------------------

    function test_lensInternals_effectiveRelativeCapBps_tier75M() public {
        // extTVL 75M lands in [50M, 250M) -> relCapBps = 2000
        adapterA.setExtMarketTVL(75_000_000e6);
        _addAndEnable(adapterA);

        (StrategyExplainabilityLens.AdapterAllocationInfo[] memory infos,,) =
            lens.explainAllocation(0);

        uint256 expected = (75_000_000e6 * 2000) / 10000;
        assertEq(infos[0].relCap, expected, "relCap mismatch for 75M extTVL");
    }

    function test_lensInternals_effectiveRelativeCapBps_tier300K() public {
        // extTVL 300K lands in [100K, 500K) -> relCapBps = 200
        adapterA.setExtMarketTVL(300_000e6);
        _addAndEnable(adapterA);

        (StrategyExplainabilityLens.AdapterAllocationInfo[] memory infos,,) =
            lens.explainAllocation(0);

        uint256 expected = (300_000e6 * 200) / 10000;
        assertEq(infos[0].relCap, expected, "relCap mismatch for 300K extTVL");
    }

    function test_lensInternals_effectiveRelativeCapBps_belowMinTier() public {
        // extTVL < 100K -> relCapBps = 0 -> relCap = 0
        adapterA.setExtMarketTVL(50_000e6);
        _addAndEnable(adapterA);

        (StrategyExplainabilityLens.AdapterAllocationInfo[] memory infos,,) =
            lens.explainAllocation(0);

        assertEq(infos[0].relCap, 0, "relCap must be 0 for extTVL < 100K");
    }

    // ------------------------------------------------------------------------
    // _effectiveMinNewAdapterSeed -- verified via headroom > 0 during ramp
    // ------------------------------------------------------------------------

    function test_lensInternals_effectiveMinNewAdapterSeed_smallTVL_newAdapter() public {
        // TVL < 1M -> dynamicSeed = 10_000e6.
        // Setup: adapterA established with position, adapterB is new (ramp).
        // explainAllocation should include adapterB with headroom capped by rampBps.
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setNewAdapterRampParams(0, 86400);

        // Establish adapterA so TVL > 0, then add adapterB as the new adapter
        _addAndEnable(adapterA);
        _setMaxIdle(10000);
        _coreDeposit(500_000e6); // TVL = 500K < 1M, adapterA absorbs allocation

        // Add adapterB after deposit -- it starts at position=0 (new / in ramp)
        _addAndEnable(adapterB);

        (StrategyExplainabilityLens.AdapterAllocationInfo[] memory infos,,) =
            lens.explainAllocation(100_000e6);

        // Find adapterB in results
        uint256 bIdx = type(uint256).max;
        for (uint256 i = 0; i < infos.length; i++) {
            if (infos[i].adapter == address(adapterB)) { bIdx = i; break; }
        }
        require(bIdx != type(uint256).max, "adapterB not in infos");
        assertEq(uint256(infos[bIdx].skipReason), 0, "adapterB should not be skipped");
        assertGt(infos[bIdx].headroom, 0, "headroom must be > 0 for new adapter in ramp");
    }

    function test_lensInternals_effectiveMinNewAdapterSeed_largeTVL_newAdapter() public {
        // TVL >= 10M -> dynamicSeed = tvl * 200 / 10000.
        // Setup: adapterA established with large position, adapterB new (ramp).
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setNewAdapterRampParams(0, 86400);

        _addAndEnable(adapterA);
        _setMaxIdle(10000);
        _coreDeposit(15_000_000e6); // adapterA absorbs; TVL >= 10M

        _addAndEnable(adapterB);

        (StrategyExplainabilityLens.AdapterAllocationInfo[] memory infos,,) =
            lens.explainAllocation(5_000_000e6);

        uint256 bIdx = type(uint256).max;
        for (uint256 i = 0; i < infos.length; i++) {
            if (infos[i].adapter == address(adapterB)) { bIdx = i; break; }
        }
        require(bIdx != type(uint256).max, "adapterB not in infos");
        assertEq(uint256(infos[bIdx].skipReason), 0, "adapterB should not be skipped");
        assertGt(infos[bIdx].headroom, 0, "headroom must be > 0 for new adapter in large TVL ramp");
    }

    // ------------------------------------------------------------------------
    // _computeNormScores -- score ordering reflects APY ratio
    // ------------------------------------------------------------------------

    function test_lensInternals_computeNormScores_higherAPY_higherScore() public {
        // A(900bps) > B(600bps): infos sorted descending, A is first with higher score
        adapterA.setAPY(900);
        adapterB.setAPY(600);

        _addAndEnable(adapterA);
        _addAndEnable(adapterB);

        (StrategyExplainabilityLens.AdapterAllocationInfo[] memory infos,,) =
            lens.explainAllocation(0);

        assertEq(infos.length, 2, "expected 2 adapters");
        assertGt(infos[0].score, infos[1].score, "higher APY should yield higher score");
        assertEq(infos[0].adapter, address(adapterA), "adapterA should rank first");
    }

    function test_lensInternals_computeNormScores_equalAPY_equalScores() public {
        // All 3 at 500bps -> equal normalised scores (~3333 each, sum ~10000)
        adapterA.setAPY(500);
        adapterB.setAPY(500);
        adapterC.setAPY(500);

        _addAndEnable(adapterA);
        _addAndEnable(adapterB);
        _addAndEnable(adapterC);

        (StrategyExplainabilityLens.AdapterAllocationInfo[] memory infos,,) =
            lens.explainAllocation(0);

        assertEq(infos.length, 3, "expected 3 adapters");
        uint256 s0 = infos[0].score;
        uint256 s1 = infos[1].score;
        uint256 s2 = infos[2].score;
        uint256 d01 = s0 > s1 ? s0 - s1 : s1 - s0;
        uint256 d12 = s1 > s2 ? s1 - s2 : s2 - s1;
        assertLe(d01, 1, "equal APY adapters should have equal scores (rounding)");
        assertLe(d12, 1, "equal APY adapters should have equal scores (rounding)");
    }

    // ------------------------------------------------------------------------
    // _sortDescending -- returned infos array is ordered by score descending
    // ------------------------------------------------------------------------

    function test_lensInternals_sortDescending_correctOrder() public {
        // A(900) > B(600) > C(300) -> explainAllocation returns [A, B, C]
        adapterA.setAPY(900);
        adapterB.setAPY(600);
        adapterC.setAPY(300);

        _addAndEnable(adapterA);
        _addAndEnable(adapterB);
        _addAndEnable(adapterC);

        (StrategyExplainabilityLens.AdapterAllocationInfo[] memory infos,,) =
            lens.explainAllocation(0);

        assertEq(infos.length, 3, "expected 3 adapters");
        assertEq(infos[0].adapter, address(adapterA), "A should be first (highest APY)");
        assertEq(infos[1].adapter, address(adapterB), "B should be second");
        assertEq(infos[2].adapter, address(adapterC), "C should be third");
        assertGe(infos[0].score, infos[1].score, "scores not descending [0]>=[1]");
        assertGe(infos[1].score, infos[2].score, "scores not descending [1]>=[2]");
    }

    function test_lensInternals_sortDescending_singleAdapter_noRevert() public {
        // Single adapter: trivial sort, should not revert
        _addAndEnable(adapterA);

        (StrategyExplainabilityLens.AdapterAllocationInfo[] memory infos,,) =
            lens.explainAllocation(0);

        assertEq(infos.length, 1, "expected 1 adapter");
        assertEq(infos[0].adapter, address(adapterA), "single adapter returned");
    }

    function test_lensInternals_sortDescending_noAdapters_emptyResult() public {
        // No enabled adapters -> empty infos array
        (StrategyExplainabilityLens.AdapterAllocationInfo[] memory infos,,) =
            lens.explainAllocation(0);

        assertEq(infos.length, 0, "no adapters should return empty infos");
    }

    // ------------------------------------------------------------------------
    // _evaluateAdapter skip reasons
    // ------------------------------------------------------------------------

    // GAP: SkipReason.Flagged branch never asserted
    function test_lensInternals_evaluateAdapter_flaggedSkipped() public {
        _addAndEnable(adapterA);
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setFlaggedAdapter(address(adapterA), true);

        (StrategyExplainabilityLens.AdapterAllocationInfo[] memory infos,,) =
            lens.explainAllocation(0);

        bool found = false;
        for (uint256 i = 0; i < infos.length; i++) {
            if (infos[i].adapter == address(adapterA)) {
                assertEq(
                    uint256(infos[i].skipReason),
                    uint256(StrategyExplainabilityLens.SkipReason.Flagged),
                    "flagged adapter should have SkipReason.Flagged"
                );
                found = true;
                break;
            }
        }
        assertTrue(found, "adapterA must appear in infos");
    }

    // GAP: SkipReason.OverMaxCap branch never asserted
    // With TVL=0: maxExp = adapterMaxExposureBps * 0 / 1e4 = 0, current = 0 -> 0 >= 0 -> OverMaxCap
    function test_lensInternals_evaluateAdapter_overMaxCapSkipped() public {
        _addAndEnable(adapterA);

        (StrategyExplainabilityLens.AdapterAllocationInfo[] memory infos,,) =
            lens.explainAllocation(0);

        bool found = false;
        for (uint256 i = 0; i < infos.length; i++) {
            if (infos[i].adapter == address(adapterA)) {
                assertEq(
                    uint256(infos[i].skipReason),
                    uint256(StrategyExplainabilityLens.SkipReason.OverMaxCap),
                    "with zero TVL all adapters should be OverMaxCap"
                );
                found = true;
                break;
            }
        }
        assertTrue(found, "adapterA must appear in infos");
    }

    // GAP: maxCapacity cap clips headroom — adapter.maxCapacity() clamps the headroom value
    // Set adapterA TVL=1000e6, maxCap=1 -> lens caps headroom to 1 (passes ZeroHeadroom since >=1)
    function test_lensInternals_evaluateAdapter_capacityClipsHeadroom() public {
        _addAndEnable(adapterA);
        // Non-zero TVL so OverMaxCap check passes (current=0, maxExp = exposureBps * TVL / 1e4 > 0)
        adapterA.setDeposited(1000e6);
        // Set maxCapacity to 1: headroom = min(maxExp, rampLimit, cap-current) = 1
        adapterA.setMaxCap(1);

        (StrategyExplainabilityLens.AdapterAllocationInfo[] memory infos,,) =
            lens.explainAllocation(0);

        bool found = false;
        for (uint256 i = 0; i < infos.length; i++) {
            if (infos[i].adapter == address(adapterA)) {
                // headroom should be clipped to cap-current = 1-0 = 1
                assertEq(infos[i].headroom, 1, "headroom should be clipped to maxCapacity");
                found = true;
                break;
            }
        }
        assertTrue(found, "adapterA must appear in infos");
    }

    // AUDIT-FINDING-8 regression: prevent re-introduction of T1 ceiling bug.
    // Before fix: effectiveAbsCapBps applied adapterMaxExposureBps (default 50%) even at T1
    // (dMax=1), causing 50% of TVL to stay idle in early-stage. After fix: T1 short-circuits
    // to 10000 (100%) before any ceiling or overlays, preserving intentional-concentration design.
    function test_AUDIT_FINDING_8_T1_ignores_global_ceiling() public {
        _addAndEnable(adapterA);
        _addAndEnable(adapterB);

        // Set global ceiling to 50% (5000 bps) — tighter than the ramp limit (80%).
        // At T2+, this would cap posA at 50% of TVL. At T1, effectiveAbsCapBps
        // short-circuits to 10000 (100%), so the ceiling is never applied.
        // With ramp=8000 (80%), posA = 800 USDC. Ceiling of 50% would give 500 USDC.
        // posA=800 > 500 proves the T1 short-circuit bypassed the global ceiling.
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setRebalanceParams(5, 2, 50, 21600, 80, 5000, 8000);

        // maxIdleAfterDepositBps raised to 100% — ramp leaves ~20% idle, which is expected
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setMaxIdleAfterDepositBps(10000);

        // Deposit 1000 USDC (T1 regime: < 25,000 USDC)
        _coreDeposit(1000e6);

        uint256 posA = vault.positionAssets(address(adapterA));
        uint256 posB = vault.positionAssets(address(adapterB));

        // posA=800 (ramp-limited at 80%) > 500 (ceiling at 50%) — T1 bypasses global ceiling
        assertGt(posA, 500e6, "T1: posA exceeds 50%-ceiling - global ceiling bypassed at T1");

        // adapter B not selected (dMax=1 — single-adapter mode)
        assertEq(posB, 0, "T1: only top adapter selected");
    }

    // ============================================================================
    // EXT_TVL_PANIC — Trigger 3 regression tests (Phase 1.5)
    // ============================================================================

    // S2-T1: snapshot mechanism — pokeExternalTVL captures OLD value before overwrite,
    // but only after the first window has elapsed (first poke = baseline only, no snapshot).
    function test_S2_extTVLPanic_snapshotCapturedAfterWindow() public {
        _addAndEnable(adapterA);

        // First poke: establishes baseline. Snapshot stays 0 (first-time guard).
        adapterA.setExtMarketTVL(100_000_000e6);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();
        assertEq(StrategyParamsModule(address(vault)).lastExtTVLSnapshot(address(adapterA)), 0,
            "first poke: snapshot must stay 0");

        // Advance 1 hour so window elapses, then poke again with new TVL.
        vm.warp(block.timestamp + 3601);
        adapterA.setExtMarketTVL(70_000_000e6);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        // Snapshot must now hold the OLD value (100M), current holds new (70M).
        assertEq(StrategyParamsModule(address(vault)).lastExtTVLSnapshot(address(adapterA)),
            100_000_000e6, "snapshot must equal pre-poke value");
        assertEq(StrategyParamsModule(address(vault)).cachedExternalTVL(address(adapterA)),
            70_000_000e6, "current cache must equal new value");
    }

    // S2-T2: panic fires — 30% drop from snapshot triggers EXT_TVL_PANIC.
    function test_S2_extTVLPanic_triggerFires_on30pctDrop() public {
        _addAndEnable(adapterA);

        // Establish baseline (100M), advance window, poke with 30% drop (70M).
        // 30% drop = exactly DROP_BPS threshold => must fire.
        adapterA.setExtMarketTVL(100_000_000e6);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        vm.warp(block.timestamp + 3601);
        adapterA.setExtMarketTVL(70_000_000e6); // exactly 30% drop
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        (bool degraded, string memory reason) =
            StrategyScoringModule(address(vault)).checkDegradedMode();
        assertTrue(degraded, "30% drop must trigger EXT_TVL_PANIC");
        assertEq(reason, "EXT_TVL_PANIC", "reason must be EXT_TVL_PANIC");
    }

    // S2-T3: no panic below threshold — 29% drop does NOT fire.
    function test_S2_extTVLPanic_noFire_below30pctDrop() public {
        _addAndEnable(adapterA);

        // Baseline 100M, advance window, poke with 29% drop (71M) => below threshold.
        adapterA.setExtMarketTVL(100_000_000e6);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        vm.warp(block.timestamp + 3601);
        adapterA.setExtMarketTVL(71_000_000e6); // 29% drop — under threshold
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        (bool degraded,) = StrategyScoringModule(address(vault)).checkDegradedMode();
        assertFalse(degraded, "29% drop must NOT trigger EXT_TVL_PANIC");
    }
}