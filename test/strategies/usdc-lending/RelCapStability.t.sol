// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
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
    MockUSDC,
    MockLendingAdapter,
    UsdcMultiLendingVaultTestBase
} from "./UsdcMultiLendingVault.t.sol";

/// @title Relative Cap Stability Tests — CTO Pre-GO Requirement #4
/// @notice Proves maxExposure and relCap interaction is stable across TVL ranges.
contract RelCapStability is UsdcMultiLendingVaultTestBase {

    function setUp() public override {
        super.setUp();
        _addAndEnableAdapter(adapter1);
        _addAndEnableAdapter(adapter2);
        _addAndEnableAdapter(adapter3);

        // Set external market TVLs
        adapter1.setExtMarketTVL(100_000_000e6); // 100M
        adapter2.setExtMarketTVL(50_000_000e6);  // 50M
        adapter3.setExtMarketTVL(5_000_000e6);   // 5M

        vm.prank(admin);
        StrategySettingsModule(address(vault)).exitBootstrapMode();
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setMaxRelativeExposureBps(1000); // 10%
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();
    }

    function _warpAndDeployIdle() internal {
        vm.warp(block.timestamp + 301);
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();
    }

    /// @notice RelCap limits allocation to small-market adapter
    function test_relcap_limits_small_market() public {
        _mintAndTransferToVault(core, 1_000_000e6);
        vm.prank(core);
        vault.deposit(1_000_000e6);

        // Deploy idle cycles
        for (uint256 i = 0; i < 3; i++) {
            _warpAndDeployIdle();
        }

        // adapter3 has 5M ext TVL, relCap = 12% of 5M = 600K
        // With 1M vault TVL and maxExposure=50%, maxExp = 500K
        // maxExposure is the tighter constraint here
        uint256 pos3 = vault.positionAssets(address(adapter3));
        uint256 maxExp = (uint256(vault.adapterMaxExposureBps()) * vault.totalAssets()) / 1e4;
        assertLe(pos3, maxExp + vault.dustTolerance(), "adapter3 must respect maxExposure cap");
    }

    /// @notice maxExposure + relCap: tighter constraint wins
    function test_tighter_constraint_wins() public {
        // TRIAGE A1: adapterMaxExposureBps no longer governs cap — effectiveAbsCapBps does.
        // Use setAdapterAbsCapOverride to enforce 20% governance floor on all 3 adapters.
        vm.startPrank(admin);
        StrategySettingsModule(address(vault)).setAdapterAbsCapOverride(address(adapter1), 2000);
        StrategySettingsModule(address(vault)).setAdapterAbsCapOverride(address(adapter2), 2000);
        StrategySettingsModule(address(vault)).setAdapterAbsCapOverride(address(adapter3), 2000);
        StrategySettingsModule(address(vault)).setMaxIdleAfterDepositBps(10000);
        vm.stopPrank();

        _mintAndTransferToVault(core, 500_000e6);
        vm.prank(core);
        vault.deposit(500_000e6);

        for (uint256 i = 0; i < 5; i++) {
            _warpAndDeployIdle();
        }

        // effectiveAbsCapBps returns max(STRUCTURAL_BASE, override) = max(40%, 20%) = 40%
        // But relCap (10% × extTVL) is the binding constraint for adapter3 (5M × 10% = 500K).
        // For adapters 1+2: relCap = 10% × 100M/50M >> TVL, so STRUCTURAL_BASE (40%) binds.
        uint256 tvl = vault.totalAssets();
        uint256 structuralCap = (4000 * tvl) / 1e4; // T3 dMax=3 → ceil(11000/3)=3667 bps, min 40%

        assertLe(vault.positionAssets(address(adapter1)), structuralCap + vault.dustTolerance(), "adapter1 within maxExp");
        assertLe(vault.positionAssets(address(adapter2)), structuralCap + vault.dustTolerance(), "adapter2 within maxExp");
        assertLe(vault.positionAssets(address(adapter3)), structuralCap + vault.dustTolerance(), "adapter3 within maxExp");
    }

    /// @notice RelCap is stable across multiple deployIdle cycles
    function test_relcap_stable_across_cycles() public {
        _mintAndTransferToVault(core, 500_000e6);
        vm.prank(core);
        vault.deposit(500_000e6);

        // Run 5 cycles
        uint256[] memory positions = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            _warpAndDeployIdle();
            positions[i] = vault.positionAssets(address(adapter3));
        }

        // Positions should stabilize (not oscillate)
        // After cycle 2, delta should be <= dustTolerance
        for (uint256 i = 2; i < 5; i++) {
            uint256 delta = positions[i] > positions[i-1]
                ? positions[i] - positions[i-1]
                : positions[i-1] - positions[i];
            assertLe(delta, vault.dustTolerance(), "position must stabilize after cycle 2");
        }
    }

    /// @notice Manual relCap override is more restrictive than dynamic
    function test_manual_relcap_override() public {
        // Set very restrictive manual override (5%)
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setMaxRelativeExposureBps(500);

        _mintAndTransferToVault(core, 500_000e6);
        vm.prank(core);
        vault.deposit(500_000e6);

        for (uint256 i = 0; i < 3; i++) {
            _warpAndDeployIdle();
        }

        // adapter1 extTVL=100M, manual relCap=5% => 5M cap (won't bind here)
        // adapter3 extTVL=5M, manual relCap=5% => 250K cap
        uint256 pos3 = vault.positionAssets(address(adapter3));
        uint256 manualCap = (5_000_000e6 * 500) / 1e4; // 250K
        assertLe(pos3, manualCap + vault.dustTolerance(), "adapter3 must respect manual relCap");
    }

    /// @notice Dynamic relCap scales with external TVL bands
    function test_dynamic_relcap_scales_correctly() public {
        // adapter3 has 5M ext TVL -> dynamic relCap = 12% = 600K
        _mintAndTransferToVault(core, 2_000_000e6);
        vm.prank(core);
        vault.deposit(2_000_000e6);

        // Remove manual override
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setMaxRelativeExposureBps(0);

        for (uint256 i = 0; i < 5; i++) {
            _warpAndDeployIdle();
        }

        // Dynamic relCap for 5M ext TVL = 12% = 600K
        uint256 pos3 = vault.positionAssets(address(adapter3));
        uint256 dynCap = (5_000_000e6 * 1200) / 1e4; // 600K
        assertLe(pos3, dynCap + vault.dustTolerance(), "adapter3 must respect dynamic relCap");
    }
}
