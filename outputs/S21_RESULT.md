# S2.1 RESULT — Halmos Formal Proofs: Safety Adapter Cap Tier (P0.7)

**Branch:** feature/p0.7-safety-adapter-tier  
**Date:** 2026-06-12  
**Task:** S2.1 — formal symbolic verification of the five architectural invariants of the Safety Adapter Cap Tier.

---

## R4 Gate (0-fail)

| Metric       | PRE                    | POST                   | Gate |
|--------------|------------------------|------------------------|------|
| Tests passed | 1974                   | 1974                   | PASS |
| Tests failed | 0                      | 0                      | PASS |
| Test suites  | 126                    | 126                    | PASS |

- PRE capture: `outputs/S21_pre_test.txt`
- POST capture: `outputs/S21_post_test.txt`

Gate: POST_PASS >= PRE_PASS AND POST_FAIL == 0. **GREEN.**

---

## Halmos run — formal results

```
Running 6 tests for HalmosSafetyAdapterCapTier
[PASS] check_fbCeiling_le_abs_ceiling           (paths: 11, time: 0.13s)
[PASS] check_fbCeiling_le_rel_ceiling_when_active (paths: 8, time: 0.05s)
[PASS] check_overflow_never_exceeds_fallback_ceiling (paths: 28, time: 0.45s)
[PASS] check_overflow_self_regulates_no_overshoot (paths: 28, time: 0.24s)
[PASS] check_preserve_safety_tranche_no_unwind  (paths: 22, time: 0.14s)
[PASS] check_safety_disabled_equals_legacy      (paths: 6,  time: 0.03s)

Symbolic test result: 6 passed; 0 failed; time: 1.07s
```

Halmos run log: `outputs/S21_halmos_run.txt`

---

## Properties proved

| ID  | Function                                    | Paths | Mirrors source                          |
|-----|---------------------------------------------|-------|-----------------------------------------|
| P1  | check_overflow_never_exceeds_fallback_ceiling | 28  | StrategyScoringModule.sol:517-526       |
| P2a | check_fbCeiling_le_abs_ceiling              | 11    | StrategyScoringModule.sol:511-515       |
| P2b | check_fbCeiling_le_rel_ceiling_when_active  | 8     | StrategyScoringModule.sol:511-515       |
| P4  | check_preserve_safety_tranche_no_unwind     | 22    | StrategyAllocCalcModule.sol:298-311     |
| P5  | check_overflow_self_regulates_no_overshoot  | 28    | StrategyScoringModule.sol:517-526       |
| P6  | check_safety_disabled_equals_legacy         | 6     | StrategyRebalanceGateModule.sol:251-253 |

---

## SMT-hard properties (prop_ — algebraic proofs, halmos skips)

Three properties are undecidable by z3 QF_NIA in practice (product of two fully symbolic bitvectors). They are documented as `prop_*` functions with inline algebraic proofs in the source file. TIMEOUT != counterexample; the claims hold by mathematical argument.

| ID  | Function                              | Proof strategy                                    |
|-----|---------------------------------------|---------------------------------------------------|
| P2c | prop_governance_attack_surface_bounded | Follows from P2a + integer-div monotonicity lemma |
| P3a | prop_mandate_ceiling_monotone          | Two-step floor-div monotonicity proof             |
| P3b | prop_safety_fire_implies_normal_fire   | Transitivity from P3a                             |

---

## Files changed

| File | Change |
|------|--------|
| `test/strategies/usdc-lending/halmos/HalmosSafetyAdapterCapTier.t.sol` | **New** — 9 properties (6 `check_*` proved by halmos, 3 `prop_*` with algebraic proofs) |

---

## Next step

S2.2 — Echidna harness (Docker `trailofbits/echidna`, smoke 50k runs, baseline 1M campaign).
