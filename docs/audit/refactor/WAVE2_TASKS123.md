*Promoted from outputs/WAVE2_TASKS123_RESULT.md -- Wave 2 closing verification.*

# WAVE2_TASKS123_RESULT — Echidna audit + foundry.toml + Compound III

**Date**: 2026-06-20

---

## TASK 1 — Echidna baseline 1M audit verify

### CRITERION: VALID baseline ✓

The log (`outputs/ECHIDNA_BASELINE_RUN.txt`) contains explicit status lines:
```
[status] tests: 0/15, fuzzing: 11392/1000000
[status] tests: 0/15, fuzzing: 104201/1000000
...
[status] tests: 0/15, fuzzing: 978025/1000000
[Worker 7] Test limit reached. Stopping.
...
[Worker 1] Test limit reached. Stopping.
[status] tests: 0/15, fuzzing: 1000860/1000000
```

**1,000,860 sequences executed** (slight overshoot due to 8-worker parallelism stopping
at different points). All 8 workers hit `Test limit reached. Stopping.`

### Timing

- Launch: 2026-06-20 19:54:18 CEST
- Completion: 2026-06-20 19:58:36 CEST
- Duration: **~4 min 18 sec** (plausible: smoke 50K took 22s → 1M at 8W ≈ 22 × 20 / 2 = 220s)

### Invariant results (15/15)

```
echidna_I01_normal_uses_normal_ceiling: passing
echidna_I02_safety_below_fb_no_mandate: passing
echidna_I03a_hard_ceiling_ge_fb_ceiling: passing
echidna_I03b_overflow_within_hard_ceiling_at_deposit: passing
echidna_I03c_above_hard_implies_above_soft: passing
echidna_I04a_overflow_respects_ceiling_at_deposit: passing
echidna_I04b_post_mandate_within_soft_ceiling: passing
echidna_I05_overflow_no_overdraft: passing
echidna_I06_accounting_conserved: passing
echidna_I07_fbCeiling_le_abs_constituent: passing
echidna_I08_fbCeiling_le_rel_constituent_when_active: passing
echidna_I09_fbCeiling_le_govbound: passing
echidna_I10_preserve_safety_tranche_no_unwind: passing
echidna_I11_mandate_ceiling_monotone: passing
echidna_I12_safety_disabled_equals_legacy: passing
```

- Failures: **0** (counter in status lines shows `tests: 0/15` throughout)
- Corpus: 23 sequences, 1755 unique instructions
- Seed: 1191146323191387670 (reproducible)
- Config: testLimit=1000000, seqLen=200, workers=8, testMode=property

**VERDICT**: VALID full 1M baseline. Audit-grade evidence confirmed.

---

## TASK 2 — foundry.toml deterministic build

### Pre-fix state

`forge config --json` resolved:
- `evm_version`: **prague** (Foundry default — too new for Arbitrum, non-deterministic across Foundry versions)
- `bytecode_hash`: **ipfs** (embeds IPFS hash of metadata → non-deterministic if any source file changes)
- `cbor_metadata`: **True** (appends CBOR metadata trailer → non-deterministic)

### Fix applied

Added to `[profile.default]` and `[profile.halmos]`:
```toml
evm_version = "cancun"     # Arbitrum One supports cancun; explicit pins across Foundry upgrades
bytecode_hash = "none"     # removes IPFS-content-hash from bytecode
cbor_metadata = false      # removes CBOR metadata trailer
```

Post-fix `forge config --json` confirms:
- `evm_version`: cancun ✓
- `bytecode_hash`: none ✓
- `cbor_metadata`: False ✓
- `solc`: 0.8.28 ✓
- `optimizer_runs`: 200 ✓

### Note on evm_version choice

- multyr-core submodule uses `"shanghai"` (conservative)
- Arbitrum One has cancun-level EVM support
- `"cancun"` chosen: enables PUSH0 and transient storage opcodes (the only cancun additions
  relevant to Solidity); still backward-compatible with all our source code
- `"prague"` (prior default) would add opcodes not yet on Arbitrum → deployment risk

### Gate

| | Value |
|---|---|
| PRE pass | 2354 |
| PRE fail | 0 |
| POST pass | 2354 |
| POST fail | 0 |
| Gate | GREEN |

POST capture: `outputs/FOUNDRY_TOML_post_test.txt`

---

## TASK 3 — Compound III multichain safety audit

### Scan performed

```
grep -nE "block\.number|BLOCKS_PER_YEAR|blocksPer|supplyRatePerBlock|getSupplyRate|supplyRatePerSecond"
    src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol
```

### Findings

| Check | Result |
|---|---|
| `block.number` usage | **NONE** |
| `BLOCKS_PER_YEAR` constant | **NONE** |
| `blocksPer*` variables | **NONE** |
| `supplyRatePerBlock` | **NONE** |
| Hardcoded chain addresses | **NONE** |

### APY calculation (line 464–472)

```solidity
function _getAPYBps(address comet) internal view returns (uint16) {
    uint256 util = IComet(comet).getUtilization(); // 1e18
    uint256 ratePerSec = IComet(comet).getSupplyRate(util); // 1e18
    uint256 aprWad = ratePerSec * 31_536_000; // 365*24*60*60 seconds/year
    uint256 bps = (aprWad * 10000) / 1e18;
    return bps > type(uint16).max ? type(uint16).max : uint16(bps);
}
```

- Uses `getSupplyRate()` → returns **per-second** rate (not per-block)
- Multiplied by `31_536_000` (seconds/year) → chain-agnostic ✓
- Compound III V3 design: per-second rates throughout, no block dependency

### Address architecture

- `comet` address: injected via `addMarket(address comet)` — NOT hardcoded ✓
- `usdc` address: constructor parameter `usdc_` — NOT hardcoded ✓
- No Permit2 references ✓

### VERDICT: COMPOUND III IS MULTICHAIN-SAFE

No C-04 class issues. Design is identical to Compound V3's explicit chain-agnostic
goal. No action required.

---

## Combined gate

All 3 tasks: **VALID / GREEN / CLEAN**.
Single commit covers foundry.toml fix + all evidence files.
