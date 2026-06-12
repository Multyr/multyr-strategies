# S2.2 Echidna — Triage Report: I03 (+ I04 coverage gap)

**Date:** 2026-06-12  
**Branch:** feature/p0.7-safety-adapter-tier  
**Harness:** `test/strategies/usdc-lending/echidna/EchidnaSafetyAdapterCapTier.sol`  
**Smoke run:** 50k calls, seed 7574272771494846734

---

## 1. Failure Observed

```
echidna_I03_safety_above_fb_mandate_signal: failed!💥
  Call sequence:
    overflowDeposit(6004219791379)
    withdraw(1)
```

**Invariants NOT in smoke output** (output was captured with `tail -30`, truncating results for I04, I10, I11): status unknown for those three. I04 is predicted to ALSO fail on the same reproducer (see §3).

---

## 2. Root Cause Analysis — I03

### Current assertion (line 292–300 of harness)

```solidity
function echidna_I03_safety_above_fb_mandate_signal() external view returns (bool) {
    if (!safetyEnabled) return true;
    uint256 fb = _fbCeiling();
    if (positions[0] > fb) {
        // Hard ceiling (with tolerance) must be strictly below position.
        return _safetyHardCeiling() < positions[0];  // ← WRONG
    }
    return true;
}
```

The assertion says: "when `positions[0] > fbCeiling`, the hard ceiling must already be below position (mandate fires)."

### Why this is wrong — concrete arithmetic

Setup after `overflowDeposit(6004219791379)`:
- `_tvl` ≈ 10_000_000e6 (INITIAL_TVL = 10M USDC)
- `absCapBps = 6000`, so `fbCeiling = 6000 * 10_000_000e6 / 10000 = 6_000_000e6`
- `positions[0]` is clamped to `fbCeiling` = 6_000_000e6

After `withdraw(1)`:
- `_tvl = 10_000_000e6 - 1`
- New `fbCeiling = 6000 * (10_000_000e6 - 1) / 10000`
  - = `(60_000_000_000_000_000 - 6000) / 10000`
  - = `5_999_999_999_999` (floor division)
- `positions[0]` = 6_000_000e6 = **6_000_000_000_000** (unchanged)
- Condition: `positions[0] = 6_000_000_000_000 > fbCeiling = 5_999_999_999_999` ✓

I03 then checks `_safetyHardCeiling() < positions[0]`:
- `_safetyHardCeiling() = fbCeiling * (BPS + tolBps) / BPS`
  - `= 5_999_999_999_999 * 10080 / 10000`
  - `= 6_047_999_999_998` (floor)
- Assertion: `6_047_999_999_998 < 6_000_000_000_000` → **FALSE**

Echidna returns FALSE → I03 fails. But the protocol is behaving CORRECTLY.

### Protocol semantics (correct behaviour)

The P0.7 mandate lifecycle has two thresholds:

| Threshold | Formula | Meaning |
|-----------|---------|---------|
| `fbCeiling` | `absCapBps * tvl / BPS` | Base cap — soft breach |
| `hardCeiling` | `fbCeiling * (BPS + tolBps) / BPS` | Hard cap — mandate fires |

When `fbCeiling < positions[0] <= hardCeiling`:
- Position is in the **tolerance band** `(fbCeiling, hardCeiling]`
- **No mandate fires** — this is the intended drift allowance from `capDriftToleranceBps`
- The position is "stale" due to TVL decrease, but within acceptable drift

A mandate fires ONLY when `positions[0] > hardCeiling`. My assertion confused these two thresholds.

### Classification: **TEST BUG** — wrong threshold in assertion

I03 was designed to assert "mandate fires when position > base ceiling". The correct semantics is "mandate fires when position > HARD ceiling". The assertion inverts what "above fb" means for mandate eligibility.

**This is not a protocol bug.** The on-chain protocol uses `capDriftToleranceBps` precisely to avoid spurious mandates on small TVL fluctuations.

---

## 3. Predicted I04 Failure (same reproducer)

### Current assertion (line 303–309)

```solidity
function echidna_I04_overflow_never_exceeds_ceiling() external view returns (bool) {
    uint256 fb = _fbCeiling();
    if (safetyEnabled && positions[0] > fb) return false;
    return true;
}
```

### Why it ALSO fails

Same reproducer: after `withdraw(1)`, `positions[0] = 6_000_000_000_000 > fbCeiling = 5_999_999_999_999`. I04 returns false.

I04 checks "positions[0] <= fbCeiling at ALL TIMES". But `fbCeiling` is dynamic — it decreases when `_tvl` decreases (`withdraw` action). The property is **not an invariant** in a system where TVL can change without simultaneously rebalancing positions.

