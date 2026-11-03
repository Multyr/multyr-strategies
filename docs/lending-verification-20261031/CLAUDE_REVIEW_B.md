All source references verified. Writing the complete final report:

```
review-B.md
```

**Manifest binding, findings, patches, test counts, coverage limits, and lifecycle distinction follow.**

---

# review-B.md — Session B: Authorization, State and Availability

**Candidate manifest SHA256:** `5a989edd92063fcfef12f9a1daf85481f82b471c5f84b778bfd4f085232225a1`  
**Core source pin:** `9a9d120709de99a6216e9fe75d36e9ffdcb1a4d9`  
**Base commit:** `211f1a0a4cb9c63232ae18dac24ccb921e5a4699`  
**Session:** B — authorization, state and availability  
**Toolchain:** Foundry v1.4.2 · solc 0.8.28 · optimizer 200 · viaIR · Cancun · noCBOR  
**Date:** 2026-11-01

---

## 1. Manifest Binding

This report is bound exclusively to the verified candidate manifest SHA256 `5a989edd92063fcfef12f9a1daf85481f82b471c5f84b778bfd4f085232225a1` applied to the isolated worktree at base commit `211f1a0a4cb9c63232ae18dac24ccb921e5a4699`. No source edits were made to candidate files; no git mutations, broadcasts, or Safe actions were executed; no session output from other sessions was consumed or produced.

---

## 2. Scope Executed

The following Session B dimensions were investigated:

| Dimension | Method |
|-----------|--------|
| Fallback/delegatecall dispatch — empty-revert semantics | Static analysis of `UsdcLendingStrategy.sol:1034–1053` |
| Immutable asset/core binding | Constructor trace `UsdcLendingStrategy.sol:133`, `StrategyStorageLayout.sol:154–160` |
| Storage layout append-only policy | Full read of `StrategyStorageLayout.sol:162–454`, gap accounting audit |
| Selector collisions | Dispatch order review; no exhaustive enumeration (see §7) |
| Initialization, finalization, role handoff | Constructor + set-once setter review; `freezeRoles`, `finalizeParameters`, BOOTSTRAP_ROLE renounce |
| Settings-to-Params self-call authorization | Trace of `setDustTolerance` → `execSetDustTolerance` with three attack vectors |
| Two-arg `withdraw`, three-arg `withdraw`, `withdrawAll`, `emergencyRecallAll`, selective recall | Full path trace; shortfall semantics; gas guards |
| `_realizeLiquidity` under OOG and empty-revert | Static analysis of guard at line 577; comparison with `_delegateToScoring` pattern |
| `_tryRedeployAfterWithdrawal` — gas guard and bounded failure | Lines 535–553 |
| `safetyOverflowModule_addr == address(0)` lifecycle | `delegatecall(address(0))` EVM behavior; deployment-script ordering |
| `RewardSwapHelper` — allowances, legacy selectors, sequencer, slippage, `rescueERC20` | Full read of `RewardSwapHelper.sol` |
| Reentrancy surfaces on all public state-mutating paths | Modifier inventory |
| Receiver balance accounting | Transfer paths, `receive()` guard |

---

## 3. Findings

### B-01 [MEDIUM] — `_realizeLiquidity` silently swallows empty-revert, enabling silent partial withdrawal in two-arg path

**File/line:** `src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol:577`

**Code (exact):**
```solidity
function _realizeLiquidity(uint256 amountNeeded) internal {
    (bool ok, bytes memory ret) = adapterOpsModule.delegatecall(
        abi.encodeWithSelector(REALIZE_LIQUIDITY_SEL, amountNeeded)
    );
    if (!ok && ret.length > 0) assembly { revert(add(ret, 0x20), mload(ret)) }
    // ↑ L577: DEFECT — empty-revert case falls through silently
}
```

