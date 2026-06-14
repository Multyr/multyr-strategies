# P0.7 Audit Package — Reproduction Instructions

This document provides deterministic reproduction commands for every evidence artefact in `audit_p07_v4/`. All commands assume the auditor has cloned the branch `feature/p0.7-safety-adapter-tier` at the commit hash specified in `R12_AUDIT_TABLE.md` (last entry, HEAD).

## 1. Environment

### Required tooling

| Tool | Version | Purpose |
|---|---|---|
| Foundry | `forge 0.2.0` (1.0+ acceptable) | Solidity compilation, unit tests, coverage, fork tests |
| Solidity | `0.8.24` (pinned in `foundry.toml`) | Source compilation |
| Halmos | `0.3.0+` | Symbolic verification |
| Echidna | `2.2.3+` | Stateful fuzz |
| Python | `3.11+` | Backtest harness |
| Anvil | bundled with Foundry | Fork simulation |
| jq | `1.7+` | JSON inspection (storage layouts) |
| lcov | `2.0+` | Coverage report filtering |

### Installation

```bash
# Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Halmos
pip install halmos

# Echidna
brew install echidna  # macOS
# or download from https://github.com/crytic/echidna/releases for Linux

# Python deps (for backtest)
cd backtest && pip install -r requirements.txt
```

### Environment variables required

```bash
# Arbitrum mainnet archive RPC (required for fork test reproduction)
# Block 472761449 must be retrievable
export ARBITRUM_RPC_URL="https://<your-rpc-provider>/<key>"
export ARBITRUM_ARCHIVE_RPC_URL="${ARBITRUM_RPC_URL}"
```

## 2. Compile

```bash
forge build
```

Expected: clean compile, no warnings beyond pre-existing lib warnings. Bytecode hashes are deterministic given pinned `solc_version = "0.8.24"` and `optimizer_runs = 200`.

## 3. Unit + integration tests

```bash
forge test --no-match-contract "(V92_SafetyTierE2E|V92_AdversarialScenarios)"
```

Expected: **2006 pass, 0 fail** (post-v4 with H-02 negative tests added).

For coverage report:

```bash
forge coverage --ir-minimum \
    --no-match-coverage "(StrategyExplainabilityLens|QueueModule)" \
    --report lcov --report-file coverage/lcov.info
```

## 4. Fork tests (Arbitrum mainnet)

Both fork test contracts run against forked Arbitrum state at the specified block.

### V92_SafetyTierE2E (S2.3 — 13-step lifecycle)

```bash
forge test --match-contract V92_SafetyTierE2E \
    --fork-url $ARBITRUM_RPC_URL \
    --fork-block-number 472761449 \
    -vvv
```

Expected: `1 passed`. Test name: `test_E2E_safety_tier_full_lifecycle`.

### V92_AdversarialScenarios (H-01 — 4 adversarial paths)

```bash
forge test --match-contract V92_AdversarialScenarios \
    --fork-url $ARBITRUM_RPC_URL \
    --fork-block-number 472761449 \
    -vvv
```

Expected: `4 passed`. Test names:
- `test_E2E_governance_pause_mid_rebalance`
- `test_E2E_adapter_quarantine_during_overflow`
- `test_E2E_oracle_deviation_USDC_depeg`
- `test_E2E_failed_adapter_callback`

## 5. Halmos formal verification (S2.1 — 23 proofs)

```bash
FOUNDRY_PROFILE=halmos halmos \
    --match-contract SafetyAdapterCapTier \
    --solver-timeout-assertion 60000 \
    --loop 16 \
    --array-lengths 5,10,15 \
    --json-output test/halmos/results/halmos-evidence.json
```

Expected: **23/23 PASS**. Worst-case proof time observed: 15.82s (fb7500/n6000/tol0). Total wall-clock: <30 min.

Reference: `audit_p07_v4/EVIDENCE/halmos/HALMOS_METHODOLOGY.md` documents the case-split rationale on governance-bounded discrete parameters.

