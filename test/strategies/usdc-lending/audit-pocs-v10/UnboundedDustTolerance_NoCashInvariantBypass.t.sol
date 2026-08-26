// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * FINDING: STILL PRESENT, unchanged on feature/v10.0-storage-initialize.
 *          `StrategySettingsModule.setDustTolerance()` has no upper bound
 *          and, unlike `setRebalanceParams` (which DID gain bounds on this
 *          branch -- see C-03 comment in the source), was not touched by
 *          this branch's hardening pass. PARAM_ROLE can still set
 *          `dustTolerance = type(uint256).max` and then permanently lock it
 *          in via `finalizeParameters()` (which still performs zero
 *          validation), neutralizing the "idle cash must deploy"
 *          NoCashInvariant forever.
 * SEVERITY: MEDIUM.
 */

import { Test, console2 } from "forge-std/Test.sol";
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

    function test_POC_paramRole_sets_unbounded_dustTolerance_then_locks_it_forever() public {
        vm.prank(paramSetter);
        (bool ok, ) = address(vault).call(
            abi.encodeWithSignature("setDustTolerance(uint256)", type(uint256).max)
        );
        require(ok, "setDustTolerance call unexpectedly failed");
        assertEq(vault.dustTolerance(), type(uint256).max, "sanity: dustTolerance accepted with no bound");

        vm.prank(paramSetter);
        (bool okFinalize, ) = address(vault).call(abi.encodeWithSignature("finalizeParameters()"));
        require(okFinalize, "finalizeParameters call unexpectedly failed");
        assertTrue(vault.paramsFinalized());

        vm.prank(paramSetter);
        (bool okSecondSet, ) = address(vault).call(
            abi.encodeWithSignature("setDustTolerance(uint256)", 3e6)
        );
        assertFalse(okSecondSet, "sanity: dustTolerance is now permanently locked at type(uint256).max");
    }

    function test_POC_massive_idle_cash_never_triggers_NoCashInvariant() public {
        vm.prank(paramSetter);
        (bool ok, ) = address(vault).call(
            abi.encodeWithSignature("setDustTolerance(uint256)", type(uint256).max)
        );
        require(ok, "setDustTolerance call unexpectedly failed");

        uint256 depositAmt = 1_000_000e6;
        usdc.mint(core, depositAmt);
        vm.prank(core);
        usdc.transfer(address(vault), depositAmt);

        vm.prank(core);
        vault.deposit(depositAmt);

        assertEq(vault.idleCash(), depositAmt, "VULNERABLE: entire deposit sits idle with zero on-chain protest");
        assertEq(vault.positionAssets(address(adapter1)), 0, "nothing was deployed to the adapter");
    }
}