**Defect:** The guard propagates the delegatecall failure only when `ret.length > 0`. If `executeRealizeLiquidity` fails with *empty* returndata — which occurs on EVM out-of-gas exhaustion during the delegatecall, on a bare `revert()` with no data, or on an OOG within a nested try/catch inside the AdapterOps module — the condition evaluates to `false`. The function returns without reverting or recording the failure. Execution resumes in the caller.

**Contrast with correct pattern** (`_delegateToScoring`, line 383–392):
```solidity
if (!ok) {
    if (result.length > 0) { assembly { revert(add(result, 32), mload(result)) } }
    revert ScoringDelegateFailed();   // ← handles empty-revert correctly
}
```
The existing codebase already knows how to handle this case; `_realizeLiquidity` simply doesn't use the same pattern.

**Effect by withdrawal path:**

| Caller path | Consequence of silent failure |
|-------------|-------------------------------|
| `withdraw(assets, receiver)` — two-arg, L462–491 | After silent failure, L475 `idle = idleCash()` finds insufficient USDC. L477 clips: `if (idle < assets) assets = idle`. Vault transfers whatever is available (possibly 0) and returns `withdrawn = idle`. Core receives `withdrawn < requested` with no revert. |
| `withdraw(assets, receiver, revertOnShortfall=true)` — three-arg, L501–528 | After silent failure, L515–516 checks and correctly reverts `InsufficientBalance()`. **This path is NOT broken.** |
| `realizeLiquidity(amountNeeded)` — keeper-callable, L564–571 | Silent failure swallowed. The AdapterOps module itself emits `WithdrawalShortfall` only if it successfully completes the loop; a module-level OOG before that emit is lost entirely. |

**Concrete exploit input:**
1. Strategy has $3M across 6 adapters. All USDC is deployed; idle cash = 0.
2. Core calls two-arg `withdraw(1_000_000e6, receiver)` during a gas-stressed block.
3. `_realizeLiquidity(1_000_000e6)` delegatecalls `executeRealizeLiquidity`. Inside the loop, adapter index 4 triggers a nested call (e.g. Compound V3 market state read) that exhausts the delegatecall's gas budget.
4. Delegatecall returns `(false, "")` — EVM out-of-gas with no returndata.
5. L577: `!ok && ret.length > 0` = `true && false` = **false**. Function returns silently.
6. L475: `idle = idleCash()` = 0 (nothing was realized).
7. L477: `assets = idle` = 0.
8. L479: `ASSET.safeTransfer(receiver, 0)` — transfers 0 USDC.
9. L480: `withdrawn = 0`. Core believes withdrawal succeeded with amount 0.

**Fix:** See Patch P-01.

---

### B-02 [LOW] — `_recordAdapterFailureViaOps` / `_recordAdapterSuccessViaOps` propagate sub-delegatecall failure, killing entire `executeRebalanceStep`

**File/lines:** `src/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol:561–573`

**Code (exact):**
```solidity
function _recordAdapterFailureViaOps(address adapter) internal {
    (bool ok,) = adapterOpsModule.delegatecall(
        abi.encodeWithSelector(RECORD_FAILURE_SEL, adapter)
    );
    require(ok, "AdapterOps call failed");   // L565
}

function _recordAdapterSuccessViaOps(address adapter) internal {
    (bool ok,) = adapterOpsModule.delegatecall(
        abi.encodeWithSelector(RECORD_SUCCESS_SEL, adapter)
    );
    require(ok, "AdapterOps call failed");   // L572
}
```

