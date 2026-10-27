# Target reserve and exact-plan pricing

The review candidate adds `setTargetIdleBufferBps(uint16)` (admin only, 0–10,000). The deployment manifest must explicitly set **1000** for the requested 10% idle reserve. Unconfigured storage is zero; this is not a live configuration change. This reserve differs from `targetSafetyMarginBps`, which supplies additional headroom when a cap binds.

At each TVL tier, the planner selects the highest composite scores, up to 1/2/3/4/5 destinations at 25K/250K/1M/5M thresholds. `maxAdaptersPerAllocation` may lower that maximum. Exposure ceilings and risk, failure, liquidity, protocol capacity and relative exposure constraints can reduce deployment below the budget. The one-destination tier does not itself impose the former two-destination 55% ceiling.

The allocation budget is `TVL * (10000 - targetIdleBufferBps) / 10000`. Selected scores divide this budget; independent caps still apply. The target is an ending position, not a transfer amount. A deposit is the positive difference between target and current position. Withdrawals precede deposits. Funding includes existing idle plus realizable withdrawal proceeds, less the reserve. Illiquid withdrawals are clamped and deposits are reduced accordingly.

Example: 20.55 in Fluid, 4.45 idle, nothing in Euler: total 25, Euler target 22.50 and reserve 2.50. The plan withdraws 20.55 from Fluid and deposits 22.50 into Euler. With no existing idle, TVL is 20.55, the target is 18.495 and the reserve is 2.055. These are test examples, not assertions about current mainnet balances or scores.

Enabled allocation candidates and all registered adapters with recorded positions form the rebalance universe. Disabled, flagged, quarantined or lower-score adapters cannot gain capital but remain eligible for attempted withdrawals. Protocol liquidity or withdrawal failures can still prevent a recall; exclusion is not a promise of liquidity.

With a positive reserve, new-fund deployment uses the same target calculation, and legacy safety-overflow deployment is disabled so it cannot introduce off-target adapters or consume the intended reserve. Rebalance preservation of an above-target safety tranche is also disabled under this policy. These are explicit policy changes to review before deployment, not a reinterpretation of old overflow behavior.

The estimator receives the canonical funded action list. Its batch count, adapter directions, EMA/default choices and path overhead refer to that list. The gate evaluates the resulting allocation and costs. Remaining-plan checks enforce the current reserve and deposit eligibility; raising the reserve can invalidate a previously prepared deposit. An unprofitable Fluid-to-Euler move is still rejected. Winning the score comparison does not bypass the gate.

The prior 22 October calibration tables predate this policy change and are historical evidence only. Re-run component benchmarks and native Arbitrum fee validation for the final release before deployment approval.
