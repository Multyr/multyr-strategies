*Promoted from outputs/F_SIZE_02_RESULT.md -- Wave 2 refactor log.*

# F-SIZE-02 RESULT — UsdcMultiLendingVault EIP-170 Refactor

**Task**: Reduce UsdcMultiLendingVault below 22,000 B (was 24,048 B — 496 B from EIP-170 hard limit, CRITICAL).
**Branch**: `feature/v10.0-storage-initialize`
**Status**: COMPLETE

---

## Gate Results

| Metric | PRE | POST |
|---|---|---|
| Tests passed | 2336 | 2350 |
| Tests failed | 0 | 0 |
| Tests skipped | 1 | 1 |
| Gate | GREEN | GREEN ✅ |

PRE capture: `outputs/F_SIZE_01_post_test.txt` (2336 passed, 0 failed)
POST capture: `outputs/F_SIZE_02_post_test.txt` (2350 passed, 0 failed)
PRE sizes: `outputs/F_SIZE_02_pre_sizes.txt` (24,048 B)
POST sizes: `outputs/F_SIZE_02_post_sizes.txt`

---

## Size Results

| Contract | PRE (B) | POST (B) | Delta | EIP-170 Margin | Status |
|---|---|---|---|---|---|
| UsdcMultiLendingVault | 24,048 | 21,352 | −2,696 | +2,696 vs EIP-170 | ✅ < 22,000 target |
| StrategyAdapterOpsModule | 14,396 | 16,352 | +1,956 | +8,224 vs EIP-170 | ✅ |
| StrategySafetyOverflowModule | 12,298 | 13,478 | +1,180 | +11,098 vs EIP-170 | ✅ |

Target: UsdcMultiLendingVault < 22,000 B (margin > 2,576 B vs EIP-170).

---

## Changes Made

### Modified source files

**`src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol`** (~100 lines net reduction)

1. **Selector constants** (3 new): `CHECK_EMIT_DEGRADED_SEL`, `CHECK_DEGRADED_LOCAL_SEL`, `REALIZE_LIQUIDITY_SEL`
2. **`require` → `revert InvalidModule()`**: 3 require strings eliminated (setRebalancePlanModule, setSettingsModule, setAllocationCalcModule)
3. **`_realizeLiquidity` body extracted**: full loop → delegatecall to `StrategyAdapterOpsModule.executeRealizeLiquidity(uint256)`
4. **`_checkDegradedAdapterViews` removed, `_checkAndEmitDegradedViews` replaced**: loop → delegatecall to `StrategySafetyOverflowModule.checkAndEmitDegradedViews()`
5. **`_checkDegradedModeLocally` replaced** (removed `view`, body extracted): → delegatecall to `StrategySafetyOverflowModule.checkDegradedModeLocally()`
6. **3 view diagnostic functions** (`canHarvest`, `liquidityReadinessBps`, `rebalancePenaltyBps`): each replaced with assembly delegatecall relay to `StrategyAdapterOpsModule` (removed `view` to avoid Solidity Error 8961 in assembly)

**`src/strategies/usdc-lending/controller/StrategySafetyOverflowModule.sol`**

7. Added `import { ILendingAdapter }` 
8. Added `checkAndEmitDegradedViews() external onlyDelegateCall` (extracted from vault)
9. Added `checkDegradedModeLocally() external view onlyDelegateCall` (extracted from vault)
10. Added `_checkDegradedAdapterViews() private view` (helper)

**`src/strategies/usdc-lending/controller/StrategyAdapterOpsModule.sol`**

11. Added `executeRealizeLiquidity(uint256) external onlyDelegateCall` (extracted from vault)
12. Added `liquidityReadinessBps() external view onlyDelegateCall` (new view diagnostic)
13. Added `rebalancePenaltyBps() external view onlyDelegateCall` (new view diagnostic)
14. Added `canHarvest() external view onlyDelegateCall` (new view diagnostic — returns bool, uint256, uint64)

### Modified test files

- `test/strategies/usdc-lending/UsdcMultiLendingVault.t.sol`: removed `view` from `test_canHarvest_returns_status()` and `test_liquidityReadinessBps_tenThousandWithNoAdapters()`
- `test/strategies/usdc-lending/StabilityEMA.t.sol`: removed `view` from `test_coordinationHooks_defaults()`

### Additional test fix (SCORING-INV-2 triage)

**Root cause**: `_checkDegradedModeLocally()` was extracted to `StrategySafetyOverflowModule` (F-SIZE-02).
The scoring invariant test (`UsdcMultiLendingVault_Scoring_Invariant_Test`) didn't wire `safetyOverflowModule_addr`.
Result: in POST, addr(0) delegatecall returned "" → degraded mode never activated → deposits proceeded to `deployIdleToAdapters`.
In PRE, the inline function caught `cachedLiquidityBps=0` for all adapters → "MAJORITY_INELIGIBLE" → `degradedModeActive=true` → deposits skipped.

**Fix applied**: wire `StrategySafetyOverflowModule` in the scoring invariant setUp (line 947–952 of
`test/strategies/usdc-lending/UsdcMultiLendingVault.invariant.t.sol`). This is a test-setUp completion,
not assertion weakening — the invariant assertion `pos ≤ maxExp + dust` is unchanged.

**Side discovery**: `StrategyAllocCalcModule._effectiveAbsCapBps()` ignores `adapterMaxExposureBps` when
`dynamicMax=1` (TVL < 25B). Documented in `outputs/NEW_FINDINGS.md` as F-SCORING-INV2.

### New test file

- `test/strategies/usdc-lending/F_SIZE_02_Parity.t.sol` (15 tests, 5 contracts)
  - P1 `F_SIZE_02_DirectCallBlocked`: direct calls on 3 new module functions revert with DIRECT_CALL_FORBIDDEN
  - P2 `F_SIZE_02_BytecodeSize`: vault < 22,000 B; AdapterOpsModule < 24,576 B; OverflowModule < 24,576 B
  - P3 `F_SIZE_02_DelegatecallRouting`: harvest() and realizeLiquidity() delegatecall paths do not revert with guard error
  - P4 `F_SIZE_02_StorageInvariant`: existing storage vars unaffected; adapterOpsModule has code
  - P5 `F_SIZE_02_ViewRelay`: canHarvest/liquidityReadinessBps/rebalancePenaltyBps relay correctly

---

## Solidity Error 8961 Resolution

Solidity 0.8.28 rejects `delegatecall` opcode inside inline assembly in a function declared `view`.
The 3 view diagnostic stubs (`canHarvest`, `liquidityReadinessBps`, `rebalancePenaltyBps`) had `view` removed.
Module implementations remain `external view onlyDelegateCall` (correctly read-only).
ABI note: `IUpkeepStrategy` declares `canHarvest() external view` — vault doesn't inherit that interface,
so no Solidity error. At runtime, staticcall via interface → assembly delegatecall → view-only module → no SSTORE → EVM allows.

---

## Storage Layout Invariant

No new storage variables added in vault or modules. Slot tables identical PRE/POST:
Verified via `git diff HEAD src/strategies/usdc-lending/controller/StrategyStorageLayout.sol` — no new storage variables
declared in any of the 3 modified source files. The slot ordering is unchanged.
All F-SIZE-02 changes add only code (functions, constants) in existing contracts; no `address`/`uint256`/mapping declarations.

---

## Commit

SHA: `331143e213fd93880b90628848ee459e827e2f11`
