// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * FINDING: Unguarded external calls in CometUsdcMultiMarketAdapter._getAPYBps()
 *          let a single broken/paused Comet sub-market brick BOTH deposit()
 *          and the standard withdraw() path for every other, perfectly
 *          healthy sub-market registered on the same adapter.
 * SEVERITY: HIGH (availability / fund-lockup risk, triggered by ordinary
 *           external-protocol behavior — a Comet market pause/deprecation —
 *           not by an on-chain attacker).
 *
 * `_getAPYBps(comet)` (CometUsdcMultiMarket.sol:460-468) calls
 * `IComet(comet).getUtilization()` and `.getSupplyRate()` directly, with no
 * try/catch and no staticcall-with-fallback (unlike, e.g., the vault's own
 * `_safeTotalAssets`, which is guarded). `_marketsByAPY()`
 * (CometUsdcMultiMarket.sol:683+) calls `_getAPYBps` on *every* registered
 * market inside a selection sort, with no isolation between markets. Both
 * `deposit()` (via `_selectBestMarket()`) and the standard `withdraw()` path
 * (CometUsdcMultiMarket.sol:512) depend on this sort.
 *
 * Net effect: if any one registered Comet market becomes paused/deprecated/
 * bricked (a routine, non-attacker-controlled governance action on Compound
 * III), depositors cannot withdraw their perfectly healthy funds sitting in
 * *other* markets on the same adapter through the normal path — only
 * `emergencyPullAllToVault()` (which uses try/catch) still works, and that
 * requires DEFAULT_ADMIN_ROLE intervention.
 *
 * This PoC reuses the existing CometAdapter_Test harness/mocks from
 * test/strategies/usdc-lending/adapters/CometUsdcMultiMarketAdapter.t.sol.
 */

import {
    CometAdapter_Test,
    MockComet
} from "../adapters/CometUsdcMultiMarketAdapter.t.sol";

contract CometAdapter_SingleMarketRevert_PoC is CometAdapter_Test {
    function test_POC_healthy_market_withdraw_bricked_by_unrelated_broken_market() public {
        // 1. Deposit real USDC into comet1 only (comet2 is not yet registered).
        uint256 amt = 1_000_000e6;
        _mintAndApprove(vault, amt);
        vm.prank(vault);
        adapter.deposit(amt);
        assertEq(adapter.totalAssets(), amt, "sanity: funds landed in comet1");

        // 2. Governance/keeper later adds a second market (comet2) to diversify.
        _addMarket(comet2);

        // 3. comet2 becomes paused/deprecated on-chain (e.g. Compound III
        //    governance action) — an ordinary external event, no attacker
        //    required. Its view functions start reverting, exactly what a
        //    paused/frozen Comet market does in practice.
        comet2.setRevertOnUtilization(true);

        // 4. The vault tries to withdraw the perfectly healthy funds that are
        //    sitting in comet1. This should succeed — comet1 was never
        //    touched and holds 100% of the adapter's real assets.
        vm.prank(vault);
        vm.expectRevert(bytes("util-revert"));
        adapter.withdraw(amt, vault);

        // VULNERABLE: the withdraw() call above reverts because
        // _marketsByAPY() unconditionally calls _getAPYBps() on comet2 too
        // (to sort ALL registered markets), even though the withdrawal only
        // needed comet1. One unrelated, non-attacker-triggered broken market
        // fully DoSes standard withdrawal of unaffected, healthy funds.
        assertEq(adapter.totalAssets(), amt, "funds remain stuck: not lost, but unreachable via the standard path");
    }
}
