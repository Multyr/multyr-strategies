# AC_TRIAGE_1 — testFuzz_ALLOCDUST_conservation_N_sequential_cycles idle==0 assertion

## Failing test + exact assertion

File: `test/strategies/usdc-lending/Allocation_Consistency.t.sol:634`  
Contract: `AllocCalcToleranceFix_Test`  
Function: `testFuzz_ALLOCDUST_conservation_N_sequential_cycles(uint8 n)`

```
[FAIL: AC-03: residual must be fully redistributed in each cycle: 262500000001 != 0]
counterexample: args=[255] → bound(255, 1, 5) == 5
```

Failing assertion (line 634):
```solidity
assertEq(vault.idleCash(), 0,
    "AC-03: residual must be fully redistributed in each cycle");
```

## Expected vs actual

Expected: `vault.idleCash() == 0` after deployIdle in every cycle.  
Actual: `vault.idleCash() == 262_500_000_001` (≈ 262,500 USDC) at iteration i=1.

Note: the conservation assertion on line 632 (`pos + idle == totalDeposited`) PASSES. No
value is created or destroyed. The idle is real, not phantom.

## Root-cause analysis

### Why is 262_500_000_001 NOT a floor-division residual?

`dustTolerance = 10_000` (0.01 USDC). The failing idle ≈ 262,500 USDC is 26 million times
larger. The residual redistribution fix handles ≤ dustTolerance — it never claims to
eliminate strategic idle caused by adapter capacity limits.

### T4 cap mechanics — the actual cause

After iteration i=0:
- `amt0 = 500_000e6 + 2` (500K USDC). TVL = 500K → T3 (dMax=3).
- `cap = ceil(11000/3) = 3667 bps`. Per-adapter max = 36.7% × 500K = 183.3K USDC.
- All 3 adapters funded ~166.7K each (below cap). ✓

At i=1 deploy time:
- `amt1 = 1_000_000e6 + 2` (1M USDC). Total TVL = positions(500K) + idle(1M) = 1.5M USDC → T4 (dMax=4).
- `cap = ceil(11000/4) = 2750 bps`. Per-adapter max = 27.5% × 1.5M = 412,500 USDC.
- Current position per adapter ≈ 166,667 USDC. Headroom per adapter = 412,500 - 166,667 ≈ 245,833 USDC.
- Target per adapter (equal scores, 1M idle / 3) ≈ 333,333 USDC > headroom 245,833 → ALL 3 CLAMPED.
- Deployed = 3 × 245,833 = 737,499 USDC. Remaining = 1,000,000 - 737,499 ≈ 262,501 USDC.
- Pass 1: all clamped → `sSum == 0 → break`. remaining = 262,500 >> dustTolerance = 0.01 USDC.
- Fix condition `remaining <= _dust` is FALSE → fix does not apply (correct behavior).
- Result: 262,500 USDC stays idle.

This is correct cap-mechanics behavior, not a bug in `_computeTargets` or the fix.

## Why this is a TEST BUG, not a code bug

1. **The code does exactly what it should.** `_computeTargets` correctly clamps targets to
   adapter headroom. The T4 cap formula (27.5% per adapter) limits the 3-adapter system to
   3 × 27.5% = 82.5% deployable TVL, leaving ~17.5% as strategic idle. This is by design
   (tier-model safety).

2. **The assertion conflates two unrelated behaviors.** The fix under test (residual
   redistribution) eliminates sub-dust rounding artifacts (≤ 10000 wei). It makes no claim
   about strategic idle caused by capacity caps. `assertEq(idle, 0)` is wrong for any
   scenario where adapters are at or near their per-epoch headroom limit.

3. **The fuzz range [1, 5] spans multiple TVL tiers.** At n=2 (cumulative TVL enters T4),
   the cap dynamics inevitably leave ≈17.5% undeployed. The test assertion cannot hold
   across all n.

4. **Conservation holds perfectly.** The `pos + idle == totalDeposited` assertion passes in
   all iterations. No funds are lost. The accounting is correct.

## Proposed change (makes assertion MORE precise, not less)

The fuzz test T-AC-03 tests the **conservation invariant** — a meaningful regression: no
funds created or destroyed across N deploy cycles. This is a valid invariant.

The `assertEq(idle, 0)` claim is out of scope for the fuzz test. It is already covered,
more precisely and in a controlled setting, by:

- **T-AC-01** (`test_ALLOCDUST_rounding_residual_not_left_idle`): same TVL regime (T3, 3
  equal adapters, guaranteed headroom), exact amount (500_000e6 + 2 with residual = 1 wei).
  This IS the right place for `idle == 0`.

Proposed change to `testFuzz_ALLOCDUST_conservation_N_sequential_cycles`:

```solidity
// REMOVE line 634:
assertEq(vault.idleCash(), 0,
    "AC-03: residual must be fully redistributed in each cycle");
```

This removes an assertion that is **incorrect for its stated purpose** (the fix does not
guarantee idle==0 under capacity constraints). It does NOT weaken coverage of the fix,
because T-AC-01 specifically and deterministically tests the residual redistribution in
the exact scenario where the fix applies.

Alternative (equally precise):

```solidity
// Replace with: any remaining idle must not exceed per-adapter cap slack
// (cannot be due to the residual redistribution fix if idle >> dustTolerance)
assertLe(vault.idleCash(), 3 * (type(uint256).max), "conservation only");
```

This is trivially true — not useful. The correct approach is the REMOVE above, keeping
only the conservation assertion.

## Classification

**TEST BUG** — the `assertEq(idle, 0)` assertion is wrong for a fuzz over TVL tiers [T3, T4, T5].  
**Code fix required**: None.  
**Test fix requires approval per Rule 14.**

## Evidence files

- POST gate: `outputs/AC_post_test.txt`
- Counterexample: n=255 → bound → 5 → failure at iteration i=1 (T4 regime).
