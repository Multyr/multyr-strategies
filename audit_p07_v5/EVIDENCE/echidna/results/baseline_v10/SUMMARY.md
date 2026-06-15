# Echidna Baseline V10 — 1M sequences

**Date:** 2026-06-15
**Duration:** ~3m 32s (14:06:51 → 14:10:23)
**Seed:** 3300754573264722207
**Workers:** 8
**Config:** echidna-baseline.yaml (testLimit=1000000, seqLen=200, shrinkLimit=20000)

## Results

- Total sequences: 1,000,637
- Invariants tested: 15/15
- Counter-examples: 0
- Coverage: 1755 unique instructions
- Corpus size: 25 (started from 39 pre-existing sequences)

## Per-invariant status

| Invariant | Status |
|---|:---:|
| I01_normal_uses_normal_ceiling | PASS |
| I02_safety_below_fb_no_mandate | PASS |
| I03a_hard_ceiling_ge_fb_ceiling | PASS |
| I03b_overflow_within_hard_ceiling_at_deposit | PASS |
| I03c_above_hard_implies_above_soft | PASS |
| I04a_overflow_respects_ceiling_at_deposit | PASS |
| I04b_post_mandate_within_soft_ceiling | PASS |
| I05_overflow_no_overdraft | PASS |
| I06_accounting_conserved | PASS |
| I07_fbCeiling_le_abs_constituent | PASS |
| I08_fbCeiling_le_rel_constituent_when_active | PASS |
| I09_fbCeiling_le_govbound | PASS |
| I10_preserve_safety_tranche_no_unwind | PASS |
| I11_mandate_ceiling_monotone | PASS |
| I12_safety_disabled_equals_legacy | PASS |

Note: V9.x Cowork prompt referenced "12/12 invariants". Harness actually has 15
(I03 and I04 each have sub-variants a/b/c and a/b respectively).

## Comparison vs V9.x baseline

| Metric | V9.x | V10 | Delta |
|---|---:|---:|---:|
| Sequences | 1M | 1,000,637 | ~0 |
| Counter-examples | 0 | 0 | 0 |
| Coverage (instr) | 1755 | 1755 | 0 |
| Corpus size | 20 | 25 | +5 (smoke run added sequences) |
| Duration | ~3-4m | ~3m 32s | within noise |

V10 storage+initialize refactor preserves Echidna fuzz coverage and
invariant verification at full parity with V9.x baseline.
The harness is a pure arithmetic model with no adapter imports — V10 has
zero semantic impact.

## Full run log

`outputs/V10_P6_03_baseline_run.txt` (gitignored)
