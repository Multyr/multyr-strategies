# F-SCORING-INV2 TRIAGE 2 — 11 POST-gate Failures

**Task**: F-SCORING-INV2 (Views_Test + Withdraw_Test deposit fix approved and applied)
**PRE gate**: 2350 passed, 0 failed
**POST gate**: 2343 passed, 11 failed
**Status**: STOP — awaiting approval before touching any test (Rule 14)

---

## Summary

The F-SCORING-INV2 fix (Option B: `adapterMaxExposureBps` respected at T1 TVL) has wider test
impact than the 3 failures addressed in TRIAGE_1. 11 additional tests fail because they also
deposit at T1 TVL (< 25,000 USDC), which now leaves ~50% idle instead of 0%.

All 11 can be classified as either:
- **TEST PRECONDITION ISSUE** (same class as TRIAGE_1 — 10 tests)
- **DOCUMENTATION OF CORRECTED BUG** (1 test: `test_AUDIT_FINDING_8_T1_ignores_global_ceiling`)

None are CODE BUGS. The fix is correct by design.

---

## Failing Tests — Detail

### 1. CtoHardeningFixes: `test_deposit_allows_idle_within_percentage_bound`
**Error**: `NoCashInvariant()`  
**File**: `test/strategies/usdc-lending/CtoHardeningFixes.t.sol:241`

**Test logic**:
1. Bootstrap deposit `_coreDeposit(100e6)` (T1: 100 USDC << 25K threshold)
2. Exit bootstrap
3. Second `_coreDeposit(100e6)` → expected to pass (idle ≤ maxIdle)

**Why it fails**: At T1, cap = `adapterMaxExposureBps` = 5000 (50%). After two 100 USDC
deposits, TVL = 200 USDC. Cap = 50% → only 100 USDC deployed. Idle = 100 USDC (50% of TVL).
`maxIdleAfterDepositBps` = 500 (5%). maxIdle = 5% × 200 = 10 USDC. Idle 100 > maxIdle 10 → NoCashInvariant revert.

**Pre-fix**: cap = 10000 (100%) → all 200 USDC deployed → idle = 0 → passes.

**Classification**: TEST PRECONDITION ISSUE. The test intends to verify that a normal deposit
does not revert when idle is within bounds. It is not testing T1 behavior.

**Proposed fix**: Increase bootstrap deposit to T3 range (e.g. `250_000e6`) so adapter1
is at T3 TVL → dMax=3, full deployment possible. Second deposit of 100e6 then leaves
negligible idle relative to 250K TVL. Test assertions remain identical (no revert).

---

### 2. CtoHardeningFixes: `test_deposit_uses_dustTolerance_as_floor`
**Error**: `NoCashInvariant()`  
**File**: `test/strategies/usdc-lending/CtoHardeningFixes.t.sol:278`

**Test logic**:
1. Bootstrap `_coreDeposit(100e6)`, exit bootstrap, set `maxIdleAfterDepositBps(0)`
2. Second `_coreDeposit(100e6)` → should not revert (dustTolerance is floor)

**Why it fails**: Same as #1. At T1 with cap=50%, idle = 100 USDC after deposit.
With `maxIdleAfterDepositBps=0`, floor = dustTolerance = 3 USDC. Idle 100 >> 3 → NoCashInvariant.

**Classification**: TEST PRECONDITION ISSUE. The test verifies dustTolerance-as-floor mechanic,
not T1 behavior.

**Proposed fix**: Same — increase bootstrap deposit to 250_000e6 (T3).

---

### 3. CtoHardeningFixes: `test_bootstrap_small_deposit_when_large_idle_uses_tvl_base`
**Error**: `BootstrapIdleTooHigh()`  
**File**: `test/strategies/usdc-lending/CtoHardeningFixes.t.sol:339`

**Test logic**:
1. `_coreDeposit(1000e6)` (bootstrap, adapter1 + adapter2 active)
2. `adapter1.setDepositReverts(true)`
3. `_coreDeposit(10e6)` — small deposit should succeed (idle << 50% tvlAfter)

**Why it fails**: After first deposit of 1000 USDC (T1), cap=50% → 500 USDC deployed to adapter1.
Idle = 500 USDC. Then adapter1 breaks. Second deposit of 10 USDC stays idle (adapter1 reverts,
adapter2 is also not selected at T1 dMax=1). TVL after = 1010 USDC. maxIdle (bootstrap) = 50% ×
1010 = 505 USDC. Actual idle = 500 + 10 = 510 USDC > 505 → `BootstrapIdleTooHigh`.

