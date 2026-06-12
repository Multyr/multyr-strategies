# S2.2 Echidna — RESULT Report

**Date:** 2026-06-12  
**Branch:** feature/p0.7-safety-adapter-tier  
**Task:** P0.7 Safety Adapter Cap Tier — Echidna stateful fuzzing (12→15 invariants)

---

## Outcome

**PASS — 0 counterexamples in smoke 50k + baseline 1M.**

All 15 invariants pass. No protocol bug found. 6 harness test bugs found and fixed (all test bugs, not protocol bugs).

---

## Captures

| Artifact | Description |
|----------|-------------|
| `outputs/S22_smoke_final.txt` | Smoke 50k — 15/15 PASS, 0 FAIL, 50227 calls, seed 1338204565347212741 |
| `outputs/S22_baseline.txt` | Baseline 1M — 15/15 PASS, 0 FAIL, 1000645 calls, seed 8867801187367277746 |
| `outputs/S22_I03_TRIAGE.md` | Full triage: 6 test bugs found and resolved across 5 smoke iterations |

---

## Files Changed

| File | Change |
|------|--------|
| `test/strategies/usdc-lending/echidna/EchidnaSafetyAdapterCapTier.sol` | Harness rewrite: 12 → 15 invariants; I03→I03a/b/c, I04→I04a/b; shadow state; safetyMandateUnwind action; safetyWithdraw guard fix; I11 relCap guard; trancheFloor reset |
| `foundry.toml` | No net change (exclude line added then removed; stale foundry corpus files deleted instead) |

---

## Invariant Summary (15 total)

| ID | Name | Type | Status |
|----|------|------|--------|
| I01 | normal_uses_normal_ceiling | structural | PASS |
| I02 | safety_below_fb_no_mandate | behavioral | PASS |
| I03a | hard_ceiling_ge_fb_ceiling | structural | PASS |
| I03b | overflow_within_hard_ceiling_at_deposit | snapshot | PASS |
| I03c | above_hard_implies_above_soft | detection | PASS |
| I04a | overflow_respects_ceiling_at_deposit | snapshot | PASS |
| I04b | post_mandate_within_soft_ceiling | transition | PASS |
| I05 | overflow_no_overdraft | accounting | PASS |
| I06 | accounting_conserved (±1000 wei) | accounting | PASS |
| I07 | fbCeiling_le_abs_constituent | structural | PASS |
| I08 | fbCeiling_le_rel_constituent_when_active | structural | PASS |
| I09 | fbCeiling_le_govbound | governance | PASS |
| I10 | preserve_safety_tranche_no_unwind (H-03) | lifecycle | PASS |
| I11 | mandate_ceiling_monotone (abs-dominant) | structural | PASS |
| I12 | safety_disabled_equals_legacy | non-regression | PASS |

**Critical invariants (S2.2 tasking):**
- I06 accounting_conserved ✓ (tolerance 1000 wei)
- I10 preserve_safety_tranche_no_unwind ✓ (H-03 invariant)
- I12 safety_disabled_equals_legacy ✓ (non-regression)

---

## Test Bugs Found and Fixed (6 total)

All are **harness logic errors** — not protocol bugs. The counterexamples exposed real behavioral nuances that the assertions were not correctly modelling.

