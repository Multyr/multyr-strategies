# Wave 1 + Wave 2 Audit-Prep Summary

Executive summary for external auditor onboarding.

**Repository**: `multyr-strategies` (`feature/v10.0-storage-initialize`)
**Audit target**: USDC Lending Strategy V10 (formerly V9.2 + P0.7)
**Wave 1 period**: 2026-06-18 (single intensive sprint)
**Wave 2 period**: 2026-06-18 through 2026-06-20 (housekeeping + Echidna 1M evidence)

---

## Test gate evolution

| Milestone | Tests passing | Tests failing | Skipped |
|---|---:|---:|---:|
| Pre-Wave 1 baseline | 2,109 | 0 | 1 |
| Post-Wave 1 (15 fixes) | 2,326 | 0 | 1 |
| Post-F-SIZE-01 | 2,336 | 0 | 1 |
| Post-F-SIZE-02 | 2,350 | 0 | 1 |
| Post-F-SCORING-INV2 (Wave 2 close) | **2,354** | **0** | **1** |

Total tests added across Wave 1+2: **+245** (all net-new coverage, 0 removed).

---

## Wave 1: 15 fixes

| # | ID | Severity | Description | Commit |
|---|---|---|---|---|
| 1 | C-01 | LOW (reclassified) | StrategyStorageLayout slot doctrine — forge inspect confirmed slot 78 correct; doc comment was wrong | `2b37659` |
| 2 | C-02 | CRITICAL | StrategyScoringModule `enabled` shadowing — 3 functions renamed to `enabledList` | `76d1b72` |
| 3 | C-03 | CRITICAL | StrategySettingsModule `setRebalanceParams` bounds + sentinel preservation (`adapterMaxExposureBps==0` = no global ceiling) | `ef74327` |
| 4 | C-04 | CRITICAL | Venus `BLOCKS_PER_YEAR` Arbitrum-hardcoded → `blocksPerYear` configurable per-chain (multichain enabler) | `d1210df` |
| 5 | H-A-01 | HIGH | Aave V3 `withdrawableAssets` — `IERC20(asset).balanceOf(aToken)` not pool proxy (Phase F1) | `2965b36` |
| 6 | HIGH-D-01 | HIGH | Dolomite proportional principal reduction (share-based accounting) | `098bb2b` |
| 7 | HIGH-E-01 | HIGH | Euler `safeApprove` → `forceApprove` for Permit2 (idempotent re-init) | `ffd0fcf` |
| 8 | HIGH-V1 | HIGH | Venus NAV: `accrueVenusInterest()` keeper helper + view semantics preserved (Option B) | `292ac27` |
| 9 | HIGH-R1+R2 | HIGH | RewardSwapHelper slippage 1000 → 500 bps + `KEEPER_ROLE` gate on `swapToUSDC()` | `c329955` |
| 10 | H-03 | HIGH | StrategyRebalancePlanModule `positionAssets += actualDeposited` (balance-delta pattern) | `943bfe7` |
| 11 | F-SCORING-01 | HIGH | StrategyScoringModule 3 sites (`bestEffort` + `strict` + safety overflow) — `actualDeposited` pattern | `c15fd39` |
| 12 | AllocCalc residual | HIGH | `_computeTargets` sub-dust residual redistribution (prevent systematic drift) | `97b7781` |
| 13 | Scoring overflow margin | HIGH | `_executeSafetyOverflow` `fbCeilingNet = fbCeiling * safetyMult / 10_000` (P0.7 yield buffer) | `d6e5e56` |
| 14 | Lens x3 | HIGH | `StrategyConfigLib` single source of truth (10 constants + 2 pure helpers) + Lens deduplication | `9c65889` |
| 15 | Fork H-1 + H-2 | HIGH | Oracle independence test (USDC-native vault confirmed) + S13 two-sided conservation | `c6c716b` |

---

## Wave 2: 8 housekeeping items

| # | ID | Category | Description | Commit |
|---|---|---|---|---|
| 1 | F-SIZE-01 | Refactor | StrategyScoringModule EIP-170 refactor (24,426 → 21,528 B) | `7667722` |
| 2 | F-SIZE-02 | Refactor | UsdcMultiLendingVault EIP-170 refactor (24,048 → 21,299 B) | `331143e` |
| 3 | F-SCORING-INV2 | Bug fix | `adapterMaxExposureBps` ignored at T1 TVL — enforced at all tiers | `e882bcf` |
| 4 | HALMOS-P6 | Fix | `tolBps <= BPS` → `tolBps <= 2000` (setter gate match) | `d4ab760` |
| 5 | ECHIDNA-YAML | Config | `testMode: property` added to both yaml configs | `d10378f` |
| 6 | ECHIDNA-1M | Evidence | 1M baseline run — 15/15 invariants passing, 0 counterexamples | `51447fa` |
| 7 | PRAGMA-PIN | Hygiene | All floating `^0.8.28`/`^0.8.24` → exact `0.8.28` (76 files) | `51447fa` |
| 8 | FOUNDRY-TOML | Config | `evm_version=cancun`, `bytecode_hash=none`, `cbor_metadata=false` | `4c0e5ba` |