To independently verify the produced JSON:

```bash
jq '.[] | select(.status != "PASS")' test/halmos/results/halmos-evidence.json
# expected: empty (no failures)

jq '. | length' test/halmos/results/halmos-evidence.json
# expected: 23
```

## 6. Echidna stateful fuzz (S2.2 — 1M sequence baseline)

### Smoke run (5 min, CI-grade)

```bash
cd test/echidna
echidna SafetyAdapterTierEchidna.sol --config echidna-smoke.yaml
```

Expected: 50k sequences explored, 12 invariants pass.

### Baseline run (1h+ wall-clock, audit-grade)

```bash
cd test/echidna
echidna SafetyAdapterTierEchidna.sol \
    --config echidna.yaml \
    --output-dir results/baseline \
    > results/baseline/stdout.log 2>&1
```

Expected at termination:
- 1,000,000 sequences explored
- 12/12 invariants PASS, 0 counterexamples
- Corpus saved in `corpus/reproducers/` (shrunk minimised counterexample seeds)
- Coverage % reported in stdout — see `results/baseline/SUMMARY.md` for the post-run summary

### Replay from supplied corpus

The audit package includes the shrunk corpus. Auditor can seed reproduction from it:

```bash
echidna SafetyAdapterTierEchidna.sol \
    --config echidna.yaml \
    --corpus-dir corpus  # uses corpus/reproducers/ as seed
```

This biases exploration toward known-interesting state sequences.

## 7. Storage layout verification

```bash
# For each of the 7 controller modules:
forge inspect StrategySettingsModule:storageLayout | jq . > /tmp/settings_layout.json
forge inspect StrategyRebalancePlanModule:storageLayout | jq . > /tmp/rebalance_plan_layout.json
forge inspect StrategyRebalanceGateModule:storageLayout | jq . > /tmp/rebalance_gate_layout.json
forge inspect StrategyParamsModule:storageLayout | jq . > /tmp/params_layout.json
forge inspect StrategyStorageLayout:storageLayout | jq . > /tmp/storage_layout.json
forge inspect StrategyAllocCalcModule:storageLayout | jq . > /tmp/alloc_calc_layout.json
forge inspect StrategyExplainabilityLens:storageLayout | jq . > /tmp/lens_layout.json
```

Each should reproduce the snapshot in `audit_p07_v4/STORAGE/p07-storage-layout.json`.

Key invariant to verify: **slot 78 packed offsets**:
- `capDriftToleranceBps` at offset 0, 16 bits
- `maxIdleBps` at offset 2 (bytes), 16 bits
- `targetSafetyMarginBps` at offset 4 (bytes), 16 bits
- `mandateRedeployCooldownSeconds` at offset 6 (bytes), 32 bits
- Total: 80 bits used in 256-bit slot

## 8. Backtest reproduction

### Production validation (canonical baseline)

```bash
cd backtest
python src/simulator.py --scenario realistic
```

Reads `config/params.json` with the production-confirmed setpoint:
```json
{
  "mandateRedeployCooldownSeconds": 259200,
  "capDriftToleranceBps": 250,
  "maxIdleBps": 500,
  "targetSafetyMarginBps": 300,
  "safetyFallbackAdapters": ["aave_v3_usdc", "compound_v3_usdc"],
  "fallback_abs_cap_bps": {"aave_v3_usdc": 5000, "compound_v3_usdc": 4000},
  "fallback_rel_cap_bps": {"aave_v3_usdc": 5000, "compound_v3_usdc": 4000}
}
```

Verify config hash matches the snapshot:

```bash
sha256sum config/params.json
# Must match the value in reports_PRODUCTION_FINAL_v92/CONFIG_HASH.txt
```

Expected output in `backtest/reports/`:
- `equity_realistic.csv` — 882 rows, NAV 1.000 → 1.1574
- `PRODUCTION_VALIDATION_iter4.csv` — single-row aggregated metrics
- Metric reconciliation in `audit_p07_v4/BACKTEST/METRIC_METHODOLOGY.md`

