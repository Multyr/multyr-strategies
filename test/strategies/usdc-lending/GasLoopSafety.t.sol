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

/// @title Gas Loop Safety Tests — CTO Pre-GO Requirement #5
/// @notice Proves gas usage stays within Arbitrum block limits even under
///         worst-case adapter configurations.
contract GasLoopSafety is UsdcMultiLendingVaultTestBase {
    MockLendingAdapter public adapter4;
    MockLendingAdapter public adapter5;
    MockLendingAdapter public adapter6;
    MockLendingAdapter public adapter7;
    MockLendingAdapter public adapter8;

    // Arbitrum L2 block gas limit is ~32M, but keeper transactions target < 10M
    uint256 constant MAX_GAS_TARGET = 10_000_000;

    function setUp() public override {
        super.setUp();

        adapter4 = new MockLendingAdapter(ARBITRUM_USDC);
        adapter5 = new MockLendingAdapter(ARBITRUM_USDC);
        adapter6 = new MockLendingAdapter(ARBITRUM_USDC);
        adapter7 = new MockLendingAdapter(ARBITRUM_USDC);
        adapter8 = new MockLendingAdapter(ARBITRUM_USDC);

        adapter4.setVault(address(vault));
        adapter5.setVault(address(vault));
        adapter6.setVault(address(vault));
        adapter7.setVault(address(vault));
        adapter8.setVault(address(vault));

        adapter4.setAPY(700);
        adapter5.setAPY(550);
        adapter6.setAPY(450);
        adapter7.setAPY(350);
        adapter8.setAPY(250);

        // Add all 8 adapters
        _addAndEnableAdapter(adapter1);
        _addAndEnableAdapter(adapter2);
        _addAndEnableAdapter(adapter3);
        _addAndEnableAdapter(adapter4);
        _addAndEnableAdapter(adapter5);
        _addAndEnableAdapter(adapter6);
        _addAndEnableAdapter(adapter7);
        _addAndEnableAdapter(adapter8);

        // Set up external TVLs
        adapter1.setExtMarketTVL(100_000_000e6);
        adapter2.setExtMarketTVL(80_000_000e6);
        adapter3.setExtMarketTVL(50_000_000e6);
        adapter4.setExtMarketTVL(30_000_000e6);
        adapter5.setExtMarketTVL(20_000_000e6);
        adapter6.setExtMarketTVL(10_000_000e6);
        adapter7.setExtMarketTVL(5_000_000e6);
        adapter8.setExtMarketTVL(1_000_000e6);

        // Allow higher adapter count for stress test
        vm.startPrank(admin);
        StrategySettingsModule(address(vault)).setRebalanceParams(
            8, 2, 50, 21600, 80, 2500, 5000
        );
        StrategySettingsModule(address(vault)).exitBootstrapMode();
        StrategySettingsModule(address(vault)).setMaxRelativeExposureBps(1000);
        vm.stopPrank();

        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();
    }

    /// @notice deployIdle with 8 adapters stays under gas target
    function test_deploy_idle_gas_8_adapters() public {
        _mintAndTransferToVault(core, 5_000_000e6);
        vm.prank(core);
        vault.deposit(5_000_000e6);

        vm.warp(block.timestamp + 301);

        uint256 gasBefore = gasleft();
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, MAX_GAS_TARGET, "deployIdle must stay under 10M gas with 8 adapters");
    }

    /// @notice rebalance with 8 adapters stays under gas target
    function test_rebalance_gas_8_adapters() public {
        _mintAndTransferToVault(core, 5_000_000e6);
        vm.prank(core);
        vault.deposit(5_000_000e6);

        // Deploy idle first
        vm.warp(block.timestamp + 301);
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();

        // Dramatic APY shift across multiple adapters to pass gate check under
        // REALISTIC costs. adapter8 extTVL=1M caps it at 100K (10% rel cap), so
        // shifting only adapter8 doesn't generate enough deltaAPY to overcome
        // realistic slippage+withdrawal. We also shift adapter2,adapter3 down
        // and adapter4,adapter5 up so the move involves cap-unbound adapters
        // (extTVL >= 20M) and produces a real economically-justified rebalance.
        adapter1.setAPY(100);   // was 800 — drop hard
        adapter2.setAPY(100);   // was 600 — drop hard
        adapter3.setAPY(150);   // was 400 — drop hard
        adapter4.setAPY(2500);  // was 700 — rise hard (extTVL 30M → cap 3M)
        adapter5.setAPY(2200);  // was 550 — rise hard (extTVL 20M → cap 2M)
        adapter8.setAPY(2000);  // was 250 — rise but cap-bound (100K)

        // Zero slippage/gas ensures gate passes regardless of tier-model cap adjustments.
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setGateParams(30, 0, 0, 0, 0);

        vm.warp(block.timestamp + 21601);

        uint256 gasBefore = gasleft();
        _doRebalance();
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, MAX_GAS_TARGET, "rebalance must stay under 10M gas with 8 adapters");
    }

    /// @notice deployIdle with most adapters failing: system doesn't revert, healthy adapters get funds
    function test_deploy_idle_gas_worst_case_failures() public {
        // Keep adapter1 (highest score) and adapter8 healthy, fail the rest
        adapter2.setDepositReverts(true);
        adapter3.setDepositReverts(true);
        adapter4.setDepositReverts(true);
        adapter5.setDepositReverts(true);
        adapter6.setDepositReverts(true);
        adapter7.setDepositReverts(true);

        // Transfer directly to vault (skip deposit strict mode)
        usdc.mint(address(vault), 1_000_000e6);

        vm.warp(block.timestamp + 301);

        uint256 gasBefore = gasleft();
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, MAX_GAS_TARGET, "deployIdle with failures must stay under 10M gas");

        // adapter1 (healthy, highest score) should receive funds
        uint256 pos1 = vault.positionAssets(address(adapter1));
        assertTrue(pos1 > 0, "healthy adapter should receive funds despite other failures");

        // Failed adapters should have 0
        assertEq(vault.positionAssets(address(adapter2)), 0, "failed adapter2 should have 0");
        assertEq(vault.positionAssets(address(adapter3)), 0, "failed adapter3 should have 0");
    }
}