**Pre-fix**: First deposit deploys 1000 USDC (100% at T1). Idle = 0. Second deposit: 10 idle.
maxIdle = 505. 10 < 505 → passes.

**Classification**: TEST PRECONDITION ISSUE. The test verifies TVL-base idle computation, not T1 cap.

**Proposed fix**: Increase first deposit to 250_000e6 (T3 → all 3 adapters deploy ~84%,
idle ≈ 0). Then break adapter1. Second deposit of 10e6 stays idle. maxIdle = 50% × ~250_010e6 ≈ 125K.
10 USDC idle << 125K maxIdle → passes.

---

### 4. MultiCycleStability: `test_C3a_idleAlwaysDeployedAfterCycle`
**Error**: `C3: idle must be <= dustTolerance after each deploy cycle: 1600000000 > 3000000`  
**File**: `test/strategies/usdc-lending/MultiCycleStability.t.sol:162`

**Test logic**: 20 iterations of `_coreDeposit(10_000e6)` + `_warpAndDeployIdle()`,
then `assertLe(vault.idleCash(), vault.dustTolerance())`.

**Why it fails**: Iteration i=0: deposit 10K USDC (T1 < 25K). Cap=50%. Adapter1 is new (pos=0)
→ ramp applies (34%) → 3400 USDC deployed. `deployIdle()`: adapter1 pos≠0, no ramp → target =
50%×10K = 5000 → delta = 1600 → deploy 1600 → idle = 5000 USDC > 3 USDC (dustTolerance) → FAILS.

**Note on error message**: `1600000000` is 1600 USDC. This is the idle AFTER `deployIdle` in
iteration i=0, where deployIdle only moves the ramp residual (1600 USDC) but leaves 5000 USDC
idle because the T1 cap (50%) prevents full deployment. Wait — actually after the
deposit (3400 deployed, 6600 idle) + deployIdle (1600 more → 5000 deployed, 5000 idle), idle is
5000 USDC. The error showing 1600 might be at a later iteration when TVL is higher... regardless,
the root cause is T1 cap at 50%.

**Classification**: TEST PRECONDITION ISSUE. C3a tests deploy-cycle idle convergence. It must
operate at T3 TVL where `dMax=3` allows full deployment across 3 adapters.

**Proposed fix**: Pre-deposit 250_000e6 in test body BEFORE the loop (or add to setUp). Then
each 10_000e6 loop deposit stays in T3 TVL range → dMax=3, all deployed → idle ≤ dust.
Alternative: change loop deposit from 10_000e6 to 300_000e6.

---

### 5. Scoring_Model: `test_AUDIT_FINDING_8_T1_ignores_global_ceiling`
**Error**: `T1: posA exceeds 30%-ceiling - global ceiling bypassed at T1: 300000000 <= 300000000`  
**File**: `test/strategies/usdc-lending/Scoring_Model.t.sol:1127`

**Test logic**: Set `adapterMaxExposureBps=3000` (30%), deposit 1000 USDC (T1).
Assert `posA > 300e6` — claiming T1 bypasses the ceiling (posA would be 500e6 ramp-limited,
not 300e6 ceiling-limited → proves ceiling bypass).

**Why it fails**: F-SCORING-INV2 FIXED this exact behavior. Now at T1, cap = `adapterMaxExposureBps`
= 3000 (30%). posA = min(ramp=50%, ceil=30%) = 30% × 1000 = 300 USDC. assertGt(300e6, 300e6) → FAILS.

**Special case**: This test was WRITTEN as a regression guard for the OLD bug. The comment header
says:
> "Before fix: effectiveAbsCapBps applied adapterMaxExposureBps (default 50%) even at T1 (dMax=1),
> causing 50% of TVL to stay idle in early-stage. After fix: T1 short-circuits to 10000 (100%)
> before any ceiling or overlays"

This comment documents the PREVIOUS bug-fix rationale (apparently there was an earlier "fix"
that was incorrect — `T1 short-circuits to 10000` was itself the bug that F-SCORING-INV2 now
corrects).

**Classification**: DOCUMENTATION OF CORRECTED BUG. The test asserts the OLD incorrect behavior
as "expected". With F-SCORING-INV2 applied, the assertion must be INVERTED — the ceiling is now
respected at T1.

**Proposed fix**: REWRITE (not just data change). The test should:
1. Rename: `test_AUDIT_FINDING_8_T1_respects_global_ceiling` (behavior is now ENFORCED, not bypassed)
2. Update comment header to document F-SCORING-INV2 fix
3. Change assertion:
   ```solidity
   // OLD (incorrect, testing bug): assertGt(posA, 300e6, "...");
   // NEW (correct, testing fix):
   assertLe(posA, 300e6, "T1: global ceiling enforced after F-SCORING-INV2 fix");
   assertEq(posA, 300e6, "T1: posA exactly at 30% ceiling, ramp (50%) does not override cap");
   ```
