# Multyr fresh-strategy Safe activation and 3 USDC smoke flow

Everything needed to operate the corrected strategy deployment is kept in this
folder. The Solidity implementation and tests remain in their standard Foundry
locations so they continue to compile and run normally.

Governance is the direct 3-of-5 Safe
`0x70ef444799D6FBbE0865bA598Bee6795e064a326`. There is no
`TimelockController`, so none of the generated calls uses `schedule()` or
`execute()` wrappers. The separate two-day delay below is enforced by
`StrategyRouter` itself.

## Contents

- `generate_safe_batches.py` validates the new on-chain strategy deployment and
  creates Safe Transaction Builder JSON files.
- `run_3usdc_flow.sh` checks and optionally executes the complete user-side
  3 USDC deposit and withdrawal cycle.
- `safe-batches/` is created by the generator after the fresh deployment.

The supporting repository implementation is in:

- `src/strategies/usdc-lending/registry/ProtocolRegistry.sol`
- `script/DeployUsdcLendingStrategy.s.sol`
- `script/PostflightUsdcLendingShadow.s.sol`
- `test/strategies/usdc-lending/registry/ProtocolRegistry.t.sol`
- `test/strategies/usdc-lending/fork/ShadowDeploymentLifecycle.fork.t.sol`

## Run order

Run the deployment commands from the `multyr-strategies` repository root.

1. Configure `.env`, then dry-run and broadcast a fresh strategy deployment:

   ```bash
   export GOVERNANCE_ADDRESS=0x70ef444799D6FBbE0865bA598Bee6795e064a326
   export DO_SEAL=false
   export DEPLOY_UPKEEP=true
   export DEPLOY_LENDING_ADAPTERS=true
   ./script/deploy-usdc-lending.sh
   ./script/deploy-usdc-lending.sh --broadcast
   ```

   The deployment creates a production `ProtocolRegistry`, configures upkeep,
   removes every deployer role, and hands strategy, adapters, registry, factory,
   rate providers, and upkeep directly to the Safe. `DO_SEAL=false` is correct
   for initial testing and does not skip this ownership handoff.

2. Generate Safe Transaction Builder files:

   ```bash
   RPC_URL=<arbitrum-rpc-url> python3 safe-flow/generate_safe_batches.py
   ```

   Generation performs on-chain ownership and registry checks and refuses the
   unsafe legacy deployment.

3. Import and execute
   `safe-flow/safe-batches/01-safe-config-and-propose.json` in the Safe. Record
   `StrategyRouter.strategyAllowlistEta(strategy)` after execution.

4. Wait until that ETA. The router enforces a two-day delay and a seven-day
   execution grace window. Then execute
   `safe-flow/safe-batches/02-safe-activate-after-router-delay.json`.

5. Export `RPC_URL` and a funded `USER_PRIVATE_KEY`, run the preflight, and then
   execute the user flow:

   ```bash
   ./safe-flow/run_3usdc_flow.sh
   ./safe-flow/run_3usdc_flow.sh --execute
   ```

6. Optionally execute
   `safe-flow/safe-batches/03-safe-restore-normal-withdrawal-guards.json` after
   the smoke test. This preserves the 20,000 USDC vault cap while restoring the
   10% instant-withdrawal cap, 100 USDC minimum claim, one-day lock, and 10 USDC
   minimum strategy deployment.

## Safe transactions generated

The first batch:

- accepts pending `CoreVault` ownership for the Safe;
- sets vault and per-user deposit caps to 20,000 USDC;
- temporarily lowers the minimum deposit and withdrawal amounts to 1 USDC;
- temporarily enables immediate withdrawal of the 3 USDC smoke position;
- lowers the strategy deployment floor to 1 USDC;
- configures the low-TVL adapter ceiling for the small test;
- authorizes strategy health reporting;
- refreshes strategy liquidity caches; and
- proposes the strategy to the router.

The second batch, after the router delay:

- executes the allowlist proposal;
- registers and enables the strategy;
- applies allocation and loss limits;
- refreshes APY, TVL, and liquidity caches; and
- unpauses the core vault only after strategy activation succeeds.

## Why a fresh strategy deployment is required

The old strategy references `test/helpers/SimpleProtocolRegistry.sol`. That
registry has no owner or access control: anyone can change protocol-market
metadata. Four adapters cannot repoint their registry, and the old strategy
cannot remove those adapters. Do not activate the old strategy. Deploy the
corrected strategy and regenerate the Safe files from the new
`broadcast/strategy-addresses.json`.

The package intentionally does not freeze routing, finalize parameters, or seal
the vault. Those actions are irreversible or make initial testing harder.

## Validation

The corrected deployment and postflight ownership checks pass against an
Arbitrum fork. The exact 3 USDC end-to-end test passes: Safe accepts core
ownership, applies the 20,000 USDC cap and temporary test limits, observes the
router's two-day delay, activates the strategy, deposits 3 USDC, routes it into
the strategy, deploys idle assets through upkeep, recalls liquidity, and
completes the withdrawal with the user's new shares consumed.

When a fork is advanced two days, its frozen Chainlink timestamp becomes stale.
The fork test installs a fresh mock oracle only on the disposable fork after the
time jump. That test-only workaround is not included in the mainnet Safe calls.
