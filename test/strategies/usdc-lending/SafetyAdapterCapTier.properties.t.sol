// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ═══════════════════════════════════════════════════════════════════════════════
// SafetyAdapterCapTier.properties.t.sol — P0.7 architectural property tests
// ───────────────────────────────────────────────────────────────────────────────
// Six fuzz-based property tests covering the architectural invariants of the
// Safety Adapter Cap Tier (P0.7). These are NOT stateful Foundry invariants
// (which would require a dedicated handler harness ~600+ LOC); they are
// bounded fuzz tests that re-verify each invariant under randomised
// preconditions.
//
// Reusing the harness from CapDriftMandate.t.sol (CapDriftBase) keeps the
// adapter wiring identical across the unit-test and property-test suites and
// guarantees that mock behaviour, scoring weights, and adapter caps are the
// SAME — any divergence between the unit results and the fuzz results would
// indicate a property edge case worth surfacing.
//
// Property index:
//   I-1  non_safety_uses_normal_caps_for_mandate
//   I-2  safety_below_fallback_no_mandate_signal
//   I-3  safety_above_fallback_mandate_fires
//   I-4  overflow_never_exceeds_fallback_cap
//   I-10 preserve_safety_tranche_no_unwind
//   I-12 safety_disabled_equals_legacy_behavior
//
// Run with:
//   forge test --match-contract SafetyAdapterCapTierProperties -vv
// ═══════════════════════════════════════════════════════════════════════════════

import { Test, stdStorage, StdStorage } from "forge-std/Test.sol";
import {
    CapDrift_D1f_SafetyAdapterCapTier
} from "./CapDriftMandate.t.sol";

import {
    UsdcMultiLendingVault
} from "../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
import {
    StrategySettingsModule
} from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {
    StrategyRebalanceGateModule
} from "../../../src/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol";
import {
    StrategyRebalancePlanModule
} from "../../../src/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol";
import {
    StrategyScoringModule
} from "../../../src/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import {
    StrategyParamsModule
} from "../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import { ScoringMockAdapter } from "./Scoring_Model.t.sol";

