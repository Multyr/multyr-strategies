# NEW_FINDINGS — Wave 1 out-of-scope issues

## F-SCORING-01 — StrategyScoringModule.deployIdle: positionAssets += planned, not actual

**Discovered during**: H-03 task (StrategyRebalancePlanModule deposit fix)
**File**: `src/strategies/usdc-lending/controller/StrategyScoringModule.sol:449-453`
**Severity**: HIGH (same class as H-03)

### Description

`deployIdle()` / `deployIdleToAdapters()` has the identical accounting bug as H-03:

```solidity
// StrategyScoringModule.sol line 449-450
bool deposited = _safeAdapterDeposit(a, targets[j]);
if (deposited) positionAssets[a] += targets[j];  // BUG: uses planned, not actual
```

If an adapter accepts less than `targets[j]` (partial fill), `positionAssets[a]` is overstated by the difference. This path is triggered:
1. Directly by `deployIdle()` (called by keeper)
2. Indirectly by `_finalizePlan()` in `StrategyRebalancePlanModule` (auto-redeploy after rebalance)

The fix pattern is identical to H-03: capture `balanceBefore = ASSET.balanceOf(address(this))` before the deposit, compute `actualDeposited = balanceBefore - balanceAfter`, use `actualDeposited` in the positionAssets increment.

### Impact

`positionAssets` overstated → scoring drift → suboptimal future allocations. Same risk profile as H-03.

### Fix needed

In `StrategyScoringModule._deployIdleToAdaptersInternal()` lines ~445-454:
- Replace `positionAssets[a] += targets[j]` with balance-delta pattern (same as H-03 fix)
- Also fix line 453 for the strict (non-bestEffort) path

---

_Discovered: Wave 1 H-03 session | Status: pending separate task_
