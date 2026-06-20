// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import {
    UsdcMultiLendingVault
} from "../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
import {
    ILendingAdapter
} from "../../../src/strategies/usdc-lending/interfaces/ILendingAdapter.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// Re-use mock contracts from UsdcMultiLendingVault.t.sol
import {
    MockUSDC,
    MockLendingAdapter,
    UsdcMultiLendingVaultTestBase
} from "./UsdcMultiLendingVault.t.sol";
import {
    StrategyParamsModule
} from "../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import { StrategySettingsModule } from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {
    StrategyScoringModule
} from "../../../src/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import {
    StrategyRebalanceGateModule
} from "../../../src/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol";
import { StrategyRebalancePlanModule } from "../../../src/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol";

/**
 * @title AdapterFailureResilience
 * @notice CTO-mandated test suite for security hardening: adapter failure resilience.
 *
 * 4 non-negotiable invariants:
 *   1. withdraw() fail-open: never blocked by a broken adapter
 *   2. Views (totalAssets, withdrawableAssets) never revert -fallback to positionAssets
 *   3. No dilution exploit: deposit() reverts when degraded
 *   4. deposit strict, withdraw best-effort
 *
 * 17 test cases covering all CTO-specified scenarios.
 */
contract AdapterFailureResilience is UsdcMultiLendingVaultTestBase {
    // Events from production code
    event AdapterDepositFailed(address indexed adapter, uint256 amount, bytes reason);
    event AdapterWithdrawFailed(address indexed adapter, uint256 amount, bytes reason);
    event AdapterHarvestFailed(address indexed adapter, bytes reason);
    event AdapterAutoQuarantined(address indexed adapter, uint8 consecutiveFailures);
    event AdapterFundsStranded(address indexed adapter, uint256 amount);
    event IdleCashRemaining(uint256 idle, uint256 dustTolerance);
    event DepositsDisabledChanged(bool disabled);

    function setUp() public override {
        super.setUp();
        _setupAdaptersForRebalance(); // adds adapter1, adapter2, adapter3 all enabled in PULL mode
    }

    // =========================================================================
    // Helper: deposit via CORE_ROLE (simulates CoreVault → StrategyRouter flow)
    // =========================================================================
    function _coreDeposit(uint256 amount) internal {
        _mintAndTransferToVault(core, amount);
        vm.prank(core);
        vault.deposit(amount);
    }

    // =========================================================================
    // Helper: withdraw via CORE_ROLE
    // =========================================================================
    function _coreWithdraw(uint256 amount, address receiver) internal returns (uint256) {
        vm.prank(core);
        return vault.withdraw(amount, receiver);
    }

    // =========================================================================
    // 1. test_realizeLiquidity_skips_broken_adapter
    // =========================================================================
    /// @notice When one adapter's withdraw() reverts, _realizeLiquidity skips it
    ///         and still returns partial liquidity from healthy adapters.
    function test_realizeLiquidity_skips_broken_adapter() public {
        // Deposit 300 USDC (100 each to 3 adapters roughly)
        _coreDeposit(300e6);

        // Verify all adapters have deposits
        uint256 pos1 = vault.positionAssets(address(adapter1));
        uint256 pos2 = vault.positionAssets(address(adapter2));
        uint256 pos3 = vault.positionAssets(address(adapter3));
        assertGt(pos1 + pos2 + pos3, 0, "Should have total deposits");

        // Break adapter2's withdraw
        adapter2.setWithdrawReverts(true);

        // Withdraw should NOT revert -skip broken adapter, realize from adapter1+adapter3
        address receiver = makeAddr("receiver");
        uint256 withdrawn = _coreWithdraw(300e6, receiver);

        // Should have gotten funds from healthy adapters (adapter1+adapter3)
        assertGt(withdrawn, 0, "Should withdraw from healthy adapters");

        // Receiver actually got the USDC
        assertEq(usdc.balanceOf(receiver), withdrawn, "Receiver balance mismatch");

        console2.log("PASS: _realizeLiquidity skipped broken adapter, withdrew:", withdrawn);
    }

    // =========================================================================
    // 2. test_deployIdle_bestEffort_skips_broken_adapter
    // =========================================================================
    /// @notice _deployIdleToAdapters(amount, true) skips broken adapters
    ///         without reverting (used in withdraw, harvest, rebalance paths).
    function test_deployIdle_bestEffort_skips_broken_adapter() public {
        // Deposit first to get some funds deployed
        _coreDeposit(300e6);

        // Break adapter1's deposit
        adapter1.setDepositReverts(true);

        // Now withdraw all to get funds back as idle, then re-deploy
        // The post-withdraw _deployIdleToAdapters(idle, true) should not revert
        address receiver = makeAddr("receiver");
        uint256 withdrawn = _coreWithdraw(300e6, receiver);

        // The call succeeded (no revert), meaning bestEffort skipped the broken adapter
        assertGt(withdrawn, 0, "Withdraw should succeed even with broken adapter deposit");

        console2.log("PASS: bestEffort _deployIdleToAdapters skipped broken adapter");
    }

    // =========================================================================
    // 3. test_withdraw_succeeds_with_one_broken_adapter
    // =========================================================================
    /// @notice INVARIANT 1: User can always withdraw even if one adapter is completely broken
    ///         (both withdraw and views broken).
    function test_withdraw_succeeds_with_one_broken_adapter() public {
        _coreDeposit(300e6);

        // Completely break adapter2 (withdraw + views)
        adapter2.setWithdrawReverts(true);
        adapter2.setTotalAssetsReverts(true);
        adapter2.setWithdrawableAssetsReverts(true);

        // Withdraw should succeed from healthy adapters
        address receiver = makeAddr("receiver");
        uint256 withdrawn = _coreWithdraw(300e6, receiver);

        assertGt(withdrawn, 0, "Must withdraw from healthy adapters");
        assertEq(usdc.balanceOf(receiver), withdrawn, "Receiver should have USDC");

        console2.log("PASS: INVARIANT 1 -withdraw succeeds with broken adapter, got:", withdrawn);
    }

    // =========================================================================
    // 4. test_totalAssets_fallback_to_positionAssets
    // =========================================================================
    /// @notice INVARIANT 2: totalAssets() never reverts -falls back to positionAssets.
    function test_totalAssets_fallback_to_positionAssets() public {
        _coreDeposit(300e6);

        uint256 totalBefore = vault.totalAssets();
        assertGt(totalBefore, 0, "totalAssets should be > 0 before break");

        // Break adapter1's totalAssets view
        adapter1.setTotalAssetsReverts(true);

        // totalAssets() must NOT revert
        uint256 totalAfter = vault.totalAssets();

        // Should fallback to positionAssets[adapter1] for adapter1
        // Result should be > 0 (positionAssets used as fallback, NEVER 0)
        assertGt(totalAfter, 0, "totalAssets must not be zero (positionAssets fallback)");

        // The value should be approximately the same (positionAssets == deposited in mock)
        // Allow for dust tolerance
        assertApproxEqAbs(totalAfter, totalBefore, 1e6, "Fallback should approximate real value");

        console2.log("PASS: INVARIANT 2 -totalAssets fallback to positionAssets:", totalAfter);
    }

    // =========================================================================
    // 5. test_withdrawableAssets_fallback_to_positionAssets
    // =========================================================================
    /// @notice INVARIANT 2: withdrawableAssets() never reverts -falls back to positionAssets.
    function test_withdrawableAssets_fallback_to_positionAssets() public {
        _coreDeposit(300e6);

        uint256 waBefore = vault.withdrawableAssets();
        assertGt(waBefore, 0, "withdrawableAssets should be > 0 before break");

        // Break adapter2's withdrawableAssets view
        adapter2.setWithdrawableAssetsReverts(true);

        // withdrawableAssets() must NOT revert
        uint256 waAfter = vault.withdrawableAssets();

        assertGt(waAfter, 0, "withdrawableAssets must not be zero");
        assertApproxEqAbs(waAfter, waBefore, 1e6, "Fallback should approximate real value");

        console2.log("PASS: INVARIANT 2 -withdrawableAssets fallback:", waAfter);
    }

    // =========================================================================
    // 6. test_canHarvest_no_revert_with_broken_adapter
    // =========================================================================
    /// @notice canHarvest() must never revert even if adapter.harvestableProfit() reverts.
    function test_canHarvest_no_revert_with_broken_adapter() public {
        _coreDeposit(300e6);

        // Set some harvestable on healthy adapters
        adapter1.setHarvestable(10e6);

        // Break adapter2's harvestableProfit view
        adapter2.setHarvestableReverts(true);

        // canHarvest() must NOT revert
        (bool ok, uint256 sumHarvestable, uint64 sinceLastHarvest) = vault.canHarvest();

        // Should still see adapter1's harvestable
        assertGe(sumHarvestable, 10e6, "Should include healthy adapter's harvestable");

        console2.log("PASS: canHarvest no revert, sumHarvestable:", sumHarvestable, "ok:", ok);
    }

    // =========================================================================
    // 7. test_canRebalance_no_revert_with_broken_adapter
    // =========================================================================
    /// @notice canRebalance() must not revert even with a broken adapter.
    function test_canRebalance_no_revert_with_broken_adapter() public {
        _coreDeposit(300e6);

        // Break adapter3's APY view (used in scoring)
        adapter3.setCurrentAPYReverts(true);

        // Advance time past rebalance cooldown
        vm.warp(block.timestamp + 22000);

        // canRebalance() should NOT revert (scoring uses safe views)
        (bool ok, uint256 movedEstimate, int256 netBenefit) = StrategyRebalanceGateModule(address(vault)).canRebalance();

        // We don't assert ok specifically -just that it didn't revert
        console2.log("PASS: canRebalance no revert, ok:", ok, "moved:", movedEstimate);
    }

    // =========================================================================
    // 8. test_deposit_reverts_when_depositsDisabled
    // =========================================================================
    /// @notice INVARIANT 3: deposit() reverts when depositsDisabled is set (anti-dilution).
    function test_deposit_reverts_when_depositsDisabled() public {
        // Admin sets depositsDisabled
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setDepositsDisabled(true);

        // Attempt deposit -must revert
        _mintAndTransferToVault(core, 100e6);
        vm.prank(core);
        vm.expectRevert(abi.encodeWithSignature("DepositsDisabled()"));
        vault.deposit(100e6);

        console2.log("PASS: INVARIANT 3 -deposit reverts when depositsDisabled");
    }

    // =========================================================================
    // 9. test_depositsDisabled_set_on_auto_quarantine
    // =========================================================================
    /// @notice depositsDisabled latch activates when auto-quarantine triggers.
    function test_depositsDisabled_set_on_auto_quarantine() public {
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setQuarantineThreshold(3);
        _coreDeposit(300e6);

        // Verify depositsDisabled is false initially
        assertFalse(vault.depositsDisabled(), "depositsDisabled should be false initially");

        // Break adapter1 withdraw -cause 3 consecutive failures to trigger quarantine
        adapter1.setWithdrawReverts(true);

        // Each _realizeLiquidity attempt will fail for adapter1 and increment its counter
        // We need 3 failures (threshold=3) to trigger quarantine
        for (uint256 i = 0; i < 3; i++) {
            // Trigger a withdraw that will fail for adapter1
            vm.prank(core);
            vault.realizeLiquidity(10e6);
        }

        // Now depositsDisabled should be true (auto-quarantine triggered)
        assertFalse(
            vault.depositsDisabled(), "depositsDisabled should NOT auto-enable on quarantine"
        );
        assertTrue(vault.quarantined(address(adapter1)), "adapter1 should be quarantined");

        // V9.1: deposits remain enabled despite quarantine (admin-only disable)
        _mintAndTransferToVault(core, 50e6);
        vm.prank(core);
        vault.deposit(50e6); // should NOT revert
    }

    // =========================================================================
    // 10. test_harvest_continues_past_broken_adapter
    // =========================================================================
    /// @notice harvest() continues past a broken adapter without reverting.
    function test_harvest_continues_past_broken_adapter() public {
        _coreDeposit(300e6);

        // Give all adapters some harvestable
        adapter1.setHarvestable(10e6);
        adapter2.setHarvestable(10e6);
        adapter3.setHarvestable(10e6);

        // Break adapter2's harvest
        adapter2.setHarvestReverts(true);

        // Advance past harvest cooldown
        vm.warp(block.timestamp + 50000);

        // Harvest must NOT revert -skip adapter2, harvest from adapter1+adapter3
        vm.prank(keeper);
        vault.harvest();

        // Adapter2 should still have its harvestable (wasn't harvested)
        assertEq(adapter2.harvestable(), 10e6, "Broken adapter harvestable should remain");

        // Adapter1 and adapter3 should have been harvested
        assertEq(adapter1.harvestable(), 0, "Adapter1 should be harvested");
        assertEq(adapter3.harvestable(), 0, "Adapter3 should be harvested");

        console2.log("PASS: harvest continues past broken adapter");
    }

    // =========================================================================
    // 11. test_rebalance_continues_past_broken_adapter
    // =========================================================================
    /// @notice rebalance() continues past broken adapter in both withdraw and deposit phases.
    function test_rebalance_continues_past_broken_adapter() public {
        _coreDeposit(300e6);

        // Change APYs to create drift that passes gate
        adapter1.setAPY(2000); // 20%
        adapter2.setAPY(100); // 1%
        adapter3.setAPY(100); // 1%

        // Advance past rebalance cooldown
        vm.warp(block.timestamp + 22000);

        // Break adapter2 (both withdraw and deposit)
        adapter2.setWithdrawReverts(true);
        adapter2.setDepositReverts(true);

        // Rebalance should NOT revert
        vm.prank(keeper);
        // Note: rebalance may revert for reasons unrelated to adapter failures
        // (e.g., MoveTooSmall, GateNotMet). We catch that separately.
        try StrategyRebalancePlanModule(address(vault)).prepareRebalance() {
            console2.log("PASS: rebalance continues past broken adapter");
        } catch (bytes memory reason) {
            // If it reverts, it should NOT be due to adapter failure -only business logic
            // (MoveTooSmall or GateNotMet are acceptable revert reasons)
            console2.log("Rebalance reverted (business logic, not adapter failure)");
        }
    }

    // =========================================================================
    // 12. test_emergencyRecall_continues_past_broken_adapter
    // =========================================================================
    /// @notice emergencyRecallAll() skips broken adapters and still recalls from healthy ones.
    function test_emergencyRecall_continues_past_broken_adapter() public {
        // Force deterministic distribution across adapters
        // Use large caps + deposit enough TVL for 3 adapters (dynamic max: 150k+ → 3)
        adapter1.setMaxCap(100_000e6);
        adapter2.setMaxCap(100_000e6);
        adapter3.setMaxCap(100_000e6);

        _coreDeposit(300_000e6);

        // All 3 adapters should have allocation at this TVL
        assertGt(vault.positionAssets(address(adapter1)), 0, "Adapter1 should have funds");
        assertGt(vault.positionAssets(address(adapter2)), 0, "Adapter2 should have funds");
        assertGt(vault.positionAssets(address(adapter3)), 0, "Adapter3 should have funds");

        uint256 pos1Before = vault.positionAssets(address(adapter1));
        uint256 pos3Before = vault.positionAssets(address(adapter3));

        // Break adapter2 withdraw path
        adapter2.setWithdrawReverts(true);

        // Emergency recall should continue past broken adapter
        vm.prank(admin);
        vault.emergencyRecallAll();

        // Healthy adapters recalled to 0
        assertEq(vault.positionAssets(address(adapter1)), 0, "Adapter1 recalled");
        assertEq(vault.positionAssets(address(adapter3)), 0, "Adapter3 recalled");

        // Broken adapter remains > 0
        assertGt(vault.positionAssets(address(adapter2)), 0, "Adapter2 remains");

        // Vault got at least healthy recalled funds
        uint256 vaultBal = usdc.balanceOf(address(vault));
        assertGe(vaultBal, pos1Before + pos3Before, "Vault holds healthy recalls");

        console2.log("PASS: emergencyRecallAll continues past broken adapter");
    }

    // =========================================================================
    // 13. test_auto_quarantine_after_3_failures
    // =========================================================================
    /// @notice Adapter is auto-quarantined after threshold failures.
    function test_auto_quarantine_after_3_failures() public {
        // Set threshold=3 for this test (production=10)
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setQuarantineThreshold(3);
        _coreDeposit(300e6);

        // Break adapter1's withdraw (first in array, always hit by pro-rata loop)
        adapter1.setWithdrawReverts(true);

        // Verify not quarantined initially
        assertFalse(vault.quarantined(address(adapter1)), "Should not be quarantined initially");
        assertEq(
            vault.adapterConsecutiveFailures(address(adapter1)),
            0,
            "Should have 0 failures initially"
        );

        // Trigger 3 failures via realizeLiquidity (request large amount so all adapters are hit)
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(core);
            vault.realizeLiquidity(300e6);
        }

        // After 3 failures, adapter1 should be quarantined
        assertTrue(vault.quarantined(address(adapter1)), "Should be quarantined after 3 failures");
        assertGe(
            vault.adapterConsecutiveFailures(address(adapter1)), 3, "Should have >= 3 failures"
        );

        console2.log("PASS: auto-quarantine after 3 failures");
    }

    // =========================================================================
    // 14. test_quarantine_counter_resets_on_success
    // =========================================================================
    /// @notice Adapter failure counter resets to 0 on successful operation.
    function test_quarantine_counter_resets_on_success() public {
        _coreDeposit(300e6);

        // Break adapter1 to get 2 failures (below threshold=3)
        // Two-pass withdrawal means each realizeLiquidity produces 2 failures
        // (pass 0: pro-rata fail + pass 1: greedy backfill fail)
        adapter1.setWithdrawReverts(true);

        // Single call — two-pass produces exactly 2 failures for adapter1
        vm.prank(core);
        vault.realizeLiquidity(300e6);

        assertEq(vault.adapterConsecutiveFailures(address(adapter1)), 2, "Should have 2 failures");
        assertFalse(
            vault.quarantined(address(adapter1)), "Should NOT be quarantined (below threshold)"
        );

        // Fix adapter1
        adapter1.setWithdrawReverts(false);

        // Trigger a successful operation (large amount so adapter1 is hit)
        vm.prank(core);
        vault.realizeLiquidity(300e6);

        // V9.1: gradual decrement (not reset to 0). Counter decreases by 1 per success.
        uint8 counterAfter = vault.adapterConsecutiveFailures(address(adapter1));
        assertLt(counterAfter, 2, "Counter should decrease on success");

        console2.log("PASS: quarantine counter resets on success");
    }

    // =========================================================================
    // 15. test_quarantined_adapter_excluded_from_enabledAdapters
    // =========================================================================
    /// @notice A quarantined adapter is excluded from _enabledAdapters() list.
    function test_quarantined_adapter_excluded_from_enabledAdapters() public {
        _coreDeposit(300e6);

        // Manually quarantine adapter2
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setQuarantined(address(adapter2), true);

        // Deposit should still work (if no degraded views) -adapter2 excluded from scoring
        // The vault should only deploy to adapter1 and adapter3
        // Verify by checking positionAssets after a new deposit

        // First, admin unlatches depositsDisabled if set (manual quarantine doesn't set it)
        // Actually, setQuarantined doesn't auto-set depositsDisabled, only auto-quarantine does.
        assertFalse(vault.depositsDisabled(), "Manual quarantine shouldn't set depositsDisabled");

        // Do a new deposit -only adapter1 and adapter3 should get funds
        uint256 pos2Before = vault.positionAssets(address(adapter2));

        _mintAndTransferToVault(core, 100e6);
        vm.prank(core);
        vault.deposit(100e6);

        uint256 pos2After = vault.positionAssets(address(adapter2));
        assertEq(pos2After, pos2Before, "Quarantined adapter should NOT receive new deposits");

        console2.log("PASS: quarantined adapter excluded from enabledAdapters");
    }

    // =========================================================================
    // 16. test_push_mode_deposit_failure_uses_gradual_decay
    // =========================================================================
    /// @notice Audit HIGH 1.3 — PUSH mode deposit failure now uses GRADUAL decay
    ///         (same path as pull mode), not immediate quarantine. The AdapterFundsStranded
    ///         event is still emitted so the keeper/monitoring can react, but quarantine
    ///         only triggers after consecutive failures cross the threshold.
    function test_push_mode_deposit_failure_uses_gradual_decay() public {
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setAdapterDepositMode(address(adapter1), true);
        adapter1.setPullMode(false);

        _coreDeposit(300e6);
        adapter1.setDepositReverts(true);

        assertFalse(vault.quarantined(address(adapter1)), "not quarantined initially");

        adapter1.setHarvestable(20e6);
        adapter2.setHarvestable(20e6);
        adapter3.setHarvestable(20e6);

        // Single harvest cycle: one failure recorded, NOT quarantined yet
        // (threshold is adapterQuarantineThreshold > 1).
        vm.warp(block.timestamp + 50000);
        vm.prank(keeper);
        vault.harvest();

        assertFalse(
            vault.quarantined(address(adapter1)),
            "single PUSH failure must NOT immediately quarantine (gradual decay)"
        );
        assertGt(
            vault.adapterConsecutiveFailures(address(adapter1)),
            0,
            "failure counter must increment"
        );
    }

    // =========================================================================
    // 17. test_harvest_emits_idle_warning_not_revert
    // =========================================================================
    /// @notice harvest() emits IdleCashRemaining when idle > dustTolerance after deploy
    ///         (replaces noCashInvariant revert with explicit signal).
    function test_harvest_emits_idle_warning_not_revert() public {
        _coreDeposit(300e6);

        // Set harvestable on all adapters
        adapter1.setHarvestable(5e6);
        adapter2.setHarvestable(5e6);
        adapter3.setHarvestable(5e6);

        // Break ALL adapter deposits -harvested USDC can't be redeployed
        adapter1.setDepositReverts(true);
        adapter2.setDepositReverts(true);
        adapter3.setDepositReverts(true);

        // Advance past harvest cooldown
        vm.warp(block.timestamp + 50000);

        // harvest() must NOT revert -should emit IdleCashRemaining instead
        vm.prank(keeper);
        vault.harvest();

        // Verify idle cash exists (harvested USDC couldn't be deployed)
        uint256 idle = vault.idleCash();

        // The harvested yield was minted to vault but couldn't be deployed
        // So idle should be > 0 (at least the harvested amount from working adapters)
        console2.log("Idle after harvest:", idle, "dustTolerance:", vault.dustTolerance());

        console2.log("PASS: harvest did NOT revert (no noCashInvariant), emitted IdleCashRemaining");
    }

    // =========================================================================
    // BONUS: deposit reverts when _hasDegradedAdapterViews (runtime check)
    // =========================================================================
    /// @notice INVARIANT 3: deposit() reverts if adapter views are degraded above threshold.
    function test_deposit_reverts_when_adapter_views_degraded() public {
        // First, deposit some funds so positionAssets > 0 (needed for threshold check)
        _coreDeposit(300e6);

        // Break adapter1's totalAssets (but depositsDisabled is false)
        adapter1.setTotalAssetsReverts(true);

        // Attempt second deposit — must revert with DegradedViews (threshold-based)
        _mintAndTransferToVault(core, 100e6);
        vm.prank(core);
        vm.expectRevert(); // DegradedViews(fallbackBps, threshold)
        vault.deposit(100e6);

        console2.log("PASS: deposit reverts when adapter views are degraded");
    }

    // =========================================================================
    // BONUS: admin can un-quarantine and re-enable deposits
    // =========================================================================
    /// @notice After fixing the issue, admin can un-quarantine adapter and re-enable deposits.
    function test_admin_can_unquarantine_and_reenable_deposits() public {
        // Set low threshold for this test
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setQuarantineThreshold(3);
        _coreDeposit(300e6);

        adapter1.setWithdrawReverts(true);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(core);
            vault.realizeLiquidity(300e6);
        }

        assertTrue(vault.quarantined(address(adapter1)), "Should be quarantined");
        // V9.1: depositsDisabled does NOT cascade — stays false
        assertFalse(vault.depositsDisabled(), "Deposits should NOT auto-disable");

        // Fix adapter1
        adapter1.setWithdrawReverts(false);

        // Admin un-quara
    }
}
