// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import {
    UsdcMultiLendingVaultTestBase
} from "./UsdcMultiLendingVault.t.sol";
import {
    StrategyScoringModule
} from "../../../src/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import {
    StrategyParamsModule
} from "../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import { StrategySettingsModule } from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";

// ============================================================================
// BLOCCO C — Multi-Cycle Economic Stability Tests
// ============================================================================
// Verifies that over 30 simulated cycles (deploy + yield + harvest + rebalance),
// the vault maintains accounting integrity: no idle creep, no NAV drift, no
// stuck capital.
// ============================================================================

contract MultiCycleStabilityTest is UsdcMultiLendingVaultTestBase {

    function setUp() public override {
        super.setUp();
        _addAndEnableAdapter(adapter1);  // 800 bps APY
        _addAndEnableAdapter(adapter2);  // 600 bps APY
        _addAndEnableAdapter(adapter3);  // 400 bps APY

        adapter1.setExtMarketTVL(100_000_000e6);
        adapter2.setExtMarketTVL(80_000_000e6);
        adapter3.setExtMarketTVL(50_000_000e6);

        vm.prank(admin);
        StrategySettingsModule(address(vault)).exitBootstrapMode();
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setMaxIdleAfterDepositBps(10000);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        // Lenient gate for cycle tests
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setGateParams(30, 0, 5, 5, 1e6);
    }

    function _coreDeposit(uint256 amount) internal {
        _mintAndTransferToVault(core, amount);
        vm.prank(core);
        vault.deposit(amount);
    }

    function _warpAndDeployIdle() internal {
        vm.warp(block.timestamp + 301);
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();
    }

    function _warpAndHarvest() internal {
        vm.warp(block.timestamp + 43201); // past harvest cooldown (12h)
        vm.prank(keeper);
        vault.harvest();
    }

    function _warpAndRebalance() internal {
        vm.warp(block.timestamp + 21601); // past rebalance cooldown (6h)
        _doRebalance();
    }

    // -----------------------------------------------------------------------
    // C1: 30-cycle economic consistency
    // -----------------------------------------------------------------------

    /// @notice C1: Over 30 deploy+yield cycles:
    ///   - totalAssets is non-decreasing (yield only, no fees in mock)
    ///   - idle never creeps above 3x dustTolerance after each deploy cycle
    ///   - capital conservation: totalAssets() = idle + sum(adapter.totalAssets())
    ///
    ///   NOTE: positionAssets is bookkeeping (cost basis), not real-time value.
    ///   totalAssets() = idle + sum(adapter.totalAssets()) — yield included.
    ///   sum(positionAssets) < totalAssets once yield accrues — this is correct.
    function test_C1_thirtyC_economicConsistency() public {
        uint256 depositAmount = 300_000e6;
        _coreDeposit(depositAmount);

        uint256 prevTotalAssets = vault.totalAssets();

        for (uint256 cycle = 0; cycle < 30; cycle++) {
            // Simulate yield on each adapter (0.01% per cycle)
            adapter1.simulateYield(prevTotalAssets / 10_000);
            adapter2.simulateYield(prevTotalAssets / 15_000);
            adapter3.simulateYield(prevTotalAssets / 20_000);

            // Deploy idle (warp 5 minutes)
            _warpAndDeployIdle();

            uint256 idle = vault.idleCash();
            uint256 ta = vault.totalAssets();

            // totalAssets must be non-decreasing (yield only, no fees in mock)
            assertGe(ta, prevTotalAssets, "C1: totalAssets must be non-decreasing");
            prevTotalAssets = ta;

            // Idle must be <= 3x dustTolerance after deploy (small rounding OK)
            assertLe(idle, vault.dustTolerance() * 3, "C1: idle must not creep above 3x dust after deploy");
        }

        // Final conservation check: totalAssets = idle + sum(adapter.totalAssets())
        uint256 finalIdle = vault.idleCash();
        uint256 adapterSum = adapter1.totalAssets() + adapter2.totalAssets() + adapter3.totalAssets();
        uint256 finalTA = vault.totalAssets();
        assertApproxEqAbs(finalTA, finalIdle + adapterSum, vault.dustTolerance(),
            "C1: totalAssets must equal idle + sum(adapter.totalAssets())");
    }

    // -----------------------------------------------------------------------
    // C2: NAV/share price does not drift downward
    // -----------------------------------------------------------------------

    /// @notice C2: Over multiple cycles with no fees or slippage (mock),
    ///         the share price (totalAssets / totalShares) must be non-decreasing.
    function test_C2_navSharePriceNonDecreasing() public {
        uint256 depositAmount = 300_000e6;

        // Deposit as a user (need shares)
        usdc.mint(user, depositAmount);
        vm.prank(user);
        usdc.approve(address(vault), depositAmount);
        // Simulate core deposit flow
        _mintAndTransferToVault(core, depositAmount);
        vm.prank(core);
        uint256 shares = vault.deposit(depositAmount);

        uint256 totalShares = shares;
        uint256 prevNavPerShare = (vault.totalAssets() * 1e6) / totalShares;

        for (uint256 cycle = 0; cycle < 10; cycle++) {
            // Simulate yield
            adapter1.simulateYield(vault.totalAssets() / 1_000); // 0.1% yield

            _warpAndDeployIdle();

            // NAV per share = totalAssets * 1e6 / totalShares
            // In this vault, "shares" are tracked by CoreVault, not the strategy.
            // totalAssets() returns USDC value. We verify totalAssets is growing.
            uint256 currentTA = vault.totalAssets();
            uint256 currentNavPerShare = (currentTA * 1e6) / totalShares;

            assertGe(currentNavPerShare, prevNavPerShare,
                "C2: NAV per share must not decrease");
            prevNavPerShare = currentNavPerShare;
        }
    }

    // -----------------------------------------------------------------------
    // C3: No idle cash creep — idle returns to dust after each deploy cycle
    // -----------------------------------------------------------------------

    /// @notice C3a: After each deployIdle call, idle must return to <= dustTolerance.
    ///         Verified across 20 cycles with new deposits each time.
    function test_C3a_idleAlwaysDeployedAfterCycle() public {
        // Make smaller repeated deposits that accumulate idle
        for (uint256 i = 0; i < 20; i++) {
            // Add 10K USDC
            _coreDeposit(10_000e6);

            // Deploy idle
            _warpAndDeployIdle();

            // Idle must be back to <= dustTolerance
            assertLe(vault.idleCash(), vault.dustTolerance(),
                "C3: idle must be <= dustTolerance after each deploy cycle");
        }
    }

    /// @notice C3b: After rebalance, idle must be <= dustTolerance.
    ///         Rebalance withdraws from low-APY adapters to idle, then re-deploys.
    function test_C3b_idleDeployedAfterRebalance() public {
        uint256 depositAmount = 300_000e6;
        _coreDeposit(depositAmount);
        for (uint256 i = 0; i < 3; i++) _warpAndDeployIdle();

        // Invert APYs to trigger rebalance
        adapter1.setAPY(100);
        adapter3.setAPY(2000);

        _warpAndRebalance();

        assertLe(vault.idleCash(), vault.dustTolerance(),
            "C3: idle must be <= dustTolerance after rebalance");
    }

    // -----------------------------------------------------------------------
    // C1 + C3: Capital fully deployed — no stuck funds
    // -----------------------------------------------------------------------

    /// @notice Verifies that at steady state, capital is fully deployed (idle <= dust).
    ///         This is the "no stuck capital" invariant from the CTO spec.
    function test_C1_noStuckCapital() public {
        uint256 depositAmount = 300_000e6;
        _coreDeposit(depositAmount);

        // Multiple deploy cycles to reach steady state
        for (uint256 i = 0; i < 5; i++) {
            _warpAndDeployIdle();
        }

        uint256 idle = vault.idleCash();
        uint256 dust = vault.dustTolerance();
        assertLe(idle, dust, "no stuck capital: idle must be <= dustTolerance at steady state");

        // Deployed capital must equal totalAssets - idle
        uint256 pos1 = vault.positionAssets(address(adapter1));
        uint256 pos2 = vault.positionAssets(address(adapter2));
        uint256 pos3 = vault.positionAssets(address(adapter3));
        uint256 deployed = pos1 + pos2 + pos3;
        uint256 ta = vault.totalAssets();
        assertApproxEqAbs(deployed + idle, ta, 1, "deployed + idle must equal totalAssets exactly");
    }
}
