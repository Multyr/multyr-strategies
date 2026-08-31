# V10 Multichain Deploy Playbook

## Key principles

- **Byte-identical bytecode** across all chains (same solc 0.8.28, `evm_version=cancun`,
  `bytecode_hash=none`, `cbor_metadata=false`)
- **CREATE2 salt** encodes chain identity — same factory, different address per chain
  (collision resistance enforced by `keccak256(abi.encode("UsdcLendingV10", uint256(chainId)))`)
- **Only chain-specific config differs**: token addresses, protocol addresses, `blocksPerYear`,
  `deploySalt`, `governanceMultisig`
- Chain config files: `src/strategies/usdc-lending/config/UsdcLendingConfig{Chain}.sol`

---

## Supported chains — V10 initial

| Chain | Chain ID | blocksPerYear | Venus | Status |
|---|---:|---:|---|---|
| Arbitrum One | 42161 | 126,144,000 (0.25s) | enabled | Canonical |
| Optimism | 10 | 15,768,000 (2s) | disabled | Config ready |
| Base | 8453 | 15,768,000 (2s) | disabled | Config ready |
| Polygon PoS | 137 | 14,891,802 (~2.12s) | disabled | Config placeholder |
| Ethereum L1 | 1 | 2,628,000 (12s) | disabled | Config placeholder |
| zkSync Era | 324 | 6,307,200 (~5s) | disabled | Future / TBD |

Chains without Venus: set `venusBlocksPerYear = 0` and `venusVToken = address(0)` in config;
exclude `VenusUsdcMultiMarketAdapter` from the enabled-adapter list at deploy time.

---

## Venus blocksPerYear reference table

Venus uses per-block interest rates. `blocksPerYear` must match the target chain's block
production rate. Formula:

```
blocksPerYear = round(seconds_per_year / avg_seconds_per_block)
             = round(31,557,600 / avg_block_time)
```

| Chain | Avg block time | blocksPerYear | Notes |
|---|---:|---:|---|
| Arbitrum One | 0.25 s | 126,144,000 | ArbOS sequencer; fastest EVM |
| Optimism | 2 s | 15,768,000 | Bedrock; same as Base |
| Base | 2 s | 15,768,000 | Bedrock; same as Optimism |
| Polygon PoS | 2.12 s | 14,891,802 | Historical avg (slightly variable) |
| Ethereum L1 | 12 s | 2,628,000 | Post-Merge constant |
| zkSync Era | 5 s | 6,307,200 | Approximate; set only when Venus ships on zkSync |

When Venus is not deployed on a chain: set `venusBlocksPerYear = 0` in the config.
The adapter constructor checks `blocksPerYear > 0` and reverts if Venus is misconfigured.

---

## Per-chain governance multisig

| Chain | Role | Address | Notes |
|---|---|---|---|
| Arbitrum One | `DEFAULT_ADMIN_ROLE` / timelock | TBD — set before deploy | Multyr Arbitrum Safe |
| Optimism | `DEFAULT_ADMIN_ROLE` / timelock | TBD — set before deploy | Multyr OP Safe |
| Base | `DEFAULT_ADMIN_ROLE` / timelock | TBD — set before deploy | Multyr Base Safe |
| Polygon PoS | `DEFAULT_ADMIN_ROLE` / timelock | TBD — set before deploy | Placeholder |
| Ethereum L1 | `DEFAULT_ADMIN_ROLE` / timelock | TBD — set before deploy | Placeholder |

**Before any deploy**: replace `address(0)` in `UsdcLendingConfig{Chain}.sol` with the
chain-specific governance multisig / timelock address. The vault constructor grants
`DEFAULT_ADMIN_ROLE` directly to `_rootTimelock` — the deployer receives NO admin role.

---

## CREATE2 salt scheme

Each chain's deploy salt is deterministic and collision-resistant:

```solidity
bytes32 deploySalt = keccak256(abi.encode("UsdcLendingV10", uint256(chainId)));
```

| Chain | Chain ID | deploySalt |
|---|---:|---|
| Arbitrum One | 42161 | `0x1ec434517909d3693bbdfed8b0ff707428a8e091f9501baa17b78e4980156b59` |
| Optimism | 10 | `0xce50b347989178c6161736dc77a258fd1da9b1889c340b07f01f99b1f0718be9` |
| Base | 8453 | `0x8dc2138902280b2fdde116c5a79981fb62e8b50b3ee7539d84e98a8fd2233714` |
| Polygon PoS | 137 | `0xbe1157781e39584b5ddc353a5adf7bc5a66acb5f4dc809e990fdd7bc561f8a49` |
| Ethereum L1 | 1 | `0xd6dc56603887c2acd74b5ac3184e04a99d8a4b8582bbac8c8795491cdc1fddbf` |

Salts can be verified with:
```bash
cast keccak "$(cast abi-encode "f(string,uint256)" "UsdcLendingV10" <chainId>)"
```

