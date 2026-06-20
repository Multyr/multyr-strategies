# Echidna Fuzzing Results Summary

**Contract**: `EchidnaSafetyAdapterCapTier`
**File**: `test/strategies/usdc-lending/echidna/EchidnaSafetyAdapterCapTier.sol`
**Echidna version**: 2.2.5 (WSL)

---

## Runs

| Run | testLimit | workers | seqLen | Duration | Result |
|---|---:|---:|---:|---:|---|
| Smoke | 50,000 | 4 | 100 | ~22 sec | 15/15 PASS |
| Baseline | 1,000,000 | 8 | 200 | ~4 min 18 sec | 15/15 PASS |

Baseline executed **1,000,860 sequences** (slight overshoot: 8 workers stop asynchronously).
Log: `docs/audit/verification/ECHIDNA_1M_EVIDENCE.txt`

---

## Invariants tested (15)

| ID | Name | Result |
|---|---|---|
| I01 | `echidna_I01_normal_uses_normal_ceiling` | PASS |
| I02 | `echidna_I02_safety_below_fb_no_mandate` | PASS |
| I03a | `echidna_I03a_hard_ceiling_ge_fb_ceiling` | PASS |
| I03b | `echidna_I03b_overflow_within_hard_ceiling_at_deposit` | PASS |
| I03c | `echidna_I03c_above_hard_implies_above_soft` | PASS |
| I04a | `echidna_I04a_overflow_respects_ceiling_at_deposit` | PASS |
| I04b | `echidna_I04b_post_mandate_within_soft_ceiling` | PASS |
| I05 | `echidna_I05_overflow_no_overdraft` | PASS |
| I06 | `echidna_I06_accounting_conserved` | PASS |
| I07 | `echidna_I07_fbCeiling_le_abs_constituent` | PASS |
| I08 | `echidna_I08_fbCeiling_le_rel_constituent_when_active` | PASS |
| I09 | `echidna_I09_fbCeiling_le_govbound` | PASS |
| I10 | `echidna_I10_preserve_safety_tranche_no_unwind` | PASS |
| I11 | `echidna_I11_mandate_ceiling_monotone` | PASS |
| I12 | `echidna_I12_safety_disabled_equals_legacy` | PASS |

**Counterexamples found**: 0

---

## Configuration (baseline)

```yaml
testMode: property
testLimit: 1000000
seqLen: 200
shrinkLimit: 20000
corpusDir: test/strategies/usdc-lending/echidna/corpus
coverage: true
format: text
workers: 8
```

Seed: `1191146323191387670` (reproducible).

---

## Coverage

Final corpus: 23 sequences, 1755 unique instructions, 1 codehash.

Coverage plateaued at 1755 instructions after the corpus replay phase (~28s into the run).
No new coverage paths discovered in the remaining ~4 minutes of fuzzing — confirms coverage
saturation for the invariant-relevant code paths.
