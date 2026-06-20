# Wave 1 + Wave 2 Audit-Prep Summary

Executive summary for external auditor onboarding.

**Repository**: `multyr-strategies` (`feature/v10.0-storage-initialize`)
**Audit target**: USDC Lending Strategy V10 (formerly V9.2 + P0.7)
**Wave 1 period**: 2026-05 through 2026-06-10
**Wave 2 period**: 2026-06-10 through 2026-06-20

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
| 1 | H-01 | CRITICAL | Morpho Blue `id` parameter wrong type — deposits silently failed | `b7f3c...` |
| 2 | H-02 | CRITICAL | Euler withdrawAll unsafe — wrong `maxAmount` arg, potential revert | `c1e4d...` |
| 3 | H-03 | CRITICAL | `positionAssets` used planned not actual deposited amount | `a3f8e...` |
| 4 | H-04 | CRITICAL | Venus `accrueInterest` missing before NAV reads | `292ac...` |
| 5 | HIGH-R1 | HIGH | RewardSwapHelper slippage cap 10% → 5% | `R12 commit` |
| 6 | HIGH-R2 | HIGH | `swapToUSDC()` missing KEEPER_ROLE access control | `R12 commit` |
| 7 | HIGH-V1 | HIGH | Venus NAV: `accrueVenusInterest` keeper helper | `292ac...` |
| 8 | HIGH-C4 | HIGH | Venus `BLOCKS_PER_YEAR` Arbitrum-hardcoded → per-chain configurable | `c04 commit` |
| 9 | MED-01 | MEDIUM | StrategyAllocCalcModule residual redistribution drift | `ac commit` |
| 10 | MED-F1 | MEDIUM | `deployIdle` used planned not actual (same class as H-03) | `f-scoring-01` |
| 11 | LENS-1 | MEDIUM | StrategyConfigLib single source of truth (Lens x3 de-duplication) | `lens commit` |
| 12 | LENS-2 | MEDIUM | `StrategyExplainabilityLens` external view parity with storage | `lens commit` |
| 13 | LENS-3 | LOW | Lens parameter consistency across all view functions | `lens commit` |
| 14 | HALMOS-P1..P6 | LOW | Halmos symbolic proofs: 23 properties, P6 bound tightened | `halmos commits` |
| 15 | ECHIDNA-SETUP | LOW | Echidna `testMode: property` explicit + 15 invariant expansion | `d10378f` |

---

## Wave 2: 8 housekeeping items

| # | ID | Category | Description | Commit |
|---|---|---|---|---|
| 1 | F-SIZE-01 | Refactor | StrategyScoringModule EIP-170 refactor (24,426 → 21,528 B) | `f-size-01` |
| 2 | F-SIZE-02 | Refactor | UsdcMultiLendingVault EIP-170 refactor (24,048 → 21,299 B) | `331143e` |
| 3 | F-SCORING-INV2 | Bug fix | adapterMaxExposureBps ignored at T1 TVL — fixed at all tiers | `e882bcf` |
| 4 | HALMOS-P6 | Fix | `tolBps <= BPS` → `tolBps <= 2000` (setter gate match) | `d4ab760` |
| 5 | ECHIDNA-YAML | Config | `testMode: property` added to both yaml configs | `d10378f` |
| 6 | ECHIDNA-1M | Evidence | 1M baseline run completed — 15/15 invariants passing | `51447fa` |
| 7 | PRAGMA-PIN | Hygiene | All floating `^0.8.28`/`^0.8.24` → exact `0.8.28` (76 files) | `51447fa` |
| 8 | FOUNDRY-TOML | Config | `evm_version=cancun`, `bytecode_hash=none`, `cbor_metadata=false` | `4c0e5ba` |

Bonus discoveries (no code action required):
- Compound III confirmed multichain-safe (per-second rates, no block.number)
- Venus blocksPerYear already configurable post C-04

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
- Venus `blocksPerYear` per-chain configurable (post C-04 fix)
- Compound III: per-second rates, chain-agnostic by design
- Chain configs: `src/strategies/usdc-lending/config/UsdcLendingConfig{Chain}.sol`

---

## What is NOT in scope for this audit

- `src/strategies/multiply/` — USDC Stable Multiply (separate repo, not yet audit-ready)
- `src/strategies/pt-multiply/` — Pendle PT Multiply (separate repo)
- Lib submodules: `multyr-core`, `multyr-periphery` (separate audits)
- Fork tests (listed as P0 open item per CLAUDE.md — 0 fork tests present)

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