contract SafetyAdapterCapTierProperties is CapDrift_D1f_SafetyAdapterCapTier {

    // ── Property I-1 ────────────────────────────────────────────────────────
    // Non-safety adapters are gated by the NORMAL absolute hard ceiling. For
    // any position fraction strictly above 5125 bps (= 50% × 1.025) and below
    // the safety hardCeiling 7175 bps, the mandate MUST fire on a non-safety
    // adapter, with the nb==0 protection signature.

    function testFuzz_I1_non_safety_uses_normal_caps(uint16 pctBps) public {
        // Bound to the "above normal hardCeiling, below safety hardCeiling" band.
        // Lower bound 5200 leaves a 75 bps margin above 5125 to absorb rounding;
        // upper bound 7100 stays below safety hardCeiling 7175.
        pctBps = uint16(bound(uint256(pctBps), 5200, 7100));
        _forcePctOfNewTvl(adapterB, pctBps);

        vm.warp(block.timestamp + 22000);
        (bool ok, , int256 nb) =
            StrategyRebalanceGateModule(address(vault)).canRebalance();

        assertTrue(ok, "I-1: non-safety above normal hardCeiling MUST mandate-fire");
        assertEq(nb, int256(0), "I-1: mandate signature nb==0");
    }

    // ── Property I-2 ────────────────────────────────────────────────────────
    // Safety adapter sitting at any position UP TO its fallback abs cap
    // (7000 bps = 70% TVL) is NOT subject to the mandate via the normal cap
    // path. The forbidden outcome is ok=true && nb==0 (the mandate signature)
    // — any other tuple (ok=false, or ok=true with positive nb) is legitimate.

    function testFuzz_I2_safety_below_fallback_no_mandate_signal(uint16 pctBps) public {
        // Bound to the "above normal hardCeiling, below SAFETY hardCeiling" band
        // — exactly the band where the design must protect the safety tranche
        // from a spurious mandate. Below 5200 the adapter is in normal-cap
        // territory, where mandate behaviour is irrelevant.
        pctBps = uint16(bound(uint256(pctBps), 5200, 7100));
        _forcePctOfNewTvl(adapterA, pctBps);

        vm.warp(block.timestamp + 22000);
        (bool ok, , int256 nb) =
            StrategyRebalanceGateModule(address(vault)).canRebalance();

        if (ok) {
            assertGt(nb, 0, "I-2: safety in tranche must not mandate-fire (nb==0 forbidden)");
        }
    }

    // ── Property I-3 ────────────────────────────────────────────────────────
    // Above the SAFETY hardCeiling (71.75% = 7175 bps), the mandate MUST fire
    // even for a safety adapter — the fallback cap is a ceiling, not an
    // exemption. The mandate signature on this path differs from I-1 only in
    // that the cooldown timestamp is NOT stamped for safety (verified in
    // unit test D1f_04); here we only assert the firing semantic.

    function testFuzz_I3_safety_above_fallback_mandate_fires(uint16 pctBps) public {
        // Bound strictly above safety hardCeiling 7175 + a small margin to
        // absorb rounding. Upper bound 9000 keeps adapterA leaving room for
        // adapterB + adapterC + idle to sum to a sensible TVL (otherwise the
        // closed-form helper would have to handle near-100% targets).
        pctBps = uint16(bound(uint256(pctBps), 7400, 9000));
        _forcePctOfNewTvl(adapterA, pctBps);

        vm.warp(block.timestamp + 22000);
        (bool ok, , int256 nb) =
            StrategyRebalanceGateModule(address(vault)).canRebalance();

        assertTrue(ok, "I-3: safety above fallback hardCeiling MUST mandate-fire");
        assertEq(nb, int256(0), "I-3: mandate signature nb==0");
    }

    // ── Property I-4 ────────────────────────────────────────────────────────
    // The overflow path NEVER pushes a safety adapter above its fallback
    // ceiling. Even if the surplus idle is arbitrarily large, the safety
    // position lands at most at fbAbsCap × tvl.

    function testFuzz_I4_overflow_never_exceeds_fallback_cap(uint96 surplus) public {
        // Bound the surplus to a sensible range. Too small and the overflow
        // path no-ops; too large and we get into uint overflow on the mint.
        surplus = uint96(bound(uint256(surplus), 1e6, 100_000_000e6));

        // Saturate non-safety adapters at normal cap so the surplus has to
        // flow through the overflow path.
        uint256 normalCapAmt = (_totalTvl() * 5000) / 10_000;
        _forcePosition(adapterB, normalCapAmt);
        _forcePosition(adapterC, normalCapAmt);

        // Mint surplus into the vault.
        usdc.mint(address(vault), surplus);

        // Past the deployIdle cooldown.
        vm.warp(block.timestamp + 301);
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();

        // Invariant: adapterA's position is ≤ fbAbsCap × NEW totalTvl.
        uint256 fbAbsCeiling = (uint256(SAFETY_FB_ABS_BPS) * _totalTvl()) / 10_000;
        assertLe(
            vault.positionAssets(address(adapterA)), fbAbsCeiling,
            "I-4: safety position must never exceed fallback abs ceiling"
        );
    }

    // ── Property I-10 ────────────────────────────────────────────────────────
    // The preserve-safety-tranche rule: for any safety adapter sitting in its
    // legitimate tranche (above normal scoring target, at or below fallback
    // ceiling), a mandate triggered on a DIFFERENT adapter must NOT cause a
    // withdraw on the safety adapter.

    function testFuzz_I10_preserve_safety_tranche_no_unwind(uint16 safetyPctBps) public {
        // Bound: safety in its legitimate tranche, strictly above the normal
        // soft cap (5000) and well below the fallback ceiling (7000), with a
        // margin from both bounds to keep arithmetic clean.
        safetyPctBps = uint16(bound(uint256(safetyPctBps), 5500, 6900));
        _forcePctOfNewTvl(adapterA, safetyPctBps);
        // Mandate target: adapterB clearly above normal hardCeiling.
        _forcePctOfNewTvl(adapterB, 5500);

        vm.warp(block.timestamp + 22000);
        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).prepareRebalance();

        assertFalse(
            _planHasWithdrawFor(address(adapterA)),
            "I-10: safety tranche MUST NOT be unwound while mandate targets a different adapter"
        );
    }

    // ── Property I-12 ────────────────────────────────────────────────────────
    // Disabling all P0.7 levers must reproduce the LEGACY behaviour bit-for-bit.
    // Concretely: when safetyFallback is empty AND maxIdleBps == 0 AND
    // mandateRedeployCooldown == 0 AND targetSafetyMargin == 0, the gate behaves
    // exactly as the pre-P0.7 contract did.
    //
    // We verify the mandate-on-non-safety branch under those settings: it must
    // fire identically and stamp lastRelCapMandateTs to 0 (because cooldown is
    // disabled by configuration, not by safety status).

    function testFuzz_I12_safety_disabled_equals_legacy_behavior(uint16 pctBps) public {
        // Bound to non-safety adapterB above normal hardCeiling.
        pctBps = uint16(bound(uint256(pctBps), 5200, 6500));

        // Disable ALL P0.7 levers via governance.
        vm.startPrank(admin);
        StrategySettingsModule(address(vault)).removeSafetyFallbackAdapter(address(adapterA));
        StrategySettingsModule(address(vault)).setMaxIdleBps(0);
        StrategySettingsModule(address(vault)).setMandateRedeployCooldown(0);
        StrategySettingsModule(address(vault)).setTargetSafetyMargin(0);
        vm.stopPrank();

        _forcePctOfNewTvl(adapterB, pctBps);
        vm.warp(block.timestamp + 22000);

        (bool ok, , int256 nb) =
            StrategyRebalanceGateModule(address(vault)).canRebalance();

        assertTrue(ok, "I-12: mandate must fire identically to legacy on non-safety over-cap");
        assertEq(nb, int256(0), "I-12: legacy mandate signature nb==0");

        // Run the action path to stamp any cooldown that would otherwise be set.
        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).prepareRebalance();
        _drainPlan();

        // With cooldown=0, no timestamp must be stamped (matches legacy).
        assertEq(
            vault.lastRelCapMandateTs(address(adapterB)), 0,
            "I-12: with cooldown disabled, no timestamp must be stamped"
        );
    }
}
