# External Dependencies — Arbitrum Mainnet

All external contract addresses referenced by the V9.2 + P0.7 strategy and its tests. Verified against Arbitrum mainnet at fork block 472761449.

## Core token

| Contract | Address | Purpose |
|---|---|---|
| USDC (Arbitrum bridged) | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` | Strategy denomination asset |

## Lending protocols (7 adapters)

| Protocol | Adapter address (Aave V3 Pool example) | Comet/Pool/Vault | Audit reference |
|---|---|---|---|
| Aave V3 | `0x794a61358D6845594F94dc1DB02A252b5b4814aD` | Pool contract | OpenZeppelin (multiple), Sigma Prime |
| Compound V3 (Comet USDC) | `0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf` | Comet USDC market | OpenZeppelin |
| Dolomite | [per `DolomiteUsdcMultiMarket.sol` constants] | Margin contract | Trail of Bits |
| Euler V2 | [per `EulerUsdcMultiMarket.sol` constants] | Euler vault | Various |
| Fluid | [per `FluidUsdcMultiMarket.sol` if exists] | Fluid pool | Various |
| Morpho Blue | [per `MorphoUsdcMultiMarket.sol` constants] | Morpho market | Spearbit |
| Venus | [per `VenusUsdcMultiMarket.sol` constants] | Venus VToken | Peckshield, others |

## Automation

| Contract | Address (illustrative — verify at deployment) | Purpose |
|---|---|---|
| Chainlink Automation Registry 2.1 | `0x37D9dC70bfcd8BC77Ec2858836B0c9E89bdF8e72` (verify Arbitrum) | Keeper upkeep registry |
| LINK token (Arbitrum) | `0xf97f4df75117a78c1A5a0DBb814Af92458539FB4` | Keeper fee payment |

## Test seed source

| Contract | Address | Purpose |
|---|---|---|
| Whale account | `0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7` | USDC source for fork test seeding via `deal()` cheat |

## Pinned at fork block

All fork tests pin to block **472761449** (Arbitrum mainnet). This block is used to ensure deterministic reproduction of:
- USDC total supply and balances at the time
- Aave V3 Pool aToken indices
- Compound V3 Comet utilisation
- Per-protocol extTVL snapshots

If reproducing later, the auditor MUST use this exact block number via:

```bash
forge test --fork-url $ARBITRUM_RPC_URL --fork-block-number 472761449 -vvv
```

Newer blocks may have diverged state (e.g., protocol parameter updates, new markets) that would cause fork tests to behave differently.

## Threat model alignment

These external dependencies are addressed in `THREAT_MODEL.md` §5. The audit assumes each protocol operates per its published security model. Specific failure-mode tests are included in `EVIDENCE/forktest/V92_AdversarialScenarios.t.sol`:

- Aave / Compound failure during overflow → `test_E2E_adapter_quarantine_during_overflow`
- USDC depeg → `test_E2E_oracle_deviation_USDC_depeg`
- Adapter callback revert → `test_E2E_failed_adapter_callback`
- Chainlink keeper timing → implicit via `vm.warp` test patterns

## Verification commands

To independently verify an address is the contract claimed:

```bash
cast code <address> --rpc-url $ARBITRUM_RPC_URL | head -c 100
# Verify bytecode is non-empty and matches expected protocol fingerprint
```

For ABI verification:

```bash
cast interface <address> --rpc-url $ARBITRUM_RPC_URL
# Inspects deployed contract's selectors
```