### Sensitivity sweeps reproduction

Three sensitivity sweeps are documented and reproducible:

```bash
# Sweep #1: cooldown sensitivity (3/5/7/10/14 days)
python scripts/run_cooldown_sweep.py

# Sweep #2: capDriftToleranceBps sensitivity (150/250/400/600/1000 bps)
python scripts/run_capdrift_sweep.py

# Sweep #3: Dolomite-specific (current/disabled/score_zero/abs_300/500/800/1500 bps)
python scripts/run_dolomite_sweep.py

# Sweep #4: relCap override (100/200/400/800/1000 bps)  [if executed in v4]
python scripts/run_relcap_sweep.py
```

Each writes to `backtest/reports_sensitivity_<topic>/` with consistent structure: `cooldown_<X>/`, `capdrift_<X>bps/`, `dolo_<scenario>/`, plus `COMPARISON_TABLE.md`, `RECOMMENDATION.md`, charts.

Config restoration is automatic via `params.json.bak_<sweep>` backup files. Verify post-run:

```bash
diff config/params.json config/params.json.production_baseline
# expected: identical (sweep restored config cleanly)
```

## 9. R12 commit identity audit

```bash
git log --format='%H | %an <%ae> | %s' \
    origin/main..feature/p0.7-safety-adapter-tier > /tmp/p07-commit-table.txt
```

Each entry must show:
- Author: `multyr-infra <multyr-infra@users.noreply.github.com>`
- No `Co-authored-by:`, `🤖 Generated with Claude Code`, or `<noreply@anthropic.com>` in body

Reference: `audit_p07_v4/SIGNOFF/R12_AUDIT_TABLE.md`.

## 10. Determinism notes

- **Halmos**: deterministic given fixed `--solver-timeout-assertion 60000` and identical Z3 build. Auditor may see microsecond-scale variation in per-proof timings.
- **Echidna**: seeded with `seed: 42` in config — fully deterministic given identical Echidna version + Haskell runtime. Different versions may diverge.
- **Forge tests**: deterministic. Fork tests pinned to block 472761449.
- **Backtest**: deterministic given identical Python version + library versions. `requirements.txt` pins all dependencies.

## 11. Build / dependency snapshot

| Dependency | Version | Source |
|---|---|---|
| `solc` | `0.8.24` | Pinned in `foundry.toml` |
| `openzeppelin-contracts` | per `lib/openzeppelin-contracts` submodule commit | `git submodule status lib/openzeppelin-contracts` |
| `forge-std` | per `lib/forge-std` submodule commit | `git submodule status lib/forge-std` |
| `multyr-core` | per `lib/multyr-core` submodule commit | `git submodule status lib/multyr-core` |

External addresses (Arbitrum mainnet):

| Contract | Address |
|---|---|
| USDC | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |
| Aave V3 Pool | `0x794a61358D6845594F94dc1DB02A252b5b4814aD` |
| Compound V3 Comet (USDC) | `0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf` |
| Whale (test seed source) | `0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7` |

Consolidated in `audit_p07_v4/EXTERNAL_DEPENDENCIES.md`.

## 12. Expected total reproduction wall-clock

| Phase | Time |
|---|---:|
| Compile | 1 min |
| Unit + integration tests (no fork) | 2 min |
| Fork tests (5 total) | 15 min |
| Halmos (23 proofs) | 30 min |
| Echidna smoke (50k) | 5 min |
| Echidna baseline (1M) | 1-3h |
| Storage layout snapshots | 1 min |
| Backtest production validation | 3 min |
| Backtest 4 sweeps reproduction | 15 min |
| **Total deterministic reproduction** | **~2-4h** |

This timing assumes a modern x86_64 workstation with 16+ GB RAM and SSD. Echidna baseline campaign is the dominant cost; smoke run is sufficient for sanity-grade verification.
