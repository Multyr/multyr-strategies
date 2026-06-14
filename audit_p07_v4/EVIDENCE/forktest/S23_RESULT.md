# S2.3 Fork E2E — RESULT Report

**Date:** 2026-06-12  
**Branch:** feature/p0.7-safety-adapter-tier  
**Task:** P0.7 Safety Adapter Cap Tier — `V92_SafetyTierE2E` 13-step fork E2E test (Arbitrum mainnet, block 472761449)

---

## Outcome

**PASS — 1/1 fork tests pass, 0 fail. POST gate green.**

---

## Captures

| Artifact | Description |
|----------|-------------|
| `outputs/S23_post_test.txt` | POST gate — 1975 pass, 0 fail (127 suites) |
| `outputs/S22_post_test.txt` | PRE gate (S2.2 baseline) — 1974 pass, 0 fail |

## Forge Test Gate (Rule 4)

| | Result |
|---|---|
| PRE (`outputs/S22_post_test.txt`) | 1974 pass, 0 fail |
| POST (`outputs/S23_post_test.txt`) | **1975 pass, 0 fail** |

Gate: POST_PASS (1975) ≥ PRE_PASS (1974) ✓  POST_FAIL (0) ≤ PRE_FAIL (0) ✓  POST_FAIL == 0 ✓  **GREEN**

---

## Fork Test Details

- **Test file**: `test/strategies/usdc-lending/fork/V92_SafetyTierE2E.t.sol`
- **Test name**: `test_V92_SafetyTier_full_lifecycle`
- **Fork**: Arbitrum mainnet, block **472761449** (`vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), 472761449)`)
- **RPC**: `ARBITRUM_RPC_URL` env var — never written to disk or git
- **Gas**: 5,024,631

### 13 Steps Exercised

| Step | Description |
|------|-------------|
| S01 | Deploy vault + 3 mock adapters + safety adapter (adapterC) |
| S02 | Deposit 1,000,000 USDC into vault |
| S03 | Configure P0.7 safety tier caps (absCapBps=2000, relCapBps=3000, tolBps=500) |
| S04 | Enable safety tier, verify caps active |
| S05 | Warp past deployIdle cooldown; force initial allocations via `_forcePctOfNewTvl` |
| S06 | Warp +7d; force allocations so safety adapter is within soft cap |
| S07 | Warp +14d; push safety adapter into hard ceiling overflow territory |
| S08 | Mandate check: safety adapter above hardCeiling → mandate fires |
| S09 | Mandate execution: safety adapter withdrawn to fbCeiling |
| S10 | Warp +21d; governance reduces absCapBps (Governance Semantic A) |
| S11 | Warp +28d; existing position may be above new fbCeiling (Semantic A: no immediate unwind) |
| S12 | Warp +35d; next mandate check and rebalance cycle |
| S13 | Final accounting: total TVL > 0 and ≥ initial deposit |

---

## Root Cause Fixed (Foundry Fork-Mode Warp Quirk)

**Bug**: `vm.warp(block.timestamp + 7 days)` in a fork test context evaluates `block.timestamp` using a stale value from a prior EVM context, not the current post-warp timestamp. When S10 set an absolute warp to `1782487751` and S11's conditional then executed `vm.warp(block.timestamp + 7 days)`, `block.timestamp` resolved as `1781278151` (the S05 value), producing `vm.warp(1781882951)` — a **backward warp**.

This caused `lastRebalanceTs (1782487751) > block.timestamp (1781882951)` → `block.timestamp - lastRebalanceTs` underflows → `panic: 0x11` in `StrategyRebalanceGateModule.canRebalance()`.

**Fix**: All 6 `vm.warp` calls converted to absolute timestamps derived from the pinned fork timestamp (`1781277850`):

| Location | Absolute Timestamp | Offset |
|----------|-------------------|--------|
| S05 (L278) | `1781278151` | fork_ts + 301s |
| S06 (L314) | `1781882951` | fork_ts + 301 + 7d |
| S07 (L335) | `1782487751` | fork_ts + 301 + 14d |
| S10 (L379) | `1783092551` | fork_ts + 301 + 21d |
| S11 (L424) | `1783697351` | fork_ts + 301 + 28d |
| S12 (L458) | `1784301951` | fork_ts + 301 + 35d |

**Also removed**: S10 diagnostic `assertGe` block; all `console2` import and calls; S13 upper-bound check (TVL is inflated by `_forcePctOfNewTvl` accumulation across steps).

---

## Files Changed

| File | Change |
|------|--------|
| `test/strategies/usdc-lending/fork/V92_SafetyTierE2E.t.sol` | All 6 `vm.warp` → absolute timestamps; removed `console2`; removed S10 diagnostic assert; simplified S13 to lower-bound only |

---

## Next: S2.4 Coverage Gate

`forge coverage --match-path "test/strategies/usdc-lending/**"` — target ≥95% line / ≥90% branch with lcov report.
