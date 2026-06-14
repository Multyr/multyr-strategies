# Echidna Corpus Type — P0.7 Safety Adapter Cap Tier

**Date:** 2026-06-13
**Branch:** feature/p0.7-safety-adapter-tier
**Campaign:** S2.2 — 15/15 properties PASS, 50k smoke + 1M baseline

---

## Corpus Contents

The corpus in `test/strategies/usdc-lending/echidna/corpus/` contains:

| Directory | Type | Description |
|-----------|------|-------------|
| `coverage/` | Raw coverage corpus | All sequences that increase coverage. Used by Echidna to seed future runs. Not human-readable (encoded call sequences). |
| `reproducers/` | **Shrunk reproducers** | Minimized counterexample seeds. These are the FINAL shrunk outputs — each sequence is the shortest trace that triggers the property violation (or proves invariant boundary). |
| `reproducers-unshrunk/` | Pre-shrink counterexamples | The raw counterexamples found before Echidna's shrinking pass. Retained for reference but superseded by `reproducers/`. |

**Corpus type packaged in audit: `reproducers/` (shrunk)**

The S2.2 baseline 1M-sequence campaign found no property violations (all 15 properties PASS). The `reproducers/` directory contains traces from the smoke phase (50k sequences) before properties were hardened. These are shrunk — each file is a minimized call sequence.

---

## Why reproducers/ (shrunk)?

Per Echidna documentation and audit best practice:

- Shrunk reproducers are the artifact auditors care about: they represent the minimal failing trace for each property. In a PASS campaign (no violations), they represent edge-case seeds the fuzzer explored near boundaries.
- Pre-shrink counterexamples (`reproducers-unshrunk/`) are verbose and contain redundant calls. They are retained for completeness but are not the canonical reproducible evidence.

---

## Campaign Summary (S2.2)

| Property | Passes | Violations |
|----------|--------|-----------|
| I01 — tvl_accounting_conserved | 1,000,000 | 0 |
| I02 — safety_adapter_cap_never_exceeded | 1,000,000 | 0 |
| I03 — idle_above_maxIdle_triggers_deploy | 1,000,000 | 0 |
| I04 — mandate_cooldown_respected | 1,000,000 | 0 |
| I05 — fallback_ceiling_monotone_in_tvl | 1,000,000 | 0 |
| I06 — accounting_conserved | 1,000,000 | 0 |
| I07 — no_overflow_when_safety_list_empty | 1,000,000 | 0 |
| I08 — safety_adapter_priority_order | 1,000,000 | 0 |
| I09 — rel_cap_binding_vs_abs_cap | 1,000,000 | 0 |
| I10 — quarantine_blocks_deposit | 1,000,000 | 0 |
| I11 — removeFromSafetyList_disables_overflow | 1,000,000 | 0 |
| I12 — cap_drift_tolerance_respected | 1,000,000 | 0 |
| I13 — mandate_cooldown_survives_params_update | 1,000,000 | 0 |
| I14 — total_safety_allocation_bounded | 1,000,000 | 0 |
| I15 — no_deposit_after_full_quarantine | 1,000,000 | 0 |

**Result: 15/15 PASS. Zero counterexamples. Corpus is empty of violations.**

---

## Evidence References

- S2.2 campaign output: `outputs/S22_RESULT.md`, `outputs/S22_baseline.txt`
- Halmos formal proofs (23/23): `EVIDENCE/halmos/S21_RESULT.md`