---

## Per-chain deploy procedure

### Prerequisites

- `foundry.toml` must have `bytecode_hash = "none"` and `cbor_metadata = false`
  for byte-identical builds across machines.
- `PRIVATE_KEY` env var: deployer EOA (receives NO admin roles — governance multisig must
  be set in config before deploy).
- `RPC_URL` env var: target chain archival RPC.
- Verify `UsdcLendingConfig{Chain}.sol`:
  - `governanceMultisig != address(0)` — or deploy will grant admin to zero address (dangerous)
  - `venusBlocksPerYear` matches the chain's block time (or 0 if Venus disabled)
  - All token/protocol addresses verified against block explorer

### Step 1 — Deterministic build verification

```bash
forge clean
forge build
# Verify CBOR metadata absent (bytecode_hash=none + cbor_metadata=false):
forge test --match-test test_bytecode_reproducibility -vvv
# Run twice — logged keccak256(creationCode) must be identical both runs.
```

### Step 2 — Dry run (simulation)

```bash
RPC_URL=<target-rpc> forge script script/DeployUsdcLendingStrategy.s.sol \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY --simulate
```

Verify in simulation output:
- Correct USDC address for target chain
- Correct `blocksPerYear` in VenusAdapter (if enabled)
- `DEFAULT_ADMIN_ROLE` granted to governance multisig, NOT to deployer

### Step 3 — Deploy

```bash
RPC_URL=<target-rpc> forge script script/DeployUsdcLendingStrategy.s.sol \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast \
  --verify --etherscan-api-key $ETHERSCAN_KEY
```

### Step 4 — Post-deploy verify checklist

After broadcast completes, verify each item on the target chain:

```bash
# 1. Vault deployed at expected CREATE2 address
cast code <vault-address> --rpc-url $RPC_URL | wc -c
# Must be > 2 (non-zero bytecode)

# 2. Bytecode codehash matches Arbitrum reference
cast code --disassemble <vault-address> --rpc-url $RPC_URL > /tmp/deployed_bytecode.hex
# Compare keccak256 to Arbitrum reference from test_bytecode_reproducibility output

# 3. DEFAULT_ADMIN_ROLE granted to governance multisig (NOT deployer)
cast call <vault-address> \
  "hasRole(bytes32,address)(bool)" \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  <governance-multisig> --rpc-url $RPC_URL
# Must return: true

cast call <vault-address> \
  "hasRole(bytes32,address)(bool)" \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  <deployer-eoa> --rpc-url $RPC_URL
# Must return: false

# 4. USDC address correct
cast call <vault-address> "asset()(address)" --rpc-url $RPC_URL
# Arbitrum: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831
# Optimism:  0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85
# Base:      0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913

# 5. Venus blocksPerYear (if enabled)
cast call <venus-adapter-address> "blocksPerYear()(uint256)" --rpc-url $RPC_URL
# Must match chain-specific value from table above

# 6. Permit2 set correctly
cast call <vault-address> "permit2()(address)" --rpc-url $RPC_URL 2>/dev/null || true
# 0x000000000022D473030F116dDEE9F6B43aC78BA3 on all chains

# 7. Contract size within EIP-170 limit
forge build --sizes | grep UsdcMultiLendingVault
# Must be <= 24576 bytes (project safety: <= 23552 bytes)
```

### Step 5 — Bootstrap adapters

After deployment, governance must bootstrap adapters through the `BOOTSTRAP_ROLE`:

```bash
# Call via governance multisig (Gnosis Safe):
# 1. bootstrapper.bootstrap() — registers and enables adapters
# 2. After bootstrap(), BOOTSTRAP_ROLE is permanently renounced
# 3. Call exitBootstrapMode() via DEFAULT_ADMIN_ROLE when ready to go live
```

---

## Single-audit claim

V10 byte-identical bytecode means a single Spearbit/Sherlock audit of the Arbitrum
deployment covers the logic for all chains. Chain-specific differences (addresses,
`blocksPerYear`) are deploy-time governance parameters, not compiled code.

The only chain-specific contracts are the `UsdcLendingConfig{Chain}.sol` libraries
(pure functions, no storage, no proxy) — these are excluded from the audit scope as
they contain no logic beyond constant-returning `get()`.

Byte-identity is verified by:
```bash
# Run on two different machines / clean builds:
forge clean && forge test --match-test test_bytecode_reproducibility -vvv
# Logged keccak256(creationCode) must match across runs and across chains.
```

---

## Per-chain blocksPerYear verification (audit evidence)

Fixed in **C-04** (Wave 1 HIGH). See `docs/audit/WAVE1_2_SUMMARY.md`.

Before V10, `BLOCKS_PER_YEAR` was a hardcoded compile-time constant — wrong for all
chains other than Arbitrum. V10 passes `blocksPerYear` as a constructor parameter via
`UsdcLendingChainConfig`, verified at deploy time by the config library.