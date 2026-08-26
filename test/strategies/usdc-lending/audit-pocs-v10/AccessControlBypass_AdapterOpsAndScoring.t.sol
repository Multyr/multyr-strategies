// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * FINDING (FIXED): Missing access control on delegatecall-module externals
 *          reachable via UsdcMultiLendingVault.fallback().
 * SEVERITY: HIGH (was).
 *
 * `onlyDelegateCall` (`require(address(this) != _self, ...)`) only rejects a
 * direct call to the standalone module contract -- it never checked
 * msg.sender or any role. `UsdcLendingStrategy.fallback()` delegatecalls any
 * unrecognized selector to a fixed module chain for ANY caller, with no
 * access check before dispatch, so every affected function was reachable
 * unauthenticated through the vault.
 *
 * FIX: added a shared `onlyKeeperOrCoreOrRevert` modifier to
 * StrategyStorageLayout.sol (inherited by every delegatecall module) and
 * applied the correct role gate to each previously-unprotected entry point,
 * matching the exact pattern StrategyRebalancePlanModule already used
 * correctly:
 *   - StrategyAdapterOpsModule.safeAdapterDeposit/adapterDeposit/
 *     executeRealizeLiquidity -> onlyKeeperOrCoreOrRevert (both CORE_ROLE-
 *     triggered deposit/withdraw and KEEPER_ROLE-triggered harvest/
 *     deployIdle/rebalance paths legitimately reach these)
 *   - StrategyAdapterOpsModule.recordAdapterFailure/recordAdapterSuccess/
 *     recordWithdrawGas/syncPositionAssets -> onlyRoleOrRevert(KEEPER_ROLE)
 *     (their only legitimate callers are KEEPER-gated)
 *   - StrategyScoringModule.deployIdleToAdapters -> onlyKeeperOrCoreOrRevert
 *   - StrategyScoringModule.computeInputsForPlan -> onlyRoleOrRevert(KEEPER_ROLE)
 *
 * Each PoC below now demonstrates the attacker call REVERTING with
 * Unauthorized(), while confirming the legitimate CORE/KEEPER-driven flows
 * that share the exact same code path still work (msg.sender is preserved
 * unchanged through the whole delegatecall chain, so a role check here
 * correctly authorizes every real caller without breaking anything).
 */

import { Test, console2 } from "forge-std/Test.sol";
import { Unauthorized } from "../../../../src/strategies/usdc-lending/controller/StrategyStorageLayout.sol";
import {
    UsdcMultiLendingVaultTestBase,
    MockUSDC,
    MockLendingAdapter
} from "../UsdcMultiLendingVault.t.sol";

