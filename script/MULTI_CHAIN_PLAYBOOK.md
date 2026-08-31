# Multi-Chain Deployment Playbook — V10.0 (storage+initialize)

**Protocol:** Multyr USDC Lending Strategy  
**Version:** V10.0 — storage+initialize adapter pattern  
**Audit status:** audit_p07_v5 (pre-submission)  
**Last updated:** 2026-06-15

---

## Overview

V10.0 introduces the storage+initialize adapter pattern, making all adapter bytecode
**chain-agnostic**. A single audit of the Arbitrum canonical deployment covers all chains.
The only chain-specific contract is `AdapterFactory`, which is a thin CREATE2 registry.

**Per-chain deployment is 7 steps. Only Step 2 requires chain-specific admin action.**

---

## Step 1 — Prerequisites

Before deploying to a new chain:

1. **Timelock / multisig**: configure a multisig or timelock with M-of-N signers appropriate
   to the chain's security model. Record address as `MULTYR_TIMELOCK_ADMIN`.

2. **Address validation**: confirm USDC token address, Chainlink sequencer uptime feed
   address, and target protocol addresses (Aave pool, fToken, vToken, etc.) for the new
   chain. Do NOT assume addresses are the same as Arbitrum.

3. **Bytecode verification**: compute `keccak256` of each adapter's creation bytecode against
   the Arbitrum reference (see Step 6). Byte-identical bytecode means the same audit applies.

4. **Environment variables**:
   ```bash
   export MULTYR_TIMELOCK_ADMIN=<multisig_address>
   export DEPLOYER_PRIVATE_KEY=<deployer_pk>    # NOT the multisig key
   export CHAIN_ID=<target_chain_id>
   ```

---

## Step 2 — Deploy AdapterFactory (chain-specific)

AdapterFactory is the only chain-specific deployment. It holds the on-chain CREATE2 registry
for adapter deployments.

```bash
forge script script/DeployAdapterFactory.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify
```

Record the deployed address:

```bash
mkdir -p deployments/$CHAIN_ID
echo '{"AdapterFactory": "<address>", "admin": "<multisig>", "chainId": <N>}' \
  > deployments/$CHAIN_ID/AdapterFactory.json
```

---

## Step 3 — Prepare chain-specific config JSON

Create `deployments/$CHAIN_ID/config.json` with all chain-specific addresses:

```json
{
  "chainId": 42161,
  "usdc": "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
  "aavePool": "0x794a61358D6845594F94dc1DB02A252b5b4814aD",
  "aaveAUsdc": "0x724dc807b04555b71ed48a6896b6F41593b8C637",
  "fluidFToken": "<fluid_fusdc_address>",
  "venusVToken": "<venus_vusdc_address>",
  "sequencerFeed": "0xFdB631F5EE196F0ed6FAa767959853A9F217697D",
  "uniswapV3Router": "0xE592427A0AEce92De3Edee1F18E0157C05861564",
  "camelotV3Router": "0x1F98431c8aD98523631AE4a59f267346ea31F984",
  "chainlinkAutomationRegistry": "<registry_address>",
  "adapterFactory": "<deployed_in_step_2>"
}
```

**Governance checkpoint**: submit this config to the multisig for review BEFORE Step 4.
Incorrect addresses cannot be changed post-deploy without a new proxy upgrade.

---

## Step 4 — Pre-compute adapter addresses

Use `AdapterFactory.computeAddress()` to derive the deterministic CREATE2 address for each
adapter before deployment. This allows pre-authorizing adapters in the strategy module.

```solidity
// Example (forge script or cast):
address factory = <AdapterFactory_address>;
bytes32 salt = keccak256(abi.encodePacked("MULTYR_V10", "AAVE", block.chainid));
bytes memory creationCode = type(AaveV3USDCAdapter).creationCode;
address predicted = AdapterFactory(factory).computeAddress(salt, keccak256(creationCode));
```

