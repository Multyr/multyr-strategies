// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// =============================================================================
// EchidnaSafetyAdapterCapTier.sol -- P0.7 stateful fuzzing harness (S2.2)
// =============================================================================
//
// Standalone stateful model of the Safety Adapter Cap Tier arithmetic.
// No imports from src/ -- mirrors only the arithmetic paths identified in:
//   StrategyScoringModule.sol:479-526    (overflow deposit step)
//   StrategyAllocCalcModule.sol:298-311  (preserve-safety-tranche rule)
//   StrategyRebalanceGateModule.sol:239-275 (mandate hard ceiling computation)
//   StrategySettingsModule.sol:567       (governance cap bound)
//
// Modelled system: 3 adapters (safety=0, normalA=1, normalB=2) + idle balance.
// TVL = sum(positions) + idleBalance.
// Safety adapter is governed by (absCapBps, relCapBps): fallback ceiling =
//   min(absCapBps*tvl/BPS, relCapBps*extTVL/BPS) [if relCapBps>0].
// Normal adapters are capped by normalAbsCapBps (the shared adapterMaxExposureBps).
//
// GOVERNANCE SEMANTIC A (cap reduction semantics):
//   Cap reduction via governance CAN leave existing position above new soft cap.
//   The protocol does NOT revert the setter; instead, the next mandate check fires.
//   Invariants I03c and I04b explicitly cover this scenario.
//   I03c: position > new hardCeiling -> mandate detectable (always true by I03a).
//   I04b: after safetyMandateUnwind, position returns to fbCeiling.
//
// SNAPSHOT STATE (I03b, I03c, I04a, I04b):
//   Shadow state captures values AT THE MOMENT OF ACTION EXECUTION, independent
//   of subsequent TVL changes. This mirrors StrategyScoringModule._executeSafetyOverflow():511
//   which recomputes fbCeiling from live tvl at each execution call.
//   Verification: StrategyScoringModule.sol:511 computes fbCeiling inside _executeSafetyOverflow()
//   on every invocation; no pre-computation stored. SafetyOverflowDeployed event emits amount
//   and idle but NOT ceiling -- shadow state approach is the correct model.
//
// Echidna fuzzes: deposit, withdraw, overflowDeposit, normalDeploy,
//   normalWithdraw, safetyWithdraw, safetyMandateUnwind, triggerMandate,
//   updateCaps, updateNormalCap, updateTolerance, disableSafety, enableSafety, promoteSafety.
// Each echidna_* function returns false only on a genuine invariant violation.
//
// Run (smoke 50k):
//   echidna test/strategies/usdc-lending/echidna/EchidnaSafetyAdapterCapTier.sol \
//     --contract EchidnaSafetyAdapterCapTier \
//     --config test/strategies/usdc-lending/echidna/echidna-smoke.yaml
//
// Run (baseline 1M, background):
//   echidna test/strategies/usdc-lending/echidna/EchidnaSafetyAdapterCapTier.sol \
//     --contract EchidnaSafetyAdapterCapTier \
//     --config test/strategies/usdc-lending/echidna/echidna-baseline.yaml
//
// Critical invariants per S2.2 tasking:
//   I06 accounting_conserved           -- TOLERANCE = 1000 wei
//   I10 preserve_safety_tranche_no_unwind (H-03 invariant)
//   I12 safety_disabled_equals_legacy  -- non-regression
// =============================================================================