contract AccessControlBypass_PoC is UsdcMultiLendingVaultTestBase {
    address attacker = address(0xA11CE);

    function setUp() public override {
        super.setUp();
        _addAndEnableAdapter(adapter1);
    }

    function test_POC_A_forced_quarantine_now_blocked() public {
        assertFalse(vault.hasRole(KEEPER_ROLE, attacker));
        assertFalse(vault.hasRole(PARAM_ROLE, attacker));
        assertFalse(vault.hasRole(DEFAULT_ADMIN_ROLE, attacker));

        vm.prank(attacker);
        (bool ok, bytes memory ret) = address(vault).call(
            abi.encodeWithSignature("recordAdapterFailure(address)", address(adapter1))
        );
        assertFalse(ok, "FIXED: unprivileged recordAdapterFailure must now revert");
        assertEq(bytes4(ret), Unauthorized.selector);
        assertFalse(vault.quarantined(address(adapter1)));

        // Legitimate KEEPER-triggered path still works (via the rebalance
        // plan's withdraw-failure recording -- exercised end-to-end here by
        // calling the now-gated function directly as KEEPER, matching its
        // documented legitimate caller).
        vm.prank(keeper);
        (bool okKeeper, ) = address(vault).call(
            abi.encodeWithSignature("recordAdapterFailure(address)", address(adapter1))
        );
        assertTrue(okKeeper, "sanity: KEEPER_ROLE can still call recordAdapterFailure");
    }

    function test_POC_B_deployIdle_pause_bypass_now_blocked() public {
        uint256 idleAmt = 100e6;
        usdc.mint(address(vault), idleAmt);

        vm.prank(admin);
        vault.pause();
        assertTrue(vault.paused());

        uint256 posBefore = vault.positionAssets(address(adapter1));

        vm.prank(attacker);
        (bool ok, bytes memory ret) = address(vault).call(
            abi.encodeWithSignature("deployIdleToAdapters(uint256,bool)", idleAmt, true)
        );
        assertFalse(ok, "FIXED: unprivileged deployIdleToAdapters must now revert");
        assertEq(bytes4(ret), Unauthorized.selector);
        assertEq(vault.positionAssets(address(adapter1)), posBefore, "no capital moved");

        // Legitimate CORE-triggered path (deposit()) still works once unpaused.
        vm.prank(admin);
        vault.unpause();
        _mintAndTransferToVault(core, idleAmt);
        vm.prank(core);
        vault.deposit(idleAmt);
        assertGt(vault.positionAssets(address(adapter1)), posBefore, "sanity: CORE-triggered deposit still deploys capital");
    }

    function test_POC_C_safeAdapterDeposit_desync_now_blocked() public {
        uint256 amt = 50e6;
        usdc.mint(address(vault), amt);

        vm.prank(attacker);
        (bool ok, bytes memory ret) = address(vault).call(
            abi.encodeWithSignature("safeAdapterDeposit(address,uint256)", address(adapter1), amt)
        );
        assertFalse(ok, "FIXED: unprivileged safeAdapterDeposit must now revert");
        assertEq(bytes4(ret), Unauthorized.selector);
        assertEq(adapter1.deposited(), 0, "no funds moved to the adapter");

        // Legitimate CORE-triggered path still works.
        vm.prank(core);
        (bool okCore, ) = address(vault).call(
            abi.encodeWithSignature("safeAdapterDeposit(address,uint256)", address(adapter1), amt)
        );
        assertTrue(okCore, "sanity: CORE_ROLE can still call safeAdapterDeposit");
    }

    function test_POC_D_executeRealizeLiquidity_now_blocked() public {
        uint256 depositAmt = 100_000e6;
        _mintAndTransferToVault(core, depositAmt);
        vm.prank(core);
        vault.deposit(depositAmt);

        uint256 posBefore = vault.positionAssets(address(adapter1));
        assertGt(posBefore, 0, "sanity: adapter1 holds a real yield-bearing position");

        vm.prank(attacker);
        vm.expectRevert(Unauthorized.selector);
        vault.realizeLiquidity(posBefore);

        vm.prank(attacker);
        (bool ok, bytes memory ret) = address(vault).call(
            abi.encodeWithSignature("executeRealizeLiquidity(uint256)", posBefore)
        );
        assertFalse(ok, "FIXED: unprivileged executeRealizeLiquidity must now revert");
        assertEq(bytes4(ret), Unauthorized.selector);
        assertEq(vault.positionAssets(address(adapter1)), posBefore, "no capital pulled out");

        // Legitimate KEEPER/CORE-triggered path still works.
        vm.prank(keeper);
        vault.realizeLiquidity(posBefore / 2);
        assertLt(vault.positionAssets(address(adapter1)), posBefore, "sanity: KEEPER_ROLE realizeLiquidity() still works");
    }

    function test_POC_E_forced_sync_now_blocked() public {
        vm.prank(attacker);
        (bool ok, bytes memory ret) = address(vault).call(abi.encodeWithSignature("syncPositionAssets(bool)", true));
        assertFalse(ok, "FIXED: unprivileged syncPositionAssets must now revert");
        assertEq(bytes4(ret), Unauthorized.selector);

        // Legitimate KEEPER-triggered path still works.
        vm.prank(keeper);
        (bool okKeeper, ) = address(vault).call(abi.encodeWithSignature("syncPositionAssets(bool)", true));
        assertTrue(okKeeper, "sanity: KEEPER_ROLE can still call syncPositionAssets");
    }
}