Record all predicted addresses in `deployments/$CHAIN_ID/predicted_adapters.json`.

---

## Step 5 — Atomic deployment via factory.deployAndInit()

Deploy each adapter atomically: CREATE2 + initialize in a single transaction.

```bash
forge script script/DeployUsdcLendingStrategy.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify \
  --sig "run(address)" <AdapterFactory_address>
```

Alternatively, deploy adapters individually:

```bash
# Each adapter: deployAndInit(creationCode, salt, initData)
cast send $ADAPTER_FACTORY "deployAndInit(bytes,bytes32,bytes)(address)" \
  $(cat out/AaveV3USDCAdapter.sol/AaveV3USDCAdapter.json | jq -r '.bytecode.object') \
  $SALT \
  $(cast calldata "initialize(address,address,address,address,address,uint256)" \
      $USDC $AAVE_POOL $AAVE_AUSDC $ADMIN $STRATEGY $MAX_CAP) \
  --private-key $DEPLOYER_PRIVATE_KEY
```

---

## Step 6 — Verify byte-identical bytecode hash

After deployment, confirm the adapter bytecode is byte-identical to the Arbitrum reference:

```bash
# Arbitrum reference hashes (from canonical deployment):
AAVE_HASH="<keccak256_of_deployed_bytecode>"
COMET_HASH="<keccak256_of_deployed_bytecode>"
# ... (fill from deployments/42161/bytecode_hashes.json)

# New chain verification:
cast code <new_chain_aave_adapter_address> --rpc-url $NEW_RPC | keccak256
# Must match AAVE_HASH
```

Byte-identical deployed bytecode means:
- The same formal audit covers all chains (no re-audit required per chain)
- Any bug found on one chain is present on all chains (no silently different behavior)
- The V10 storage+initialize pattern is confirmed: no constructor immutables (which would differ per-chain)

Record results in `deployments/$CHAIN_ID/bytecode_hashes.json`.

---

## Step 7 — Register Chainlink Automation upkeep

```bash
forge script script/DeployStrategyUpkeep.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify \
  --env STRATEGY_ADDRESS=<deployed_strategy>
```

Then register the upkeep in Chainlink Automation UI or via the registry contract:
- Gas limit: 5,000,000 (recommended)
- LINK funding: minimum 10 LINK (top up to 50 LINK for 30-day coverage)
- Trigger: block-based, checkInterval = 1 block

---

## Deployment artifact format

Each chain's deployment artifacts are stored in `deployments/<chainId>/`:

```
deployments/
  42161/                          # Arbitrum One (canonical)
    AdapterFactory.json
    Strategy.json                 # vault + all module addresses
    adapters.json                 # adapter address per venue
    bytecode_hashes.json          # keccak256 of each adapter's deployed code
    config.json                   # chain-specific protocol addresses used
  8453/                           # Base (future)
    ...
  10/                             # Optimism (future)
    ...
```

---

## Audit perimeter implications

The V10.0 single-audit model:

| Chain | Audit required? | Notes |
|---|:---:|---|
| Arbitrum One (canonical) | YES — full audit | Reference deployment, covers all chains |
| Base | No re-audit if bytecode matches | Verify Step 6 before launch |
| Optimism | No re-audit if bytecode matches | Verify Step 6 before launch |
| zkSync Era | May require re-audit | zkSync EVM divergences may affect bytecode |
| BNB Chain | Likely no re-audit | Verify Venus adapter chain addresses |

**Validation effort per new chain:** ~1 day (config review + bytecode check + smoke test) vs
~4 weeks for a full re-audit. The V10 pattern exists specifically to enable this.

---

## Currently deployed

| Chain | Chain ID | AdapterFactory | Strategy | Status |
|---|---|---|---|---|
| Arbitrum One | 42161 | TBD | TBD | In development (audit_p07_v5) |
| Base | 8453 | Not deployed | - | Planned post-audit |
| Optimism | 10 | Not deployed | - | Planned post-audit |
