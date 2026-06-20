// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ═══════════════════════════════════════════════════════════════════════════════
// P07NegativePathsSettings.t.sol — E.8 diff branch coverage (2026-06-12)
// ───────────────────────────────────────────────────────────────────────────────
// Negative-path tests for StrategySettingsModule P0.7 setters.
// Exercises 13 previously-uncovered branches from E.7 analysis:
//   setMaxIdleBps, setTargetSafetyMargin, setMandateRedeployCooldown,
//   addSafetyFallbackAdapter (5 guards), updateSafetyFallbackCaps (2 guards),
//   removeSafetyFallbackAdapter (1 revert + 1 swap-and-pop logic branch).
//
// Run: forge test --match-contract P07NegativePathsSettings -vv
// ═══════════════════════════════════════════════════════════════════════════════

import { CapDriftBase } from "./CapDriftMandate.t.sol";
import {
    StrategySettingsModule
} from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {
    ZeroAddress, InvalidAdapter, AdapterNotEnabled,
    InvalidFallbackCap, AlreadySafetyFallback, NotSafetyFallback,
    ParamOutOfRange
} from "../../../src/strategies/usdc-lending/controller/StrategyStorageLayout.sol";

contract P07NegativePathsSettings is CapDriftBase {

    function setUp() public {
        _deploy();
        _seedVault(1_000_000e6);
    }

    // ── setMaxIdleBps ────────────────────────────────────────────────────────

    /// @notice setMaxIdleBps(>2000) reverts ParamOutOfRange.
    function test_setMaxIdleBps_reverts_above_2000() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ParamOutOfRange.selector));
        StrategySettingsModule(address(vault)).setMaxIdleBps(2001);
    }

    // ── setTargetSafetyMargin ────────────────────────────────────────────────

    /// @notice setTargetSafetyMargin(>2000) reverts ParamOutOfRange.
    function test_setTargetSafetyMargin_reverts_above_2000() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ParamOutOfRange.selector));
        StrategySettingsModule(address(vault)).setTargetSafetyMargin(2001);
    }

    // ── setMandateRedeployCooldown ───────────────────────────────────────────

    /// @notice setMandateRedeployCooldown(>30 days) reverts ParamOutOfRange.
    function test_setMandateRedeployCooldown_reverts_above_30days() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ParamOutOfRange.selector));
        StrategySettingsModule(address(vault)).setMandateRedeployCooldown(30 days + 1);
    }

    // ── addSafetyFallbackAdapter ─────────────────────────────────────────────

    /// @notice addSafetyFallbackAdapter(address(0),...) reverts ZeroAddress.
    function test_addSafetyFallback_reverts_zero_address() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ZeroAddress.selector));
        StrategySettingsModule(address(vault)).addSafetyFallbackAdapter(address(0), 2000, 0);
    }

    /// @notice addSafetyFallbackAdapter on a disabled adapter reverts AdapterNotEnabled.
    function test_addSafetyFallback_reverts_not_enabled() public {
        vm.startPrank(admin);
        vault.toggleAdapter(address(adapterA), false);
        vm.expectRevert(abi.encodeWithSelector(AdapterNotEnabled.selector));
        StrategySettingsModule(address(vault)).addSafetyFallbackAdapter(address(adapterA), 2000, 0);
        vm.stopPrank();
    }

    /// @notice addSafetyFallbackAdapter(absCapBps=0) reverts InvalidFallbackCap.
    function test_addSafetyFallback_reverts_absCapBps_zero() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidFallbackCap.selector));
        StrategySettingsModule(address(vault)).addSafetyFallbackAdapter(address(adapterA), 0, 0);
    }

    /// @notice addSafetyFallbackAdapter(absCapBps>8000) reverts InvalidFallbackCap.
    function test_addSafetyFallback_reverts_absCapBps_above_max() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidFallbackCap.selector));
        StrategySettingsModule(address(vault)).addSafetyFallbackAdapter(address(adapterA), 8001, 0);
    }

    /// @notice addSafetyFallbackAdapter(relCapBps>10000) reverts InvalidFallbackCap.
    function test_addSafetyFallback_reverts_relCapBps_above_max() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidFallbackCap.selector));
        StrategySettingsModule(address(vault)).addSafetyFallbackAdapter(
            address(adapterA), 2000, 10001
        );
    }

    /// @notice addSafetyFallbackAdapter twice reverts AlreadySafetyFallback.
    function test_addSafetyFallback_reverts_already_registered() public {
        vm.startPrank(admin);
        StrategySettingsModule(address(vault)).addSafetyFallbackAdapter(address(adapterA), 2000, 0);
        vm.expectRevert(abi.encodeWithSelector(AlreadySafetyFallback.selector));
        StrategySettingsModule(address(vault)).addSafetyFallbackAdapter(address(adapterA), 2000, 0);
        vm.stopPrank();
    }

    // ── updateSafetyFallbackCaps ─────────────────────────────────────────────

    /// @notice updateSafetyFallbackCaps on unregistered adapter reverts NotSafetyFallback.
    function test_updateSafetyFallbackCaps_reverts_not_registered() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(NotSafetyFallback.selector));
        StrategySettingsModule(address(vault)).updateSafetyFallbackCaps(address(adapterA), 2000, 0);
    }

    /// @notice updateSafetyFallbackCaps(absCapBps=0) reverts InvalidFallbackCap.
    function test_updateSafetyFallbackCaps_reverts_absCapBps_invalid() public {
        vm.startPrank(admin);
        StrategySettingsModule(address(vault)).addSafetyFallbackAdapter(address(adapterA), 2000, 0);
        vm.expectRevert(abi.encodeWithSelector(InvalidFallbackCap.selector));
        StrategySettingsModule(address(vault)).updateSafetyFallbackCaps(address(adapterA), 0, 0);
        vm.stopPrank();
    }

    // ── removeSafetyFallbackAdapter ──────────────────────────────────────────

    /// @notice removeSafetyFallbackAdapter on unregistered adapter reverts NotSafetyFallback.
    function test_removeSafetyFallback_reverts_not_registered() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(NotSafetyFallback.selector));
        StrategySettingsModule(address(vault)).removeSafetyFallbackAdapter(address(adapterA));
    }

    /// @notice removeSafetyFallbackAdapter on non-last element exercises swap-and-pop (L624).
    /// @dev    Covers the `if (i != len - 1)` branch: adapterB is swapped to index 0
    ///         after adapterA is removed, preserving it as the sole remaining entry.
    function test_removeSafetyFallback_swapAndPop_nonLast() public {
        vm.startPrank(admin);
        StrategySettingsModule(address(vault)).addSafetyFallbackAdapter(address(adapterA), 2000, 0);
        StrategySettingsModule(address(vault)).addSafetyFallbackAdapter(address(adapterB), 3000, 0);
        assertEq(
            StrategySettingsModule(address(vault)).safetyFallbackAdaptersLength(), 2,
            "pre: two safety adapters registered"
        );

        // Remove adapterA (index 0) — i(0) != len-1(1) so swap-and-pop fires.
        StrategySettingsModule(address(vault)).removeSafetyFallbackAdapter(address(adapterA));
        vm.stopPrank();

        assertFalse(
            StrategySettingsModule(address(vault)).isSafetyFallbackAdapter(address(adapterA)),
            "adapterA must be de-registered"
        );
        assertTrue(
            StrategySettingsModule(address(vault)).isSafetyFallbackAdapter(address(adapterB)),
            "adapterB must remain registered after swap-and-pop"
        );
        assertEq(
            StrategySettingsModule(address(vault)).safetyFallbackAdaptersLength(), 1,
            "post: one safety adapter remaining"
        );
    }
}
