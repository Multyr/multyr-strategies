# HALMOS_V10_DIFF.md — V10 storage+initialize symbolic verification diff

Generated: 2026-06-15
Run: halmos --contract HalmosSafetyAdapterCapTier --loop 8 --solver-timeout-assertion 60000
Evidence: 	est/strategies/usdc-lending/halmos/results/halmos-evidence.json

## Commit 2 setUp analysis — MOOT

The Cowork Phase 3 prompt anticipated a setUp() refactor for HalmosSafetyAdapterCapTier.t.sol
to pin adapter storage slots via m.store(). After reading the file:

- All 23 check_* functions are public pure — pure arithmetic, no state reads.
- The contract has NO setUp() function.
- No adapter contracts are instantiated, referenced, or called.
- The tests mirror production code with pure arithmetic functions (_fbCeiling, _mandateAbsHard).

**Conclusion:** V10 storage change (immutable → storage) has ZERO impact on these tests.
V10StoragePins helper (P3-01) is infrastructure for future adapter-touching Halmos tests only.
No setUp refactor needed. Commit 2 skipped as moot.

## V10 baseline run results — 23/23 PASS

| Property | V9.x time (s) | V10 time (s) | Delta | Status |
|---|---:|---:|---:|---|
| P1 check_overflow_never_exceeds_fallback_ceiling | 0.49 | 0.49 | 0% | PASS |
| P2a check_fbCeiling_le_abs_ceiling | 0.14 | 0.15 | +7% | PASS |
| P2b check_fbCeiling_le_rel_ceiling_when_active | 0.05 | 0.06 | +20% | PASS |
| P2c check_P2c_govbound_abs4000 | 1.27 | 1.33 | +5% | PASS |
| P2c check_P2c_govbound_abs5000 | 2.46 | 2.37 | -4% | PASS |
| P2c check_P2c_govbound_abs6000 | 4.15 | 4.13 | 0% | PASS |
| P2c check_P2c_govbound_abs7500 | 8.83 | 8.86 | 0% | PASS |
| P2c check_P2c_govbound_abs8000 | 0.05 | 0.06 | +20% | PASS |
| P3a check_P3a_mandate_monotone_fb4000_n4000_tol0 | 0.03 | 0.03 | 0% | PASS |
| P3a check_P3a_mandate_monotone_fb6000_n4000_tol500 | 12.54 | 12.80 | +2% | PASS |
| P3a check_P3a_mandate_monotone_fb7500_n6000_tol0 | 15.82 | 15.56 | -2% | PASS |
| P3a check_P3a_mandate_monotone_fb8000_n4000_tol0 | 7.64 | 7.72 | +1% | PASS |
| P3a check_P3a_mandate_monotone_fb8000_n4000_tol1000 | 7.78 | 7.56 | -3% | PASS |
| P3a check_P3a_mandate_monotone_fb8000_n8000_tol500 | 0.03 | 0.04 | +33% | PASS |
| P3b check_P3b_..._fb4000_n4000_tol0 | 0.04 | 0.03 | -25% | PASS |
| P3b check_P3b_..._fb6000_n4000_tol500 | 9.08 | 9.19 | +1% | PASS |
| P3b check_P3b_..._fb7500_n6000_tol0 | 14.98 | 15.74 | +5% | PASS |
| P3b check_P3b_..._fb8000_n4000_tol0 | 8.65 | 8.87 | +3% | PASS |
| P3b check_P3b_..._fb8000_n4000_tol1000 | 7.92 | 7.91 | 0% | PASS |
| P3b check_P3b_..._fb8000_n8000_tol500 | 0.03 | 0.03 | 0% | PASS |
| P4 check_preserve_safety_tranche_no_unwind | 0.15 | 0.16 | +7% | PASS |
| P5 check_overflow_self_regulates_no_overshoot | 0.33 | 0.33 | 0% | PASS |
| P6 check_safety_disabled_equals_legacy | 0.03 | 0.04 | +33% | PASS |
| **TOTAL** | **102.55** | **103.44** | **+0.9%** | **23/23 PASS** |

All deltas within ±33% noise range for sub-second proofs, ±5% for multi-second proofs.
No divergent proofs. No timeouts. Commit 4 (fixes) skipped — not needed.

## Compile note

Halmos 0.2.0 runs orge build --ast internally. The project requires ia_ir = true
(QueueModule.sol stack depth). First run recompiles 186 files (~815s). Subsequent runs
use the warm AST artifact cache ("No files changed"). A [profile.halmos] section was
added to foundry.toml with out = "out" to share the default profile artifact cache
and avoid redundant recompilation.