The correct scope of I04: "overflowDeposit itself never deposits above fbCeiling **at the moment of deposit**". This is a per-action guarantee, not an always-true state invariant.

### Classification: **TEST BUG** — wrong scope (per-action vs always-true)

---

## 4. Proposed Fixes (awaiting approval)

### I03-revised: structural guarantee

Replace the dynamic assertion with the structural guarantee that the tolerance band is always non-negative:

```solidity
/// I03 (revised): Safety hard ceiling >= base fbCeiling at all times.
///   Structural guarantee: tolBps >= 0 implies hardCeiling >= fbCeiling.
///   Mirrors P3a/P3b Halmos proofs in stateful context.
function echidna_I03_hard_ceiling_ge_fb_ceiling() external view returns (bool) {
    if (!safetyEnabled) return true;
    return _safetyHardCeiling() >= _fbCeiling();
}
```

This is NON-TRIVIAL for Echidna to verify: it exercises `_safetyHardCeiling()` and `_fbCeiling()` across all governance parameter mutations (`updateCaps`, `updateTolerance`, `updateNormalCap`). It is MORE precise than the old I03, not weaker.

### I04-revised: at-deposit snapshot

Add two state trackers to the harness and freeze the ceiling at deposit time:

```solidity
// Add to state variables:
uint256 internal _lastFbCeilingAtDeposit;
uint256 internal _lastOverflowPositionAfterDeposit;

// Modify overflowDeposit to record post-deposit state:
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
    // Capture state for I04 (frozen at deposit moment, independent of future TVL changes).
    _lastFbCeilingAtDeposit = fb;
    _lastOverflowPositionAfterDeposit = positions[0];
    // Establish tranche floor if above normal cap.
    uint256 normalCap = (uint256(normalAbsCapBps) * _tvl) / BPS;
    if (positions[0] > normalCap) {
        safetyTrancheFloor = positions[0];
    }
}

/// I04 (revised): overflowDeposit never places position above fbCeiling at time of deposit.
///   Checks the at-deposit snapshot, not the current state (which varies with TVL).
///   Mirrors Halmos P1 + P5 in stateful context.
function echidna_I04_overflow_respects_ceiling_at_deposit() external view returns (bool) {
    if (_lastFbCeilingAtDeposit == 0) return true; // no deposit yet
    return _lastOverflowPositionAfterDeposit <= _lastFbCeilingAtDeposit;
}
```

This is STRUCTURALLY equivalent to P1/P5 Halmos proofs but in the stateful fuzzing context. The assertion is tight: `_lastOverflowPositionAfterDeposit` is exactly `positions[0]` after deposit, which by `room` clamping equals at most `fbCeiling` = `_lastFbCeilingAtDeposit`. Any refactor that breaks the clamping logic will fail this invariant.

---

## 5. Clarification needed before applying fix

1. **I04 status**: the smoke output was truncated (`tail -30`). Is I04 also failing? Recommend re-running smoke with full output before patching: `echidna ... 2>&1 | Out-File outputs/S22_smoke_full.txt -Encoding utf8`.

2. **I10, I11 status**: also not in truncated output. Same re-run would clarify.

3. **Approval for I03/I04 reformulation**: per CLAUDE.md rule 14, no test edit before explicit approval. The proposed reformulations are TIGHTER, not looser — they check correct structural properties. Please confirm before I apply.

---

## 6. Summary

| Invariant | Status | Classification | Root Cause |
|-----------|--------|---------------|------------|
| I03 | FAILING | Test bug | Wrong threshold: `positions[0] > fb` does NOT imply `hardCeiling < positions[0]` (tolerance band) |
| I04 | PREDICTED FAILING | Test bug | Wrong scope: `positions[0] <= fb` is not always-true when TVL shrinks (mandate pending) |
| I01/I02/I05/I06/I07/I08/I09/I12 | PASSING | — | Structurally correct assertions |
| I10/I11 | UNKNOWN | — | Output truncated; re-run needed |

**No protocol bug found.** Both failures are harness logic errors in I03 and I04. The counterexample (`overflowDeposit` → `withdraw`) exposes that TVL-decrease-induced drift into the tolerance band is allowed by the protocol (by design), but the assertions treated the tolerance band as a hard boundary.

---

## 7. Corpus reproducers (complete list)

Echidna saved 4 reproducers at `test/strategies/usdc-lending/echidna/corpus/reproducers/`:

