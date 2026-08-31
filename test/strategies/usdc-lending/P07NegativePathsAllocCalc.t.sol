// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ═══════════════════════════════════════════════════════════════════════════════
// P07NegativePathsAllocCalc.t.sol — E.8 diff branch coverage (2026-06-12)
// ───────────────────────────────────────────────────────────────────────────────
// Test for the relative-cap binding branch in StrategyAllocCalcModule:
//   L305: if (fbRelCeiling < fbCeiling) fbCeiling = fbRelCeiling
//
// The preserve-safety-tranche logic in _computeTargetAllocations computes the
// fallback ceiling as min(absCapBps×tvl, relCapBps×extTVL). When the relative
// ceiling is smaller, L305 substitutes it. This branch is only reached when:
//   (a) adapter is a safety fallback (absCapBps > 0)
//   (b) current position > normal scoring target  (current > capped)
//   (c) relCapBps > 0 AND extTVL > 0
//   (d) fbRelCeiling < fbCeiling (rel cap is binding)
//
// Test design:
//   - adapterA is safety with SAFETY_FB_ABS_BPS=7000, SAFETY_FB_REL_BPS=7000
//   - Set adapterA extTVL to 100_000e6 (100k USDC — small pool)
//     → fbRelCeiling = 7000 × 100k / 10000 = 70_000e6
//     → fbAbsCeiling = 7000 × ~TVL / 10000 >> fbRelCeiling  → L305 fires
//   - Force adapterA position > 70_000e6 (above fbRelCeiling) so preservation
//     does NOT trigger (current > fbRelCeiling) and the rebalance plan targets
//     a withdraw. This distinguishes "rel cap bound" from "abs cap" because if
//     fbAbsCeiling were used instead, current < fbAbsCeiling → preservation
//     → no withdraw in plan.
//   - Assert: rebalance plan includes a WITHDRAW for adapterA.
//
// Run: forge test --match-contract P07AllocCalc_RelCapBinding -vv
// ═══════════════════════════════════════════════════════════════════════════════

import {
    CapDrift_D1f_SafetyAdapterCapTier
} from "./CapDriftMandate.t.sol";
import {
    StrategySettingsModule
} from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {
    StrategyParamsModule
} from "../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import {
    StrategyRebalancePlanModule
} from "../../../src/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol";

contract P07AllocCalc_RelCapBinding is CapDrift_D1f_SafetyAdapterCapTier {

    /// @notice When relCapBps × extTVL < absCapBps × tvl, the relative ceiling
    ///         binds (L305). If position is above the rel ceiling, no preservation
    ///         fires and the plan targets a withdraw — proving L305 was taken.
    function test_safety_ceiling_uses_rel_when_relCeiling_lt_absCeiling() public {
        // Reduce adapterA extTVL: 100k USDC so rel ceiling = 7000 × 100k / 1e4 = 70k.
        // The abs ceiling = 7000 × TVL / 1e4 >> 70k, so L305 (rel binds) fires.
        adapterA.setExtMarketTVL(100_000e6);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        // Force adapterA position well above fbRelCeiling (70k) but below fbAbsCeiling.
        // With adapterA APY=500 and others APY=400,900, normal scoring gives adapterA
        // roughly 30% of TVL as target. Force to 200k to exceed normal capped:
        //   normal capped ≈ 30% × 1M = 300k → position (200k) < 300k.
        // Need position > capped. Use a value above the 50%-cap hard ceiling instead:
        // maxExp = adapterMaxExposureBps × tvl = 5000 × TVL / 1e4 = 50% × TVL.
        // Force position to 55% of new TVL → above maxExp → capped = maxExp × safetyMult.
        //
        // Closed-form from _forcePctOfNewTvl: target = tvlOthers × pct / (10000 - pct).
        // With pct=5500 and tvlOthers≈1M: target ≈ 1.22M >> 70k → position > fbRelCeiling.
        // L305 fires → fbCeiling = fbRelCeiling (70k). current (1.22M) > 70k → no preserve.
        // Plan must WITHDRAW adapterA (target < current).
        _forcePctOfNewTvl(adapterA, 5500);

        vm.warp(block.timestamp + 22000);
        vm.prank(keeper);
        try StrategyRebalancePlanModule(address(vault)).prepareRebalance() {} catch {}

        // If L305 fired correctly (rel cap = 70k < abs cap), preservation did NOT trigger
        // (position > 70k), so the plan contains a WITHDRAW action for adapterA.
        // If L305 were broken (abs cap used = ~2M), position (1.22M) < abs ceiling (2M)
        // → preservation → capped = current → no WITHDRAW → test would fail.
        assertTrue(
            _planHasWithdrawFor(address(adapterA)),
            "rel cap must bind and force a withdraw (L305 correctly substitutes fbRelCeiling)"
        );
    }
}
