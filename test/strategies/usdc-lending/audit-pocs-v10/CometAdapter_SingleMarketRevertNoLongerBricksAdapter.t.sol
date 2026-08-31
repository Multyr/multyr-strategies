// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * FINDING (FIXED): `CometUsdcMultiMarket._getAPYBps()` called
 *          `IComet.getUtilization()`/`.getSupplyRate()` with no try/catch,
 *          and `_assetsOn()` called `IComet.balanceOf()` with no try/catch
 *          either. `_marketsByAPY()` (used by both `deposit()` and the
 *          standard `withdraw()` path) called `_getAPYBps` on every
 *          registered market unconditionally to sort them. If any one
 *          registered Comet market was paused/deprecated (an ordinary
 *          external Compound III governance action, not attacker-
 *          controlled), the whole call reverted -- bricking withdrawal of
 *          funds sitting in OTHER, perfectly healthy markets on the same
 *          adapter.
 * SEVERITY: HIGH (was).
 *
 * FIX: both `_getAPYBps()` and `_assetsOn()` now wrap their external calls
 * in try/catch. A failing market reports APY=0 / assets=0 instead of
 * reverting -- it naturally sorts last / is skipped by the withdraw loop's
 * `if (can < 1) continue;`, so one broken market can no longer take down
 * access to funds in every other market.
 */

import { CometAdapter_Test, MockComet } from "../adapters/CometUsdcMultiMarketAdapter.t.sol";

contract CometAdapter_SingleMarketRevert_PoC is CometAdapter_Test {
    function test_POC_healthy_market_withdraw_no_longer_bricked_by_unrelated_broken_market() public {
        uint256 amt = 1_000_000e6;
        _mintAndApprove(vault, amt);
        vm.prank(vault);
        adapter.deposit(amt);
        assertEq(adapter.totalAssets(), amt, "sanity: funds landed in comet1");

        _addMarket(comet2);

        // comet2 becomes paused/deprecated on-chain -- an ordinary external
        // event, no attacker required.
        comet2.setRevertOnUtilization(true);

        // Withdrawing the healthy comet1-only balance now succeeds despite
        // comet2 being completely broken.
        vm.prank(vault);
        uint256 withdrawn = adapter.withdraw(amt, vault);

        assertEq(withdrawn, amt, "FIXED: full withdrawal succeeds even though an unrelated market is broken");
        assertEq(adapter.totalAssets(), 0, "all funds recovered");
    }
}
