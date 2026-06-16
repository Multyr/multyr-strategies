# P0.7 Coverage — Exclusions and Exemptions

**Date:** 2026-06-12
**Branch:** feature/p0.7-safety-adapter-tier

---

## Forge Coverage Exclusions

The following are excluded from forge coverage reporting via `--no-match-coverage`
or documented here as audit-accepted exemptions.

---

### 1. `QueueModule` (lib/multyr-core)

**Exclusion flag:** `--no-match-coverage "QueueModule"`

**Reason:** External library under `lib/multyr-core`. Contains zero P0.7-added
lines. The module is maintained and versioned separately as part of `multyr-core v1.0.0`.
Including it in coverage reporting would inflate the denominator without reflecting
P0.7 test quality.

**Audit-correctness:** This is the standard approach for vendored external dependencies.
`multyr-core` has its own test suite.

---

### 2. `StrategyExplainabilityLens.sol` — 4 Branch Gaps

**Status:** Accepted as off-chain lens exemption.

**Location:** `src/strategies/usdc-lending/lens/StrategyExplainabilityLens.sol`

**Uncovered branches (4):**

| Line | Branch | Reason |
|------|--------|--------|
| `_computeTargets` | `sSum == 0` edge case | All adapters with score=0 — degenerate state unreachable in normal operation |
| `_computeTargets` | `all clamped` continuation | Requires all adapters to hit their headroom simultaneously — not a P0.7 execution path |
| `_computeTargets` | `target > headrooms[j]` clamping | Triggered only when proportional allocation exceeds cap; rare under normal scoring distribution |
| `_runPhase2Alloc` | `catch` block | Outer try/catch — requires an internal function to revert, which is architecturally prevented |

**Audit-correctness:** `StrategyExplainabilityLens` is a read-only, off-chain
observability tool. It has no state mutation, no access control, and is never called
by any on-chain keeper or rebalance flow. Its outputs are informational. Branch
gaps in lens functions do not affect protocol safety.

**Coverage note:** The lens itself underwent a significant refactor in S2.4
(commit d59613f) to fix a Yul stack-too-deep under `--ir-minimum` coverage mode.
After refactor: 96.2% line coverage, 55.6% branch coverage on P0.7-added lens code.
The 4 remaining branch gaps are the degenerate/edge-case paths documented above.

---

## Forge Coverage Run Command

```bash
forge coverage \
  --match-path "test/strategies/usdc-lending/**" \
  --ir-minimum \
  --no-match-coverage "QueueModule" \
  --report lcov \
  --report-file coverage/lcov.info
```

- `--ir-minimum`: required for Yul stack depth (QueueModule + lens refactor)
- `--no-match-coverage "QueueModule"`: excludes lib/multyr-core from output counts
- Fork RPC: `ARBITRUM_RPC_URL` env var — never written to disk or committed to git
- Fork block pinned: 472761449 (Arbitrum mainnet)

---

## Summary

| Exclusion | Type | Audit-acceptable? |
|-----------|------|:-----------------:|
| `QueueModule` | External lib | Yes |
| Lens 4 branches | Off-chain observability edge cases | Yes |
| `_executeSafetyOverflow` defensive guards | Belt-and-braces / failure recovery | Documented in `COVERAGE_UNREACHABLE.md` |
