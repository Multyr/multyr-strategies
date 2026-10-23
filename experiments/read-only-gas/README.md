# Read-only rebalance cost prototype

Historical experiment retained for reproducibility. The replacement-strategy integration now lives in `src/strategies/usdc-lending/gas/` and the controller modules; see [integration notes](../../docs/gas-estimation/README.md). Neither version has been deployed by this task.

Status: isolated experiment; not deployed or wired into the strategy. Results below are from 15 October 2026. Production deployment is not recommended until the integration and validation gaps below are closed.

## Implementation

`src/ReadOnlyGasEstimator.sol` models execution gas separately from Arbitrum poster fees, converts ETH costs to USDC using validated ETH/USD and USDC/USD feeds, rounds up, and applies a margin. It checks oracle rounds, age, decimals, bounds and sequencer recovery. Invalid dependencies produce an unreliable quote; the candidate gate fails closed. The numeric fallback is diagnostic, not permission to execute with invalid pricing.

`CandidateActions.sol` extracts the current withdrawal-first, scored-deposit ordering and action filtering. `CandidateEvaluation.sol` uses this same returned action list for benefit and cost calculations. Production execution must consume that list and revalidate it before spending. This library has not replaced the current executor, including its idle clamping and leftover redeployment behavior.

The estimator reads deposit and withdrawal EMAs and applies conservative global or adapter-specific floors. Only its immutable calibrator can change adapter floors. Production ownership/governance remains to be designed. The experiment has no recurring keeper gas quote writes. `EmaPrototype.sol` tests the EMA arithmetic but does not instrument existing contracts.

## Results

19 unit/fuzz tests passed, including oracle failures, gas spikes, action filtering, floor authorization and EMA bounds. See `results/unit-tests.log`.

| Candidate actions | Estimator call gas (account cooled) | Repeated call gas |
| --- | ---: | ---: |
| 2 | 81,891 | 81,740 |
| 4 | 94,405 | 94,254 |
| 6 | 106,938 | 106,771 |
| 8 | 119,482 | 119,289 |
| 10 | 132,034 | 131,810 |

These are test-harness call measurements, not independently cold transaction receipts. A stored-quote baseline measured 66,403 gas for initial update, 32,176 for repeated same-transaction update, and 4,862 for reading. Those exclude complete transaction and L1 costs. Net operational savings are **not established**; avoid estimating every candidate combination independently. Share oracle/fee reads and evaluate the final candidate once where possible.

Fork block 515046000: all 15 adapter round trips succeeded at 10, 100 and 10,000 USDC. No transactions were broadcast by these tests.

| Adapter | Deposit gas range | Withdrawal gas range |
| --- | ---: | ---: |
| Aave | 428,192–428,219 | 216,000–216,014 |
| Morpho | 788,937–788,965 | 1,448,334–1,448,347 |
| Euler | 588,684–588,709 | 288,535–288,549 |
| Fluid | 302,488–302,530 | 183,652–183,666 |
| Venus | 407,806–407,833 | 247,192–247,205 |

These are adapter call measurements with token setup and a deposit/withdrawal in one test transaction. They are not independent cold executions or complete strategy rebalances. Dolomite and Comet were not covered. See `results/adapter-fork.log`.

Provisional defaults are 1,000,000 deposit gas and 2,000,000 withdrawal gas, with 25% margin, 400,000 preparation gas and 150,000 per execution step. These exceed the sampled adapter calls but are not calibrated production bounds. Mock four-action cost was 0.510762 USDC; the tested +2% yield scenario rejected 21 and 100 USDC books and accepted 10,000 USDC. This is scenario evidence, not a general TVL threshold.

At live block 515047018, the pre-margin poster model underestimated NodeInterface RPC estimates by 11.16% for direct preparation and 3.57% for keeper preparation/execution. The 25% margin covered these samples only. Dynamic per-byte pricing is still an approximation of compressed transaction costs, not an exact quote or proven bound. See `results/live-fee-comparison.json` and `fee-benchmark.cjs`.

## Required before deployment

1. Instrument both strict and best-effort deposit paths and all withdrawal paths. Current best-effort deposits record gas; strict deposits do not. `recordWithdrawGas` has no in-tree caller. Existing zero withdrawal EMAs cannot be trusted as measurements.
2. Integrate one shared candidate builder with the actual gate and executor, covering preparation, every transaction, skips/clamps, finalization and leftover redeployment. Include estimator overhead once per real evaluation and benchmark the entire gate.
3. Select and validate production price feeds and governance, including behavior during USDC depegs and sequencer outages. Current price-feed tests use mocks.
4. Preserve existing cooldowns, caps and health checks, add hysteresis as appropriate, and re-evaluate remaining economics before execution when prices or the plan change. Invalid pricing blocks discretionary rebalances; emergency withdrawals need a separate safety policy.
5. Shadow full keeper transactions against receipts across all adapters, vault sizes and multi-step plans. Compare actual total ETH paid converted at execution-time prices, and reconcile poster gas without counting it twice. The fork microbenchmarks do not satisfy this acceptance criterion.
6. Compare full operational cost with the stored-quote approach at realistic keeper frequency. Read-only evaluation is materially more expensive than reading a stored quote, so eliminating quote updates alone does not prove savings.

## Reproduce

From this directory, run `forge test --no-match-contract AdapterForkTest -vv`.
For fork checks, run `RUN_ADAPTER_FORK=true forge test --match-contract AdapterForkTest --fork-url https://arb1.arbitrum.io/rpc --fork-block-number 515046000 -vv`.
Run `node fee-benchmark.cjs` for a new live fee comparison (overwrites that results file).

## Fee semantics references

- [Arbitrum gas and fees](https://docs.arbitrum.io/how-arbitrum-works/deep-dives/gas-and-fees): poster fees and execution accounting.
- [ArbGasInfo interface](https://raw.githubusercontent.com/OffchainLabs/nitro-precompile-interfaces/main/ArbGasInfo.sol): current price components.
- [NodeInterface](https://developer.arbitrum.io/arbitrum-essentials/nodeinterface/overview): RPC estimation interface, unavailable to Solidity as an ordinary on-chain call.
