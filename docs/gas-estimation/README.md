# Read-only rebalance gas integration

Replacement contracts only. No production transaction has been sent for this change. Every module must be rebuilt from this revision because they share storage. The deployed strategy's write-once modules cannot be patched in place.

## Flow

1. Scoring returns targets, APYs and normalized scores. A shared `CandidateActions` builder filters dust/minimum moves and orders withdrawals followed by scored deposits.
2. `previewRebalanceGas()` is a true view returning the candidate actions and quote. `canRebalance()` remains compatible with the upkeep STATICCALL path.
3. Preparation independently rebuilds the same actions after syncing positions. The existing gate evaluates the executable targets and reads the estimator. Approval and execution use the same action amounts and ordering.
4. Before every execution transaction, the remaining suffix is repriced. Preparation costs are excluded because they have already been paid. Current APYs, liquidity, venue eligibility, funding and deposit caps are checked. Invalid pricing, inadequate benefit or changed feasibility cancels the economic plan and starts the cooldown/backoff.
5. Unexpected partial/failed operations stop the economic plan after accounting for completed movements. Residual cash remains available to the existing idle deployment/withdrawal paths. Dynamic plans do not silently execute unpriced extra deposits during finalization.

Cap-drift mandates keep their existing explicit safety bypass. Emergency/core withdrawals never require a valid oracle or a profitable gas quote. They still record successful withdrawal gas. This distinction is intentional: discretionary yield optimization and safety recalls have different policies.

## Cost model and measurement boundaries

The estimator uses per-adapter deposit/withdrawal EMAs, bounded below by governance-calibrated floors. Strict and best-effort deposits, planned withdrawals, core liquidity realization and emergency/selective recalls now record successful measurements. Zero-result pull deposits/withdrawals and reverted calls do not initialize successful-operation samples. EMA updates themselves are excluded from measured adapter gas; preparation/step overhead must include accounting, EMA writes, logging, validation and wrapper dispatch.

Model = preparation (when applicable) + execution-step overhead × step count + intrinsic L2 overhead × transaction count + adapter gas + finalization. Current strategy batch size determines step count. Execution cost uses the greater of current Arbitrum L2 price and transaction gas price. Poster cost uses dynamic per-transaction/per-byte prices and configured wrapper bytes. It is an approximation of compressed transaction cost, not an exact Nitro simulation. Configured margin applies to the converted whole-plan cost, with rounding upward.

ETH/USD and USDC/USD have separate freshness limits, normalization and sanity bounds. Sequencer outage/recovery, stale/invalid data, fee read failure or implausible fee values produce an unreliable quote. The diagnostic fallback amount does not authorize an economic rebalance. `validatedPrices()` exposes the validated conversion inputs for historical receipt reconciliation.

The profitability gate retains hysteresis, benefit/cost ratio, recent-rebalance penalty, regime horizon/confidence and protection premium. In dynamic mode the yield benefit is calculated from the actual action-induced allocation delta. Yield losses reduce any protection premium. It no longer multiplies whole-portfolio APY delta by two-sided turnover.

## Governance and deployment

- Deployment and postflight now require `GAS_CONFIG_HASH` (keccak256 of the ABI returndata of `config()`), plus the three reviewed `GAS_*_FEED` addresses. They verify the Arbitrum fee precompile, fee availability/bounds, exact feed identities, configuration hash and completed governance transfer. A matching hash is an operator-reviewed configuration commitment, not proof of calibration. Adapter-specific floors must also be reviewed separately.
- `RebalanceScores(actionsHash, adapters, normalizedScores, apyBps, targetAssets, tvl)` is emitted once on successful preparation. Arrays share the scoring input order; targets are pre-filtering scoring targets. The indexed hash binds the filtered executable actions, strategy, chain, batch size and preparation flag, matching the estimator hash. Rejected/reverted preparation has no persistent event; use read-only scoring/preview for those cases. No events are emitted by static previews.
- Safety mandates remain independent of oracle/profitability availability, but each safety deposit now rechecks deposit controls and current caps/capacity. Invalid deposits emit `RebalanceDepositSkipped`; recovered cash remains idle and protective withdrawals can continue. Emergency recall entrypoints remain independent of this plan path.

