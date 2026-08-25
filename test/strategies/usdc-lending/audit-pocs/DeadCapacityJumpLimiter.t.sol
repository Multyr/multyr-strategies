// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * FINDING: The "adapter capacity delta limiter" (Audit HIGH 1.6) is dead
 *          code — `cachedAdapterCapacity` is declared and read, but never
 *          written anywhere in the codebase, so the jump-dampening guard in
 *          `StrategyAllocCalcModule._checkAdapterEligibility()` can never
 *          fire, regardless of how wildly an adapter's `maxCapacity()`
 *          swings between observations.
 * SEVERITY: MEDIUM-HIGH (silently broken defense-in-depth control; the
 *           storage layout comment and docs/threat-model.md both describe
 *           this as an ACTIVE, already-fixed mitigation — "Audit HIGH 1.5/1.6
 *           — delta limiter for external TVL and adapter capacity" — but only
 *           the TVL half (cachedExternalTVL, populated in
 *           StrategyParamsModule.pokeExternalTVL) actually works. The
 *           capacity half never got a write path).
 *
 * StrategyStorageLayout.sol:307-308:
 *     // Audit HIGH 1.6 — cached adapter capacity for delta sanity checks.
 *     mapping(address => uint256) public cachedAdapterCapacity;
 *
 * StrategyAllocCalcModule._checkAdapterEligibility() (StrategyAllocCalcModule.sol:353-361):
 *     try ILendingAdapter(adapter).maxCapacity() returns (uint256 cap) {
 *         ...
 *         else if (cachedAdapterCapacity[adapter] > 0 && cap > 0 && ...) {
 *             uint256 maxJump = (cachedAdapterCapacity[adapter] * MAX_EXTERNAL_TVL_JUMP_BPS) / 10_000;
 *             if (cap > maxJump) headroom = headroom / 2;   // <-- never reached
 *         }
 *     }
 *
 * `grep -rn "cachedAdapterCapacity" src/` confirms exactly 3 occurrences: the
 * declaration and the two reads above — there is no assignment anywhere in
 * the source tree. Correspondingly, `event AdapterCapacityJump` and
 * `event AdapterCapacityDecreased` (StrategyStorageLayout.sol:467-468) are
 * declared but never emitted anywhere in the codebase either.
 *
 * Net effect: an adapter (buggy, compromised, or simply misconfigured by
 * governance) can report a `maxCapacity()` that swings by any multiple —
 * including from near-zero to effectively unlimited — from one scoring pass
 * to the next, and the strategy applies zero dampening. This defeats the
 * documented purpose of the control without requiring any special
 * preconditions: it is inert on every call, for every adapter, always.
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

        // Observation #1: near-zero capacity.
        adapter1.setMaxCap(1);
        usdc.mint(address(vault), 10e6);
        vm.prank(keeper);
        (bool ok1, ) = address(vault).call(abi.encodeWithSignature("deployIdle()"));
        ok1; // irrelevant whether it deployed — we only care about the cache

        assertEq(
            vault.cachedAdapterCapacity(address(adapter1)), 0,
            "capacity cache still unpopulated after first scoring pass that read maxCapacity()"
        );

        // Observation #2: capacity "jumps" by 9+ orders of magnitude in a
        // single call — precisely the kind of swing MAX_EXTERNAL_TVL_JUMP_BPS
        // (10x per poke) is documented to dampen for the analogous external-
        // TVL cache. No dampening occurs here: headroom is computed directly
        // from the raw, unvalidated maxCapacity() value every time.
        adapter1.setMaxCap(1_000_000_000_000e6); // 1 trillion USDC
        usdc.mint(address(vault), 10e6);
        vm.warp(block.timestamp + vault.minSecondsBetweenDeployIdle() + 1); // clear deployIdle() cooldown
        vm.recordLogs();
        vm.prank(keeper);
        (bool ok2, ) = address(vault).call(abi.encodeWithSignature("deployIdle()"));
        require(ok2, "deployIdle() call unexpectedly failed");

        // VULNERABLE: the cache that is supposed to detect and dampen this
        // exact scenario was never written to, so it is still zero and the
        // guard branch in _checkAdapterEligibility can never execute.
        assertEq(
            vault.cachedAdapterCapacity(address(adapter1)), 0,
            "VULNERABLE: cachedAdapterCapacity never gets populated -> Audit HIGH 1.6 capacity jump limiter is dead code"
        );

        // Confirm no code path in this run emitted the dedicated
        // capacity-jump/decrease telemetry events either (further evidence
        // the whole mitigation is unreachable, not just quiet).
        bytes32 jumpTopic = keccak256("AdapterCapacityJump(address,uint256,uint256)");
        bytes32 decreaseTopic = keccak256("AdapterCapacityDecreased(address,uint256,uint256)");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            assertTrue(entries[i].topics[0] != jumpTopic, "AdapterCapacityJump should be unreachable dead code");
            assertTrue(entries[i].topics[0] != decreaseTopic, "AdapterCapacityDecreased should be unreachable dead code");
        }
    }
}
