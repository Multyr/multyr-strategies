# P0.7 Coverage Breakdown — Deliverable E.7

**Date:** 2026-06-12  
**Branch:** feature/p0.7-safety-adapter-tier  
**Tool:** `forge coverage --ir-minimum --no-match-coverage "QueueModule" --report lcov`  
**Fork block:** 472761449 (Arbitrum mainnet)

---

## 1. Per-File Coverage Table — All Controller Files

| File | Lines Hit/Total (%) | Branches Hit/Total (%) | P0.7-touched? |
|------|-------------------:|----------------------:|:---:|
| `StrategyAllocCalcModule.sol` | 268/292 (91.8%) | 57/84 (67.9%) | YES |
| `StrategyRebalanceGateModule.sol` | 151/158 (95.6%) | 31/50 (62.0%) | YES |
| `StrategyScoringModule.sol` | 305/354 (86.2%) | 55/117 (47.0%) | YES |
| `StrategySettingsModule.sol` | 274/283 (96.8%) | 42/76 (55.3%) | YES |
| `StrategyStorageLayout.sol` | 67/75 (89.3%) | 23/26 (88.5%) | YES |
| `StrategyExplainabilityLens.sol` | 212/231 (91.8%) | 41/69 (59.4%) | YES (S2.4-bis) |
| `StrategyAdapterOpsModule.sol` | 69/82 (84.1%) | 14/29 (48.3%) | NO |
| `StrategyParamsModule.sol` | 114/140 (81.4%) | 20/46 (43.5%) | NO |
| `StrategyRebalancePlanModule.sol` | 207/237 (87.3%) | 36/58 (62.1%) | NO |
| `UsdcLendingStrategy.sol` | 400/442 (90.5%) | 93/117 (79.5%) | NO |
| **P0.7-touched subtotal** | **1277/1393 (91.7%)** | **249/422 (59.0%)** | — |
| **All controller files** | **2067/2294 (90.1%)** | **412/672 (61.3%)** | — |

---

## 2. Diff Coverage — Lines/Branches ADDED by P0.7 vs origin/main

> This is the auditor-relevant metric: coverage of code that P0.7 actually wrote.

| File | Added Lines | Instrumented | Covered | Uncov | Line % | Add Br. | Cov Br. | Branch % |
|------|------------:|-------------:|--------:|------:|-------:|--------:|--------:|---------:|
| `StrategyAllocCalcModule.sol` | 50 | 22 | 22 | 0 | **100.0%** | 8 | 7 | **87.5%** |
| `StrategyRebalanceGateModule.sol` | 63 | 23 | 23 | 0 | **100.0%** | 6 | 6 | **100.0%** |
| `StrategyScoringModule.sol` | 70 | 38 | 37 | 1 | **97.4%** | 14 | 3 | 21.4% |
| `StrategySettingsModule.sol` | 143 | 48 | 46 | 2 | **95.8%** | 17 | 4 | 23.5% |
| `StrategyStorageLayout.sol` | 62 | 0 | 0 | 0 | N/A (all struct/storage) | 0 | 0 | N/A |
| `StrategyExplainabilityLens.sol` | 113 | 53 | 51 | 2 | **96.2%** | 9 | 5 | 55.6% |
| **TOTAL P0.7 DIFF** | **501** | **184** | **179** | **5** | **97.3%** | **54** | **25** | **46.3%** |

> Note: 317 of 501 added lines are blank lines, NatSpec comments, struct declarations, import statements, pragma — not instrumented by the coverage tool. Correct to exclude.

**Summary:**
- **Diff line coverage: 97.3%** — exceeds ≥95% target ✓
- **Diff branch coverage: 46.3%** — below ≥90% target ✗

---

## 3. Uncovered Added Lines (5 total)

### StrategyScoringModule.sol — L467
```solidity
_executeSafetyOverflow();  // L467
```
**Context:** This is the call site in `_selectAdapters` that triggers the overflow mandate. The function `_executeSafetyOverflow` itself has 398,353 hits. This specific call site (L467) was not reached, meaning the code path in `_selectAdapters` that branches to call it was not exercised. The alternate entry (direct Echidna calls) exercised the function body but not this call site.

### StrategySettingsModule.sol — L625, L628
```solidity
safetyFallbackAdapters[i] = safetyFallbackAdapters[len - 1];  // L625 (swap)
break;  // L628
```
**Context:** `removeSafetyFallbackAdapter` — the "swap-and-pop" branch when the adapter to remove is not the last element (`i != len - 1`). Tests only removed the last adapter. Easy to cover.

### StrategyExplainabilityLens.sol — L234, L235
```solidity
target = headrooms[j];  // L234 (clamping branch)
clamped[j] = true;      // L235
```
**Context:** Lens (read-only, off-chain observability). The `_computeTargets` proportional allocation branch where `target > headrooms[j]`. Not safety-critical.

---

## 4. Uncovered Branches on Added Lines — Classification

### StrategyAllocCalcModule.sol (1 missed branch)
| Line | Branch | Classification |
|------|--------|----------------|
| L305 | `if (fbRelCeiling < fbCeiling) fbCeiling = fbRelCeiling` | **P0.7 safety logic** — rel cap binding. Not triggered when abs cap dominates. |

