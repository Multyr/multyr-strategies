# Safe migration — Arbitrum One (42161)

Safe: `0x70ef444799D6FBbE0865bA598Bee6795e064a326`

1. Import `01-propose-allowlist.safe.json` in Safe Transaction Builder, sign and execute. This proposes the replacement strategy; no vault funds move.
2. Wait at least 300 seconds after that transaction executes on-chain. Signing alone does not start the delay.
3. Import `02-migrate.safe.json`, simulate it in Safe, then sign and execute all 25 calls together as one atomic batch.

The migration batch executes:

- Calls 1–3: disable retiring upkeep, assert no active rebalance plan, disable retiring strategy deposits.
- Calls 4–10: recall all seven retiring adapters.
- Calls 11–12: return strategy assets to the unchanged Core vault and assert the retiring strategy and adapters are drained (at most 100 raw USDC units, 0.0001 USDC, residual).
- Calls 13–19: set reviewed per-adapter gas floors in the existing estimator for the replacement adapters.
- Calls 20–25: execute allowlist approval, register the replacement, configure Router limits/weights and disable the retired strategy.

Any failing call, including the drain assertion, reverts the whole migration batch. The exact two files passed a fork execution against the deployed contracts; simulate again in Safe because live balances and plan state can change.

After batch 2 succeeds, activate the staged AWS keeper configuration and check the first deployment receipts and per-adapter balances. Personal withdrawals or redeposits are not required; vault shares and the Core vault remain unchanged.

Deployment is complete and verified. These Safe transactions have NOT been executed on the live chain by this task.
