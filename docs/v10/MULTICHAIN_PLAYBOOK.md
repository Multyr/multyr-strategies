# V10 Multichain Deploy — Summary

Full deploy playbook: [`script/MULTI_CHAIN_PLAYBOOK.md`](../../script/MULTI_CHAIN_PLAYBOOK.md)

---

## Key principles

- **Byte-identical bytecode** across all chains (same solc 0.8.28, `evm_version=cancun`,
  `bytecode_hash=none`, `cbor_metadata=false`)
- **CREATE2 salt** encodes chain identity — same factory, different address per chain
  (collision resistance enforced)
- **Only chain-specific config differs**: token addresses, protocol addresses, `blocksPerYear`
- Chain config files: `src/strategies/usdc-lending/config/UsdcLendingConfig{Chain}.sol`

---

## Supported chains (V10 initial)

| Chain | blocksPerYear | Status |
|---|---:|---|
| Arbitrum One | 126,144,000 (0.25s blocks) | Canonical |
| Optimism | 15,768,000 (2s blocks) | Config ready |
| Base | 15,768,000 (2s blocks) | Config ready |
| Polygon PoS | 14,891,802 (2.12s avg) | Config placeholder |
| Ethereum L1 | 2,628,000 (12s blocks) | Config placeholder |

Chains without Venus adapter: set `blocksPerYear = 0` in config and disable Venus in
the enabled-adapter list.

---

## Single-audit claim

V10 byte-identical bytecode means a single Spearbit/Sherlock audit of the Arbitrum
deployment covers the logic for all chains. Chain-specific differences (addresses,
`blocksPerYear`) are post-deploy governance parameters, not compiled code.

The only chain-specific contract is `AdapterFactory` (CREATE2 registry, 2,817 B, trivial).

---

## Per-chain blocksPerYear verification

Venus protocol uses per-block interest rates. The `blocksPerYear` parameter in
`VenusUsdcMultiMarketAdapter` must match the target chain's block production rate:

```
blocksPerYear = seconds_per_year / seconds_per_block
             = 31,536,000 / target_block_time
```

This was identified as HIGH-C4 in Wave 1 and fixed — see `docs/audit/WAVE1_2_SUMMARY.md`.
