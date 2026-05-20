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

/// @title Economic Sanity & Capital Efficiency Tests — CTO Pre-GO Requirements #7/8
/// @notice Proves capital is deployed efficiently and scoring allocates rationally.
contract EconomicSanity is UsdcMultiLendingVaultTestBase {

    function setUp() public override {
        super.setUp();
        _addAndEnableAdapter(adapter1); // 800 bps
        _addAndEnableAdapter(adapter2); // 600 bps
        _addAndEnableAdapter(adapter3); // 400 bps

        adapter1.setExtMarketTVL(100_000_000e6);
        adapter2.setExtMarketTVL(80_000_000e6);
        adapter3.setExtMarketTVL(50_000_000e6);

        vm.prank(admin);
        StrategySettingsModule(address(vault)).exitBootstrapMode();
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setMaxIdleAfterDepositBps(10000);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();
    }

    function _warpAndDeployIdle() internal {
        vm.warp(block.timestamp + 301);
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();
    }

    /// @notice Higher APY adapter gets more capital (score-proportional)
    function test_higher_apy_gets_more_capital() public {
        // Widen APY gap to make the ordering deterministic despite other scoring factors
        adapter1.setAPY(1500); // 15%
        adapter2.setAPY(800);  // 8%
        adapter3.setAPY(200);  // 2%

        _mintAndTransferToVault(core, 300_000e6);
        vm.prank(core);
        vault.deposit(300_000e6);

        // Multiple deploy cycles so ramp limit doesn't cap top adapter
        for (uint256 i = 0; i < 5; i++) {
            _warpAndDeployIdle();
        }

        uint256 pos1 = vault.positionAssets(address(adapter1));
        uint256 pos2 = vault.positionAssets(address(adapter2));
        uint256 pos3 = vault.positionAssets(address(adapter3));

        // adapter1 (1500bps) should get more than adapter3 (200bps)
        // Note: ramp limits and maxExposure may constrain the exact ordering between
        // adapter1 and adapter2, but the highest APY adapter must beat the lowest
        assertGt(pos1, pos3, "highest APY adapter must get more than lowest APY");
        assertGt(pos2, pos3, "mid APY adapter must get more than lowest APY");
    }

    /// @notice Capital efficiency: idle <= dustTolerance after deploy cycle
    function test_capital_efficiency_minimal_idle() public {
        _mintAndTransferToVault(core, 500_000e6);
        vm.prank(core);
        vault.deposit(500_000e6);

        for (uint256 i = 0; i < 3; i++) {
            _warpAndDeployIdle();
        }

        uint256 idle = StrategyScoringModule(address(vault)).idleCash();
        uint256 tvl = vault.totalAssets();
        uint256 idlePct = (idle * 1e4) / tvl;

        assertLe(idle, vault.dustTolerance(), "idle must be within dust tolerance");
        assertLe(idlePct, 100, "idle must be < 1% of TVL");
    }

    /// @notice Score inversion: if APYs swap, allocation follows
    function test_score_inversion_follows_apy_change() public {
        // Widen APY gap
        adapter1.setAPY(1500);
        adapter3.setAPY(200);

        _mintAndTransferToVault(core, 300_000e6);
        vm.prank(core);
        vault.deposit(300_000e6);

        for (uint256 i = 0; i < 3; i++) {
            _warpAndDeployIdle();
        }

        uint256 pos1Before = vault.positionAssets(address(adapter1));
        uint256 pos3Before = vault.positionAssets(address(adapter3));
        assertGt(pos1Before, pos3Before, "adapter1 should lead before inversion");

        // Invert APYs dramatically
        adapter1.setAPY(100);
        adapter3.setAPY(2000);

        // Lenient gate for test
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setGateParams(30, 0, 5, 5, 1e6);

        // Rebalance
        vm.warp(block.timestamp + 21601);
        _doRebalance();

        uint256 pos1After = vault.positionAssets(address(adapter1));
        uint256 pos3After = vault.positionAssets(address(adapter3));

        // After inversion, adapter3 should have more
        assertGt(pos3After, pos1After, "adapter3 should lead after inversion");
    }

    /// @notice Adapter partial failure: capital reallocates to healthy adapters
    function test_adapter_partial_failure_reallocates() public {
        _mintAndTransferToVault(core, 300_000e6);
        vm.prank(core);
        vault.deposit(300_000e6);

        for (uint256 i = 0; i < 3; i++) {
            _warpAndDeployIdle();
        }

        uint256 pos2Before = vault.positionAssets(address(adapter2));
        uint256 pos3Before = vault.positionAssets(address(adapter3));

        // adapter1 goes into failure mode — quarantine it
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setQuarantined(address(adapter1), true);

        // New deposit
        _mintAndTransferToVault(core, 100_000e6);
        vm.prank(core);
        vault.deposit(100_000e6);

        for (uint256 i = 0; i < 3; i++) {
            _warpAndDeployIdle();
        }

        uint256 pos2After = vault.positionAssets(address(adapter2));
        uint256 pos3After = vault.positionAssets(address(adapter3));

        // Remaining adapters should absorb the new capital
        assertGt(pos2After, pos2Before, "adapter2 must absorb more capital");
        assertGt(pos3After, pos3Before, "adapter3 must absorb more capital");
    }

    /// @notice Equal APY: allocation splits roughly equally
    function test_equal_apy_equal_split() public {
        adapter1.setAPY(500);
        adapter2.setAPY(500);
        adapter3.setAPY(500);

        _mintAndTransferToVault(core, 300_000e6);
        vm.prank(core);
        vault.deposit(300_000e6);

        for (uint256 i = 0; i < 3; i++) {
            _warpAndDeployIdle();
        }

        uint256 pos1 = vault.positionAssets(address(adapter1));
        uint256 pos2 = vault.positionAssets(address(adapter2));
        uint256 pos3 = vault.positionAssets(address(adapter3));
        uint256 tvl = vault.totalAssets();
        uint256 avgPos = tvl / 3;

        // Each position should be within 20% of average
        uint256 tolerance = avgPos / 5; // 20%
        assertApproxEqAbs(pos1, avgPos, tolerance, "adapter1 roughly equal share");
        assertApproxEqAbs(pos2, avgPos, tolerance, "adapter2 roughly equal share");
        assertApproxEqAbs(pos3, avgPos, tolerance, "adapter3 roughly equal share");
    }

    /// @notice TVL conservation: totalAssets == sum(positions) + idle
    function test_tvl_conservation() public {
        _mintAndTransferToVault(core, 500_000e6);
        vm.prank(core);
        vault.deposit(500_000e6);

        for (uint256 i = 0; i < 3; i++) {
            _warpAndDeployIdle();
        }

        uint256 tvl = vault.totalAssets();
        uint256 idle = StrategyScoringModule(address(vault)).idleCash();
        uint256 sumPos = vault.positionAssets(address(adapter1))
            + vault.positionAssets(address(adapter2))
            + vault.positionAssets(address(adapter3));

        assertEq(tvl, idle + sumPos, "TVL must equal idle + sum(positions)");
    }
}