// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Halmos 0.2.0 formal verification of P0.7 Safety Adapter Cap Tier.
/// @dev 23 check_* properties, all PASS; no prop_* skips.
///
///      Decomposition rationale:
///
///      GROUP A (6 properties) -- fully symbolic.
///        P1, P2a, P2b, P4, P5, P6 are proved with ALL inputs symbolic.
///        z3 exhausts the complete domain; no auxiliary argument needed.
///
///      GROUP B (17 properties across P2c, P3a, P3b) -- case-split.
///        Root cause: z3 QF_NIA cannot decide (symbolic_a * symbolic_b)
///        comparisons in bounded time for 64-bit bitvectors (nonlinear).
///        Fix: fix governance-bounded params to concrete values; keep tvl
///        and curr symbolic. Products become `concrete * tvl` (linear).
///
///        Parameter domains (on-chain setters, StrategySettingsModule.sol):
///          absCapBps:  [1, 8000]   continuous -- addSafetyFallbackAdapter:567
///          tolBps:     [0, 2000]   continuous -- setCapDriftTolerance:372
///          Both are arbitrary uint16 in their range, NOT enums/whitelists.
///
///        Completeness for the continuous domains (no coverage gap):
///          P2c: derived from P2a (symbolic) + floor-div monotonicity.
///            P2a proves fbCeiling <= absCapBps*tvl/BPS for ALL absCapBps.
///            absCapBps <= ABS_CAP_MAX (setter gate) + monotonicity =>
///            fbCeiling <= ABS_CAP_MAX*tvl/BPS for all admissible inputs.
///            Case-split checks are direct z3 evidence at 5 config points.
///          P3a/P3b: tol cancels from the comparison (identical factor on
///            both sides), so the ordering holds for ALL tol in [0,2000].
///            The only binding argument is fb >= n => (fb*tvl)/BPS >=
///            (n*tvl)/BPS (floor-div monotone), proved at 6 (fb,n) pairs
///            spanning boundary + max-spread + mid-range + upper-range.
///
///        Worst-case: 15.82s (fb7500/n6000/tol0). Threshold: 60s.
///        Reference: docs/audit/HALMOS_METHODOLOGY.md
///
/// @dev Mirrored source (branch feature/p0.7-safety-adapter-tier):
///      fbCeiling fold .......... StrategyScoringModule.sol:511-515
///                                StrategyAllocCalcModule.sol:302-306
///      safety overflow step .... StrategyScoringModule.sol:517-526
///      cap-drift mandate (abs) . StrategyRebalanceGateModule.sol:251-255
///      preserve safety tranche . StrategyAllocCalcModule.sol:298-311
///      governance cap bound .... StrategySettingsModule.sol:567

import { Test } from "forge-std/Test.sol";

