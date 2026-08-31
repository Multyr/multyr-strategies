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

/// @title Keeper Failure Tests — CTO Pre-GO Requirement #3
/// @notice Proves the system handles keeper failures, adapter failures, and
///         extended keeper absence gracefully.
contract KeeperFailure is UsdcMultiLendingVaultTestBase {

    function setUp() public override {
        super.setUp();
        _addAndEnableAdapter(adapter1);
        _addAndEnableAdapter(adapter2);
        _addAndEnableAdapter(adapter3);

        // Exit bootstrap BEFORE deposit so deploy path is standard
        vm.prank(admin);
        StrategySettingsModule(address(vault)).exitBootstrapMode();
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setMaxIdleAfterDepositBps(10000);
    }

    function _warpAndDeployIdle() internal {
        vm.warp(block.timestamp + 301);
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();
    }

    /// @notice Single adapter deposit failure: funds go to remaining adapters
    function test_single_adapter_deposit_failure() public {
        // First deposit healthy funds (adapter1 works)
        _mintAndTransferToVault(core, 100_000e6);
        vm.prank(core);
        vault.deposit(100_000e6);
        _warpAndDeployIdle();

        // Now break adapter1 and send more funds
        adapter1.setDepositReverts(true);
        uint256 pos1Before = vault.positionAssets(address(adapter1));

        // Transfer directly to vault (skip deposit strict mode) and use keeper deployIdle
        usdc.mint(address(vault), 200_000e6);
        _warpAndDeployIdle();

        // adapter1 position should not increase (deposit fails)
        uint256 pos1After = vault.positionAssets(address(adapter1));
        uint256 pos2 = vault.positionAssets(address(adapter2));
        uint256 pos3 = vault.positionAssets(address(adapter3));

        assertEq(pos1After, pos1Before, "failed adapter position must not increase");
        assertTrue(pos2 > 0 || pos3 > 0, "other adapters should receive funds");
    }

    /// @notice Multiple adapter failures: system doesn't revert, remaining adapter gets funds
    function test_multiple_adapter_failures() public {
        adapter1.setDepositReverts(true);
        adapter2.setDepositReverts(true);

        // Transfer directly to vault and use keeper deployIdle (bestEffort=true)
        usdc.mint(address(vault), 300_000e6);
        _warpAndDeployIdle();

        uint256 pos1 = vault.positionAssets(address(adapter1));
        uint256 pos2 = vault.positionAssets(address(adapter2));
        uint256 pos3 = vault.positionAssets(address(adapter3));

        assertEq(pos1, 0, "failed adapter1 should have no position");
        assertEq(pos2, 0, "failed adapter2 should have no position");
        assertTrue(pos3 > 0, "adapter3 should receive funds");
    }

    /// @notice Auto-quarantine kicks in after threshold failures (threshold=3 for test)
    function test_auto_quarantine_after_threshold() public {
        // Low threshold for test speed (production=10)
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setQuarantineThreshold(3);

        adapter1.setDepositReverts(true);

        // Each deployIdle counts 1 failure (retry uses countFailure=false)
        for (uint256 i = 0; i < 4; i++) {
            usdc.mint(address(vault), 100_000e6);
            _warpAndDeployIdle();
        }

        assertTrue(vault.quarantined(address(adapter1)), "quarantined after repeated failures");
        // V9.1: depositsDisabled does NOT cascade on quarantine
        assertFalse(vault.depositsDisabled(), "deposits should NOT be disabled");
    }

    /// @notice No keeper for 7 days: funds stay idle, no loss, system recoverable
    function test_no_keeper_forever() public {
        _mintAndTransferToVault(core, 300_000e6);
        vm.prank(core);
        vault.deposit(300_000e6);

        // Deploy idle once so some funds are in adapters
        _warpAndDeployIdle();
        uint256 tvlBefore = vault.totalAssets();

        // Warp 7 days with no keeper action
        vm.warp(block.timestamp + 7 days);

        // TVL should be preserved (no loss from inaction)
        uint256 tvlAfter = vault.totalAssets();
        assertGe(tvlAfter, tvlBefore, "TVL must not decrease without keeper");

        // System should still accept deposits
        _mintAndTransferToVault(core, 50_000e6);
        vm.prank(core);
        vault.deposit(50_000e6);

        // Keeper can resume and deploy idle
        _warpAndDeployIdle();
        uint256 idle = StrategyScoringModule(address(vault)).idleCash();
        assertLe(idle, vault.dustTolerance(), "idle should converge after keeper resumes");
    }

    /// @notice Adapter withdraw failure during rebalance: system doesn't brick
    function test_withdraw_failure_during_rebalance() public {
        _mintAndTransferToVault(core, 300_000e6);
        vm.prank(core);
        vault.deposit(300_000e6);

        // Deploy funds first
        _warpAndDeployIdle();

        // Now make adapter1 fail on withdraw
        adapter1.setWithdrawReverts(true);

        // Dramatic APY shift: adapter3 from 400→1500, adapter1 from 800→100
        adapter1.setAPY(100);
        adapter3.setAPY(1500);

        // Zero slippage/gas ensures gate passes regardless of tier-model cap adjustments.
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setGateParams(30, 0, 0, 0, 0);

        // Warp past rebalance cooldown
        vm.warp(block.timestamp + 21601);

        // Rebalance should still succeed (best-effort withdraw skips broken adapter)
        _doRebalance();

        // System should still be functional
        uint256 tvl = vault.totalAssets();
        assertTrue(tvl > 0, "system must remain functional after withdraw failure");
    }
}
