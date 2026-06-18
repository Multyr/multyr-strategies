# AC_RESULT — StrategyAllocCalcModule _computeTargets residual redistribution

## Status: RESOLVED ✅

## Bug (Wave 1 item 12/15)
`_computeTargets` 3-pass loop exits when `remaining ≤ _dust`, leaving up to `selCount-1`
wei per pass undeployed due to floor division. Over repeated `deployIdle` calls this creates
systematic idle drift. The idle amount is bounded by `_dust × passes` but is never assigned.

## Fix — `src/strategies/usdc-lending/controller/StrategyAllocCalcModule.sol` (lines 447-461)

After the 3-pass loop, added residual redistribution block:

```solidity
if (remaining > 0 && remaining <= _dust) {
    for (uint256 j = 0; j < selCount; ++j) {
        if (clamped[j]) continue;
        uint256 rem = headrooms[j] > targets[j] ? headrooms[j] - targets[j] : 0;
        if (rem >= remaining) {
            targets[j] += remaining;
            break;
        }
    }
}
```

Selected arrays are ordered highest-score-first, so the residual naturally goes to the
best eligible adapter. The check `rem >= remaining` ensures headroom is respected.

## Tests — `AllocCalcToleranceFix_Test` in `test/strategies/usdc-lending/Allocation_Consistency.t.sol`

| Test | What it verifies |
|---|---|
| `test_ALLOCDUST_rounding_residual_not_left_idle` (T-AC-01) | T3 regime, 3 equal-APY adapters, amount ≡ 1 (mod 3) → residual = 1 wei → idle == 0 after fix |
| `test_ALLOCDUST_conservation_unequal_scores` (T-AC-02) | Unequal scores, non-round amount → sum(pos) + idle == deposited |
| `testFuzz_ALLOCDUST_conservation_N_sequential_cycles` (T-AC-03) | Fuzz n∈[1,5] sequential cycles → conservation holds throughout |
| `test_ALLOCDUST_cap_boundary_no_overdeposit` (T-AC-04) | Adapter pinned at exact capacity → headroom=0 → fix correctly skips it |

## Rule 14 Triage (AC_TRIAGE_1.md)

`testFuzz_ALLOCDUST_conservation_N_sequential_cycles` initially failed with `idle = 262_500_000_001`.
Classification: **TEST BUG** — `assertEq(idle, 0)` assertion incorrectly assumed full deployment
in T4 regime where cap mechanics (dMax=4 → 2750 bps/adapter × 3 = 82.5% deployable) leave
~17.5% as structural idle. The `assertEq(idle, 0)` was removed per Rule 14 approval (2026-06-18).
Conservation assertion retained. T-AC-01 specifically covers the residual redistribution fix.

## Gate

| | Passed | Failed | Skipped |
|---|---|---|---|
| PRE  | 2279 | 0 | 1 |
| POST | 2300 | 0 | 1 |

PRE capture: `outputs/FS01_post_test.txt` (prior session)
POST capture: `outputs/AC_post_test.txt`

Gate: ✅ POST_PASS (2300) ≥ PRE_PASS (2279), POST_FAIL (0) == 0

## Files changed

- `src/strategies/usdc-lending/controller/StrategyAllocCalcModule.sol` — residual redistribution in `_computeTargets`
- `test/strategies/usdc-lending/Allocation_Consistency.t.sol` — `AllocCalcToleranceFix_Test` (4 tests, T-AC-01 to T-AC-04; Rule 14 fix in T-AC-03)
- `outputs/AC_TRIAGE_1.md` — Rule 14 triage report
- `outputs/AC_RESULT.md` — this file
