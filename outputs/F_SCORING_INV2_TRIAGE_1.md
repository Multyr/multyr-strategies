# F-SCORING-INV2 TRIAGE — 3 Regressions in Views_Test / Withdraw_Test

**Task**: F-SCORING-INV2 fix (Option B applied, PRE gate was 2350/0)
**POST gate**: 2350 + 4 new = 2354 expected, but 3 pre-existing tests now FAIL
**Status**: STOP — awaiting approval before touching tests

---

## Failing Tests

### 1. `test_idleCash_returns_vault_balance` (UsdcMultiLendingVault_Views_Test)

**Assertion**: `assertLe(vault.idleCash(), vault.dustTolerance())`
**Expected**: `idleCash <= 3_000_000` (3 USDC dust)
**Actual**: `idleCash = 500_000_000` (500 USDC) → `assertion failed: 500000000 > 3000000`

### 2. `test_hasIdleCash_returns_false_when_below_dust` (UsdcMultiLendingVault_Views_Test)

**Assertion**: `assertFalse(vault.hasIdleCash())`
**Expected**: `false` (no meaningful idle)
**Actual**: `true` (500 USDC idle > 3 USDC dust)

### 3. `test_withdraw_realizes_liquidity_from_adapters` (UsdcMultiLendingVault_Withdraw_Test)

**Assertion**: `assertTrue(adapter1.deposited() < adapter1Before || adapter2.deposited() < adapter2Before)`
**Expected**: at least one adapter reduces position after withdraw
**Actual**: both adapters unchanged — withdrawal served entirely from idle cash

---

## Root Cause Analysis

### Causal chain

`UsdcMultiLendingVault_Views_Test.setUp()` and `UsdcMultiLendingVault_Withdraw_Test.setUp()` each:
1. Use `UsdcMultiLendingVaultTestBase.defaultParams` with `adapterMaxExposureBps = 5000` (50%)
2. Add 3 adapters via `_setupAdaptersForRebalance()`
3. Deposit 1000 USDC (`_mintAndTransferToVault(core, 1000e6); vault.deposit(1000e6)`)

TVL after deposit = 1000 USDC < 25_000e6 → **T1 single-adapter mode** (`_effectiveMaxAdapters() = 1`).

**PRE-fix behavior** (`_effectiveAbsCapBps()` at T1 returned `10000`):
- adapter1 (best APY=800) receives cap=10000 → 100% × 1000 USDC = 1000 USDC deployed
- idle = 0 USDC
- Bootstrap check: `idle (0) ≤ maxIdleBootstrapBps (50%) × 1000 = 500 USDC` → OK
- `idleCash() = 0 ≤ dustTolerance (3 USDC)` → tests pass

**POST-fix behavior** (F-SCORING-INV2 Option B: returns `adapterMaxExposureBps = 5000` at T1):
- adapter1 receives cap=5000 → 50% × 1000 USDC = 500 USDC deployed
- idle = 500 USDC (50% of TVL stays in vault)
- Bootstrap check: `idle (500) ≤ maxIdleBootstrapBps (50%) × 1000 = 500` → exactly at limit, no revert (≤)
- `idleCash() = 500e6 > dustTolerance = 3e6` → test_idleCash FAILS
- `hasIdleCash() = true` → test_hasIdleCash FAILS
- Withdraw 500 USDC → served from 500 idle → adapters unchanged → test_withdraw FAILS

### Classification: **TEST PRECONDITION ISSUE — not a code bug**

The F-SCORING-INV2 fix is **correct by design**. At T1 TVL, concentrating 100% in one adapter while silently bypassing the governance cap (`adapterMaxExposureBps`) was the BUG being fixed.

These tests were implicitly relying on the buggy T1 behavior (cap=10000) to achieve their precondition (idle=0 after deposit). They never intended to TEST the T1 cap behavior; they are testing view functions (idleCash, hasIdleCash) and withdrawal liquidity realization.

The tests are NOT wrong in their assertions. The assertions remain correct. What is wrong is the PRECONDITION: a 1000 USDC deposit at T1 TVL can no longer fully deplete idle cash when `adapterMaxExposureBps < 10000`.

---

## Why this is NOT a code bug

1. The fix correctly enforces that at T1 TVL, only `adapterMaxExposureBps`% is allocated to the single adapter.
2. The new behavior is semantically correct: at small TVL, the governance ceiling still caps the single adapter.
3. `test_SCORING_INV2_behavioral_T1_cap_enforced` (new, in F_SCORING_INV2_CapFix.t.sol) proves this is the intended post-fix behavior and it PASSES.
4. The 3 failing tests do NOT assert anything about the T1 cap — they assert about idle cash and withdraw routing. Their failure is collateral from a changed deployment amount.

