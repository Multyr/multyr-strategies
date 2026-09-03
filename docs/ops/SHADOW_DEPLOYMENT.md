# Shadow Deployment Runbook — USDC Lending Strategy

> **Environment:** an Arbitrum One environment that mirrors mainnet state — a
> hosted Shadow fork, or a local `anvil --fork-url <arbitrum> --chain-id 42161`.
> The strategy **reuses `UsdcLendingConfigArbitrum`** for every protocol venue +
> Permit2, and expects Multyr core (`CoreVault` / `StrategyRouter` /
> `BufferManager` / `StrategyHealthRegistry`) to already exist at its Arbitrum
> mainnet addresses on the fork.
>
> There is deliberately **no `UsdcLendingConfigShadow.sol`** and **no change to
> `DeployUsdcLendingStrategy.s.sol`** — only an environment profile
> (`.env.shadow`) and a pre/post wrapper.

## Shape

`script/deploy-usdc-lending-shadow.sh` is a three-step wrapper:

| Step | Script | Broadcast? | Purpose |
|---|---|---|---|
| 1 | `PreflightUsdcLendingShadow.s.sol` | no | chain/env identity, USDC, all 7 venues + Permit2 have code, core deployed + `asset()==USDC`, governance nonzero/distinct, deployer balances, config bounds, predicted-CREATE collision |
| 2 | `DeployUsdcLendingStrategy.s.sol` | yes (with `--broadcast`) | the **unmodified** production deploy script |
| 3 | `PostflightUsdcLendingShadow.s.sol` | no | verify wiring + de-privilege (7 adapters, not paused, `CORE_ROLE ×2`, bootstrap renounced, deployer `KEEPER_ROLE` revoked, upkeep has `KEEPER_ROLE`), then write `deployments/shadow/<id>/manifest.json` |

## Safety properties (enforced before any transaction)

The shell refuses to run unless:

- it loads `.env.shadow` only (never `.env`);
- `DEPLOY_ENV=shadow`;
- `cast chain-id --rpc-url $SHADOW_RPC_URL` returns `42161`;
- `SHADOW_RPC_URL` is the only RPC — no fallback to `RPC_URL`;
- the deployer key is `SHADOW_DEPLOYER_PRIVATE_KEY` (a plain `DEPLOYER_PRIVATE_KEY`
  in `.env.shadow` is rejected; any ambient one is cleared);
- the derived deployer address is not in `FORBIDDEN_DEPLOYER_ADDRESSES`;
- guardian / governance Safe / keeper / emergency are present, nonzero, distinct, and
  none equals the deployer;
- **simulation is the default** — `--broadcast` is required to send transactions;
- a completed `manifest.json` for the deployment id blocks re-broadcast unless
  `--force`.

## Deterministic salts

The strategy salt is `keccak256("UsdcLendingV10", 42161)`; adapter salts derive
from it. On a fresh Shadow fork the `AdapterFactory` deploys at a nonce-based
address that differs per run, so the final CREATE2 adapter addresses are only
deterministic **relative to that run's factory** — a Shadow run is an isolated
rehearsal, not an address-for-address production preview. Step 1's
predicted-CREATE check guarantees no run writes over a prior partial deploy.

## Local anvil note

`anvil --fork-url <arbitrum>` **must** use `--hardfork shanghai` — with
`--hardfork cancun` `eth_call` fails ("Excess blob gas not set": Arbitrum blocks
carry no EIP-4844 fields). Set `SHADOW_EVM_VERSION=shanghai` in `.env.shadow` so
the wrapper compiles to match. A hosted Shadow RPC needs no override.

```bash
anvil --fork-url https://arb1.arbitrum.io/rpc --chain-id 42161 --hardfork shanghai
# fund the shadow deployer on the fork:
cast rpc anvil_setBalance <deployer> 0x56BC75E2D63100000            # 100 ETH
cast rpc anvil_impersonateAccount 0x724dc807b04555b71ed48a6896b6F41593b8C637
cast send 0xaf88d065e77c8cC2239327C5EDb3A432268e5831 \
  "transfer(address,uint256)" <deployer> 10000000 \
  --from 0x724dc807b04555b71ed48a6896b6F41593b8C637 --unlocked
```

## Procedure

```bash
cp .env.shadow.example .env.shadow      # fill in SHADOW_RPC_URL,
                                        # SHADOW_DEPLOYER_PRIVATE_KEY, and the
                                        # four SHADOW_*_ADDRESS operators
./script/deploy-usdc-lending-shadow.sh --preflight     # step 1 only
./script/deploy-usdc-lending-shadow.sh                 # step 1 + dry-run step 2
./script/deploy-usdc-lending-shadow.sh --broadcast     # steps 1 → 2 → 3
```

## Outputs — `deployments/shadow/<deployment-id>/`

`<deployment-id>` = `<utc-timestamp>-<git-sha>` unless pinned via
`SHADOW_DEPLOYMENT_ID`.

| File | Written by | Contents |
|---|---|---|
| `addresses.json` | step 2 (`STRATEGY_OUTPUT_JSON`) | flat address book |
| `manifest.json` | step 3 | env, git commit, chain id, source block, timestamp, operator addresses, deployed addresses **+ strategy runtime code hash**, forked-in core addresses, role/ownership snapshot, config parameters |

Committed as reproducibility evidence; forge `run-*.json` under the path is
gitignored.

## Keeper / emergency roles

`StrategyUpkeep` is deployed, fully configured, granted `KEEPER_ROLE`, and transferred to the
direct governance Safe as in production.
`SHADOW_KEEPER_ADDRESS` / `SHADOW_EMERGENCY_ADDRESS` are recorded and verified in
the manifest but not additionally granted roles — that is a governance-policy
decision.

## Router registration

`DeployUsdcLendingStrategy` Phase 2.1 self-registers the strategy in the router
**only if the deployer owns the router**. On Shadow the router owner is the
governance Safe, so the strategy deploys **unregistered**; step 3 reports this. Register
it through Shadow governance (`proposeStrategyAllowlist` → wait →
`executeStrategyAllowlist` → `register`) as a separate step.

## Tests

`test/strategies/usdc-lending/fork/ShadowDeploymentLifecycle.fork.t.sol` runs
preflight (positive + every negative path), the wrapped deploy, postflight, the
strategy lifecycle (deposit → deployIdle → harvest → rebalance → emergency
recall), the manifest role snapshot, and repeated-deploy isolation. Skips
without `SHADOW_RPC_URL` / `ARBITRUM_RPC_URL`.
