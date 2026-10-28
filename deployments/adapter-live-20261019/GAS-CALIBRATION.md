# Gas calibration checked against live settings

Live check block: 516222569. The current strategy points to estimator 0xD29649980B46e73127d14Cd6f2620527E3c9934d. The calibrator is the governance Safe. Oracle validation passed at that block. All seven target-adapter overrides are unset; the four replacement adapters are not yet registered.

The existing 51-call `01-activate-adapter-fixes.safe.json` ALREADY contains these seven calibration writes. No additional JSON and no change to its calldata are needed. Execution by the Safe is required to apply the values; they have not been written on-chain by this task.

| Adapter | Measured deposit gas | Measured withdrawal gas | Deposit floor | Withdrawal floor |
|---|---:|---:|---:|---:|
| Aave | 443,812 | 218,486 | 600,000 | 300,000 |
| Morpho | 895,158 | 2,971,173 | 1,100,000 | 4,000,000 |
| Comet | 396,863 | 200,553 | 550,000 | 300,000 |
| Euler | 658,592 | 305,985 | 900,000 | 450,000 |
| Dolomite | 894,418 | 444,184 | 1,200,000 | 600,000 |
| Fluid | 332,439 | 186,263 | 450,000 | 300,000 |
| Venus | 525,791 | 249,691 | 750,000 | 350,000 |

Measurements come from the final seven-adapter fork round-trip run in ../adapter-fixes-20261019/release-validation.log. Each floor exceeds the measured sample; these are conservative calibration points, not guaranteed maximum transaction gas. Morpho's latest withdrawal used about 2.97M gas, so the earlier 1.45M sample cannot justify a lower withdrawal allowance.

The estimator uses max(EMA, adapter floor), falling back to the global floor only when the adapter override is zero. Therefore EMA learning does not automatically reduce a quote below the configured floor. Per-adapter overrides replace the global 2M deposit / 3M withdrawal floor for these addresses; unconfigured adapters retain global defaults.

Retained settings: preparation 1.5M gas, execution-step overhead 1M per transaction, finalization 300k, intrinsic 21k per transaction, modeled calldata 164 bytes, 50% margin, ETH/USD freshness 7200 seconds, USDC/USD freshness 90000 seconds, sequencer grace 3600 seconds, invalid-data fallback 100 USDC. These are not reduced merely to force profitability. USDC estimates vary with the actual action list, transaction count, validated prices and Arbitrum fee data; no fixed 20–30 cent quote is promised.

Warm NAV: the repository W6 job polls every 120 seconds and refreshes 120 seconds before expiry. With a 600-second TTL this gives roughly eight minutes between refreshes. No interval change is included.