- `setRebalanceGasEstimator` is admin-only, write-once, before parameter finalization, with no active plan.
- No recurring gas-quote setter or stored quote is introduced. Estimator configuration and adapter calibration are governed writes; ownership uses two-step transfer.
- The final reserved storage slot contains the estimator address and safety-plan flag. Existing preceding fields are retained.
- Unconfigured fixtures/strategies retain legacy gate behavior for compatibility. **New deployment scripts require `REBALANCE_GAS_ESTIMATOR`**, valid prices and completed estimator governance handoff before broadcasting strategy deployment. Postflight checks the same wiring/ownership.
- Deploy estimator script inputs are explicit: `GAS_PREPARE`, `GAS_STEP`, `GAS_FINALIZE`, `GAS_DEPOSIT_FLOOR`, `GAS_WITHDRAW_FLOOR`, `GAS_INTRINSIC`, `GAS_CALLDATA_BYTES`, `GAS_MARGIN_BPS`, `GAS_ETH_MAX_AGE`, `GAS_USDC_MAX_AGE`, `GAS_SEQUENCER_GRACE`, `GAS_FALLBACK_USDC`, `GAS_ETH_USD_FEED`, `GAS_USDC_USD_FEED`, `GAS_SEQUENCER_FEED`, `GAS_GOVERNANCE`.
- `DeployReadOnlyGasEstimator.s.sol` proposes governance; governance must accept before strategy deployment. No automatic migration or broadcast is part of this work.

## Keeper and shadow validation

Existing upkeep decisions remain on chain. The keeper needs no estimator-write job. Receipts now log effective gas price and total fee, plus estimator/economics events emitted by the strategy. Arbitrum receipt `gasUsed * effectiveGasPrice` already includes poster gas; do not add L1 gas again.

From `multyr-periphery/keeper`, run the read-only tool:

```sh
RPC_URL=<rpc> node scripts/rebalance-gas-shadow.ts <replacement-strategy> [prepare-tx step-tx ...]
```

The tool pins preview and gate reads to one block. For supplied receipts, it converts actual fees using validated historical prices at each receipt block. Invalid historical pricing yields null USDC cost, not a fabricated conversion. A plan quote must be compared with the entire transaction sequence, including preparation, every step, and any failure/cancellation costs. The tool marks receipt coverage as caller-supplied, not independently proven complete. It never sends transactions.

## Release criteria

Local tests cannot establish real-world estimation accuracy. Before deployment approval: calibrate preparation/step/finalization and per-adapter floors using cold wrapper receipts, cover all adapters and multiple TVLs/batch sizes, compare full estimated vs actual cost, choose feeds and their heartbeat limits, verify governance/configuration, and review the full replacement module set. The prior experiment's adapter microbenchmarks and gas figures are not integration benchmark results.

## Existing Core compatibility and configuration

The replacement `harvest()` accepts KEEPER_ROLE or CORE_ROLE and returns the Router-compatible `(int256 pnl, uint256 realized)`. Its selector remains unchanged for the existing upkeep caller. Pinned-fork integration verifies Router harvest and recall without changing deployed Core/Router/native-USDC code.

Replacement deployments require `SOURCE_STRATEGY` and `SOURCE_STRATEGY_UPKEEP`. Constructor values and remaining strategy controls are copied from those contracts and verified; adapter controls and upkeep targets are remapped. The safety-overflow module is now deployed and wired as well. [Settings migration](SETTINGS-MIGRATION.md) describes preserved values, runtime-state exclusions, remaining adapter-internal checks and the AWS/Router cutover. Passing interface/configuration tests does not replace full-plan gas calibration or a funded seven-adapter migration rehearsal.
