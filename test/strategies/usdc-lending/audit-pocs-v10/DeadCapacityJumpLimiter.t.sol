// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * FINDING (FIXED): The "adapter capacity delta limiter" (Audit HIGH 1.6) was
 *          dead code -- `cachedAdapterCapacity` was declared and read in
 *          `StrategyAllocCalcModule._checkAdapterEligibility()`, but never
 *          written anywhere in the codebase, so the jump-dampening guard
 *          could never fire regardless of how wildly an adapter's
 *          `maxCapacity()` swung between observations.
 * SEVERITY: MEDIUM-HIGH (was).
 *
 * FIX: `StrategyParamsModule.pokeExternalTVL()` (already a KEEPER_ROLE poke
 * looping over enabled adapters to refresh `cachedExternalTVL`) now also
 * polls `adapter.maxCapacity()` each cycle and writes `cachedAdapterCapacity`,
 * mirroring the existing `MAX_EXTERNAL_TVL_JUMP_BPS`-based dampening pattern
 * used for external TVL, and emitting the (previously unreachable)
 * `AdapterCapacityJump`/`AdapterCapacityDecreased` telemetry events.
 */

import { Test, Vm, console2 } from "forge-std/Test.sol";
import { StrategyParamsModule } from "../../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
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

    function test_POC_capacity_cache_now_populated_and_jump_detected() public {
        // _addAndEnableAdapter() already triggers one pokeExternalTVL() during
        // setUp, so the cache is non-zero from the start (matching adapter1's
        // default MockLendingAdapter.maxCap = type(uint256).max) -- what
        // matters is that a fresh poke after changing maxCap() actually
        // updates the cache, which it previously never did.
        adapter1.setMaxCap(1_000_000e6);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        assertEq(
            vault.cachedAdapterCapacity(address(adapter1)), 1_000_000e6,
            "FIXED: capacity cache is now populated/updated after a keeper poke"
        );

        // A wild jump on the next poke is now observable and telemetered.
        adapter1.setMaxCap(1_000_000_000_000e6); // 1 trillion USDC, a huge jump
        vm.recordLogs();
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        assertEq(
            vault.cachedAdapterCapacity(address(adapter1)), 1_000_000_000_000e6,
            "cache tracks the latest observed capacity"
        );

        bytes32 jumpTopic = keccak256("AdapterCapacityJump(address,uint256,uint256)");
        bool sawJump = false;
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == jumpTopic) sawJump = true;
        }
        assertTrue(sawJump, "FIXED: AdapterCapacityJump is now reachable and fires on a large capacity swing");

        // Downstream: StrategyAllocCalcModule._checkAdapterEligibility() reads
        // this cache and halves headroom on the next allocation pass when a
        // jump like this is detected (not re-exercised here -- this PoC's
        // scope is the previously-dead read/write plumbing itself).
    }
}
