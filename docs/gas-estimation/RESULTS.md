> Release update: replacement contracts are now deployed and the exact Safe migration batches passed a fork rehearsal. See [the release report](../../deployments/replacement-20261017/RELEASE.md). Earlier sections below are retained as dated validation history.

# Validation — 17 October 2026

## Final regression run

`forge test --match-path 'test/strategies/usdc-lending/*.t.sol' -vv` completed with **2,542 passed, zero failed and eight skipped across 177 suites**. The two new opt-in fork checks are among the skips in this general run; both were executed successfully in the separate pinned-fork runs below. Other environment-dependent fork suites remain skipped, including the full deployment/deposit rehearsal.

The estimator deployment, strategy deployment and shadow postflight scripts all compile. `git diff --check`, shell syntax and the read-only snapshot tool's Python syntax checks pass. This is not production deployment approval; the remaining release gates below still apply.

## Core compatibility and settings carry-over

- Six Router/harvest integration regressions passed, including the unchanged upkeep caller, role boundaries, partial adapter failures and no double-reporting of previously accrued NAV.
- A pinned Arbitrum fork at block 515526090 passed harvest and recall through the deployed Router using unchanged Core/Router/native-USDC runtime code. The reward adapter is a funded fixture; this is interface validation, not a full seven-protocol migration rehearsal.
- Six settings-copy regressions passed, including constructor/global parity against the pinned live source, nondefault regime/control values, zero defaults, disabled/quarantined adapters, mapped safety fallback and expired bootstrap behavior.
- The public source snapshot contains 82 scalar values and seven adapter configurations. Deployment reads source settings, maps upkeep controls and verifies parity. It now deploys/wires the previously omitted safety-overflow module. See [configuration boundaries and cutover](SETTINGS-MIGRATION.md).
- Updated strategy runtime is 21,813 bytes; safety-overflow runtime is 13,156 bytes. All recorded runtimes remain below EIP-170.

## Earlier strategy follow-up

- 351 targeted Solidity tests passed across 36 suites after adding safety-plan deposit checks, score events and deployment preflight checks. New regressions cover deposit disablement, capacity reduction, flag changes, oracle-independent safety execution, exact score/event data and invalid deployment dependencies/configuration.
- 32 keeper tests and TypeScript checking passed, including score-event decoding. Keeper telemetry recognizes `RebalanceScores` and `RebalanceDepositSkipped`.
- All three estimator/strategy deployment and postflight scripts compiled successfully. Changed runtimes remain below EIP-170: plan module 21,202 bytes, allocation module 20,960 bytes, largest changed runtime settings module 22,939 bytes. Sizes are refreshed in `results/runtime-sizes.json`.
- Successful preparation now emits the action-bound score event. The mock preparation calls measured 689,676 and 710,809 gas for 10,000 and 300,000 USDC scenarios; whole plans measured 1,781,132 and 1,839,855 gas. These remain call-level mocks, not cold wrapper receipts or production calibration. Preparation increased by about 9,443 gas in these three-adapter fixtures; larger adapter sets need separate measurement.
- Safety plans skip unsafe deposits with an event while allowing protective recalls; the economic exemption no longer exempts those deposits from current controls/caps/capacity.
- Deployment and postflight require reviewed feed identities, the Arbitrum fee source, live fee availability, completed estimator governance handoff and an exact `GAS_CONFIG_HASH`. This does not certify calibration or adapter-specific floors.
- No deployment or migration was performed. The local `.env` has no estimator address, reviewed feed addresses, calibration inputs or configuration hash; `.env.shadow` is absent. A live deployment dry run is therefore not established.
- Remaining release work: cold full-wrapper calibration across all adapters, including failure costs; repair the shadow report's rejection of failed receipts; validate keeper gas-limit headroom through actual wrapper execution. AWS live-state verification requires an authenticated session.

## Previous validation — 16 October

The integration is implemented locally. No deployment or migration was performed.

## Automated checks

- 345 Solidity tests passed across 36 suites: estimator, dynamic gate/plan integration, multi-step rebalancing, accounting, role matrix, V10 engine and the base vault regression suites.
- 31 keeper tests passed; TypeScript typechecking passed.
- `DeployReadOnlyGasEstimator.s.sol`, `DeployUsdcLendingStrategy.s.sol` and `PostflightUsdcLendingShadow.s.sol` compiled successfully. They were compiled only, never broadcast.
- All changed runtime contracts satisfy EIP-170. Largest: StrategySettingsModule, 22,939 bytes (limit 24,576). Full sizes are in `results/runtime-sizes.json`.
- Whitespace/error checks passed. Foundry could not write its optional global signature cache under the sandbox; this did not affect compilation or test results.

The targeted tests exercise stale/invalid oracle rejection, sequencer recovery, transaction-price spikes, per-adapter floors, governance ownership, static preview, exact prepared-action parity, changed capacity, partial/failed operations, successful multi-step finalization, EMA recording and emergency exits during oracle failure. Legacy gas-mode regression tests remain covered.

## Benchmark limits

Estimator-only call-level measurements were approximately 83k–137k gas for 2–10 actions. The harness labels its first/repeated calls cold/warm, but it does not reproduce separate completely cold transactions. Those labels must not be interpreted as receipt-level gas bounds.

Full mock-plan calls for 10,000 and 300,000 USDC books consumed about 1.77m and 1.83m gas across preparation and two execution steps. Preparation alone measured about 680k–701k, demonstrating that the original experimental 400k preparation allowance was insufficient for that phase. The integration fixture now uses illustrative 800k preparation and 600k per-step overhead; production deployment deliberately requires explicit calibrated inputs. Adapter floors are still 1m deposit / 2m withdrawal in that fixture, with a 25% margin.

The 21 USDC scenario had no executable candidate after action filtering; a zero/default quote there is not a zero execution cost. The 100 USDC scenario was rejected. The 10,000 and 300,000 USDC scenarios were accepted and completed. These are mock-price/mock-adapter scenarios, not universal TVL thresholds or live Arbitrum fee observations.

## Before release approval

Realistic cold keeper-wrapper receipts on an Arbitrum fork/shadow deployment remain necessary to calibrate every adapter, preparation, per-step/finalization overhead and the L1 posting model. Select reviewed live feed addresses and heartbeat limits, complete governance handoff, and validate estimated vs actual total plan costs. Historical adapter microbenchmarks are not a substitute for these full-plan observations. Net savings relative to keeper-published quotes are not yet established.

## Reproduce

```sh
forge test --match-path 'test/strategies/usdc-lending/{ReadOnlyGas*,MultiStepRebalance,RebalanceEngineV10,RoleGateMatrix,RebalanceAccounting,UsdcMultiLendingVault}.t.sol' -vv
forge build script/DeployReadOnlyGasEstimator.s.sol script/DeployUsdcLendingStrategy.s.sol script/PostflightUsdcLendingShadow.s.sol
```

In `multyr-periphery/keeper`, run `npm run typecheck` and `npm test`. Run the shadow report described in `README.md` against the replacement strategy once a reviewed deployment exists. No private key is needed for the shadow report.
