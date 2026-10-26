# Retired Venus accounting repair — 20 October 2026

Status: original three-call batch superseded after reproducing ADAPTER_NOT_DRAINED at block 516655973. Safe execution remains pending.

Use only `02-reconcile-retired-venus-v2.safe.json`. It replaces the original batch; it is not a second step to execute after it. The original file is retained as evidence. No additional seed is needed.

Import `02-reconcile-retired-venus-v2.safe.json` into Safe Transaction Builder for Safe `0x70ef444799D6FBbE0865bA598Bee6795e064a326` on Arbitrum One. Simulate and execute all four calls together:

1. Strategy `syncPositionAsset(oldVenus)` records the real, nonzero seed balance instead of the stale 20.549181 USDC position.
2. Strategy `selectiveRecall([oldVenus])` redeems that seed into the same strategy and clears the recorded position.
3. Strategy `callAdapterEmergencyPull(oldVenus)` requests redemption of all remaining vToken shares and sweeps the resulting USDC into the strategy. This removes rounding/accrual residue left by the amount-based recall.
4. Existing guard `assertDrained([oldVenus], 0)` requires the retired adapter to be empty, reverting the batch if the recall fails to empty it.

The deployer supplied 0.001 USDC, minted 89,546 vToken units and transferred only those newly minted units to the retired adapter. The adapter reports 999 raw USDC units after mint rounding. All three preparation receipts succeeded; see `seed-receipts.json`. Do not run the seed script again. No waiting period is required.

The source of the problem was a retained accounting balance on a disabled, fully drained adapter. Sync deliberately rejects an observed zero balance as suspicious. This recovery creates a genuine tiny position, lets the existing admin sync acknowledge it, then redeems it normally. No strategy deployment, cap changes, adapter changes, or keeper configuration changes are required for this accounting correction.

The fork test asserts the old accounting balance and actual adapter assets both become zero, and checks that every deposit in the resulting candidate plan is funded by cash or preceding withdrawals. The resulting plan has seven actions, starting with a Fluid withdrawal, rather than the prior unfunded deposit-only plan. This does not force a rebalance or bypass its economic gate. Fork estimator reliability is not a confirmation of a live executable/profitable rebalance; re-read live checkUpkeep, canRebalance and previewRebalanceGas after Safe execution.

Post-execution checks: old Venus `positionAssets` is zero; old adapter `totalAssets` is zero; current Fluid funds remain intact; scoring TVL excludes the retired position; candidate funding is valid. The recalled seed is held by the strategy, not paid to the deployer.

## Failed simulation diagnosis

At block 516655973, selectiveRecall successfully returned 999 raw USDC but left 91 vToken units, valued at 1 raw USDC (0.000001 USDC). The strict drain guard reverted the whole batch. The original immediate-after-seed rehearsal did not expose this time-dependent residue. The corrected batch retains the strict zero guard and adds a full-share redemption attempt before it. At the later current-state fork, three vToken raw units remain worth less than 0.000001 USDC: Venus rejects redeeming them with `redeemAmount is zero`. Both positionAssets and totalAssets are zero. The guard checks representable USDC assets, not literal zero vToken units.

V2 fork validation passed at blocks 516655973 and 516689420. Both ended with positionAssets = 0 and totalAssets = 0; all seven candidate actions had sequential funding. No transaction was broadcast. A profitable live rebalance is not established by these fork tests.