| # | Original Invariant | Classification | Root Cause | Fix |
|---|-------------------|---------------|------------|-----|
| 1 | I03 (wrong threshold) | Test bug | `positions[0] > fbCeiling` does NOT imply mandate; positions in tolerance band `(fb, hardCeiling]` are legal. I03 confused fbCeiling with hardCeiling. | Split into I03a (structural), I03b (at-deposit snapshot), I03c (detection corollary) |
| 2 | I04 (wrong scope) | Test bug | `positions[0] <= fbCeiling` is NOT always-true; TVL decreases can transiently put existing positions above fbCeiling (pending mandate). | Split into I04a (at-deposit snapshot, captures fbCeiling at execution time mirroring StrategyScoringModule:511) and I04b (post-mandate-unwind snapshot) |
| 3 | I11 (relCap not excluded) | Test bug | `absCapBps >= normalAbsCapBps` does not guarantee `safetyHard >= normalHard` when relCap is active and constraining (relCeil < absCeil). External TVL cap overrides absCapBps ordering. | Added guard: skip assertion when fbCeiling < absCeil (rel cap binding) |
| 4 | I10 phase 1 (tolerance band unwind) | Test bug (Cowork Case 1: positions ≤ hardCeiling) | `safetyWithdraw` guard used `positions[0] <= fbCeiling` — too narrow. Real protocol has no unwind mechanism in tolerance band `(fb, hardCeiling]`. | Extended guard to `positions[0] <= hardCeiling` |
| 5 | I10 phase 2 (governance bypass) | Test bug | `updateNormalCap` temporarily raises normalCap above positions[0], disabling guard's `positions[0] > normalCap` condition. Guard was still normalCap-dependent. | Replaced guard with pure `positions[0] <= hardCeiling` check — no normalCap dependency |
| 6 | I10 phase 3 (trancheFloor not reset) | Test bug | After `safetyMandateUnwind`, positions[0] moves to new fbCeiling (lower than old trancheFloor). Harness did not reset safetyTrancheFloor post-mandate. Real protocol resets the tranche reference after mandate execution. | Both `safetyWithdraw` and `safetyMandateUnwind` now reset safetyTrancheFloor to new positions[0] after execution |

---

## Governance Semantic A (documented)

Cap reduction via governance (updateCaps reducing absCapBps, or TVL decrease reducing fbCeiling) CAN leave existing positions above new soft cap. The protocol:
1. Does NOT revert the setter
2. Does NOT immediately unwind the position
3. Next mandate check fires when positions[0] > hardCeiling

This is explicitly modelled in:
- I03c: `positions[0] > hardCeiling → positions[0] > fbCeiling` (mandate detectable on any trigger path)
- I04b: `safetyMandateUnwind` verifies post-unwind position is within soft ceiling
- Harness header: documented in GOVERNANCE SEMANTIC A comment block

---

## Harness additions (vs original 12 invariants)

**New state variables** (shadow state, per Cowork Step 1 verification):
- `_lastFbCeilingAtDeposit` — fbCeiling at overflowDeposit time (mirrors StrategyScoringModule:511)
- `_lastHardCeilingAtDeposit` — hardCeiling at overflowDeposit time
- `_lastOverflowPositionAfterDeposit` — positions[0] post-deposit
- `_lastSoftCeilingAtMandateUnwind` — fbCeiling at safetyMandateUnwind time
- `_lastPositionAfterMandateUnwind` — positions[0] post-unwind
- `_mandateUnwindOccurred` — flag for I04b

**New action**: `safetyMandateUnwind()` — full keeper unwind to fbCeiling when positions[0] > hardCeiling; updates safetyTrancheFloor; feeds I04b snapshot.

**Step 1 verification summary**: `_executeSafetyOverflow():511` recomputes fbCeiling from live tvl at each invocation (no pre-computation). Event `SafetyOverflowDeployed` emits amount/idle but not ceiling. Cap updates (governance) and deposits (keeper-triggered) are separate transactions. → Shadow state approach is legitimate and mirrors real protocol computation.

---

## Forge test gate (Rule 4)

| | Result |
|---|---|
| PRE (`outputs/S21_post_test.txt`) | 1974 pass, 0 fail |
| POST (run on S22 changes) | **1974 pass, 0 fail** |

Gate: POST_PASS (1974) >= PRE_PASS (1974) ✓  POST_FAIL (0) <= PRE_FAIL (0) ✓  POST_FAIL == 0 ✓  **GREEN**

Note: Echidna harness compiles within Foundry (standalone contract, no Forge imports). Stale auto-generated `corpus/foundry/*.sol` files from old failing runs deleted — they referenced removed invariants and caused compilation errors. Future Echidna failing-run artifacts will need the same cleanup before forge test.

---

## Next: S2.3 Fork Test

`V92_SafetyTierE2E` — 13-step fork test against Arbitrum mainnet.  
RPC: `ARBITRUM_RPC_URL` env var (never written to disk/git).
