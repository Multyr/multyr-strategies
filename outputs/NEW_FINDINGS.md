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

_Discovered: Wave 1 H-03 session | Status: **RESOLVED** in commit `c15fd397` (F-SCORING-01 task)_

---

## F-SIZE-01 — StrategyScoringModule bytecode size exceeds project 1KB-safety rule

**Discovered during**: Wave 1 item 14/15 (LENS library refactor) — `forge build --sizes`
**File**: `src/strategies/usdc-lending/controller/StrategyScoringModule.sol`
**Severity**: LOW (still below EIP-170 hard limit)

### Description

`forge build --sizes` reports `StrategyScoringModule` at **24,426 bytes**.

- EIP-170 hard limit: 24,576 B ✓ (not violated)
- Project 1KB-safety rule (CLAUDE.md rule 15): 23,552 B ✗ (426 B over)

This violation is **pre-existing** — StrategyScoringModule was not changed in the lens
refactor (only StrategyStorageLayout and StrategyExplainabilityLens were modified). The
`internal` library delegation in StorageLayout is inlined by the compiler (zero bytecode
change). The 24,426 B size was present before this WS.

### Fix needed

To bring under 23,552 B: extract non-hot logic into a deployed library or additional module.
Candidate: `_executeSafetyOverflow` (~20 lines) or the P0.7 safety tier helper functions.
Do NOT use internal library functions — those get inlined and don't reduce caller size.
Use `public`/`external` functions in a deployed library or in an existing module.

_Discovered: Wave 1 lens-refactor WS | Status: **OPEN** — out of scope for current task_

---

## F-SIZE-02 -- UsdcMultiLendingVault bytecode size exceeds project 1KB-safety rule

**Discovered during**: Pre-Wave 2 contract sizes audit (`forge build --sizes`)
**File**: `src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol`
**Severity**: LOW (still below EIP-170 hard limit 24,576 B)

### Description

`forge build --sizes` reports `UsdcMultiLendingVault` at **23,992 bytes**.

- EIP-170 hard limit: 24,576 B OK (margin 584 B)
- Project 1KB-safety rule (CLAUDE.md rule 15): 23,552 B FAIL (440 B over)

Margin to EIP-170 is only 584 B -- the second most critical size finding.
Any Wave 2 code addition touching UsdcLendingStrategy.sol risks crossing EIP-170.

### Fix needed

Extract cold-path or admin-only logic to a separate module (delegatecall pattern
already used by the vault). Candidates: bootstrapping logic, settings delegation.

_Discovered: Wave 1 closing sizes audit | Status: **OPEN** -- out of scope for current task_

---

## F-SIZE-02 UPDATE -- UsdcMultiLendingVault grew +56 B after F-SIZE-01

**Discovered during**: F-SIZE-01 (StrategyScoringModule EIP-170 refactor)
**File**: `src/strategies/usdc-lending/controller/StrategyStorageLayout.sol`
**Change**: Added `address public safetyOverflowModule_addr;` storage var + `event SafetyOverflowModuleSet` + reduced `__gap[2]` to `__gap[1]` -- net +56 B to all inheriting contracts.

UsdcMultiLendingVault grew from **23,992 B -> 24,048 B** (margin 584 -> 528 B vs EIP-170 hard limit 24,576 B).
Still below EIP-170 hard limit. Project 1KB-safety rule (23,552 B) already exceeded before this change.
F-SIZE-02 must close this separately.

_Status: **OPEN** -- tracked under F-SIZE-02_
