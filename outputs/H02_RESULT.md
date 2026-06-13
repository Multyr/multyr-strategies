# H-02 RESULT — Defensive Guard Coverage Tests

**Task:** Add 3 defensive guard tests to `P07NegativePathsScoring.t.sol`
**Date:** 2026-06-13
**Branch:** feature/p0.7-safety-adapter-tier
**Status:** COMPLETE

---

## Changes Made

### `test/strategies/usdc-lending/P07NegativePathsScoring.t.sol`

Added 3 new tests (H-02) alongside the 3 existing E.8 tests:

| Test | Guard | Line (impl) | Assertion |
|------|-------|-------------|-----------|
| `test_safetyOverflow_skips_extTVL_below_500k_minimum` | L506 extTVL < 500k | impl:L506 | Event-based: `SafetyOverflowDeployed` NOT emitted for adapterA (extTVL=400k); IS emitted for adapterB |
| `test_safetyOverflow_handles_deposit_revert` | L525 !ok deposit | impl:L525 | positionAssets[A] unchanged (accounting conserved); adapterB receives fallthrough deposit |
| `test_safetyOverflow_skips_flagged_adapter` | L499 flagged[a] | impl:L499 | adapterA (flagged) skipped; adapterB receives overflow; event emitted for B only |

Added helpers:
- `_assertOverflowEmittedFor(Vm.Log[], address expected)` — verifies `SafetyOverflowDeployed` emitted with `topics[1] == expected` (adapter IS indexed)
- `_assertNoOverflowEmitted(Vm.Log[])` — verifies no `SafetyOverflowDeployed` in log array

### Design note for test_safetyOverflow_skips_extTVL_below_500k_minimum

Uses event-only assertion (not positionAssets delta) because the normal scoring path also runs
within the same `deployIdle()` call and may allocate to adapterA as a regular enabled adapter.
`SafetyOverflowDeployed` is the canonical record of the OVERFLOW path specifically — checking it
isolates overflow guard behavior without conflating the normal scoring path.

---

## Test Gate

**PRE** (`outputs/E8_post_test.txt`): **2001 pass, 0 fail**
**POST** (`outputs/H02_post_test.txt`): **2004 pass, 0 fail**

Gate: POST_PASS (2004) >= PRE_PASS (2001) ✓ AND POST_FAIL (0) == 0 ✓

Net new tests: +3 (H-02 deliverable: all 3 defensive guard tests passing)

---

## Guard Coverage After H-02

| Guard | L | Type | Risk | Direct Test |
|-------|---|------|------|-------------|
| `nSafety == 0` | 483 | Early return | LOW | ✓ E.8 |
| `tvl < 1` | 486 | Arithmetic | LOW | — arch. invariant |
| `idle ≤ maxIdle` | 489 | Primary exit | LOW | — implicit |
| `!enabled[a]` | 498 | Belt-and-braces | LOW | — governance precondition |
| `flagged[a]` | 499 | Operational | LOW | **✓ H-02** |
| `quarantined[a]` | 500 | Circuit breaker | MEDIUM | ✓ E.8 |
| `extTVL < 500k` | 506 | Pool depth | MEDIUM | **✓ H-02** (event-isolated) |
| `absCapBps == 0` | 510 | Belt-and-braces | LOW | — governance revert test |
| `relCeiling binds` | 514 | Rel-cap binding | HIGH | ✓ E.8 AllocCalc |
| `current ≥ fbCeil` | 518 | At-ceiling | MEDIUM | — V92 E2E S05→S06 |
| `toDeposit < dust` | 521 | Dust | LOW | — TVL-scale invariant |
| `!ok` (deposit fail) | 525 | Failure recovery | HIGH | **✓ H-02** |

12 guards total; 6 directly tested (E.8: 3, H-02: 3); 6 covered by architectural invariants/E2E.
