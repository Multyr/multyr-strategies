EMA-first replacement release — Arbitrum One

Source: commit 407b3df, tag usdc-lending-ema-first-20261023.
Estimator: reliable execution EMA first, adapter/global defaults for missing or unreliable observations. Final margin 30%. Target reserve 10%, configurable by governance. Do not copy old strategy settings.

Safe execution order (only after exact-file rehearsal passes):
1. Import 01-propose-allowlist.safe.json into Safe Transaction Builder on Arbitrum One. Simulate, sign and execute. This starts the router allowlist delay and moves no vault funds.
2. Wait the on-chain router delay after execution, not merely signing (see postflight.json).
3. Import 02-migrate.safe.json. Simulate against current state, sign and execute the entire batch atomically. It stops the old upkeep/deposits, checks no old plan is active, recalls every registered old adapter, withdraws to Core, asserts the old strategy is drained, sets estimator overhead/defaults, and activates the replacement while disabling the old strategy. A failed drain check reverts the batch; do not remove it.

The new strategy is not active until step 3 succeeds. The batch leaves recalled funds in Core for normal deployment by the vault keeper. No transfer to the deployer is requested.

After migration: run keeper/scripts/check-ema-migration.mjs, then build the keeper image and roll AWS using config/arbitrum-one.ema-first-20261023.json. Keep the old config/service until the on-chain migration completes. Preserve other W1–W6 job settings and use stop-before-start rollout with only one active signer worker.

The subgraph discovers the strategy on Router StrategyRegistered and backfills its adapters; the release also indexes the new upkeep from its deployment receipt block. Studio deployment is distinct from publishing a network version or adding GRT signal.
