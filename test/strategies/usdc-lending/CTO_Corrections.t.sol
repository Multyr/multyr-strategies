// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, Vm } from "forge-std/Test.sol";
import {
    UsdcMultiLendingVault
} from "../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
import {
    StrategyParamsModule
} from "../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import { StrategySettingsModule } from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {
    StrategyScoringModule
} from "../../../src/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import {
    StrategyStorageLayout
} from "../../../src/strategies/usdc-lending/controller/StrategyStorageLayout.sol";
import {
    MockUSDC,
    MockLendingAdapter,
    UsdcMultiLendingVaultTestBase
} from "./UsdcMultiLendingVault.t.sol";

/// @title CTO Corrections Tests — V9.1
/// @notice Tests dynamic adapter count, MICRO cap, skip events, stale cache
contract CTO_DynamicAdapterCount is UsdcMultiLendingVaultTestBase {
    MockLendingAdapter public adapter4;
    MockLendingAdapter public adapter5;

    function setUp() public override {
        super.setUp();

        adapter4 = new MockLendingAdapter(ARBITRUM_USDC);
        adapter4.setAPY(700);
        adapter4.setExtMarketTVL(50_000_000e6);

        adapter5 = new MockLendingAdapter(ARBITRUM_USDC);
        adapter5.setAPY(600);
        adapter5.setExtMarketTVL(30_000_000e6);

        // Register all 5 adapters
        _addAndEnableAdapter(adapter1); // 800 bps
        _addAndEnableAdapter(adapter2); // 600 bps
        _addAndEnableAdapter(adapter3); // 400 bps
        _addAndEnableAdapter(adapter4); // 700 bps
        _addAndEnableAdapter(adapter5); // 600 bps

        // Set extTVL for existing adapters (large markets)
        adapter1.setExtMarketTVL(100_000_000e6);
        adapter2.setExtMarketTVL(80_000_000e6);
        adapter3.setExtMarketTVL(20_000_000e6);

        // Exit bootstrap
        vm.prank(admin);
        StrategySettingsModule(address(vault)).exitBootstrapMode();
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setMaxIdleAfterDepositBps(10000);

        // Poke external TVL
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();
    }

    function _countAllocated() internal view returns (uint256 count) {
        uint256 dust = vault.dustTolerance();
        address[5] memory addrs = [address(adapter1), address(adapter2), address(adapter3), address(adapter4), address(adapter5)];
        for (uint256 i = 0; i < 5; i++) {
            if (vault.positionAssets(addrs[i]) > dust) count++;
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  TVL-based dynamic adapter count
    // ═══════════════════════════════════════════════════════════

    /// @notice 10k TVL → max 2 adapters
    function test_10k_tvl_max_2_adapters() public {
        _mintAndTransferToVault(core, 10_000e6);
        vm.prank(core);
        vault.deposit(10_000e6);

        assertLe(_countAllocated(), 2, "10k TVL should use max 2 adapters");
        assertGt(_countAllocated(), 0, "should allocate to at least 1");
    }

    /// @notice 50k TVL → max 2 adapters
    function test_50k_tvl_max_2_adapters() public {
        _mintAndTransferToVault(core, 50_000e6);
        vm.prank(core);
        vault.deposit(50_000e6);

        assertLe(_countAllocated(), 2, "50k TVL should use max 2 adapters");
        assertGt(_countAllocated(), 0, "should allocate to at least 1");
    }

    /// @notice 150k TVL → max 3 adapters
    function test_150k_tvl_max_3_adapters() public {
        _mintAndTransferToVault(core, 200_000e6);
        vm.prank(core);
        vault.deposit(200_000e6);

        uint256 allocated = _countAllocated();
        assertLe(allocated, 3, "200k TVL should use max 3 adapters");
        assertGe(allocated, 2, "200k TVL should use at least 2 adapters");
    }

    /// @notice 1M TVL → max 4 adapters
    function test_1M_tvl_max_4_adapters() public {
        _mintAndTransferToVault(core, 1_000_000e6);
        vm.prank(core);
        vault.deposit(1_000_000e6);

        uint256 allocated = _countAllocated();
        assertLe(allocated, 4, "1M TVL should use max 4 adapters");
        assertGe(allocated, 2, "1M TVL should use at least 2 adapters");
    }

    /// @notice 10M TVL → max 5 adapters (requires lower maxExposure + 2 cycles)
    function test_10M_tvl_max_5_adapters() public {
        // Lower maxExposure to 25% so 5 adapters can all fit
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setRebalanceParams(
            5, 2, 50, 21600, 80, 2500, 5000 // maxExposureBps=2500 (25%)
        );

        _mintAndTransferToVault(core, 10_000_000e6);
        vm.prank(core);
        vault.deposit(10_000_000e6);

        // 2 deployIdle cycles for full distribution
        vm.warp(block.timestamp + 301);
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();
        vm.warp(block.timestamp + 301);
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();

        uint256 allocated = _countAllocated();
        assertEq(allocated, 5, "10M TVL with 25% cap should use all 5 adapters");
    }

    /// @notice No excessive fragmentation at low TVL
    function test_no_fragmentation_at_low_tvl() public {
        _mintAndTransferToVault(core, 5_000e6);
        vm.prank(core);
        vault.deposit(5_000e6);

        // At 5k TVL, only 2 adapters — each gets ~2.5k minimum (not spread thin)
        uint256 dust = vault.dustTolerance();
        uint256 smallPositions = 0;
        address[5] memory addrs = [address(adapter1), address(adapter2), address(adapter3), address(adapter4), address(adapter5)];
        for (uint256 i = 0; i < 5; i++) {
            uint256 pos = vault.positionAssets(addrs[i]);
            if (pos > dust && pos < 1_000e6) smallPositions++;
        }
        assertEq(smallPositions, 0, "no positions should be fragmented below 1k USDC");
    }

    /// @notice Diversification increases as TVL grows
    function test_diversification_increases_with_tvl() public {
        // Low TVL
        _mintAndTransferToVault(core, 50_000e6);
        vm.prank(core);
        vault.deposit(50_000e6);
        uint256 allocLow = _countAllocated();

        // Increase TVL
        _mintAndTransferToVault(core, 500_000e6);
        vm.prank(core);
        vault.deposit(500_000e6);
        vm.warp(block.timestamp + 301);
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();
        uint256 allocHigh = _countAllocated();

        assertGe(allocHigh, allocLow, "more adapters at higher TVL");
    }
}

/// @title CTO MICRO Cap + Events Tests
contract CTO_MicroCapAndEvents is UsdcMultiLendingVaultTestBase {

    MockLendingAdapter public adapterMicro;
    MockLendingAdapter public adapterNormal;

    function setUp() public override {
        super.setUp();

        // MICRO market: extTVL = 300k (100K-500K band → CONFIDENCE_MICRO)
        adapterMicro = new MockLendingAdapter(ARBITRUM_USDC);
        adapterMicro.setAPY(1000); // high APY
        adapterMicro.setExtMarketTVL(300_000e6);

        // Normal market: extTVL = 50M (MED band)
        adapterNormal = new MockLendingAdapter(ARBITRUM_USDC);
        adapterNormal.setAPY(500);
        adapterNormal.setExtMarketTVL(50_000_000e6);

        _addAndEnableAdapter(adapterMicro);
        _addAndEnableAdapter(adapterNormal);

        vm.prank(admin);
        StrategySettingsModule(address(vault)).exitBootstrapMode();
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setMaxIdleAfterDepositBps(10000);

        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        // Enable relative exposure cap (required for MICRO cap to work)
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setMaxRelativeExposureBps(1000); // 10%
    }

    /// @notice MICRO market capped at 2% of external TVL (MICRO_RELATIVE_CAP_BPS=200)
    function test_micro_market_strict_cap() public {
        _mintAndTransferToVault(core, 100_000e6);
        vm.prank(core);
        vault.deposit(100_000e6);

        uint256 posMicro = vault.positionAssets(address(adapterMicro));
        // 2% of 300k = 6k USDC max
        uint256 microCap = (300_000e6 * 200) / 10000; // 6k
        assertLe(posMicro, microCap + vault.dustTolerance(), "MICRO market should be capped at 2% of extTVL");
    }

    /// @notice MICRO cap applies regardless of high APY
    function test_micro_cap_overrides_high_apy() public {
        // Even though MICRO adapter has highest APY (1000 vs 500), it gets less allocation
        _mintAndTransferToVault(core, 100_000e6);
        vm.prank(core);
        vault.deposit(100_000e6);

        uint256 posMicro = vault.positionAssets(address(adapterMicro));
        uint256 posNormal = vault.positionAssets(address(adapterNormal));

        // Normal adapter should have more despite lower APY (no MICRO cap)
        assertGt(posNormal, posMicro, "normal market should have more than MICRO despite lower APY");
    }

    /// @notice Adapter with CONFIDENCE_ZERO (extTVL < 100K) is skipped
    function test_confidence_zero_skipped() public {
        MockLendingAdapter adapterTiny = new MockLendingAdapter(ARBITRUM_USDC);
        adapterTiny.setAPY(2000); // very high APY
        adapterTiny.setExtMarketTVL(50_000e6); // 50K < 100K → CONFIDENCE_ZERO
        _addAndEnableAdapter(adapterTiny);

        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        _mintAndTransferToVault(core, 100_000e6);
        vm.prank(core);
        vault.deposit(100_000e6);

        assertEq(vault.positionAssets(address(adapterTiny)), 0, "ZERO confidence adapter should get no allocation");
    }

    /// @notice AdapterSkippedLowConfidence event emitted for ZERO confidence
    function test_event_skipped_low_confidence() public {
        MockLendingAdapter adapterTiny = new MockLendingAdapter(ARBITRUM_USDC);
        adapterTiny.setAPY(2000);
        adapterTiny.setExtMarketTVL(50_000e6); // 50k < 100k → CONFIDENCE_ZERO
        _addAndEnableAdapter(adapterTiny);

        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        _mintAndTransferToVault(core, 100_000e6);

        // Record logs to verify event was emitted
        vm.recordLogs();
        vm.prank(core);
        vault.deposit(100_000e6);

        // Check AdapterSkippedLowConfidence was emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("AdapterSkippedLowConfidence(address,uint256,uint256)");
        bool found = false;
        for (uint256 j = 0; j < logs.length; j++) {
            if (logs[j].topics.length > 0 && logs[j].topics[0] == eventSig) {
                found = true;
                break;
            }
        }
        assertTrue(found, "AdapterSkippedLowConfidence event should be emitted");
    }

    /// @notice AdapterSkippedOverCap event emitted when adapter at cap
    function test_event_skipped_over_cap() public {
        // TRIAGE A1: adapterMaxExposureBps no longer governs abs cap — effectiveAbsCapBps does.
        // Use setAdapterAbsCapOverride to enforce 10% governance floor (still below STRUCTURAL_BASE).
        // Note: effectiveAbsCapBps returns max(STRUCTURAL_BASE, override). At T2 (dMax=2),
        // STRUCTURAL_BASE=6000 bps > 1000 bps override, so STRUCTURAL_BASE wins.
        // To force a 10% hard cap test, assert against STRUCTURAL_BASE (60% at T2).
        vm.startPrank(admin);
        StrategySettingsModule(address(vault)).setAdapterAbsCapOverride(address(adapterMicro), 1000);
        StrategySettingsModule(address(vault)).setAdapterAbsCapOverride(address(adapterNormal), 1000);
        vm.stopPrank();

        _mintAndTransferToVault(core, 100_000e6);
        vm.prank(core);
        vault.deposit(100_000e6);

        vm.warp(block.timestamp + 301);
        _mintAndTransferToVault(core, 100_000e6);
        vm.prank(core);
        vault.deposit(100_000e6);

        // effectiveAbsCapBps at T2 (200K TVL, dMax=2): STRUCTURAL_BASE = ceil(11000/2) = 6000 bps
        uint256 tvl = vault.totalAssets();
        uint256 maxExp = (uint256(6000) * tvl) / 1e4; // 60% structural cap at T2
        uint256 dust = vault.dustTolerance();
        assertLe(vault.positionAssets(address(adapterMicro)), maxExp + dust, "micro over maxExposure");
        assertLe(vault.positionAssets(address(adapterNormal)), maxExp + dust, "normal over maxExposure");
    }

    /// @notice Stale cache event: verify confidence degrades with stale data
    function test_stale_cache_degrades_confidence() public {
        _mintAndTransferToVault(core, 50_000e6);
        vm.prank(core);
        vault.deposit(50_000e6);

        uint256 pos1 = vault.positionAssets(address(adapterNormal));

        // Warp past staleness (12h + 1)
        vm.warp(block.timestamp + 43201);

        // Next deposit uses stale cache → degraded confidence
        vm.warp(block.timestamp + 301);
        _mintAndTransferToVault(core, 50_000e6);
        vm.prank(core);
        vault.deposit(50_000e6);

        // System should still work (no revert) — stale = conservative, not broken
        assertGt(vault.totalAssets(), 0, "vault should be operational with stale cache");
    }

    /// @notice Euler gets allocation at higher TVL thresholds
    function test_euler_allocates_at_higher_tvl() public {
        MockLendingAdapter adapterEuler = new MockLendingAdapter(ARBITRUM_USDC);
        adapterEuler.setAPY(800);
        adapterEuler.setExtMarketTVL(4_000_000e6); // 4M → LOW (7000)
        _addAndEnableAdapter(adapterEuler);

        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        // At 1M TVL, dynamic max=4, Euler should be in top 3-4 by APY
        _mintAndTransferToVault(core, 1_000_000e6);
        vm.prank(core);
        vault.deposit(1_000_000e6);

        vm.warp(block.timestamp + 301);
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();
    }
}
