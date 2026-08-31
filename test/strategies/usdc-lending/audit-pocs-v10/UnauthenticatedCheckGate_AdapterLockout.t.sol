// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * FINDING (FIXED): `StrategyRebalanceGateModule.checkGate()` took
 *          `enabledAdapters` and `tvl` as plain, unvalidated calldata
 *          parameters and was guarded only by `onlyDelegateCall`, reachable
 *          unauthenticated through the vault's fallback dispatcher. Firing
 *          the P0.4 "cap drift mandate" check with `emitOnMandate=true`
 *          writes `lastRelCapMandateTs[hitAdapter] = block.timestamp`, which
 *          `StrategyAllocCalcModule._checkAdapterEligibility()` then reads to
 *          make a targeted adapter fully ineligible for new deposits for up
 *          to `mandateRedeployCooldownSeconds`. A spoofed `tvl=1` collapsed
 *          the hard ceiling to ~0, so any adapter with a nonzero position
 *          could be locked out for free, repeatably, by anyone.
 * SEVERITY: HIGH (was).
 *
 * FIX: `checkGate()` now requires `onlyRoleOrRevert(KEEPER_ROLE)` -- its only
 * legitimate caller is `prepareRebalance()` (already KEEPER-gated), so
 * msg.sender is always the same already-authorized keeper by the time this
 * runs.
 */

import { Test, console2 } from "forge-std/Test.sol";
import { Unauthorized } from "../../../../src/strategies/usdc-lending/controller/StrategyStorageLayout.sol";
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

    function test_POC_spoofed_checkGate_now_blocked_for_unprivileged_caller() public {
        assertEq(vault.lastRelCapMandateTs(address(adapter1)), 0, "sanity: no mandate cooldown active yet");
        assertFalse(vault.hasRole(vault.KEEPER_ROLE(), attacker));
        assertFalse(vault.hasRole(vault.PARAM_ROLE(), attacker));
        assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), attacker));

        address[] memory targets = new address[](1);
        targets[0] = address(adapter1);
        uint16[] memory apys = new uint16[](0);
        uint256[] memory targetAllocs = new uint256[](0);

        vm.prank(attacker);
        (bool ok, bytes memory ret) = address(vault).call(
            abi.encodeWithSignature(
                "checkGate(uint16[],address[],uint256[],uint256,uint256)",
                apys, targets, targetAllocs,
                uint256(1),   // spoofed tvl=1 -- would have collapsed the hard ceiling to ~0
                uint256(0)
            )
        );
        assertFalse(ok, "FIXED: unprivileged checkGate() must now revert");
        assertEq(bytes4(ret), Unauthorized.selector);
        assertEq(
            vault.lastRelCapMandateTs(address(adapter1)), 0,
            "FIXED: no mandate cooldown was started -- adapter1 is untouched"
        );

        // Capital deployment for adapter1 is unaffected -- it was never locked
        // out (the mandate cooldown check in _checkAdapterEligibility() only
        // excludes an adapter when lastRelCapMandateTs > 0, confirmed above
        // it's still 0). deployIdle() runs normally with no eligibility skip.
        usdc.mint(address(vault), 50_000e6);
        vm.warp(block.timestamp + vault.minSecondsBetweenDeployIdle() + 1);
        vm.prank(keeper);
        (bool okDeploy, ) = address(vault).call(abi.encodeWithSignature("deployIdle()"));
        require(okDeploy, "deployIdle() call unexpectedly failed");

        assertEq(
            vault.lastRelCapMandateTs(address(adapter1)), 0,
            "sanity: still no mandate cooldown after a normal keeper-driven deployIdle() cycle"
        );
    }
}
