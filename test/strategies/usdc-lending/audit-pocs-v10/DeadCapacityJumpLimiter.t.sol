// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * FINDING: STILL PRESENT, unchanged on feature/v10.0-storage-initialize.
 *          The "adapter capacity delta limiter" (Audit HIGH 1.6) is dead
 *          code -- `cachedAdapterCapacity` is declared and read, but never
 *          written anywhere in the codebase, so the jump-dampening guard in
 *          `StrategyAllocCalcModule._checkAdapterEligibility()` can never
 *          fire, regardless of how wildly an adapter's `maxCapacity()`
 *          swings between observations. Re-verified on this branch: grep for
 *          `cachedAdapterCapacity` across src/strategies/usdc-lending/ still
 *          returns exactly 1 declaration + 2 reads (StrategyAllocCalcModule.sol
 *          ~403-406), zero writes.
 * SEVERITY: MEDIUM-HIGH.
 */

import { Test, Vm, console2 } from "forge-std/Test.sol";
import {
    UsdcMultiLendingVaultTestBase,
    MockUSDC,
    MockLendingAdapter
} from "../UsdcMultiLendingVault.t.sol";

contract DeadCapacityJumpLimiter_PoC is UsdcMultiLendingVaultTestBase {
    function setUp() public override {
        super.setUp();
        _addAndEnableAdapter(adapter1);
    }

    function test_POC_capacity_cache_never_populated_despite_huge_swings() public {
        assertEq(vault.cachedAdapterCapacity(address(adapter1)), 0, "sanity: starts at 0 (never cached)");

        adapter1.setMaxCap(1);
        usdc.mint(address(vault), 10e6);
        vm.prank(keeper);
        (bool ok1, ) = address(vault).call(abi.encodeWithSignature("deployIdle()"));
        ok1;

        assertEq(
            vault.cachedAdapterCapacity(address(adapter1)), 0,
            "capacity cache still unpopulated after first scoring pass that read maxCapacity()"
        );

        adapter1.setMaxCap(1_000_000_000_000e6); // 1 trillion USDC, a 10^12x jump
        usdc.mint(address(vault), 10e6);
        vm.warp(block.timestamp + vault.minSecondsBetweenDeployIdle() + 1);
        vm.recordLogs();
        vm.prank(keeper);
        (bool ok2, ) = address(vault).call(abi.encodeWithSignature("deployIdle()"));
        require(ok2, "deployIdle() call unexpectedly failed");

        assertEq(
            vault.cachedAdapterCapacity(address(adapter1)), 0,
            "VULNERABLE: cachedAdapterCapacity never gets populated -> Audit HIGH 1.6 capacity jump limiter is dead code"
        );

        bytes32 jumpTopic = keccak256("AdapterCapacityJump(address,uint256,uint256)");
        bytes32 decreaseTopic = keccak256("AdapterCapacityDecreased(address,uint256,uint256)");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            assertTrue(entries[i].topics[0] != jumpTopic, "AdapterCapacityJump should be unreachable dead code");
            assertTrue(entries[i].topics[0] != decreaseTopic, "AdapterCapacityDecreased should be unreachable dead code");
        }
    }
}
