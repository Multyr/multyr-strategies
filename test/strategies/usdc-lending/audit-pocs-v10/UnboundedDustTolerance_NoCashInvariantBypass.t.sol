// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * FINDING (FIXED): `StrategySettingsModule.setDustTolerance()` had no upper
 *          bound. PARAM_ROLE could set `dustTolerance = type(uint256).max`
 *          and permanently lock it in via `finalizeParameters()`, silently
 *          neutralizing the "idle cash must deploy" NoCashInvariant forever.
 * SEVERITY: MEDIUM (was).
 *
 * FIX: `setDustTolerance()` now enforces `_dustTolerance <= 100_000e6`
 * (100K USDC), matching the `ParamOutOfRange` pattern every sibling setter
 * in the file already used.
 */

import { Test, console2 } from "forge-std/Test.sol";
import { ParamOutOfRange } from "../../../../src/strategies/usdc-lending/controller/StrategyStorageLayout.sol";
import {
    UsdcMultiLendingVaultTestBase,
    MockUSDC,
    MockLendingAdapter
} from "../UsdcMultiLendingVault.t.sol";

contract UnboundedDustTolerance_PoC is UsdcMultiLendingVaultTestBase {
    function setUp() public override {
        super.setUp();
        _addAndEnableAdapter(adapter1);
        adapter1.setMaxCap(0); // starve headroom so idle cash has nowhere to go
    }

    function test_POC_unbounded_dustTolerance_now_blocked() public {
        vm.prank(paramSetter);
        (bool ok, bytes memory ret) = address(vault).call(
            abi.encodeWithSignature("setDustTolerance(uint256)", type(uint256).max)
        );
        assertFalse(ok, "FIXED: setDustTolerance(type(uint256).max) must now revert");
        assertEq(bytes4(ret), ParamOutOfRange.selector);
        assertEq(vault.dustTolerance(), 3e6, "dustTolerance unchanged from the test-harness default");

        // A sane value within bounds still works normally.
        vm.prank(paramSetter);
        (bool okSane, ) = address(vault).call(
            abi.encodeWithSignature("setDustTolerance(uint256)", 50_000e6)
        );
        assertTrue(okSane, "sanity: an in-bounds dustTolerance is still settable");
        assertEq(vault.dustTolerance(), 50_000e6);
    }

    function test_POC_massive_idle_cash_still_triggers_NoCashInvariant() public {
        // The maximum allowed dustTolerance (100K) is still far below a 1M
        // deposit that can't be deployed (adapter capped at 0), so the
        // invariant fires as designed -- it can no longer be defeated.
        vm.prank(paramSetter);
        (bool ok, ) = address(vault).call(
            abi.encodeWithSignature("setDustTolerance(uint256)", 100_000e6)
        );
        require(ok, "setDustTolerance(100_000e6) unexpectedly failed");

        uint256 depositAmt = 1_000_000e6;
        usdc.mint(core, depositAmt);
        vm.prank(core);
        usdc.transfer(address(vault), depositAmt);

        vm.prank(core);
        vm.expectRevert(); // NoCashInvariant
        vault.deposit(depositAmt);
    }
}
