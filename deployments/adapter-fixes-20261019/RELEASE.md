# Adapter and allocation correction — 19 October 2026

Status: all 104 deployment transactions succeeded and all 22 contracts are explorer-verified. Live migration has not been executed. The exact unsigned Safe batches passed a fork rehearsal against the deployed addresses.

## Changes

- Venus discovers the market's annual time slots; the Arbitrum time-based market uses 31,536,000, eliminating the 4x rate error.
- All seven adapters expose an actual unlimited capacity (`uint256.max`) when their internal configuration uses zero as an unlimited sentinel.
- Morpho, Fluid and Dolomite calculate historical simple annualized PPS return using a common sampled-rate library. A completed observation remains available immediately after refresh. Observations require at least one hour, expire after two days, and losses immediately invalidate positive cached yield. Morpho also respects its shorter configured staleness limit. Repeated early refreshes cannot continually reset the measurement window.
- Rate sampling uses 1e24 shares to reduce rounding error on six-decimal assets; existing snapshot getters keep their prior scale. Morpho writes its market-rate cache and uses the sampled return for market comparisons.
- Global adapter exposure is set to 25%. Allocation allows five slots for small vaults (at least four plus diversification headroom), with a static limit of seven. Per-adapter floor overrides and safety overflow cannot bypass the global ceiling. Unallocatable funds remain idle. Deposit idle limits are explicitly 100% so capped or temporarily unavailable venues cannot make deposits revert; the 1% idle target still tells the keeper to seek eligible capacity. The cap is an allocation constraint; yield accrual or withdrawals can subsequently change percentages.
- Existing APY ABI names are retained for compatibility. These values are primarily simple annualized APR or historical PPS return, not a promise of compounded forward APY.
- Canonical rebalance deposits are limited to actual idle cash plus planned withdrawals, preventing preserved safety allocations from producing an unfundable plan. The same ordered, clipped actions are priced, gated and executed.
- Per-adapter gas floors replace oversized global defaults for the replacement adapters. EMA measurements above a floor still increase the quote. Oracle validation, Arbitrum L1/L2 accounting, transaction overhead and the 50% safety margin remain.

## Migration shape

The strategy's fixed modules require a replacement strategy to change allocation policy. The core vault, share token, Router, buffer and read-only gas estimator remain in place. New adapters bind to the new strategy. This deployment uses reviewed defaults and the explicit 25% setting; it does not copy old strategy settings.

Safe batch 1 proposes the replacement in the Router allowlist. After the on-chain delay, batch 2 disables old upkeep/deposits, recalls all old adapter assets to the unchanged vault, asserts the old strategy is drained, calibrates the new adapters, registers the replacement and disables the retired strategy. All calls in batch 2 must execute atomically. AWS cutover follows its successful execution.

Snapshot-based adapters start with no completed observation. They need at least one hour before a fresh historical rate can be measured. This may initially leave funds idle under the strict cap; it must never justify exceeding the cap.

## Deployment and keeper handoff

- Strategy: `0xB143245BBB4333435CD8cc7CcCe1d6E0ABcF5DB6`
- StrategyUpkeep: `0x7c8de9F5d184b507ed2d110403cf4792865C8123`
- Strategy creation transaction: `0xf5c41d70e79315e0dfbee4740fbcd8d0e4e6841ae0223b40eda50238eca908cf`
- Actual L2 deployment block: `516130405` (use this for indexing, not Solidity's reported block number).
- Keeper changes pushed to `Multyr/multyr-periphery`, branch `keeper_smart_contracts`, commit `25c538648e7b898f2e65eff345006d352f69f3e8`.
- Pending keeper file: `keeper/config/arbitrum-one.next.json`; activate using `KEEPER_CONFIG=/app/config/arbitrum-one.next.json` after Safe migration. AWS is not activated by this release.

`addresses.json` contains the complete address book; `VERIFIED.md` links every deployed contract. `provenance/manifest.json` identifies the exact creation artifacts and preserved compiler-metadata source dependency closures. The strategy deployment came from the modified working tree, not the clean historical HEAD; do not identify the historical HEAD alone as the deployed source.

The full-plan fork test used hypothetical APY changes on real protocol adapters. It consumed 5,943,262 wrapper gas against 6,463,000 modeled L2 gas and quoted 468,248 raw USDC (0.468248 USDC), including modeled costs and margin. This is one scenario, not a fixed quote or a live rebalance receipt.
