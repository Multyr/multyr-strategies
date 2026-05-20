// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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

/// @title Idle Convergence Tests — CTO Pre-GO Requirement #1
/// @notice Proves idle always converges to zero deterministically.
contract IdleConvergence is UsdcMultiLendingVaultTestBase {
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

        _addAndEnableAdapter(adapter1); // 800 bps
        _addAndEnableAdapter(adapter2); // 600 bps
        _addAndEnableAdapter(adapter3); // 400 bps
        _addAndEnableAdapter(adapter4); // 700 bps
        _addAndEnableAdapter(adapter5); // 600 bps

        adapter1.setExtMarketTVL(100_000_000e6);
        adapter2.setExtMarketTVL(80_000_000e6);
        adapter3.setExtMarketTVL(20_000_000e6);

        vm.prank(admin);
        StrategySettingsModule(address(vault)).exitBootstrapMode();
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setMaxIdleAfterDepositBps(10000);
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setMaxRelativeExposureBps(1000);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();
    }

    function _deployIdle() internal {
        vm.warp(block.timestamp + 301);
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();
    }

    /// @notice Idle decreases monotonically with each deployIdle cycle
    function test_idle_decreases_monotonically_per_cycle() public {
        _mintAndTransferToVault(core, 1_000_000e6);
        vm.prank(core);
        vault.deposit(1_000_000e6);

        uint256 prevIdle = vault.idleCash();
        for (uint256 i = 0; i < 5; i++) {
            _deployIdle();
            uint256 currentIdle = vault.idleCash();
            assertLe(currentIdle, prevIdle, "idle must decrease monotonically");
            prevIdle = currentIdle;
            if (currentIdle == 0) break;
        }
    }

    /// @notice Idle reaches zero within 3 cycles for any distribution
    function test_idle_zero_within_3_cycles() public {
        _mintAndTransferToVault(core, 500_000e6);
        vm.prank(core);
        vault.deposit(500_000e6);

        for (uint256 i = 0; i < 3; i++) {
            if (vault.idleCash() <= vault.dustTolerance()) break;
            _deployIdle();
        }

        assertLe(vault.idleCash(), vault.dustTolerance(), "idle must be zero within 3 cycles");
    }

    /// @notice Idle converges even with cap constraints limiting adapters
    function test_idle_convergence_with_cap_constraints() public {
        // Set low maxExposure to force caps
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setRebalanceParams(
            5, 2, 50, 21600, 80, 2500, 8000 // maxExposureBps=25%
        );

        _mintAndTransferToVault(core, 1_000_000e6);
        vm.prank(core);
        vault.deposit(1_000_000e6);

        for (uint256 i = 0; i < 5; i++) {
            if (vault.idleCash() <= vault.dustTolerance()) break;
            _deployIdle();
        }

        assertLe(vault.idleCash(), vault.dustTolerance(), "idle must converge with cap constraints");
    }

    /// @notice Idle converges despite keeper delay (1h, 6h, 24h between cycles)
    function test_idle_convergence_with_keeper_delay() public {
        _mintAndTransferToVault(core, 500_000e6);
        vm.prank(core);
        vault.deposit(500_000e6);

        // Cycle 1: 1h delay
        vm.warp(block.timestamp + 3600);
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();

        // Cycle 2: 6h delay
        vm.warp(block.timestamp + 21600);
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();

        // Cycle 3: 24h delay
        vm.warp(block.timestamp + 86400);
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();

        assertLe(vault.idleCash(), vault.dustTolerance(), "idle must converge despite keeper delay");
    }

    /// @notice Idle converges when only 2 of 5 adapters have headroom
    function test_idle_convergence_partial_allocation() public {
        // Set adapter1-3 maxCap very low → nearly full after first deposit
        adapter1.setMaxCap(10_000e6);
        adapter2.setMaxCap(10_000e6);
        adapter3.setMaxCap(10_000e6);
        // adapter4+5 have unlimited capacity

        _mintAndTransferToVault(core, 200_000e6);
        vm.prank(core);
        vault.deposit(200_000e6);

        for (uint256 i = 0; i < 3; i++) {
            if (vault.idleCash() <= vault.dustTolerance()) break;
            _deployIdle();
        }

        assertLe(vault.idleCash(), vault.dustTolerance(), "idle must converge with partial headroom");
    }
}