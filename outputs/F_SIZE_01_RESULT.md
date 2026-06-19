# F-SIZE-01 RESULT -- StrategyScoringModule EIP-170 Refactor

**Task**: Reduce StrategyScoringModule below 22,000 B (was 24,426 B -- only 150 B from EIP-170 hard limit CRITICAL).
**Branch**: `feature/v10.0-storage-initialize`
**Status**: COMPLETE

---

## Gate Results

| Metric | PRE | POST |
|---|---|---|
| Tests passed | 2326 | 2336 (+10 parity tests) |
| Tests failed | 0 | 0 |
| Tests skipped | 1 | 1 |
| Gate | GREEN | GREEN |

PRE capture: `outputs/F_SIZE_01_pre_test.txt`
POST capture: `outputs/F_SIZE_01_post_test.txt`
POST sizes: `outputs/F_SIZE_01_post_sizes.txt`

---

## Size Results

| Contract | PRE (B) | POST (B) | Delta | EIP-170 Margin | Status |
|---|---|---|---|---|---|
| StrategyScoringModule | 24,426 | 21,582 | -2,844 | 2,994 | GREEN |
| StrategySafetyOverflowModule | (new) | 12,298 | -- | 12,278 | GREEN |
| StrategyAdapterOpsModule | 13,334 | 14,396 | +1,062 | 10,180 | GREEN |
| StrategySettingsModule | 22,670 | 22,954 | +284 | 1,622 | YELLOW |
| UsdcMultiLendingVault | 23,992 | 24,048 | +56 | 528 | RED (F-SIZE-02) |

`forge build --sizes` exit 1: only due to pre-existing `CoreHarness` test harness (45,153 B) -- not a deployable contract.

---

## Changes Made

### New file
- `src/strategies/usdc-lending/controller/StrategySafetyOverflowModule.sol` (NEW, 12,298 B)
  - `executeSafetyOverflow() external onlyDelegateCall` -- full body from `StrategyScoringModule._executeSafetyOverflow()`
  - `emitLowConfidenceSkips(address[],uint256) external onlyDelegateCall` -- full body from `StrategyScoringModule._emitLowConfidenceSkips()`
  - `_safeAdapterDeposit(address,uint256) private` -- private copy delegating to adapterOpsModule
  - `onlyDelegateCall` modifier guards both functions against direct calls

### Modified source files
- `src/strategies/usdc-lending/controller/StrategyScoringModule.sol` (761 -> 630 lines, -131 lines)
  - Removed bodies of `_executeSafetyOverflow`, `_emitLowConfidenceSkips`, `_syncPositionAssets`
  - Added selectors: `EXEC_SAFETY_OVERFLOW_SEL`, `EMIT_LOW_CONF_SEL`, `SYNC_POSITION_ASSETS_SEL`
  - Call sites delegatecall to `safetyOverflowModule_addr` / `adapterOpsModule` respectively
  - Guard: `if (safetyOverflowModule_addr != address(0))` for backward compat during deployment

- `src/strategies/usdc-lending/controller/StrategyAdapterOpsModule.sol` (+65 lines)
  - Added `syncPositionAssets(bool force) external onlyDelegateCall` with full body from `_syncPositionAssets`

- `src/strategies/usdc-lending/controller/StrategyStorageLayout.sol`
  - Added `address public safetyOverflowModule_addr;` (set-once via StrategySettingsModule)
  - Added `event SafetyOverflowModuleSet(address indexed module);`
  - Reduced `uint256[2] private __gap` to `uint256[1]` to maintain slot count

- `src/strategies/usdc-lending/controller/StrategySettingsModule.sol`
  - Added `setSafetyOverflowModule(address)` setter (set-once, `onlyRoleOrRevert(DEFAULT_ADMIN_ROLE)`)
  - Routed via vault fallback -- no vault bytecode growth

### Modified test files (15 files)
Added `StrategySafetyOverflowModule` deployment + `setSafetyOverflowModule` wiring to all test base classes:
- `test/strategies/usdc-lending/UsdcMultiLendingVault.t.sol`
- `test/strategies/usdc-lending/CapDriftMandate.t.sol`
- `test/strategies/usdc-lending/RemediationSprint.t.sol`
- `test/strategies/usdc-lending/DelegatecallEquivalence.t.sol`
- `test/strategies/usdc-lending/Dynamic_Seed.t.sol`
- `test/strategies/usdc-lending/Allocation_Consistency.t.sol`
- `test/strategies/usdc-lending/RebalanceEngineV10.t.sol`
- `test/strategies/usdc-lending/Scoring_Model.t.sol`
- `test/strategies/usdc-lending/StabilityEMA.t.sol`
- `test/strategies/usdc-lending/StrategyBootstrapper.t.sol`
- `test/strategies/usdc-lending/TVL_Confidence.t.sol`
- `test/strategies/usdc-lending/UsdcMultiLendingVault.fuzz.t.sol`
- `test/strategies/usdc-lending/UsdcMultiLendingVault.invariant.t.sol`
- `test/strategies/usdc-lending/replay-defense/RAPatternRegression.t.sol`
- `test/strategies/usdc-lending/fork/V92_SafetyTierE2E.t.sol`

### New test file
- `test/strategies/usdc-lending/F_SIZE_01_Parity.t.sol` (10 tests, 5 contracts)
  - P1 `F_SIZE_01_DirectCallBlocked`: `executeSafetyOverflow()` and `emitLowConfidenceSkips()` direct calls revert with `DIRECT_CALL_FORBIDDEN`
  - P2 `F_SIZE_01_SetOnce`: `setSafetyOverflowModule` rejects second call and zero address
  - P3 `F_SIZE_01_BytecodeSize`: `extcodesize(scoringMod) < 22000` and `extcodesize(overflowMod) < 24576`
  - P4 `F_SIZE_01_StorageSlot`: `safetyOverflowModule_addr` reads back, existing storage vars unaffected
  - P5 `F_SIZE_01_BehaviorPreservation`: delegatecall paths produce no DIRECT_CALL_FORBIDDEN or SafetyOverflow: reverts

---

## Side Effect Noted

`UsdcMultiLendingVault` grew 23,992 B -> 24,048 B (+56 B) because `StrategyStorageLayout` gained
`safetyOverflowModule_addr` storage slot. Still below EIP-170 hard limit (margin 528 B).
Project 1KB-safety rule (23,552 B) was already exceeded before this task.
Documented in `outputs/NEW_FINDINGS.md` under F-SIZE-02 UPDATE.
Next task: **F-SIZE-02** -- reduce UsdcMultiLendingVault.

---

## Invariants Preserved

- onlyDelegateCall guard: direct calls to StrategySafetyOverflowModule always revert (tested P1)
- Set-once setter: `safetyOverflowModule_addr` cannot be overwritten (tested P2)
- Backward compat: if module not set, scoring path skips delegatecall (no revert)
- Storage layout: gap reduced by 1 slot to exactly offset new storage var -- no slot drift
- All 2326 pre-existing tests still pass (no behavior regression)