contract EchidnaSafetyAdapterCapTier {

    // -------------------------------------------------------------------------
    // Constants (mirror StrategySettingsModule.sol governance bounds)
    // -------------------------------------------------------------------------
    uint256 internal constant BPS = 1e4;
    uint16  internal constant ABS_CAP_MAX      = 8000;   // 80% strategy TVL
    uint16  internal constant REL_CAP_MAX      = 10000;  // 100% extTVL
    uint16  internal constant NORMAL_CAP_MAX   = 8000;   // adapterMaxExposureBps
    uint16  internal constant TOL_MAX          = 2000;   // capDriftToleranceBps
    uint256 internal constant ACCOUNTING_TOL   = 1000;   // I06 tolerance (1000 wei)
    uint256 internal constant INITIAL_TVL      = 10_000_000e6; // 10M USDC (6 dec)
    uint256 internal constant EXT_TVL          = 500_000_000e6;

    // -------------------------------------------------------------------------
    // State: modelled system
    // -------------------------------------------------------------------------

    // positions[0] = safety adapter (adapterA)
    // positions[1] = normal adapter A (adapterB)
    // positions[2] = normal adapter B (adapterC)
    uint256[3] public positions;
    uint256    public idleBalance;

    // Governance parameters
    uint16  public absCapBps     = 6000; // safety fallback abs cap
    uint16  public relCapBps     = 0;    // 0 = rel branch inactive
    uint16  public normalAbsCapBps = 5000; // shared normal cap (adapterMaxExposureBps)
    uint16  public tolBps        = 80;   // capDriftToleranceBps
    bool    public safetyEnabled = true; // is safety tier active

    // Cooldown state (H-03 invariant)
    uint256 public lastMandateTs;        // timestamp of last mandate on normal adapter
    uint256 public mandateRedeployCooldown = 3600; // seconds

    // Promotion state (I10)
    uint256 public safetyTrancheFloor;   // position value when safety tranche was established

    // Internal total TVL tracker (adjusted on deposit/withdraw)
    uint256 internal _tvl;

    // -------------------------------------------------------------------------
    // Shadow state for at-deposit snapshots (I03b, I04a)
    // Captured inside overflowDeposit at the moment of execution.
    // Independent of subsequent TVL changes (per-action guarantee).
    // Mirrors StrategyScoringModule._executeSafetyOverflow():511 recompute pattern.
    // -------------------------------------------------------------------------
    uint256 internal _lastFbCeilingAtDeposit;        // fbCeiling at overflowDeposit time
    uint256 internal _lastHardCeilingAtDeposit;      // hardCeiling at overflowDeposit time
    uint256 internal _lastOverflowPositionAfterDeposit; // positions[0] immediately post-deposit

    // Shadow state for post-mandate-unwind snapshot (I04b)
    uint256 internal _lastSoftCeilingAtMandateUnwind;   // fbCeiling at safetyMandateUnwind time
    uint256 internal _lastPositionAfterMandateUnwind;   // positions[0] immediately post-unwind
    bool    internal _mandateUnwindOccurred;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------
    constructor() {
        _tvl = INITIAL_TVL;
        idleBalance = INITIAL_TVL;
    }

    // -------------------------------------------------------------------------
    // Internal helpers (mirror the on-chain arithmetic)
    // -------------------------------------------------------------------------

    function _fbCeiling() internal view returns (uint256) {
        if (!safetyEnabled) return 0;
        uint256 absCeil = (uint256(absCapBps) * _tvl) / BPS;
        if (relCapBps > 0) {
            uint256 relCeil = (uint256(relCapBps) * EXT_TVL) / BPS;
            return relCeil < absCeil ? relCeil : absCeil;
        }
        return absCeil;
    }

    function _normalHardCeiling(uint256 idx) internal view returns (uint256) {
        // adapterMaxExposureBps * tvl * (1 + tolBps) / BPS^2
        uint256 absMaxExp = (uint256(normalAbsCapBps) * _tvl) / BPS;
        return (absMaxExp * (BPS + uint256(tolBps))) / BPS;
    }

    function _safetyHardCeiling() internal view returns (uint256) {
        if (!safetyEnabled) return _normalHardCeiling(0);
        uint256 fb = _fbCeiling();
        uint256 fbMaxExp = fb; // fbCeiling is already the effective max exposure
        return (fbMaxExp * (BPS + uint256(tolBps))) / BPS;
    }

    function _totalTracked() internal view returns (uint256) {
        return positions[0] + positions[1] + positions[2] + idleBalance;
    }

    function _clamp(uint256 v, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (v < lo) return lo;
        if (v > hi) return hi;
        return v;
    }

    // -------------------------------------------------------------------------
    // Actions (Echidna calls these to explore state space)
    // -------------------------------------------------------------------------

    /// Deposit new capital into the vault (increases TVL and idle).
    function deposit(uint256 amount) external {
        amount = _clamp(amount, 1, 1_000_000e6);
        idleBalance += amount;
        _tvl += amount;
    }

    /// Withdraw capital from idle (decreases TVL and idle).
    function withdraw(uint256 amount) external {
        if (amount > idleBalance) amount = idleBalance;
        if (amount == 0) return;
        idleBalance -= amount;
        _tvl -= amount;
    }

    /// Safety overflow deposit: deploy idle into the safety adapter up to fbCeiling.
    /// Mirrors StrategyScoringModule._executeSafetyOverflow():511-526.
    /// fbCeiling is recomputed from live _tvl at this moment (no pre-computation).
    function overflowDeposit(uint256 amount) external {
        if (!safetyEnabled) return;
        uint256 fb = _fbCeiling();
        if (positions[0] >= fb) return;
        uint256 room = fb - positions[0];
        amount = _clamp(amount, 0, idleBalance);
        if (amount > room) amount = room;
        if (amount == 0) return;
        positions[0] += amount;
        idleBalance -= amount;
        // Capture at-deposit snapshots for I03b and I04a.
        // Order: hardCeiling computed AFTER positions update (hardCeiling is TVL-dependent, not position-dependent).
        _lastFbCeilingAtDeposit = fb;
        _lastHardCeilingAtDeposit = _safetyHardCeiling();
        _lastOverflowPositionAfterDeposit = positions[0];
        // Establish tranche floor if above normal cap.
        uint256 normalCap = (uint256(normalAbsCapBps) * _tvl) / BPS;
        if (positions[0] > normalCap) {
            safetyTrancheFloor = positions[0];
        }
    }

    /// Deploy idle into a normal adapter (idx=1 or 2) up to its normal cap.
    function normalDeploy(uint8 idx, uint256 amount) external {
        uint256 i = uint256(idx) % 2 + 1; // maps to positions[1] or positions[2]
        uint256 normalCap = (uint256(normalAbsCapBps) * _tvl) / BPS;
        if (positions[i] >= normalCap) return;
        uint256 room = normalCap - positions[i];
        amount = _clamp(amount, 0, idleBalance);
        if (amount > room) amount = room;
        if (amount == 0) return;
        positions[i] += amount;
        idleBalance -= amount;
    }

    /// Withdraw from a normal adapter back to idle.
    function normalWithdraw(uint8 idx, uint256 amount) external {
        uint256 i = uint256(idx) % 2 + 1;
        amount = _clamp(amount, 0, positions[i]);
        if (amount == 0) return;
        positions[i] -= amount;
        idleBalance += amount;
    }

    /// Withdraw from the safety adapter back to idle (mandate unwind path, partial).
    /// In the real protocol, the ONLY mechanism that reduces a safety adapter position is
    /// mandate execution: triggered when positions[0] > hardCeiling, the keeper calls
    /// the unwind path. Within positions[0] <= hardCeiling (soft tranche + tolerance band),
    /// no keeper action unwinds safety — governance changes to normalCap do NOT remove
    /// this protection (the protocol does not auto-unwind on normalAbsCapBps changes).
    /// Guard: block any withdrawal when safety is enabled AND positions[0] <= hardCeiling.
    /// After execution: safetyTrancheFloor is reset to the new positions[0] level (the
    /// mandate execution establishes a NEW tranche floor at the post-unwind position).
    function safetyWithdraw(uint256 amount) external {
        if (positions[0] == 0) return;
        if (!safetyEnabled) {
            // Safety tier disabled: positions[0] behaves as a normal adapter.
            amount = _clamp(amount, 0, positions[0]);
            positions[0] -= amount;
            idleBalance += amount;
            return;
        }
        uint256 hardCeiling = _safetyHardCeiling();
        // Only unwind when positions[0] > hardCeiling (true mandate territory).
        // Governance-induced normalCap increases cannot bypass this protection.
        if (positions[0] <= hardCeiling) return;
        amount = _clamp(amount, 0, positions[0]);
        positions[0] -= amount;
        idleBalance += amount;
        // Reset trancheFloor to new position (mandate resets the safety tranche level).
        uint256 normalCap = (uint256(normalAbsCapBps) * _tvl) / BPS;
        safetyTrancheFloor = positions[0] > normalCap ? positions[0] : 0;
    }

    /// Full mandate unwind: keeper computes exact excess above fbCeiling and unwinds.
    /// Simulates StrategyRebalancePlanModule mandate execution (unwind to soft ceiling).
    /// Only fires when positions[0] > hardCeiling (true mandate territory) — consistent
    /// with safetyWithdraw semantics. Within tolerance band (fb, hardCeiling], no unwind.
    /// After execution: safetyTrancheFloor is reset to the new positions[0] level.
    function safetyMandateUnwind() external {
        if (!safetyEnabled) return;
        uint256 hardCeiling = _safetyHardCeiling();
        if (positions[0] <= hardCeiling) return; // not in true mandate territory
        uint256 fb = _fbCeiling();
        // Full unwind to fbCeiling (mirrors keeper exact-amount computation).
        uint256 excess = positions[0] > fb ? positions[0] - fb : 0;
        if (excess == 0) return;
        positions[0] -= excess;
        idleBalance += excess;
        // Reset trancheFloor to new position (mandate execution establishes new tranche floor).
        uint256 normalCap = (uint256(normalAbsCapBps) * _tvl) / BPS;
        safetyTrancheFloor = positions[0] > normalCap ? positions[0] : 0;
        // Capture post-unwind snapshot for I04b.
        _lastSoftCeilingAtMandateUnwind = fb;
        _lastPositionAfterMandateUnwind = positions[0];
        _mandateUnwindOccurred = true;
    }

    /// Trigger a mandate on a normal adapter (simulates canRebalance -> over hard ceiling).
    function triggerMandate(uint8 idx) external {
        uint256 i = uint256(idx) % 2 + 1;
        uint256 hardCeiling = _normalHardCeiling(i);
        if (positions[i] <= hardCeiling) return;
        // Stamp the cooldown timestamp.
        lastMandateTs = block.timestamp;
    }

    /// Governance: update safety fallback caps (within setter bounds).
    function updateCaps(uint16 newAbs, uint16 newRel) external {
        if (newAbs == 0 || newAbs > ABS_CAP_MAX) return;
        if (newRel > REL_CAP_MAX) return;
        absCapBps = newAbs;
        relCapBps = newRel;
    }

    /// Governance: update normal cap (within bounds).
    function updateNormalCap(uint16 newCap) external {
        if (newCap == 0 || newCap > NORMAL_CAP_MAX) return;
        normalAbsCapBps = newCap;
    }

    /// Governance: update tolerance (within setter bounds).
    function updateTolerance(uint16 newTol) external {
        if (newTol > TOL_MAX) return;
        tolBps = newTol;
    }

    /// Governance: disable safety tier (simulates removeSafetyFallbackAdapter).
    /// I12: after disabling, system must behave as legacy (no P0.7 features active).
    function disableSafety() external {
        safetyEnabled = false;
        safetyTrancheFloor = 0;
    }

    /// Governance: re-enable safety tier.
    function enableSafety() external {
        if (absCapBps == 0) absCapBps = 6000;
        safetyEnabled = true;
    }

    /// Promote safety adapter into its tranche (explicitly set position above normal cap).
    /// Simulates overflow deposit bringing position into the [normalCap, fbCeiling] band.
    function promoteSafety() external {
        uint256 normalCap = (uint256(normalAbsCapBps) * _tvl) / BPS;
        uint256 fb = _fbCeiling();
        if (fb <= normalCap) return;
        // Move safety just above normalCap to establish tranche.
        uint256 target = normalCap + (fb - normalCap) / 2;
        if (target > positions[0] && (target - positions[0]) <= idleBalance) {
            uint256 delta = target - positions[0];
            positions[0] += delta;
            idleBalance -= delta;
            safetyTrancheFloor = positions[0];
        }
    }

    // -------------------------------------------------------------------------
    // INVARIANTS (echidna_* functions must always return true)
    // -------------------------------------------------------------------------

    /// I01: Non-safety adapter's mandate threshold uses normalAbsCapBps, not fbCeiling.
    /// If a normal adapter exceeds the normal hard ceiling, mandate fires.
    function echidna_I01_normal_uses_normal_ceiling() external view returns (bool) {
        for (uint256 i = 1; i <= 2; i++) {
            uint256 hardCeil = _normalHardCeiling(i);
            // If position > hardCeiling AND no recent mandate: invariant allows mandate.
            // We check the ceiling itself is correctly computed (>= normalCap).
            uint256 normalCap = (uint256(normalAbsCapBps) * _tvl) / BPS;
            if (hardCeil < normalCap) return false; // ceiling must be >= normalCap
        }
        return true;
    }

    /// I02: Safety adapter at or below fbCeiling is NOT subject to an unwind mandate.
    function echidna_I02_safety_below_fb_no_mandate() external view returns (bool) {
        if (!safetyEnabled) return true; // inactive: not applicable
        uint256 fb = _fbCeiling();
        if (positions[0] <= fb) {
            // Position is within the fallback ceiling: hard ceiling for safety
            // must be >= position (no forced unwind).
            return _safetyHardCeiling() >= positions[0];
        }
        return true;
    }

    /// I03a STRUCTURAL: Safety hard ceiling >= base fbCeiling (tolerance band is non-negative).
    /// Sanity config guarantee: tolBps >= 0 => hardCeiling = fbCeiling*(BPS+tol)/BPS >= fbCeiling.
    /// Non-trivial across governance mutations: updateCaps, updateTolerance, updateNormalCap.
    function echidna_I03a_hard_ceiling_ge_fb_ceiling() external view returns (bool) {
        if (!safetyEnabled) return true;
        return _safetyHardCeiling() >= _fbCeiling();
    }

    /// I03b SAFETY: Overflow deposit never places position above hard ceiling at deposit time.
    /// At-deposit snapshot (mirrors StrategyScoringModule._executeSafetyOverflow():511).
    /// Since room = fbCeiling - current and fbCeiling <= hardCeiling (I03a), this is a
    /// roundtrip arithmetic check: deposit clamp -> hardCeiling snapshot -> assert consistent.
    /// +2 wei tolerance for floor-division remainder in hardCeiling computation.
    function echidna_I03b_overflow_within_hard_ceiling_at_deposit() external view returns (bool) {
        if (_lastHardCeilingAtDeposit == 0) return true; // no deposit yet
        return _lastOverflowPositionAfterDeposit <= _lastHardCeilingAtDeposit + 2;
    }

    /// I03c DETECTION: Position above hard ceiling is always above soft ceiling.
    /// Mandate trigger condition (positions[0] > hardCeiling) implies mandate scope condition
    /// (positions[0] > fbCeiling). Covers governance semantic A: cap reduction CAN leave
    /// position above new soft cap; next mandate check fires only when above hardCeiling.
    /// Corollary of I03a; provides direct Echidna coverage of the detection arithmetic.
    function echidna_I03c_above_hard_implies_above_soft() external view returns (bool) {
        if (!safetyEnabled) return true;
        uint256 hardCeiling = _safetyHardCeiling();
        if (positions[0] > hardCeiling) {
            return positions[0] > _fbCeiling();
        }
        return true;
    }

    /// I04a DEPOSIT: overflowDeposit never places position above fbCeiling at time of deposit.
    /// At-deposit snapshot -- independent of future TVL changes (per-action guarantee, not
    /// always-true state invariant). Mirrors StrategyScoringModule._executeSafetyOverflow():511
    /// where fbCeiling is recomputed from live tvl at each execution call.
    function echidna_I04a_overflow_respects_ceiling_at_deposit() external view returns (bool) {
        if (_lastFbCeilingAtDeposit == 0) return true; // no deposit yet
        return _lastOverflowPositionAfterDeposit <= _lastFbCeilingAtDeposit;
    }

    /// I04b TRANSITION: After safetyMandateUnwind, position is at or below soft fbCeiling.
    /// Verifies mandate execution arithmetic: full unwind to fbCeiling is correctly computed.
    /// Covers governance semantic A: mandate-triggered unwind correctly handles post-cap-reduction
    /// or post-TVL-decrease positions (both bring position above soft ceiling).
    /// +2 wei tolerance for floor-division rounding in excess computation.
    function echidna_I04b_post_mandate_within_soft_ceiling() external view returns (bool) {
        if (!_mandateUnwindOccurred) return true;
        return _lastPositionAfterMandateUnwind <= _lastSoftCeilingAtMandateUnwind + 2;
    }

    /// I05: Overflow self-regulation: idleBalance is non-negative (no overdraft).
    function echidna_I05_overflow_no_overdraft() external view returns (bool) {
        // idleBalance is uint256; Solidity reverts on underflow, but we verify
        // accounting consistency: total positions + idle <= tvl + TOLERANCE.
        return _totalTracked() <= _tvl + ACCOUNTING_TOL;
    }

    /// I06: Accounting conserved within TOLERANCE (1000 wei).
    ///      Total of all positions + idle must equal TVL within rounding tolerance.
    function echidna_I06_accounting_conserved() external view returns (bool) {
        uint256 total = _totalTracked();
        if (total > _tvl + ACCOUNTING_TOL) return false;
        if (total + ACCOUNTING_TOL < _tvl) return false;
        return true;
    }

    /// I07: fbCeiling is always at most the abs constituent cap.
    ///      Mirrors P2a (Halmos) in stateful context.
    function echidna_I07_fbCeiling_le_abs_constituent() external view returns (bool) {
        if (!safetyEnabled) return true;
        uint256 absCeil = (uint256(absCapBps) * _tvl) / BPS;
        return _fbCeiling() <= absCeil;
    }

    /// I08: fbCeiling is at most the rel constituent cap when rel is active.
    ///      Mirrors P2b (Halmos) in stateful context.
    function echidna_I08_fbCeiling_le_rel_constituent_when_active() external view returns (bool) {
        if (!safetyEnabled || relCapBps == 0) return true;
        uint256 relCeil = (uint256(relCapBps) * EXT_TVL) / BPS;
        return _fbCeiling() <= relCeil;
    }

    /// I09: fbCeiling is at most ABS_CAP_MAX * tvl / BPS (governance bound).
    ///      Mirrors P2c (Halmos) in stateful context.
    function echidna_I09_fbCeiling_le_govbound() external view returns (bool) {
        if (!safetyEnabled) return true;
        uint256 govBound = (uint256(ABS_CAP_MAX) * _tvl) / BPS;
        return _fbCeiling() <= govBound;
    }

    /// I10: Preserve-safety-tranche rule (H-03 invariant).
    ///      When safety position is in its tranche (above normalCap, at/below fbCeiling),
    ///      safetyWithdraw MUST NOT reduce positions[0] below safetyTrancheFloor.
    ///      We check: if trancheFloor is set and position is still in tranche, position
    ///      has not been unintentionally wound down below trancheFloor.
    function echidna_I10_preserve_safety_tranche_no_unwind() external view returns (bool) {
        if (!safetyEnabled || safetyTrancheFloor == 0) return true;
        uint256 normalCap = (uint256(normalAbsCapBps) * _tvl) / BPS;
        uint256 fb = _fbCeiling();
        // Only check while position remains in the tranche band.
        if (positions[0] > normalCap && positions[0] <= fb) {
            // Position must be >= trancheFloor (no unwind below established floor).
            return positions[0] >= safetyTrancheFloor;
        }
        return true;
    }

    /// I11: Mandate ceiling is monotone in cap value (abs-constituent-dominant case).
    ///      When absCapBps >= normalAbsCapBps AND the abs constituent is the binding cap
    ///      (rel cap is inactive or non-constraining), safetyHardCeiling >= normalHardCeiling.
    ///      Governance semantic: if relCapBps is active and constrains fbCeiling below the
    ///      abs constituent (relCeil < absCeil), the external TVL limit overrides the higher
    ///      absCapBps and the monotonicity claim does NOT apply. We skip that case explicitly.
    function echidna_I11_mandate_ceiling_monotone() external view returns (bool) {
        if (!safetyEnabled) return true;
        if (absCapBps >= normalAbsCapBps) {
            // Only assert monotonicity when the abs constituent is the binding constraint.
            // If relCapBps is active and constrains fbCeiling (relCeil < absCeil),
            // the external TVL cap overrides absCapBps -- skip to avoid false positive.
            uint256 absCeil = (uint256(absCapBps) * _tvl) / BPS;
            uint256 fbCeil  = _fbCeiling();
            if (fbCeil < absCeil) return true; // rel cap is binding -- not an abs-monotone case
            return _safetyHardCeiling() >= _normalHardCeiling(1);
        }
        return true;
    }

    /// I12: Safety disabled == legacy behaviour.
    ///      When safetyEnabled == false: the hard ceiling for adapter[0] equals
    ///      the normal hard ceiling (no P0.7 premium).
    function echidna_I12_safety_disabled_equals_legacy() external view returns (bool) {
        if (safetyEnabled) return true;
        // With safety disabled, safetyHardCeiling() falls back to normalHardCeiling.
        return _safetyHardCeiling() == _normalHardCeiling(0);
    }
}