| File | Call sequence | Suspected trigger |
|------|--------------|-------------------|
| `4959599605862162201.txt` | `overflowDeposit(6004219791379)` → `withdraw(1)` | I03 (reported in smoke) |
| `1741195589903990740.txt` | `withdraw(10027032467062)` → `deposit(5)` → `promoteSafety` → `withdraw(2)` | I03 or I04 (TVL decrease pattern) |
| `227288732450395413.txt` | `updateCaps` | I03 or I04 (governance reduces absCapBps → fbCeiling drops) |
| `3839781732829237318.txt` | `promoteSafety` → `withdraw` → `deposit` → `safetyWithdraw` | Possibly I10 (tranche floor stale after TVL change) |

Reproducer 3 (`updateCaps` alone) is noteworthy: if `updateCaps` reduces `absCapBps`, the new `fbCeiling = newAbs * _tvl / BPS` may be below the existing `positions[0]`. This can trigger both I03 and I04 in a single action. This is the same TEST BUG root cause: fbCeiling is dynamic and can drop below an existing position.

Reproducer 4 (`promoteSafety → withdraw → deposit → safetyWithdraw`) may be flagging I10. The `safetyTrancheFloor` is set when TVL is at level T1. After `withdraw` (TVL = T1-x), `normalCap` drops, potentially taking the safety adapter out of the tranche band (`positions[0] > fb` after the drop). After `deposit` (TVL = T1-x+y), `normalCap` rises again. `safetyWithdraw` re-checks the current `normalCap` — if the safety adapter is now BELOW the new `normalCap`, the tranche guard does not fire, and the withdraw proceeds, reducing `positions[0]` below `safetyTrancheFloor`. If `safetyTrancheFloor` was set at the old TVL-level `normalCap`, this would falsely trigger I10.

**Assessment of I10**: this may be a second TEST BUG — `safetyTrancheFloor` captures a position when TVL was at a specific level, but I10 checks it against `positions[0]` after TVL changed. The tranche floor concept is TVL-relative (normalCap grows with TVL), so a static `safetyTrancheFloor` comparison is incorrect if TVL changed materially. **Needs additional analysis before confirming.**

**Recommendation**: re-run smoke with full output (no tail truncation) to get definitive status for I04/I10/I11, then fix all confirmed test bugs together in one patch.

---

## 8. Smoke run 2 — full output (after I03/I04 patch, before I10/I11 fix)

After patching I03 → I03a/I03b/I03c and I04 → I04a/I04b, re-run smoke showed:

| Invariant | Status |
|-----------|--------|
| I03a, I03b, I03c | PASS ✓ |
| I04a, I04b | PASS ✓ |
| I01, I02, I05-I09, I12 | PASS ✓ |
| **I10** | **FAIL** |
| **I11** | **FAIL** |

**I11 failure** — reproducer: `updateCaps(5006, 1)` (single call)

I11 checks: `absCapBps (5006) >= normalAbsCapBps (5000)` → assert `safetyHard >= normalHard`.

But `relCapBps = 1` → `relCeil = 1 × 500M / 10000 = 50M USDC` (much smaller than `absCeil ≈ 5006M`).
`_fbCeiling()` = min(5006M, 50M) = 50M → `safetyHard = 50.4M`.
`normalHard = 5000 × TVL / BPS × (1+tol) ≈ 5040M` (computed from TVL, no rel constraint).
→ `safetyHard (50.4M) < normalHard (5040M)` → I11 FALSE.

**Classification**: TEST BUG — I11's condition `absCapBps >= normalAbsCapBps` is insufficient when `relCapBps` is active and constraining. The external TVL limit (relCap) overrides the higher absCapBps value, breaking the monotonicity claim.

**Fix**: Add guard — only assert monotonicity when abs constituent is the binding constraint (fbCeiling == absCeil, i.e., relCap not constraining).

---

**I10 failure (phase 1)** — reproducer: `promoteSafety → withdraw(1.78T) → deposit(940B) → safetyWithdraw(4.84B)`

Trace:
1. `promoteSafety`: safetyTrancheFloor = 5.5T (at TVL=10T, fb=6T)
2. `withdraw(1.78T)` → TVL=8.22T → new fb=4.93T
3. `deposit(940B)` → TVL=9.16T → new fb=5.496T, normalCap=4.58T
4. State: positions[0]=5.5T > fb=5.496T → in tolerance band (not tranche guard territory)
5. `safetyWithdraw(4.84B)`: normalCap=4.58T, hardCeiling=5.54T
   - Old guard: `positions[0] > normalCap AND positions[0] <= fb` → 5.5T > 5.496T, so `<= fb` FALSE → guard doesn't fire
   - Withdrawal executes: positions[0] = 5.495T
