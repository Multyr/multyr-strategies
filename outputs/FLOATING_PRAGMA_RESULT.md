# FLOATING_PRAGMA_RESULT — Wave 2 housekeeping: pragma determinism

**Task**: Pin all floating `pragma solidity ^x.y.z;` to exact version `0.8.28` in
`src/strategies/usdc-lending/` and `test/strategies/usdc-lending/`.

**Date**: 2026-06-20

---

## Gate evidence

| | Value |
|---|---|
| PRE pass | 2354 |
| PRE fail | 0 |
| POST pass | 2354 |
| POST fail | 0 |
| Skipped | 1 (unchanged) |
| Gate | GREEN |

PRE: from prior session (F-SCORING-INV2 + Halmos P6 + echidna yaml baseline),
captured in `bxgnn2xgk.output` (2354/0/1).
POST: `outputs/FLOATING_PRAGMA_post_test.txt` — 2354 passed, 0 failed, 1 skipped.

---

## Changes

**Files changed**: 76 `.sol` files (14 src + 62 test)

**Versions pinned**:
- `^0.8.28` → `0.8.28`: adapters, lens, bootstrapper, swap, test suite
- `^0.8.24` → `0.8.28`: rate providers, ILendingAdapter interface
  (project compiler is solc 0.8.28; all files compile cleanly under it)

**Excluded from sed**: `test/strategies/usdc-lending/echidna/corpus/` (HTML/TXT
coverage artifacts, not Solidity — corpus already references source pragma, no change needed).

**Also included in commit**: `outputs/F_SIZE_02_RESULT.md` SHA TBD → actual SHA.

---

## Echidna baseline 1M (PHASE 2 — launched same session)

- PID: 351 (WSL), launched 2026-06-20 19:54:18 CEST
- Completed: 2026-06-20 19:58:36 CEST (~4 min)
- testLimit: 1,000,000 sequences | workers: 8 | seqLen: 200
- Corpus final: 23 sequences, 1755 unique instructions
- Log: `outputs/ECHIDNA_BASELINE_RUN.txt`
- Result: **ALL 15 invariants PASSING** (I01–I12, no counterexample)

---

## Build verify

`forge build` exit 0 after pragma pin. Lint warnings only (`unsafe-typecast`),
pre-existing, no new errors introduced.

---

## Floating pragma count verification

```
grep -rn "pragma solidity \^" src/strategies/usdc-lending/ test/strategies/usdc-lending/ \
  --include="*.sol" | grep -v "/corpus/"
# Result: 0 matches
```