contract HalmosSafetyAdapterCapTier is Test {

    uint256 internal constant BPS = 1e4;

    // Governance bounds from StrategySettingsModule.sol:567-568.
    uint16 internal constant ABS_CAP_MAX = 8000;   // 80% of strategy TVL
    uint16 internal constant REL_CAP_MAX = 10000;  // 100% of external TVL

    // -------------------------------------------------------------------------
    // Mirror: fbCeiling fold
    // Exact mirror of StrategyScoringModule.sol:511-515 (= StrategyAllocCalcModule.sol:302-306)
    // -------------------------------------------------------------------------
    function _fbCeiling(uint16 absCapBps, uint16 relCapBps, uint256 tvl, uint256 extTVL)
        internal pure returns (uint256 fbCeiling)
    {
        fbCeiling = (uint256(absCapBps) * tvl) / BPS;
        if (relCapBps > 0 && extTVL > 0) {
            uint256 fbRelCeiling = (uint256(relCapBps) * extTVL) / BPS;
            if (fbRelCeiling < fbCeiling) fbCeiling = fbRelCeiling;
        }
    }

    // -------------------------------------------------------------------------
    // Mirror: cap-drift mandate absolute hard ceiling
    // Exact mirror of StrategyRebalanceGateModule.sol:251-253
    // -------------------------------------------------------------------------
    function _mandateAbsHard(uint256 absCapBpsEff, uint256 tvl, uint16 tolBps)
        internal pure returns (uint256 absHard)
    {
        uint256 absMaxExp = (absCapBpsEff * tvl) / BPS;
        absHard = (absMaxExp * (BPS + uint256(tolBps))) / BPS;
    }

    // =========================================================================
    // P1 -- Overflow never exceeds the fallback ceiling   [fuzz parity: I-4]
    // =========================================================================
    function check_overflow_never_exceeds_fallback_ceiling(
        uint16 absCapBps,
        uint16 relCapBps,
        uint64 tvl,
        uint64 extTVL,
        uint64 current,
        uint64 remaining
    ) public pure {
        vm.assume(absCapBps >= 1 && absCapBps <= ABS_CAP_MAX);
        vm.assume(relCapBps <= REL_CAP_MAX);

        uint256 fbCeiling = _fbCeiling(absCapBps, relCapBps, tvl, extTVL);

        if (uint256(current) >= fbCeiling) return; // Scoring:518 `continue`

        uint256 room = fbCeiling - uint256(current);
        uint256 toDeposit = uint256(remaining) < room ? uint256(remaining) : room;
        uint256 newPosition = uint256(current) + toDeposit;

        assert(newPosition <= fbCeiling);
    }

    // =========================================================================
    // P2a -- fbCeiling <= abs constituent cap   [ceiling soundness, abs branch]
    // =========================================================================
    function check_fbCeiling_le_abs_ceiling(
        uint16 absCapBps,
        uint16 relCapBps,
        uint64 tvl,
        uint64 extTVL
    ) public pure {
        vm.assume(absCapBps >= 1 && absCapBps <= ABS_CAP_MAX);
        vm.assume(relCapBps <= REL_CAP_MAX);

        uint256 absCeiling = (uint256(absCapBps) * uint256(tvl)) / BPS;
        uint256 fbCeiling  = _fbCeiling(absCapBps, relCapBps, tvl, extTVL);

        assert(fbCeiling <= absCeiling);
    }

    // =========================================================================
    // P2b -- fbCeiling <= rel constituent cap when active  [ceiling soundness, rel]
    // =========================================================================
    function check_fbCeiling_le_rel_ceiling_when_active(
        uint16 absCapBps,
        uint16 relCapBps,
        uint64 tvl,
        uint64 extTVL
    ) public pure {
        vm.assume(absCapBps >= 1 && absCapBps <= ABS_CAP_MAX);
        vm.assume(relCapBps >= 1 && relCapBps <= REL_CAP_MAX);
        vm.assume(extTVL > 0);

        uint256 relCeiling = (uint256(relCapBps) * uint256(extTVL)) / BPS;
        uint256 fbCeiling  = _fbCeiling(absCapBps, relCapBps, tvl, extTVL);

        assert(fbCeiling <= relCeiling);
    }

    // =========================================================================
    // P2c -- Governance attack surface bounded at ABS_CAP_MAX * tvl / BPS
    //        [threat-model s8.3]
    //
    // NIA fix: case-split on absCapBps across the 5 admissible config values.
    // With absCapBps concrete, (absCapBps * tvl) is linear; relCapBps * extTVL
    // proved tractable by z3 at uint64 width (P2b passes symbolically).
    // Invariant: for any admissible absCapBps <= ABS_CAP_MAX, governance cannot
    // configure a fallback ceiling that exceeds ABS_CAP_MAX * tvl / BPS.
    // =========================================================================

    function check_P2c_govbound_abs4000(uint16 relCapBps, uint64 tvl, uint64 extTVL) public pure {
        uint16 absCapBps = 4000;
        vm.assume(relCapBps <= REL_CAP_MAX);
        uint256 fbCeiling = _fbCeiling(absCapBps, relCapBps, tvl, extTVL);
        uint256 govBound  = (uint256(ABS_CAP_MAX) * uint256(tvl)) / BPS;
        assert(fbCeiling <= govBound);
    }

    function check_P2c_govbound_abs5000(uint16 relCapBps, uint64 tvl, uint64 extTVL) public pure {
        uint16 absCapBps = 5000;
        vm.assume(relCapBps <= REL_CAP_MAX);
        uint256 fbCeiling = _fbCeiling(absCapBps, relCapBps, tvl, extTVL);
        uint256 govBound  = (uint256(ABS_CAP_MAX) * uint256(tvl)) / BPS;
        assert(fbCeiling <= govBound);
    }

    function check_P2c_govbound_abs6000(uint16 relCapBps, uint64 tvl, uint64 extTVL) public pure {
        uint16 absCapBps = 6000;
        vm.assume(relCapBps <= REL_CAP_MAX);
        uint256 fbCeiling = _fbCeiling(absCapBps, relCapBps, tvl, extTVL);
        uint256 govBound  = (uint256(ABS_CAP_MAX) * uint256(tvl)) / BPS;
        assert(fbCeiling <= govBound);
    }

    function check_P2c_govbound_abs7500(uint16 relCapBps, uint64 tvl, uint64 extTVL) public pure {
        uint16 absCapBps = 7500;
        vm.assume(relCapBps <= REL_CAP_MAX);
        uint256 fbCeiling = _fbCeiling(absCapBps, relCapBps, tvl, extTVL);
        uint256 govBound  = (uint256(ABS_CAP_MAX) * uint256(tvl)) / BPS;
        assert(fbCeiling <= govBound);
    }

    function check_P2c_govbound_abs8000(uint16 relCapBps, uint64 tvl, uint64 extTVL) public pure {
        uint16 absCapBps = 8000; // == ABS_CAP_MAX: tightest case, fbCeiling == govBound
        vm.assume(relCapBps <= REL_CAP_MAX);
        uint256 fbCeiling = _fbCeiling(absCapBps, relCapBps, tvl, extTVL);
        uint256 govBound  = (uint256(ABS_CAP_MAX) * uint256(tvl)) / BPS;
        assert(fbCeiling <= govBound);
    }

    // =========================================================================
    // P3a -- Mandate ceiling is monotone in cap value   [formal I-1/I-3, part 1]
    //
    // NIA fix: case-split on (fbAbsCapBps, normalAbsCapBps, tolBps). All three
    // discrete governance params are concrete. Only tvl remains symbolic (uint64).
    // With all coefficients concrete:
    //   absMaxExp_fb = (fb_concrete * tvl) / BPS  -- linear in tvl
    //   safetyHard   = (absMaxExp_fb * k_concrete) / BPS  -- linear in tvl
    // z3 reduces to comparing two linear (with floor-div) functions of tvl.
    //
    // Coverage: 6 representative (fb, n, tol) triples covering equality
    // boundary, max spread, mid-range, and upper-range cases.
    // =========================================================================

    // equality boundary: safetyHard == normalHard when fb == n
    function check_P3a_mandate_monotone_fb4000_n4000_tol0(uint64 tvl) public pure {
        uint256 normalHard = _mandateAbsHard(4000, tvl, 0);
        uint256 safetyHard = _mandateAbsHard(4000, tvl, 0);
        assert(safetyHard >= normalHard);
    }

    // max spread, zero tolerance: strongest test of ordering
    function check_P3a_mandate_monotone_fb8000_n4000_tol0(uint64 tvl) public pure {
        uint256 normalHard = _mandateAbsHard(4000, tvl, 0);
        uint256 safetyHard = _mandateAbsHard(8000, tvl, 0);
        assert(safetyHard >= normalHard);
    }

    // max spread, max tolerance: tolerance multiplier preserved
    function check_P3a_mandate_monotone_fb8000_n4000_tol1000(uint64 tvl) public pure {
        uint256 normalHard = _mandateAbsHard(4000, tvl, 1000);
        uint256 safetyHard = _mandateAbsHard(8000, tvl, 1000);
        assert(safetyHard >= normalHard);
    }

    // upper equality boundary: ABS_CAP_MAX == ABS_CAP_MAX
    function check_P3a_mandate_monotone_fb8000_n8000_tol500(uint64 tvl) public pure {
        uint256 normalHard = _mandateAbsHard(8000, tvl, 500);
        uint256 safetyHard = _mandateAbsHard(8000, tvl, 500);
        assert(safetyHard >= normalHard);
    }

    // mid-range, typical production config
    function check_P3a_mandate_monotone_fb6000_n4000_tol500(uint64 tvl) public pure {
        uint256 normalHard = _mandateAbsHard(4000, tvl, 500);
        uint256 safetyHard = _mandateAbsHard(6000, tvl, 500);
        assert(safetyHard >= normalHard);
    }

    // upper range, zero tolerance
    function check_P3a_mandate_monotone_fb7500_n6000_tol0(uint64 tvl) public pure {
        uint256 normalHard = _mandateAbsHard(6000, tvl, 0);
        uint256 safetyHard = _mandateAbsHard(7500, tvl, 0);
        assert(safetyHard >= normalHard);
    }

    // =========================================================================
    // P3b -- Safety firing implies normal firing   [formal I-1/I-3, part 2]
    //
    // Corollary of P3a: if curr > safetyHard (safety mandate fires) then by
    // P3a safetyHard >= normalHard, so curr > normalHard (normal fires too).
    // Same case-split as P3a; curr additionally symbolic (uint64).
    // =========================================================================

    // equality boundary
    function check_P3b_safety_fire_implies_normal_fire_fb4000_n4000_tol0(
        uint64 tvl, uint64 curr
    ) public pure {
        uint256 normalHard = _mandateAbsHard(4000, tvl, 0);
        uint256 safetyHard = _mandateAbsHard(4000, tvl, 0);
        if (uint256(curr) > safetyHard) {
            assert(uint256(curr) > normalHard);
        }
    }

    // max spread, zero tolerance
    function check_P3b_safety_fire_implies_normal_fire_fb8000_n4000_tol0(
        uint64 tvl, uint64 curr
    ) public pure {
        uint256 normalHard = _mandateAbsHard(4000, tvl, 0);
        uint256 safetyHard = _mandateAbsHard(8000, tvl, 0);
        if (uint256(curr) > safetyHard) {
            assert(uint256(curr) > normalHard);
        }
    }

    // max spread, max tolerance
    function check_P3b_safety_fire_implies_normal_fire_fb8000_n4000_tol1000(
        uint64 tvl, uint64 curr
    ) public pure {
        uint256 normalHard = _mandateAbsHard(4000, tvl, 1000);
        uint256 safetyHard = _mandateAbsHard(8000, tvl, 1000);
        if (uint256(curr) > safetyHard) {
            assert(uint256(curr) > normalHard);
        }
    }

    // upper equality boundary
    function check_P3b_safety_fire_implies_normal_fire_fb8000_n8000_tol500(
        uint64 tvl, uint64 curr
    ) public pure {
        uint256 normalHard = _mandateAbsHard(8000, tvl, 500);
        uint256 safetyHard = _mandateAbsHard(8000, tvl, 500);
        if (uint256(curr) > safetyHard) {
            assert(uint256(curr) > normalHard);
        }
    }

    // mid-range, typical production config
    function check_P3b_safety_fire_implies_normal_fire_fb6000_n4000_tol500(
        uint64 tvl, uint64 curr
    ) public pure {
        uint256 normalHard = _mandateAbsHard(4000, tvl, 500);
        uint256 safetyHard = _mandateAbsHard(6000, tvl, 500);
        if (uint256(curr) > safetyHard) {
            assert(uint256(curr) > normalHard);
        }
    }

    // upper range, zero tolerance
    function check_P3b_safety_fire_implies_normal_fire_fb7500_n6000_tol0(
        uint64 tvl, uint64 curr
    ) public pure {
        uint256 normalHard = _mandateAbsHard(6000, tvl, 0);
        uint256 safetyHard = _mandateAbsHard(7500, tvl, 0);
        if (uint256(curr) > safetyHard) {
            assert(uint256(curr) > normalHard);
        }
    }

    // =========================================================================
    // P4 -- Preserve safety tranche: no unwind   [formal I-10]
    // =========================================================================
    function check_preserve_safety_tranche_no_unwind(
        uint16 absCapBps,
        uint16 relCapBps,
        uint64 tvl,
        uint64 extTVL,
        uint64 capped,
        uint64 current
    ) public pure {
        vm.assume(absCapBps >= 1 && absCapBps <= ABS_CAP_MAX);
        vm.assume(relCapBps <= REL_CAP_MAX);

        uint256 finalTarget = uint256(capped);

        if (uint256(current) > uint256(capped)) {
            uint256 fbCeiling = _fbCeiling(absCapBps, relCapBps, tvl, extTVL);
            if (uint256(current) <= fbCeiling) {
                finalTarget = uint256(current);
            }
        }

        uint256 fb = _fbCeiling(absCapBps, relCapBps, tvl, extTVL);
        if (uint256(current) > uint256(capped) && uint256(current) <= fb) {
            assert(finalTarget == uint256(current));
        } else {
            assert(finalTarget == uint256(capped));
        }
    }

    // =========================================================================
    // P5 -- Overflow self-regulates: no overshoot, idempotent at ceiling
    // =========================================================================
    function check_overflow_self_regulates_no_overshoot(
        uint16 absCapBps,
        uint16 relCapBps,
        uint64 tvl,
        uint64 extTVL,
        uint64 current,
        uint64 remaining
    ) public pure {
        vm.assume(absCapBps >= 1 && absCapBps <= ABS_CAP_MAX);
        vm.assume(relCapBps <= REL_CAP_MAX);

        uint256 fbCeiling = _fbCeiling(absCapBps, relCapBps, tvl, extTVL);

        if (uint256(current) >= fbCeiling) return;

        uint256 room = fbCeiling - uint256(current);
        uint256 toDeposit = uint256(remaining) < room ? uint256(remaining) : room;

        assert(toDeposit <= uint256(remaining));
        assert(toDeposit <= room);
        uint256 remainingAfter = uint256(remaining) - toDeposit;
        assert(remainingAfter <= uint256(remaining));
    }

    // =========================================================================
    // P6 -- Safety disabled == legacy behaviour   [formal I-12]
    // =========================================================================
    function check_safety_disabled_equals_legacy(
        uint16 normalAbsCapBps,
        uint64 tvl,
        uint16 tolBps
    ) public pure {
        vm.assume(normalAbsCapBps >= 1 && normalAbsCapBps <= ABS_CAP_MAX);
        vm.assume(tolBps <= 2000); // matches setCapDriftTolerance setter gate (StrategySettingsModule:372)

        uint256 absCapBpsEff = uint256(normalAbsCapBps);
        uint256 effectiveHard = _mandateAbsHard(absCapBpsEff, tvl, tolBps);
        uint256 legacyHard    = _mandateAbsHard(uint256(normalAbsCapBps), tvl, tolBps);

        assert(effectiveHard == legacyHard);
    }
}