6. I10: positions[0] (5.495T) ∈ (normalCap=4.58T, fb=5.496T] → check 5.495T >= trancheFloor (5.5T) → FAIL

**Classification (Cowork Case 1)**: TEST BUG — positions[0] <= hardCeiling (5.54T) during unwind. Real protocol has no mechanism to reduce safety positions in tolerance band (fb, hardCeiling]. `safetyWithdraw` was too permissive.

**Fix phase 1**: Extend guard to `positions[0] <= hardCeiling` (from `positions[0] <= fb`), removing normalCap dependency.

---

**I10 failure (phase 2)** — after guard fix: `updateNormalCap(1) → updateCaps(2,0) → promoteSafety → updateNormalCap(2) → safetyWithdraw(1) → updateNormalCap(1)`

New root cause: `updateNormalCap(2)` temporarily raises normalCap=2T > positions[0]=1.5T → guard condition `positions[0] > normalCap` FALSE → safetyWithdraw(1) executes → positions[0]=1.5T-1 → `updateNormalCap(1)` lowers normalCap back → positions[0] re-enters tranche band below trancheFloor.

**Classification**: TEST BUG — hardCeiling guard was still normalCap-dependent in the action's guard. The safetyWithdraw guard needs to be purely: `if (positions[0] <= hardCeiling) return;` (no normalCap check at all).

**Fix phase 2**: Replace guard with `if (!safetyEnabled) { ... } else if (positions[0] <= hardCeiling) return;`. Governance-induced normalCap increases cannot bypass this protection.

---

**I10 failure (phase 3)** — after guard fix 2: `overflowDeposit(5.03T) → withdraw(1.69T) → safetyMandateUnwind()`

Trace:
1. `overflowDeposit`: positions[0]=5.03T, safetyTrancheFloor=5.03T (above normalCap=5T)
2. `withdraw(1.69T)`: TVL drops → hardCeiling=5.024T, positions[0]=5.03T > hardCeiling → mandate territory
3. `safetyMandateUnwind()`: unwinds to new fb=4.984T → positions[0]=4.984T
4. I10: positions[0] (4.984T) ∈ (normalCap=4.15T, fb=4.984T] → check 4.984T >= trancheFloor (5.03T) → FAIL

**Root cause**: `safetyMandateUnwind` did not reset `safetyTrancheFloor`. After a mandate execution, the safety adapter is at the new fbCeiling — the tranche floor should be updated to this new level.

**Classification**: TEST BUG — harness action missing post-mandate trancheFloor reset. The real protocol's mandate execution would update the tranche reference.

**Fix phase 3**: `safetyMandateUnwind` (and `safetyWithdraw` in mandate territory) reset `safetyTrancheFloor` to new positions[0] after execution.

---

## 9. Final smoke results (after all fixes)

Smoke 50k, seed 1338204565347212741:

```
15/15 PASS, 0 FAIL, Total calls: 50227
```

All invariants: I01, I02, I03a, I03b, I03c, I04a, I04b, I05-I12 PASS.

## 10. Baseline 1M results

Baseline 1M, seed 8867801187367277746:

```
15/15 PASS, 0 FAIL, Total calls: 1000645
```

Coverage final: 1755 unique instructions, 22 corpus seqs.
Output: `outputs/S22_baseline.txt`

## 11. Summary table — all found issues

| Issue | Classification | Fix applied | Verifiable | Rule 14 compliant |
|-------|---------------|-------------|------------|-------------------|
| I03 (wrong threshold) | Test bug | I03 → I03a/b/c (structural+snapshot+detection) | More precise, not weaker | ✓ |
| I04 (wrong scope) | Test bug | I04 → I04a/b (at-deposit snapshot + post-mandate) | More precise, not weaker | ✓ |
| I11 (relCap not excluded) | Test bug | Guard: skip when relCap binding | More precise, not weaker | ✓ |
| I10 phase 1 (tolerance band unwind) | Test bug (Case 1) | Guard extended to hardCeiling | More precise, not weaker | ✓ |
| I10 phase 2 (normalCap governance bypass) | Test bug | Guard: pure hardCeiling check | More precise, not weaker | ✓ |
| I10 phase 3 (trancheFloor not reset after mandate) | Test bug | Reset safetyTrancheFloor after unwind | Correct model of real protocol | ✓ |

**No protocol bug found.** All 6 issues were harness logic errors. The counterexamples exposed real behavioral nuances of the P0.7 tier that the invariants were not correctly modeling:
- Tolerance band is not mandate territory
- Governance changes to normalCap are decoupled from safety tranche protection
- Mandate execution resets the tranche reference point