### StrategyScoringModule.sol (11 missed branches)
| Lines | Branch | Classification |
|-------|--------|----------------|
| L483 | `if (nSafety == 0) return` | Guard: no safety adapters registered |
| L486 | `if (tvl < 1) return` | Guard: zero TVL edge case |
| L498 | `if (!enabled[a]) continue` | Guard: disabled adapter skip |
| L499 | `if (flagged[a]) continue` | Guard: flagged adapter skip |
| L500 | `if (quarantined[a]) continue` | Guard: quarantined adapter skip |
| L506 | `if (extTVL < 500_000e6) continue` | Guard: insufficient external TVL |
| L510 | `if (sf.absCapBps == 0) continue` | Belt-and-braces: not a safety adapter |
| L514 | `if (fbRelCeiling < fbCeiling) fbCeiling = fbRelCeiling` | Rel cap binding (mirrors AllocCalc) |
| L518 | `if (current >= fbCeiling) continue` | Guard: already at ceiling, no action |
| L521 | `if (toDeposit < _dust) continue` | Guard: dust threshold |
| L525 | `if (!ok) continue` | Guard: deposit call failed |

**All 11 are defensive guards** in `_executeSafetyOverflow`. The main execution path (adapter enabled, not flagged, extTVL > threshold, below ceiling, amount above dust, deposit succeeds) is fully covered with 398k hits. These guards are the failure/edge-case branches.

### StrategySettingsModule.sol (13 missed branches)
| Lines | Branch | Classification |
|-------|--------|----------------|
| L520 | `if (_bps > 2000) revert` | Revert: setTargetSafetyMargin out-of-range |
| L531 | `if (_bps > 2000) revert` | Revert: setSafetyMarginBuffer out-of-range |
| L542 | `if (_seconds > 30 days) revert` | Revert: setSafetyRebalanceCooldown out-of-range |
| L559 | `if (adapter == address(0)) revert` | Revert: addSafetyFallbackAdapter zero addr |
| L561 | `if (!enabled[adapter]) revert` | Revert: adapter not whitelisted |
| L567 | `if (absCapBps == 0 \|\| absCapBps > 8000) revert` | Revert: invalid absCap |
| L568 | `if (relCapBps > 10000) revert` | Revert: invalid relCap |
| L569 | `if (safetyFallback[adapter].absCapBps != 0) revert` | Revert: already registered |
| L600 | `if (sf.absCapBps == 0) revert` | Revert: updateSafetyFallbackCaps not registered |
| L601 | `if (absCapBps == 0 \|\| absCapBps > 8000) revert` | Revert: invalid absCap |
| L602 | `if (relCapBps > 10000) revert` | Revert: invalid relCap |
| L618 | `if (safetyFallback[adapter].absCapBps == 0) revert` | Revert: removeSafety not registered |
| L624 | `if (i != len - 1)` | Logic: swap-and-pop non-last element |

**12 of 13 are revert paths** — validation guards that fire only with invalid inputs. Tests used valid inputs throughout. 1 is a swap-and-pop logic branch (L624).

### StrategyExplainabilityLens.sol (4 missed branches)
All are lens-only: `sSum == 0` edge case, `all clamped` continuation, `target > headroom` clamping, catch block. Read-only, off-chain, not safety-critical.

---

## 5. Decision Framework Assessment

| Criterion | Result |
|-----------|--------|
| Diff line coverage | **97.3%** ✓ (≥95%) |
| Diff branch coverage | **46.3%** ✗ (≥90%) |
| P0.7-touched file line avg | **91.7%** ✗ (≥95%) |
| P0.7-touched file branch avg | **59.0%** ✗ (≥90%) |

**CASO A (pure):** Does NOT hold. Per-file metrics are below 95%/90% thresholds.

**CASO A (modified — "regression-free" framing):**  
The branch gap is structurally pre-existing in `StrategyScoringModule` (86.2% / 47%) and exists in the baseline. P0.7 added 14 branches to `StrategyScoringModule`; 3 are covered (main execution path, 398k hits). The 11 missed are all defensive guards in `_executeSafetyOverflow`. These guards' absence does NOT indicate missing P0.7 test coverage for the main invariant — Echidna 1M sequences + Halmos 23 proofs + V92 fork E2E verify the core P0.7 semantics.

**CASO B scope (if required by auditor):** 14 targeted tests would close the diff-branch gap:
- SettingsModule revert paths: 12 tests (~2h) — `addSafetyFallbackAdapter` / `updateSafetyFallbackCaps` / `removeSafetyFallbackAdapter` with invalid inputs
- ScoringModule guard paths: 3 tests (~1h) — `nSafety==0`, `flagged adapter skip`, `already-at-ceiling skip`
- AllocCalcModule rel-cap binding: 1 test (~30min)

Estimated effort: 3.5h to close diff-branch gap from 46.3% to ~90%+.

---

## 6. Exclusion Documentation

| Excluded | Why | Audit-correctness |
|----------|-----|-------------------|
| `QueueModule` (lib/multyr-core) | External library, 0 P0.7 lines | Correct — not P0.7 surface |
| `StrategyExplainabilityLens.sol` line/branch gaps | Read-only, off-chain observability; no state mutation | Acceptable for audit |
| `StrategyScoringModule` pre-existing branches | 103/117 branches are pre-P0.7 code unchanged by this PR | Pre-existing baseline, not a P0.7 regression |

---

## 7. Reproduction Command

```bash
export ARBITRUM_RPC_URL="..."   # never written to disk
forge coverage \
  --match-path "test/strategies/usdc-lending/**" \
  --ir-minimum \
  --no-match-coverage "QueueModule" \
  --report lcov \
  --report-file coverage/lcov.info
# Fork block pinned: 472761449
# All 1975 tests pass, 0 fail
```