Bonus discoveries (no code action required):
- Compound III confirmed multichain-safe (per-second rates, no `block.number`)
- Venus `blocksPerYear` already configurable post C-04

---

## Fork tests present

The following fork tests exist in this repository and call `vm.createSelectFork` against real Arbitrum state:

- `test/strategies/usdc-lending/fork/V92_SafetyTierE2E.t.sol` — 13-step P0.7 E2E scenario (Chainlink keeper, Safety Tier mandate, rebalance gate)
- `test/fork_pre/v92/V92_AdversarialScenarios.t.sol` — 4 H-01-* adversarial scenarios (oracle independence, USDC-native vault confirmed)
- `test/fork_pre/adapters/` — per-adapter fork deposit + withdraw tests (Aave, Comet, Dolomite, Euler, Fluid, Morpho, Venus) — env-var gated (`ARBITRUM_RPC_URL`)

Wave 1 items H-01 + H-02 strengthened oracle-independence and S13 two-sided conservation assertions (commit `c6c716b`).

Note: fork tests in `test/fork_pre/` are env-var gated and do not run in CI without `ARBITRUM_RPC_URL` set. The "0 fork tests" note in `CLAUDE.md` refers to the *multiply* strategy (`src/strategies/multiply/`), not the USDC Lending strategy in scope for this audit.

---

## Formal verification evidence

### Halmos (symbolic execution)
- **23 properties** verified across 6 test files
- All `check_*` functions: PASS (0 counterexamples)
- See `docs/audit/HALMOS_METHODOLOGY.md`

### Echidna (property-based fuzzing)
- **15 invariants** covering the Safety Adapter Cap Tier (P0.7)
- Baseline: 1,000,860 sequences, ~4 min 18 sec, 0 counterexamples
- See `docs/audit/verification/ECHIDNA_RESULTS_SUMMARY.md` + `ECHIDNA_1M_EVIDENCE.txt`

---

## Contract size status (post Wave 2)

All production contracts within EIP-170 hard limit (24,576 B) and project 1KB-safety rule (23,552 B).

- Previously RED: StrategyScoringModule (24,426 B) → now 21,528 B (GREEN)
- Previously RED: UsdcMultiLendingVault (24,048 B) → now 21,299 B (GREEN)
- Largest deployed: StrategySettingsModule 22,901 B (margin 1,675 B)

Full table: `docs/audit/sizes/CONTRACT_SIZES.md`

---

## Multichain architecture (V10)

V10 storage+initialize refactor enables byte-identical deployment across chains:
- `evm_version = "cancun"` (pinned, Arbitrum One compatible)
- `bytecode_hash = "none"` + `cbor_metadata = false` (reproducible bytecode)
- Venus `blocksPerYear` per-chain configurable (post C-04 fix, commit `d1210df`)
- Compound III: per-second rates, chain-agnostic by design
- Chain configs: `src/strategies/usdc-lending/config/UsdcLendingConfig{Chain}.sol`

---

## What is NOT in scope for this audit

- `src/strategies/multiply/` — USDC Stable Multiply (separate dev repo, not yet audit-ready)
- `src/strategies/pt-multiply/` — Pendle PT Multiply (separate dev repo)
- Lib submodules: `multyr-core`, `multyr-periphery` (separate audits)
- `test/fork_pre/` fork tests — informational only; not in audit scope

---

## Key files for auditors

| File | Purpose |
|---|---|
| `docs/overview.md` | Architecture overview |
| `docs/adapters.md` | Per-adapter specifications |
| `docs/audit-scope.md` | In-scope file list + LOC counts |
| `docs/invariants.md` | Halmos + Echidna formal claims |
| `docs/threat-model.md` | Attack surface analysis |
| `docs/audit/sizes/CONTRACT_SIZES.md` | Bytecode size analysis |
| `docs/audit/verification/ECHIDNA_RESULTS_SUMMARY.md` | Fuzzing evidence |
| `docs/audit/HALMOS_METHODOLOGY.md` | Symbolic proof methodology |
| `outputs/NEW_FINDINGS.md` | Open/resolved finding tracker |
