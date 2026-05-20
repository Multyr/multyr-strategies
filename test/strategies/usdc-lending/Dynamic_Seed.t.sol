// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import { StrategyExplainabilityLens } from "../../../src/strategies/usdc-lending/lens/StrategyExplainabilityLens.sol";
import { StrategyRebalanceGateModule } from "../../../src/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol";
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
import { ScoringMockAdapter } from "./Scoring_Model.t.sol";
import { StrategyRebalancePlanModule } from "../../../src/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol";

/// @title Dynamic Seed Tests — BLOCCO L
/// @notice Tests effectiveMinNewAdapterSeed() at different TVL levels.
contract Dynamic_Seed is Test {
    address constant ARBITRUM_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    UsdcMultiLendingVault public vault;
    MockUSDC public usdc;
    ScoringMockAdapter public adapter1;
    ScoringMockAdapter public adapter2;
    ScoringMockAdapter public adapterNew; // new adapter to test seed behavior

    address public admin = address(0x1);
    address public core = address(0x2);
    address public router = address(0x6);
    address public keeper = address(0x3);

    bytes32 constant PARAM_ROLE = keccak256("PARAM_ROLE");

    function setUp() public {
        usdc = new MockUSDC();
        vm.etch(ARBITRUM_USDC, address(usdc).code);
        usdc = MockUSDC(ARBITRUM_USDC);

        adapter1 = new ScoringMockAdapter(ARBITRUM_USDC);
        adapter2 = new ScoringMockAdapter(ARBITRUM_USDC);
        adapterNew = new ScoringMockAdapter(ARBITRUM_USDC);

        adapter1.setAPY(800);
        adapter2.setAPY(600);
        adapterNew.setAPY(700);

        // Audit #2 P0.6: seed realistic external TVL so confidence != ZERO
        adapter1.setExtMarketTVL(50_000_000e6);
        adapter2.setExtMarketTVL(50_000_000e6);
        adapterNew.setExtMarketTVL(50_000_000e6);

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
            adapterMaxExposureBps: 5000,
            newAdapterRampBps: 3000, // 30% ramp for new adapters
            gateHorizonDays: 7,
            gateMinNetBenefitBps: 2,
            slippageBpsEstimate: 5,
            withdrawalSpreadBpsEstimate: 5,
            gasCostUSDC: 0,
            harvestThresholdBps: 5,
            minSecondsBetweenHarvests: 43200,
            dustTolerance: 10000,
            stabilityEMAPeriod: 7,
            minNewAdapterSeed: 0, // let dynamic seed drive
            newAdapterRampDuration: 86400, // 1 day ramp
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
            ARBITRUM_USDC, core, router, admin, keeper, address(0),
            address(paramsModule), address(scoringMod), address(adapterOpsMod), gateMod, params);

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

        adapter1.setVault(address(vault));
        adapter2.setVault(address(vault));
        adapterNew.setVault(address(vault));

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

    // ═══════════════════════════════════════════════════════════
    //  L1. effectiveMinNewAdapterSeed returns correct values
    // ═══════════════════════════════════════════════════════════

    // TRIAGE A1: assertions updated to TIER_MODEL_V1 bands per docs/TIER_MODEL.md Section 4.
    // Old pre-V1 bands: T_low=10K, T_mid=50K, T_high=2%TVL.
    // New bands: T1+T2(<250K)=100 USDC, T3(250K-1M)=1K, T4(1M-5M)=5K, T5(5M-25M)=25K.

    /// @notice TVL 50K → T2 → seed = 100 USDC
    function test_seed_scales_with_tvl_low() public {
        _addAndEnable(adapter1);
        _addAndEnable(adapter2);
        _setMaxIdle(10000);

        _coreDeposit(50_000e6); // TVL = 50k → T2 (<250K)

        uint256 seed = StrategyParamsModule(address(vault)).effectiveMinNewAdapterSeed();
        assertEq(seed, 100e6, "low TVL seed should be 100 USDC (T2 band)");
    }

    /// @notice TVL 2M → T4 → seed = 5K USDC
    function test_seed_scales_with_tvl_mid() public {
        _addAndEnable(adapter1);
        _addAndEnable(adapter2);
        _setMaxIdle(10000);

        _coreDeposit(2_000_000e6); // TVL = 2M → T4 (1M-5M)

        uint256 seed = StrategyParamsModule(address(vault)).effectiveMinNewAdapterSeed();
        assertEq(seed, 5_000e6, "mid TVL seed should be 5K USDC (T4 band)");
    }

    /// @notice TVL 20M → T5 → seed = 25K USDC
    function test_seed_scales_with_tvl_high() public {
        _addAndEnable(adapter1);
        _addAndEnable(adapter2);
        _setMaxIdle(10000);

        _coreDeposit(20_000_000e6); // TVL = 20M → T5 (5M-25M)

        uint256 seed = StrategyParamsModule(address(vault)).effectiveMinNewAdapterSeed();
        assertEq(seed, 25_000e6, "high TVL seed should be 25K USDC (T5 band)");
    }

    /// @notice Static minNewAdapterSeed acts as floor
    function test_seed_floor_respected() public {
        // Set static floor higher than dynamic
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setNewAdapterRampParams(100_000e6, 86400);

        _addAndEnable(adapter1);
        _addAndEnable(adapter2);
        _setMaxIdle(10000);

        _coreDeposit(50_000e6); // TVL = 50k → dynamic = 10k, static = 100k

        uint256 seed = StrategyParamsModule(address(vault)).effectiveMinNewAdapterSeed();
        assertEq(seed, 100_000e6, "static floor should override when higher");
    }

    // TRIAGE A1: TVL=50K → T2 → dynamic=100 USDC. static=5K > dynamic → static wins.
    /// @notice Static floor wins when higher than dynamic band value
    function test_seed_cap_not_exceeded() public {
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setNewAdapterRampParams(5_000e6, 86400);

        _addAndEnable(adapter1);
        _addAndEnable(adapter2);
        _setMaxIdle(10000);

        _coreDeposit(50_000e6); // TVL = 50k → T2 → dynamic = 100 USDC, static = 5K → static wins

        uint256 seed = StrategyParamsModule(address(vault)).effectiveMinNewAdapterSeed();
        assertEq(seed, 5_000e6, "static floor should be used when higher than dynamic band");
    }

    // ═══════════════════════════════════════════════════════════
    //  L2. New adapter onboarding behavior
    // ═══════════════════════════════════════════════════════════

    /// @notice New adapter enters and receives allocation when headroom exists
    function test_new_adapter_onboarding() public {
        // Register all 3 adapters upfront so there's headroom for all
        _addAndEnable(adapter1);
        _addAndEnable(adapter2);
        _addAndEnable(adapterNew);
        _setMaxIdle(10000);

        // First deposit — all 3 adapters compete for allocation
        _coreDeposit(500_000e6);

        uint256 pos1 = vault.positionAssets(address(adapter1));
        uint256 pos2 = vault.positionAssets(address(adapter2));
        uint256 posNew = vault.positionAssets(address(adapterNew));

        assertGt(pos1, 0, "adapter1 should have allocation");
        assertGt(pos2, 0, "adapter2 should have allocation");
        assertGt(posNew, 0, "new adapter should receive allocation");

        // New adapter should be limited by ramp (30% of TVL)
        uint256 tvl = vault.idleCash() + pos1 + pos2 + posNew;
        uint256 rampCap = (tvl * 3000) / 1e4; // 30%
        assertLe(posNew, rampCap + vault.dustTolerance(), "new adapter should be ramp-limited");
    }

    /// @notice New adapter grows over time past seed threshold
    function test_new_adapter_grows_past_seed() public {
        _addAndEnable(adapter1);
        _addAndEnable(adapter2);
        _addAndEnable(adapterNew);
        _setMaxIdle(10000);

        // Multiple deposits to grow new adapter past seed
        _coreDeposit(100_000e6);
        vm.warp(block.timestamp + 301);
        _coreDeposit(100_000e6);
        vm.warp(block.timestamp + 301);
        _coreDeposit(100_000e6);

        uint256 posNew = vault.positionAssets(address(adapterNew));
        assertGt(posNew, 0, "new adapter should have grown");

        // Warp past ramp duration
        vm.warp(block.timestamp + 86401);

        // After ramp + past seed threshold, adapter treated as mature
        _coreDeposit(100_000e6);
        uint256 posNewAfter = vault.positionAssets(address(adapterNew));
        assertGt(posNewAfter, posNew, "adapter should continue growing after ramp");
    }

    /// @notice New adapter does NOT break distribution
    function test_new_adapter_does_not_break_distribution() public {
        _addAndEnable(adapter1);
        _addAndEnable(adapter2);
        _setMaxIdle(10000);

        _coreDeposit(500_000e6);
        uint256 pos1Before = vault.positionAssets(address(adapter1));
        uint256 pos2Before = vault.positionAssets(address(adapter2));

        // Add new adapter and deposit more
        _addAndEnable(adapterNew);
        vm.warp(block.timestamp + 301);
        _coreDeposit(200_000e6);

        // Existing adapters should not lose allocation
        uint256 pos1After = vault.positionAssets(address(adapter1));
        uint256 pos2After = vault.positionAssets(address(adapter2));

        assertGe(pos1After, pos1Before, "existing adapter1 should not lose funds");
        assertGe(pos2After, pos2Before, "existing adapter2 should not lose funds");
    }
}