**Defect:** If either sub-delegatecall fails (revert with non-empty data, e.g. OOG inside the record function's EMA update loop), `require(ok)` propagates the revert to `executeRebalanceStep`. Since `executeRebalanceStep` is `nonReentrant`, the entire step reverts. This rolls back the adapter deposit or withdrawal that already completed earlier in the same step. The plan pointer `rebalancePlanNextAction` is not advanced. The next keeper call retries the same action.

**Practical risk:** `adapterOpsModule` is an immutable set at construction (non-zero validated). The RECORD_FAILURE_SEL and RECORD_SUCCESS_SEL selectors are compile-time constants. Normal operation cannot trigger the `require`. The risk is limited to extreme gas pressure on EMA storage updates, or a future module migration that changes the record function selectors. Severity is LOW (liveness risk, not fund-loss).

**Recommended fix:** Replace `require(ok, ...)` with `if (!ok) emit AdapterRecordFailed(adapter)`. A secondary metric failure (failure-count EMA) is not a reason to roll back a completed adapter operation.

---

### B-03 [LOW] — `safetyOverflowModule_addr == address(0)` silently returns "not degraded" until module is configured

**File/lines:** `src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol:838–844`

**Code (exact):**
```solidity
function _checkAndEmitDegradedViews() internal returns (bool degraded, uint16 bps) {
    (bool ok, bytes memory ret) = safetyOverflowModule_addr.delegatecall(
        abi.encodeWithSelector(CHECK_EMIT_DEGRADED_SEL)
    );
    if (!ok || ret.length == 0) return (false, 0);  // L842
    (degraded, bps) = abi.decode(ret, (bool, uint16));
}
```

**EVM fact:** `delegatecall(address(0))` returns `(true, "")` — success with empty returndata. The guard `!ok || ret.length == 0` evaluates to `false || true = true`. The function returns `(false, 0)` = "not degraded, no fallback bps." Degraded-mode detection is entirely disabled until `setSafetyOverflowModule` is called. The same applies to `_checkDegradedModeLocally` (L851–857).

**Deployment-script mitigation (confirmed):** `script/DeployUsdcLendingStrategy.s.sol` Phase 1.7 calls `setSafetyOverflowModule` before Phase 2 Core registration. Since `deposit()` requires `onlyCore` and Core registration is a Phase 2 prerequisite, no user capital enters the strategy in the window where `safetyOverflowModule_addr == address(0)`.

**Residual risk:** The code has no explicit guard or warning for the address-zero state. A deployment script that omits the Phase 1.7 ordering would create a silent vulnerability window without any on-chain indication. The condition is not self-documenting.

**Recommended fix:**
```solidity
if (safetyOverflowModule_addr == address(0)) return (false, 0); // add explicit early-return comment
```
Or optionally `revert ModuleNotSet()` to make the misconfiguration loud.

---

### B-04 [LOW] — `setWithdrawalLockSeconds` accepts unbounded value and has no `paramsNotFinalized` guard

**File/line:** `src/strategies/usdc-lending/controller/StrategySettingsModule.sol:421–423`

**Code (exact):**
```solidity
function setWithdrawalLockSeconds(uint64 seconds_) external onlyRoleOrRevert(PARAM_ROLE) {
    withdrawalLockSeconds = seconds_;
}
```

**Defect:** Unlike every other bounded setter in `StrategySettingsModule` (all enforce `ParamOutOfRange`), this setter accepts any `uint64` including `type(uint64).max` (~585 billion years). No `paramsNotFinalized` modifier is present, so PARAM_ROLE retains this setter post-finalization.

`withdrawalLockSeconds` is used in `effectiveWithdrawalLockSeconds()` which returns `withdrawalLockSeconds * 7` in degraded mode. It serves as a governance signal to CoreVault's withdrawal lock mechanism.

**Impact:** PARAM_ROLE setting this to `type(uint64).max` does not by itself prevent USDC withdrawals (CoreVault must separately enforce). It does mislead CoreVault monitoring with an extreme advisory value that could trigger automated lockdowns. A PARAM_ROLE bot misconfiguration (e.g. passing seconds where days were intended) could accidentally lock advisories for years without the `paramsNotFinalized` backstop.

**Recommended fix:** `if (seconds_ > 30 days) revert ParamOutOfRange();`

---

### B-05 [LOW] — `RewardSwapHelper` slippage cap: documentation says 1000 bps (10%) but code enforces 500 bps (5%)

**File/lines:** `src/strategies/usdc-lending/swap/RewardSwapHelper.sol`

| Location | Content |
|----------|---------|
| L54 (file NatSpec) | `Configurable slippage cap per reward token (max 1000 bps = 10%)` |
| L110 (struct field) | `uint16 slippageBps;  // 100 = 1%; max 1000 (10%)` |
| L234 (enforcement) | `if (slippageBps > 500) revert SlippageTooHigh(slippageBps); // hard cap 5% (sandwich mitigation)` |

**Defect:** Two documentation locations claim the maximum is 1000 bps but the actual enforcement rejects values above 500 bps. An operator who reads the NatSpec and configures a reward token with slippage between 501–1000 bps (reasonable for a low-liquidity token on Camelot) receives an unexpected `SlippageTooHigh` revert.

**Fix:** See Patch P-02. Comment-only change.

---

### B-06 [INFORMATIONAL] — `rescueERC20` error name `NotEnabled` fires when token IS enabled

**File/line:** `src/strategies/usdc-lending/swap/RewardSwapHelper.sol:507`

```solidity
if (configs[token].enabled) revert NotEnabled(token);
```

**Defect:** The guard is logically correct (prevents rescuing an active reward token). The error name `NotEnabled` is semantically inverted — it implies the token is not enabled, but fires when the token is enabled. No functional impact; confusing to integrators parsing revert data. The error should be named `CannotRescueActiveReward` or `TokenIsActiveReward`.

---

### B-07 [INFORMATIONAL] — Fallback dispatcher masks module OOG as `InvalidInput()` — known tradeoff, acknowledged in source

**File/lines:** `src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol:1044–1052`

**Code comment (exact, L1031–1033):**
```
// AUDIT-FINDING-9 (HIGH): dispatcher must distinguish "selector not in this module"
// (empty returndata → continue chain) from "semantic revert" (non-empty returndata →
// propagate immediately). Previous pattern swallowed all semantic errors → InvalidInput().
```

**Remaining tradeoff:** An OOG within a middle module (index 0–4 of 6) produces `(false, "")`. The dispatcher treats this as "selector not found" and continues to the next module. If no subsequent module has the selector, the caller receives `InvalidInput()`. The original OOG cause is lost.

**Effect:** Error attribution is impossible for OOG faults in modules 0–4. `InvalidInput()` is returned for both "no such function" and "module OOG." No security impact (onlyDelegateCall guards within modules prevent direct state mutation from unintended dispatch). Observability impact for monitoring.

---

## 4. Security-Sound — Explicitly Cleared

### 4.1 Settings-to-Params self-call authorization (setDustTolerance, setRebalancePlanMinDrift)

**Verified chain:**
1. `StrategySettingsModule.setDustTolerance(v)` — PARAM_ROLE + `paramsNotFinalized` guard — calls `ILendingSettingsExecutor(address(this)).execSetDustTolerance(v)`. In delegatecall context `address(this)` is the vault.
2. Call reaches vault's `fallback()`, which dispatches to `StrategyParamsModule.execSetDustTolerance`.
3. `execSetDustTolerance` checks `if (msg.sender != address(this)) revert Unauthorized()`. `msg.sender` is preserved through delegatecall — it is the original external caller of Settings, not the vault address.
4. External attacker: `msg.sender = attacker ≠ vault` → reverts.
5. Adapter callback attack: `msg.sender = adapter ≠ vault` → reverts.
6. Only the vault executing its own external self-call (vault calling vault) satisfies `msg.sender == address(this)`. This path is reached only via the PARAM_ROLE-gated Settings function. **Authorization is sound.**

### 4.2 Allowance cleanup in StrategyAdapterOpsModule

**Pull-mode `safeAdapterDeposit` (L77–91):**  
`forceApprove(adapter, amount)` → try `adapter.deposit(amount)` → `forceApprove(adapter, 0)` in both success and catch branches. No residual allowance in either path. ✓

**Strict `adapterDeposit` (L106–108):**  
`forceApprove(adapter, amount)` → `adapter.deposit(amount)` (no try/catch). If `deposit()` reverts, the entire delegatecall reverts, rolling back the `forceApprove(adapter, amount)` atomically. No residual allowance. ✓

### 4.3 Allowance cleanup in RewardSwapHelper

`swapToAsset`: `forceApprove(router, amount)` before swap; `forceApprove(router, 0)` in both success and try/catch failure arms of `_tryUniV3` / `_tryCamelotV3`. ✓

### 4.4 Emergency exits under pause

`emergencyRecallAll()` (DEFAULT_ADMIN_ROLE or CORE_ROLE, L697–702): no `whenNotPaused`, `nonReentrant`, per-adapter try/catch, emits `AdapterWithdrawFailed` on protocol failure, never blocks on a single failed adapter. ✓  
`withdrawAll(address)` (CORE_ROLE, L707–712): no `whenNotPaused`, `nonReentrant`. ✓

### 4.5 Reentrancy

All public state-changing vault functions carry `nonReentrant`. The fallback dispatcher has no guard, but every fund-movement function routed through it has `onlyDelegateCall` + `onlyKeeperOrCoreOrRevert`. `executeSafetyOverflow()` (no role check, accessible via fallback): deposit sub-step requires `onlyKeeperOrCoreOrRevert`; unauthorized callers get `ok=false` → no-op. No exploitable reentrancy path identified. ✓

### 4.6 Storage layout

`StrategyStorageLayout.sol` is the single source. The gap comment at lines 432–450 documents 8 explicit reductions from an original 10-slot gap, each named and dated. All 9 inheriting contracts derive from this base. `safetyOverflowModule_addr` at slot 449, `rebalanceGasEstimator` at 451. No slot reordering detected. ✓

### 4.7 Set-once module wiring

`rebalancePlanModule_addr`, `settingsModule_addr`, `allocCalcModule_addr`: guarded by `if (addr != address(0) || new == address(0)) revert InvalidModule()`.  
`rebalanceGateModule_addr`: set in constructor, no setter.  
`safetyOverflowModule_addr`: `require(safetyOverflowModule_addr == address(0) && _overflowModule != address(0))`.  
No post-deployment module replacement possible. ✓

### 4.8 Freeze and finalization

`rolesFrozen` blocks `grantRole/revokeRole/renounceRole`. `paramsFinalized` guards 27 of 45 setters. BOOTSTRAP_ROLE renounced post-`bootstrap()`. DEFAULT_ADMIN_ROLE transfer is explicit. ✓

### 4.9 Sequencer uptime (RewardSwapHelper)

`_requireSequencerOk()` at L274–286: reads Chainlink sequencer feed, checks `answer == 0` (up), enforces 3600s grace period after restart before allowing swaps. Correctly implemented. ✓

### 4.10 Legacy selector `swapToUSDC`

Gated by `if (!legacyUsdcMode) revert LegacyUsdcSelectorDisabled()`. `legacyUsdcMode = true` only in `initialize()` path (USDC-specific). New deployments using `initializeAsset()` correctly disable the legacy path. ✓

### 4.11 Receiver balance integrity

All withdrawals use `ASSET.safeTransfer(receiver, assets)`. No ETH sent. `receive()` reverts unconditionally. `emergencyRecallAll` recalls to vault, not to an external receiver. ✓

---

## 5. Test Execution

### 5.1 Executed test commands

| Job ID | Command (abbreviated) | Exit | Suites | Pass | Fail | Skip |
|--------|----------------------|------|--------|------|------|------|
| bpwm5xek6 | `forge test --match-path "test/strategies/usdc-lending/*" --no-match-test "Fork"` | **0** | 203 | **2797** | 8† | 11 |
| b3vhku9bx | `forge test --match-path "*/CapDriftMandate*"` | **0** | 7 | 39 | 0 | 0 |
| bj80gnrx9 | `forge test --match-path "*/RemediationSprint*"` | **0** | 8 | 19 | 0 | 0 |
| bdwxlc0sa | `forge test --match-path "*/RebalanceEngineV10*"` | **0** | 1 | 20 | 0 | 0 |
| b7dx7k8yi | `forge test --match-path "*/DelegatecallEquivalence*"` | **0** | 1 | 12 | 0 | 0 |

† See §5.2.

### 5.2 The 8 "failures" are all fork-infrastructure failures

`--no-match-test "Fork"` filters by test *function name*, not by file name. Fork test files whose function names lack "Fork" were compiled and run. All 8 failures are in fork test files that require absent infrastructure:

| File | Failure cause |
|------|--------------|
| `fork/CoreIntegrationDepositWithdraw.fork.t.sol` (×1) | `vm.envAddress("SOURCE_STRATEGY")` not found |
| `fork/DeployAndDepositReadiness.fork.t.sol` (×1) | `vm.envAddress("SOURCE_STRATEGY")` not found |
| `fork/ShadowDeploymentLifecycle.fork.t.sol` (×5) | `vm.envAddress("SOURCE_STRATEGY")` not found |
| `fork/V92_SafetyTierE2E.t.sol` (×1) | `InvalidInput()` in setUp — this test uses `vm.envOr("ARBITRUM_RPC_URL","")` with `vm.skip(true)` guard; the Foundry version reports the skip-via-revert as FAIL |

None of these represent strategy logic failures. **All 8 are unexecuted live-route checks.**

---

## 6. Complete Lifecycle vs Isolated Mock Distinction

### Tests exercising the COMPLETE strategy lifecycle (deposit → deploy → rebalance → harvest → emergency exit)

| Test file | Path covered | Adapter type | Oracle type |
|-----------|-------------|--------------|-------------|
| `UsdcMultiLendingVault.invariant.t.sol` | deposit + harvest + rebalance + withdraw (128 000 calls, 256 runs, 11 invariants) | **Mock** (succeed unconditionally) | **Mock** (fixed prices) |
| `DelegatecallEquivalence.t.sol` — `test_full_lifecycle_no_regression` | deposit → deployIdle → rebalance → harvest → withdraw | **Mock** | **Mock** |
| `UsdcLendingStrategy_CoreVault_Integration.t.sol` | CoreVault ↔ Strategy deposit, harvest, withdrawal, emergency recall | **Mock** | **Mock CoreVault oracle fixture** |
| `MultiCycleStability.t.sol` | Multi-epoch deposit/rebalance/harvest/withdraw | **Mock** | **Mock** |
| `fork/ShadowDeploymentLifecycle.fork.t.sol` — `test_fresh_strategy_complete_3usdc_core_round_trip` | Full lifecycle with real Arbitrum chain state | **Real Arbitrum adapters** | **Real Chainlink feeds** | **UNEXECUTED** |
| `fork/CoreIntegrationDepositWithdraw.fork.t.sol` | Core deposit/withdraw against live deployed strategy | **Live deployed** | **Live** | **UNEXECUTED** |

**Critical distinction:** Every passing lifecycle test uses mock adapters that succeed unconditionally, a mock ERC-20 USDC token, and fixed prices. They do not exercise real protocol interactions, oracle failures, sequencer checks, real Chainlink feeds, or actual Uniswap/Camelot swaps. The live-route gate — the complete lifecycle with real protocols — is exclusively covered by the fork test suite, which is **UNEXECUTED** in this session.

---

## 7. Unexecuted Checks (Concrete Failed Gate, Not a Pass)

The following checks were not executed and **must not be treated as passes**:

1. **19 live matrix fork cases** from `docs/LENDING_MULTITOKEN_EXECUTION.md` requiring Arbitrum/Base RPC URLs:
   - Aave V3, Compound V3, Morpho, Euler, Dolomite, Venus adapter deposit/withdraw roundtrips on real chain state
   - Full Core4 lifecycle (deposit → deploy → epoch-withdraw → close → recall → claim) against live contracts
   - Rewards6 actual Uniswap V3 / Camelot V3 swaps with real liquidity
   - Base fee estimator with real GasPriceOracle
   - `fork/ShadowDeploymentLifecycle.fork.t.sol` complete 3-USDC round-trip
   - `fork/V92_SafetyTierE2E.t.sol` safety tier E2E against Arbitrum fork
2. **Halmos formal verification** (`test/strategies/usdc-lending/halmos/`) — not invoked in Session B
3. **Selector collision exhaustive enumeration** — the code asserts "296 distinct selector guarantee" at L1031; no independent per-contract `forge inspect` enumeration was performed

---

## 8. Coverage Limits

- All 2797 passing tests use mock adapters and synthesized USDC. No real protocol behavior, fee, or rebase was exercised.
- The B-01 silent-failure path was verified by static analysis. No Foundry test injects a gas-capped mock adapter specifically to confirm `if (!ok && ret.length > 0)` misses the empty-revert case end-to-end.
- Oracle staleness and sequencer failure for `RewardSwapHelper` were verified by code inspection only; no adversarial Chainlink feed state was injected.
- The selector guarantee claim was not independently verified by exhaustive enumeration.

---

## 9. Proposed Patches

### P-01 — Fix B-01: propagate empty-revert in `_realizeLiquidity`

Three-part change: add error definition, add import, fix guard.

```diff
--- a/src/strategies/usdc-lending/controller/StrategyStorageLayout.sol
+++ b/src/strategies/usdc-lending/controller/StrategyStorageLayout.sol
@@ -83,6 +83,7 @@ error ZeroAmount();
 error InsufficientBalance();
 error ScoringDelegateFailed();
+error RealizeLiquidityFailed();
 error PlanAlreadyActive();
```

```diff
--- a/src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol
+++ b/src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol
@@ -17,1 +17,1 @@
-import { StrategyStorageLayout, Unauthorized, Frozen, InvalidAdapter, ZeroAddress, InvalidAsset, AssetMismatch, AdapterFlaggedIncrement, InvalidInput, RebalanceCooldown, InsufficientAdapters, MoveTooSmall, GateNotMet, NoCashInvariant, Overflow, DepositsDisabled, DeployIdleCooldown, BootstrapIdleTooHigh, DurationTooLong, BackfillTooLarge, QueryFailed, DepositModeNotSet, WeightsSumInvalid, MinAdaptersTooLow, RiskScoreTooHigh, BootstrapInactive, ZeroAmount, InsufficientBalance, ScoringDelegateFailed, DegradedViews, InvalidModule, ParamOutOfRange } from "./StrategyStorageLayout.sol";
+import { StrategyStorageLayout, Unauthorized, Frozen, InvalidAdapter, ZeroAddress, InvalidAsset, AssetMismatch, AdapterFlaggedIncrement, InvalidInput, RebalanceCooldown, InsufficientAdapters, MoveTooSmall, GateNotMet, NoCashInvariant, Overflow, DepositsDisabled, DeployIdleCooldown, BootstrapIdleTooHigh, DurationTooLong, BackfillTooLarge, QueryFailed, DepositModeNotSet, WeightsSumInvalid, MinAdaptersTooLow, RiskScoreTooHigh, BootstrapInactive, ZeroAmount, InsufficientBalance, ScoringDelegateFailed, DegradedViews, InvalidModule, ParamOutOfRange, RealizeLiquidityFailed } from "./StrategyStorageLayout.sol";
```

```diff
--- a/src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol
+++ b/src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol
@@ -573,6 +573,9 @@ function _realizeLiquidity(uint256 amountNeeded) internal {
     function _realizeLiquidity(uint256 amountNeeded) internal {
         (bool ok, bytes memory ret) = adapterOpsModule.delegatecall(
             abi.encodeWithSelector(REALIZE_LIQUIDITY_SEL, amountNeeded)
         );
-        if (!ok && ret.length > 0) assembly { revert(add(ret, 0x20), mload(ret)) }
+        if (!ok) {
+            if (ret.length > 0) { assembly { revert(add(ret, 0x20), mload(ret)) } }
+            else revert RealizeLiquidityFailed();
+        }
     }
```

**Regression required:** Inject a mock adapter whose `withdraw` call reverts with no data. Verify that two-arg `withdraw(amount, receiver)` now reverts `RealizeLiquidityFailed` rather than silently returning `withdrawn = 0`.

---

### P-02 — Fix B-05: correct slippage cap documentation in RewardSwapHelper

```diff
--- a/src/strategies/usdc-lending/swap/RewardSwapHelper.sol
+++ b/src/strategies/usdc-lending/swap/RewardSwapHelper.sol
@@ -52,7 +52,7 @@ contract RewardSwapHelper is AccessControl, ReentrancyGuard {
 ///      MEV defenses:
 ///        - Chainlink price as anchor (not pool spot) for minOut calculation
-///        - Configurable slippage cap per reward token (max 1000 bps = 10%)
+///        - Configurable slippage cap per reward token (max 500 bps = 5%)
 ///        - Stale oracle check (per-token configurable maxFeedAgeSec)
 
@@ -108,7 +108,7 @@ struct RewardConfig {
         bytes   uniswapV3Path;       // ABI-encoded path: rewardToken → ... → output asset
         bytes   camelotV3Path;       // fallback path (empty bytes = disabled)
-        uint16  slippageBps;         // 100 = 1%; max 1000 (10%)
+        uint16  slippageBps;         // 100 = 1%; max 500 (5%)
         bool    enabled;
```

---

## 10. Summary

| ID | Severity | File | Line | Title | Patch |
|----|----------|------|------|-------|-------|
| B-01 | **Medium** | `UsdcLendingStrategy.sol` | 577 | `_realizeLiquidity` silently swallows empty-revert — two-arg withdraw delivers silent partial fill | P-01 |
| B-02 | Low | `StrategyRebalancePlanModule.sol` | 565, 572 | `require(ok)` in record helpers kills entire rebalance step on sub-delegatecall failure | Emit instead of require |
| B-03 | Low | `UsdcLendingStrategy.sol` | 842 | `safetyOverflowModule_addr == address(0)` silently returns "not degraded" | Guard recommendation |
| B-04 | Low | `StrategySettingsModule.sol` | 421 | `setWithdrawalLockSeconds` unbounded, no finalization guard | Bound recommendation |
| B-05 | Low | `RewardSwapHelper.sol` | 54, 110 | Slippage cap comments claim 1000 bps; enforcement is 500 bps | P-02 |
| B-06 | Info | `RewardSwapHelper.sol` | 507 | `rescueERC20` error name `NotEnabled` semantically inverted | Rename error |
| B-07 | Info | `UsdcLendingStrategy.sol` | 1044–1052 | Fallback OOG masking — acknowledged in source, no security impact | None |

**Non-fork test result: 2797 passed, 8 fork-env-gated failures (not logic failures), 11 skipped, across 203 suites. Exit code 0.**

**19 live-fork matrix cases are UNEXECUTED. All fork tests requiring `ARBITRUM_RPC_URL` or `SOURCE_STRATEGY` env vars are concrete unexecuted checks, not passes. This report does not claim audit completion.**

---

*Session B complete. Candidate manifest `5a989edd92063fcfef12f9a1daf85481f82b471c5f84b778bfd4f085232225a1`. Core source pin `9a9d120709de99a6216e9fe75d36e9ffdcb1a4d9`.*