---

## Proposed Test Fix (awaiting approval)

### Target files
- `test/strategies/usdc-lending/UsdcMultiLendingVault.t.sol`
- Two setUp() overrides: `UsdcMultiLendingVault_Views_Test` and `UsdcMultiLendingVault_Withdraw_Test`

### Change

Increase the deposit amount from `1000e6` to `250_000e6` (250,000 USDC).

**Rationale for `250_000e6`**:
- T3 threshold: TVL ≥ 250_000e6 → `_effectiveMaxAdapters() = 3` (`dynamicMax = 3`)
- With `dMax = 3` and `newAdapterRampBps = 3400` (34%), ramp allows 3 × 34% = 102% of TVL
- `adapterMaxExposureBps = 5000` at T3 = cap via formula = `ceil(11000/3) = 3667 bps` (smaller than 5000)
- Each adapter: min(ramp 34% × 250K = 85K, absCap 36.67% × 250K = 91.7K) = 85K → 3 × 85K = 255K > 250K → all deployed
- In bootstrap: `maxIdleBootstrapBps = 50%` → maxIdle = 125K; idle ≈ 0 → no BootstrapIdleTooHigh
- `idleCash() ≈ 0 ≤ dustTolerance` → both idle tests PASS
- Withdraw 500 USDC: idle ≈ 0 → must realize from adapters → adapter1 decreases → PASS

**Strictness**: The assertions remain IDENTICAL. Only the setUp deposit amount changes (from 1000e6 to 250_000e6). This is NOT weakening any assertion; it is fixing the test precondition to reflect the corrected system behavior where T3 TVL can fully deploy into 3 adapters within governance constraints.

### Exact diff

```diff
-contract UsdcMultiLendingVault_Views_Test is UsdcMultiLendingVaultTestBase {
-    function setUp() public override {
-        super.setUp();
-        _setupAdaptersForRebalance();
-        _mintAndTransferToVault(core, 1000e6);
-        vm.prank(core);
-        vault.deposit(1000e6);
-    }
+contract UsdcMultiLendingVault_Views_Test is UsdcMultiLendingVaultTestBase {
+    function setUp() public override {
+        super.setUp();
+        _setupAdaptersForRebalance();
+        _mintAndTransferToVault(core, 250_000e6); // T3 TVL: dMax=3 → all 3 adapters fully allocatable
+        vm.prank(core);
+        vault.deposit(250_000e6);
+    }
```

```diff
-contract UsdcMultiLendingVault_Withdraw_Test is UsdcMultiLendingVaultTestBase {
-    function setUp() public override {
-        super.setUp();
-        _setupAdaptersForRebalance();
-        _mintAndTransferToVault(core, 1000e6);
-        vm.prank(core);
-        vault.deposit(1000e6);
-    }
+contract UsdcMultiLendingVault_Withdraw_Test is UsdcMultiLendingVaultTestBase {
+    function setUp() public override {
+        super.setUp();
+        _setupAdaptersForRebalance();
+        _mintAndTransferToVault(core, 250_000e6); // T3 TVL: dMax=3 → all 3 adapters fully allocatable
+        vm.prank(core);
+        vault.deposit(250_000e6);
+    }
```

### Risk assessment

- Other tests in the same contracts that depend on a specific TVL of 1000 USDC may be affected.
  - `test_totalAssets_includes_adapters`: asserts `vault.totalAssets() == 1000e6` → would fail with 250K.
  - `test_withdrawableAssets_returns_sum`: asserts `vault.withdrawableAssets() == 1000e6` → same.
  - These would need to be updated too.
- The Withdraw tests mostly assert behavior (not specific amounts), so most should adapt.

### Alternative fix

Keep `deposit(1000e6)` but also add a comment and assertion update:
```solidity
// With F-SCORING-INV2 fix, at T1 TVL (1000 USDC < 25K), only adapterMaxExposureBps (50%)
// is deployed to the single adapter. Idle cash = ~500 USDC, not 0.
```
And relax `test_idleCash_returns_vault_balance` to `assertLe(vault.idleCash(), vault.totalAssets() / 2 + vault.dustTolerance())`.

**REJECTED**: This would weaken the assertion — it would allow 50% idle where the original correctly required near-zero idle. This makes the test less precise.

---

## Decision needed

Approve the deposit change to `250_000e6` (updating also the `totalAssets` and `withdrawableAssets` assertions in Views_Test), OR propose an alternative approach.

_Filed: F-SCORING-INV2 task | Status: **BLOCKED — awaiting approval**_
