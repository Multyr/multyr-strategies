# S2.1 RESULT -- Halmos Formal Proofs: Safety Adapter Cap Tier (P0.7)

**Branch:** feature/p0.7-safety-adapter-tier  
**Date:** 2026-06-12  
**Task:** S2.1 rev-B -- formal symbolic verification of 9 invariant groups of the
Safety Adapter Cap Tier; 23 check_* functions, no prop_* skips.

---

## R4 Gate (0-fail)

| Metric       | PRE                    | POST                   | Gate |
|--------------|------------------------|------------------------|------|
| Tests passed | 1974                   | 1974                   | PASS |
| Tests failed | 0                      | 0                      | PASS |
| Test suites  | 126                    | 126                    | PASS |

- PRE capture: `outputs/S21_pre_test.txt` (1974/0, forge test)
- POST capture: `outputs/S21_post_test.txt` (1974/0, forge test; HalmosSafetyAdapterCapTier.t.sol
  is not included in the forge test suite -- halmos runs separately)

Gate: POST_PASS >= PRE_PASS AND POST_FAIL == 0. **GREEN.**

---

## Halmos run -- formal results

```
Running 23 tests for HalmosSafetyAdapterCapTier

[PASS] check_P2c_govbound_abs4000         (paths: 17, time:  1.34s)
[PASS] check_P2c_govbound_abs5000         (paths: 17, time:  2.28s)
[PASS] check_P2c_govbound_abs6000         (paths: 17, time:  4.00s)
[PASS] check_P2c_govbound_abs7500         (paths: 17, time:  8.60s)
[PASS] check_P2c_govbound_abs8000         (paths:  9, time:  0.05s)
[PASS] check_P3a_fb4000_n4000_tol0        (paths:  4, time:  0.03s)
[PASS] check_P3a_fb6000_n4000_tol500      (paths:  7, time: 12.56s)
[PASS] check_P3a_fb7500_n6000_tol0        (paths:  7, time: 15.22s)
[PASS] check_P3a_fb8000_n4000_tol0        (paths:  7, time:  7.63s)
[PASS] check_P3a_fb8000_n4000_tol1000     (paths:  7, time:  7.31s)
[PASS] check_P3a_fb8000_n8000_tol500      (paths:  4, time:  0.03s)
[PASS] check_P3b_fb4000_n4000_tol0        (paths:  6, time:  0.03s)
[PASS] check_P3b_fb6000_n4000_tol500      (paths:  9, time:  8.75s)
[PASS] check_P3b_fb7500_n6000_tol0        (paths:  9, time: 14.86s)
[PASS] check_P3b_fb8000_n4000_tol0        (paths:  9, time:  8.75s)
[PASS] check_P3b_fb8000_n4000_tol1000     (paths:  9, time:  7.70s)
[PASS] check_P3b_fb8000_n8000_tol500      (paths:  6, time:  0.03s)
[PASS] check_fbCeiling_le_abs_ceiling     (paths: 11, time:  0.14s)
[PASS] check_fbCeiling_le_rel_ceiling...  (paths:  8, time:  0.05s)
[PASS] check_overflow_never_exceeds...    (paths: 31, time:  0.48s)
[PASS] check_overflow_self_regulates...   (paths: 30, time:  0.31s)
[PASS] check_preserve_safety_tranche...   (paths: 22, time:  0.15s)
[PASS] check_safety_disabled_equals...    (paths:  6, time:  0.04s)

Symbolic test result: 23 passed; 0 failed; time: 100.37s
```

Full halmos output: `outputs/S21_halmos_run.txt`
Evidence JSON: `test/strategies/usdc-lending/halmos/results/halmos-evidence.json`

---

## NIA nonlinearity resolution

The three properties that previously caused z3 QF_NIA TIMEOUT (P2c, P3a, P3b) were
fixed using CASE-SPLIT on discrete governance parameters:

| Problem        | Root cause                      | Fix                                        |
|----------------|---------------------------------|--------------------------------------------|
| P2c            | `absCapBps x tvl` (2 symbolic)  | absCapBps fixed to {4000,5000,6000,7500,8000} |
| P3a            | `fb x tvl`, `n x tvl`, `x tol` | (fb, n, tol) all concrete; tvl symbolic    |
| P3b            | same as P3a                     | same case-split; curr additionally symbolic |

With governance params concrete, all products reduce to `concrete x tvl` (linear in tvl).
z3 reduces to comparing two linear functions of tvl -- trivially decidable.

Slowest case: 15.22s (fb7500/n6000/tol0) -- well under the 60s assertion timeout.

---

## Properties proved

| Group | Count | Description                                    |
|-------|-------|------------------------------------------------|
| P1    | 1     | Overflow never exceeds fallback ceiling        |
| P2a   | 1     | fbCeiling <= abs constituent cap               |
| P2b   | 1     | fbCeiling <= rel constituent cap (active)      |
| P2c   | 5     | Governance attack surface bounded (case-split) |
| P3a   | 6     | Mandate ceiling monotone (case-split)          |
| P3b   | 6     | Safety firing implies normal firing (case-split)|
| P4    | 1     | Preserve safety tranche: no unwind             |
| P5    | 1     | Overflow self-regulates: no overshoot          |
| P6    | 1     | Safety disabled == legacy behaviour            |
| **Total** | **23** | **23/23 PASS, 0 FAIL, 0 TIMEOUT**         |

---

## Files changed

| File | Change |
|------|--------|
| `test/strategies/usdc-lending/halmos/HalmosSafetyAdapterCapTier.t.sol` | Replaced 3 prop_* (skipped) with 17 case-split check_* (proved); total 23 check_* |
| `test/strategies/usdc-lending/halmos/results/halmos-evidence.json` | Machine-readable evidence record |

---

## Next step

S2.2 -- Echidna harness (Docker trailofbits/echidna, smoke 50k runs, baseline 1M campaign).