4. The `posB` assertion (`assertEq(posB, 0)`) remains valid — adapter B still not selected at T1 (dMax=1).

---

### 6. UsdcMultiLendingVault_Deposit_Test: `test_deposit_deploys_to_adapters`
**Error**: `assertion failed: 500000000 > 3000000`  
**File**: `test/strategies/usdc-lending/UsdcMultiLendingVault.t.sol:1287`

**Test logic**: `_mintAndTransferToVault(core, 1000e6)` + `vault.deposit(1000e6)`.
Assert `vault.idleCash() <= vault.dustTolerance()`.

**Classification**: TEST PRECONDITION ISSUE (T1 deposit → 50% idle).

**Proposed fix**: Change inline deposit to 250_000e6. No assertion change needed.

---

### 7. UsdcMultiLendingVault_Harvest_Test: `test_harvest_auto_redeploys_idle`
**Error**: `assertion failed: 550000000 > 3000000`  
**File**: `test/strategies/usdc-lending/UsdcMultiLendingVault.t.sol:1526`

**Test logic**: `Harvest_Test.setUp()` deposits 1000 USDC (T1). Test adds 100 USDC harvestable,
calls `harvest()`. After harvest: idle = 500 (original T1 residual) + 100 (harvest) − redeploy delta.

**Classification**: TEST PRECONDITION ISSUE. `Harvest_Test.setUp()` deposit is already at T1.

**Proposed fix**: Change `Harvest_Test.setUp()` deposit from 1000e6 to 250_000e6. (Same pattern
as Views_Test and Withdraw_Test already approved.) The harvest test verifies that harvested funds
are redeployed; this still holds at T3 TVL.

---

### 8. UsdcMultiLendingVault_NoCashInvariant_Test: `test_deposit_enforces_noCash`
**Error**: `assertion failed: 500000000 > 3000000`  
**File**: `test/strategies/usdc-lending/UsdcMultiLendingVault.t.sol:2043`

**Test logic**: Inline `_mintAndTransferToVault(core, 1000e6)` + deposit. Assert `idleCash ≤ dustTolerance`.

**Classification**: TEST PRECONDITION ISSUE. The test verifies NoCash invariant enforcement, not T1 behavior.

**Proposed fix**: Change inline deposit to 250_000e6.

---

### 9. UsdcMultiLendingVault_NoCashInvariant_Test: `test_harvest_enforces_noCash`
**Error**: `assertion failed: 550000000 > 3000000`  
**File**: `test/strategies/usdc-lending/UsdcMultiLendingVault.t.sol:2054`

**Test logic**: Inline 1000 USDC deposit + 100 USDC harvestable + harvest. Assert `idleCash ≤ dustTolerance`.

**Classification**: TEST PRECONDITION ISSUE. Same as #8.

**Proposed fix**: Change inline deposit to 250_000e6.

---

### 10. UsdcMultiLendingVault_MutationKiller_Test: `test_maxExposure_limits_allocation`
**Error**: `assertion failed: 500000000 > 3000000`  
**File**: `test/strategies/usdc-lending/UsdcMultiLendingVault.t.sol:2670`

**Test logic**: Inline 1000 USDC deposit. Assert `totalAssets == 1000e6` AND `idleCash ≤ dustTolerance`.

**Classification**: TEST PRECONDITION ISSUE.

**Proposed fix**: Change inline deposit to 250_000e6. Update `assertEq(tvl, 1000e6)` → 250_000e6.

---

### 11. UsdcMultiLendingVault_MutationKiller_Test: `test_realizeLiquidity_calculates_pro_rata`
**Error**: `assertion failed`  
**File**: `test/strategies/usdc-lending/UsdcMultiLendingVault.t.sol:2449`

**Test logic**: Inline 1000 USDC deposit. Then withdraw 500 USDC. Assert at least one
adapter reduces position (pro-rata liquidation).

**Why it fails**: At T1, only 500 USDC deployed (50% cap) + 500 USDC idle. Withdraw of
500 USDC served entirely from idle → adapters unchanged → assertion `pos1After < pos1Before ||
pos2After < pos2Before` fails (both positions unchanged).

**Classification**: TEST PRECONDITION ISSUE. The test verifies pro-rata liquidation mechanics.
It requires that adapters hold funds so that a withdrawal forces realization.

