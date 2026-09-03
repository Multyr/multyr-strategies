# Direct-Safe USDC strategy deployment (no timelock)

This is the supported initial-test deployment path on Arbitrum One. The
Gnosis Safe is the direct governance address; a `TimelockController` is not
required. `DO_SEAL=false` leaves the core unsealed for testing but does **not**
leave any strategy-side privilege on the deployer.

## Do not reuse the old strategy

The old deployment uses `test/helpers/SimpleProtocolRegistry.sol`. That
registry is permissionless, its ownership cannot be transferred, and the four
registry-backed adapters cannot change their registry address. The strategy
also cannot remove adapters. Therefore the safe correction is a fresh strategy
deployment with all seven fresh adapters.

## Deploy

Set `GOVERNANCE_ADDRESS` to the deployed 3-of-5 Safe and fill the other values
in `.env`:

```bash
export GOVERNANCE_ADDRESS=0x70ef444799D6FBbE0865bA598Bee6795e064a326
export DO_SEAL=false
export DEPLOY_UPKEEP=true
export DEPLOY_LENDING_ADAPTERS=true
./script/deploy-usdc-lending.sh
./script/deploy-usdc-lending.sh --broadcast
```

The dry run is mandatory operationally even though the runner does not force
it. The broadcast deploys and configures:

- `ProtocolRegistry`, with the eleven approved markets;
- all seven lending adapters and both rate providers;
- `StrategyUpkeep`, including Aave configuration, Morpho/Dolomite/Fluid poke
  targets, a 24-hour interval, and the initial poke;
- all strategy modules and the one-shot adapter bootstrap.

Before the script exits it transfers the strategy admin/parameter roles,
adapter admin/parameter roles, factory admin/deployer roles, registry
ownership, both rate-provider controls, and upkeep ownership to the Safe. The
script reverts in simulation if a deployer privilege remains.

## Safe activation after deployment

The strategy deployment cannot bypass controls already owned by the Safe.
Generate the direct-Safe Transaction Builder batches from the new address book:

```bash
cd /Users/warlock/Documents/Codex/2026-09-03/cou/outputs/multyr-safe-flow
RPC_URL="$RPC_URL" python3 generate_safe_batches.py
```

The generator verifies on-chain that the production registry and upkeep are
Safe-owned, the Safe holds strategy/factory admin, and all four registry-backed
adapters point to the new registry. It refuses the unsafe legacy deployment.

Execute batch 1, wait for the router's built-in two-day allowlist delay, then
execute batch 2. This delay belongs to `StrategyRouter`; it is not a governance
timelock. The batches also set the requested 20,000 USDC vault/user cap and the
temporary small-value settings needed for a 3 USDC deposit/withdraw smoke test.

After the smoke test, the optional restore batch returns the normal withdrawal
and minimum-deployment guards while preserving the 20,000 USDC cap.
