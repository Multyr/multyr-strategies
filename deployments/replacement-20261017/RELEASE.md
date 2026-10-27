# USDC strategy replacement — 17 October 2026

Status: replacement strategy, estimator and migration guard deployed; all 104 strategy deployment receipts succeeded. Postflight ownership, role and module-wiring checks passed. Exact generated Safe-batch rehearsal passed against the deployed contracts (3,380,720 test gas), including a check that the unchanged Router can route deposits to the replacement.

Strategy: `0xa9E676D15976A1332905238ca609Dff9A484Efe0`

Upkeep: `0xbcaC314E7237b14E11644FC6Ba73675c8c0612DF`

## Selected configuration

The user withdrew the instruction to preserve old strategy settings. `COPY_SOURCE_SETTINGS=false`; adapter/strategy/upkeep settings are fresh deployment defaults. Existing Core, Router, guardian, Safe and keeper signer identities stay unchanged.

The deployment uses TVL-tier exposure caps (`adapterMaxExposureBps=0`, the existing dynamic-cap sentinel). This permits one adapter at TVL below 25,000 USDC; larger tiers diversify. Aave and Fluid are ordered safety fallback venues, each with an 80% fallback absolute cap and 10% external-TVL cap. Overflow targets at most 1% idle cash. Bootstrap lasts three days. These settings are deliberately not represented as copies of the old settings.

The gas model uses 1.5m preparation overhead, 1m overhead per step, 300k finalization, 2m deposit and 3m withdrawal floors per adapter, 21k intrinsic gas per transaction, 164 calldata bytes, and a 50% cost margin. ETH/USD maximum age is 7,200 seconds; USDC/USD maximum age is 90,000 seconds; sequencer recovery grace is 3,600 seconds. These are operational thresholds, not claims about official feed heartbeats. Invalid price/fee inputs reject economic rebalances. Oracle failure does not block emergency recalls.

## Safe order

1. Execute `01-propose-allowlist.safe.json` with the governance Safe on Arbitrum (42161).
2. Wait five minutes after proposal execution (the live Router delay is 300 seconds); confirm the on-chain ETA.
3. Simulate and execute `02-migrate.safe.json` as one atomic batch. It disables the old upkeep, requires no active old plan, disables old deposits, sweeps all seven old adapters, recalls USDC to Core, and checks that total and per-adapter residual balances are at most 100 raw USDC units (0.0001 USDC). Only then does it register the replacement and disable the old strategy.
4. Perform the AWS keeper address/build rollout after the Safe migration succeeds, as requested. No AWS rollout has been performed. Existing vault, claim-settlement and fee jobs retain their addresses. Update strategy upkeep W2 and strategy liquidity W5 together; avoid overlapping workers using the same KMS signer.

The migration returns assets to Core. It does not force capital reserved for pending withdrawal claims into the replacement. Normal Core allocation handles deployable surplus after cutover.

## Validation limits

Fork measurements execute real protocol contracts but are call-level gas observations; they are not fully cold Arbitrum receipts or proof of the L1 fee model's accuracy. Foundry does not implement ArbOS precompile 0x6c, so simulations replay its actual RPC response. Live estimated-versus-actual plan costs must continue to be monitored after activation. No existing vault funds have been moved on-chain by these deployment scripts.

Explorer source verification completed after explicit publication approval: all 24 replacement-deployment contracts are verified on Arbiscan. See `verification/status.json` for addresses, links and outcomes. The allocation module required the original full compilation source set; its bytecode was reproduced exactly locally before the successful standard-JSON submission.

## Results

- All 104 strategy deployment transactions succeeded; receipt fees total 0.001691310176070994 ETH, excluding the separate estimator and guard deployments.
- Postflight passed: seven adapters, estimator binding, module wiring, governance ownership, intended keeper/Core roles, removed deployer roles and renounced bootstrap role.
- Real-protocol deposits and recalls passed at 100, 10,000 and 200,000 USDC; all seven adapters passed individual 1,000 USDC round trips. These funds were fork fixtures, not live transfers.
- The full profitable four-action plan completed with zero plan failures: 6,337,365 measured wrapper gas versus 12,863,000 modeled L2 gas, modeled cost 939,503 raw USDC (0.939503 USDC). Hypothetical APY overrides were used only in the fork scenario and were not deployed.
- A separate scenario correctly cancelled a zero-yield remaining suffix. An unfunded candidate was rejected before execution.
- 24 targeted Solidity integration tests passed; keeper type-checking and 32 keeper tests passed. Earlier broad regression results are historical and precede the final capacity-target and recall changes.
- Exact 1-call proposal and 18-call migration batches passed on a live-contract fork. All funds returned to Core; old residual was within 100 raw units, replacement enabled, old disabled, and Router deposit planning selected the replacement.

No Safe proposal or migration was submitted or signed by this agent. Import the JSON files into Safe Transaction Builder, preserving order and atomic execution. Re-simulate at execution time.