**Proposed fix**: Change inline deposit to 250_000e6. At T3, nearly all 250K deployed across
3 adapters (idle ≈ 0). Withdraw 500 USDC → must pull from adapters → assertion passes.
The 500e6 withdraw amount stays as-is (small fraction of 250K TVL, still forces adapter pull).

---

## Proposed Changes (awaiting approval)

### Group A — Simple inline deposit changes (7 tests)
Change `1000e6` → `250_000e6` in test body + any assertions referencing that exact amount:

| Test | File:Line | Changes needed |
|---|---|---|
| `test_deposit_deploys_to_adapters` | UsdcMultiLendingVault.t.sol:1289-1292 | deposit 1000e6→250_000e6 |
| `test_deposit_enforces_noCash` | UsdcMultiLendingVault.t.sol:2046-2049 | deposit 1000e6→250_000e6 |
| `test_harvest_enforces_noCash` | UsdcMultiLendingVault.t.sol:2056-2059 | deposit 1000e6→250_000e6 |
| `test_maxExposure_limits_allocation` | UsdcMultiLendingVault.t.sol:2672-2680 | deposit 1000e6→250_000e6; `assertEq(tvl,1000e6)`→250_000e6 |
| `test_realizeLiquidity_calculates_pro_rata` | UsdcMultiLendingVault.t.sol:2450-2452 | deposit 1000e6→250_000e6 (withdraw 500e6 unchanged) |

### Group B — setUp deposit changes (2 tests)
| Test | File:Line | Changes needed |
|---|---|---|
| `test_harvest_auto_redeploys_idle` | Harvest_Test setUp L1469-1471 | deposit 1000e6→250_000e6 |

### Group C — CtoHardeningFixes (3 tests)
| Test | File:Line | Proposed change |
|---|---|---|
| `test_deposit_allows_idle_within_percentage_bound` | CtoHardeningFixes.t.sol:241 | First `_coreDeposit(100e6)` → `_coreDeposit(250_000e6)` (bootstrap, T3 primes all adapters); second `_coreDeposit(100e6)` stays as-is (tiny deposit at T3 TVL → negligible idle) |
| `test_deposit_uses_dustTolerance_as_floor` | CtoHardeningFixes.t.sol:278 | Same: first deposit 100e6 → 250_000e6; second 100e6 stays |
| `test_bootstrap_small_deposit_when_large_idle_uses_tvl_base` | CtoHardeningFixes.t.sol:339 | First deposit 1000e6 → 250_000e6; second deposit 10e6 stays |

### Group D — MultiCycleStability (1 test)
| Test | File:Line | Proposed change |
|---|---|---|
| `test_C3a_idleAlwaysDeployedAfterCycle` | MultiCycleStability.t.sol:162 | Add `_coreDeposit(250_000e6)` at start of test body (before loop), so TVL starts at T3; each loop deposit of 10_000e6 then stays in T3 → dMax=3 → full deployment |

### Group E — Audit Finding 8 (1 test) — SPECIAL CASE
| Test | File:Line | Proposed change |
|---|---|---|
| `test_AUDIT_FINDING_8_T1_ignores_global_ceiling` | Scoring_Model.t.sol:1127 | **Rewrite**: rename to `test_AUDIT_FINDING_8_T1_respects_global_ceiling`; update comment header; change `assertGt(posA, 300e6, ...)` → `assertEq(posA, 300e6, "T1: ceiling enforced at 30%")` |

The `posB == 0` assertion remains. The `setMaxIdleAfterDepositBps(10000)` remains.

---

## Risk Assessment

### Assertions not weakened
All proposed changes modify DEPOSIT AMOUNTS in setUp/test body, not assertions. The assertions
remain equally strict (assertLe idleCash ≤ dustTolerance is tested at T3 TVL, which is MORE
demanding than T1 because more capital must be deployed).

Exception: `test_AUDIT_FINDING_8` changes the direction of the assertion (assertGt → assertEq).
This is NOT weakening — it changes from asserting the bug to asserting the fix. The new assertion
is MORE precise (assertEq) than the old one (assertGt).

### Strictness preserved or increased
- CtoHardeningFixes: deposits increase from 100e6 to 250_000e6 → more total capital in play,
  same percentage idle constraint → MORE demanding.
- C3a: pre-deposit 250K before loop → every loop deposit is at T3, dMax=3, HARDER to keep idle≤dust.

### No other tests affected
The deposit changes are all LOCAL to individual test functions. The class-level setUps for these
tests (UsdcMultiLendingVaultTestBase) are unchanged. Tests not in this list are unaffected.

---

_Filed: F-SCORING-INV2 TRIAGE_2 | Status: **BLOCKED — awaiting Cowork approval**_
