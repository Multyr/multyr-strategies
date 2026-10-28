# Mechanical symbol inventory

Text-reference counts are a review aid, not proof of dead code: public getters can be consumed externally. Deprecated compatibility fields and telemetry are documented in PRE_AUDIT_CLEANUP.md. This inventory does not authorize removal of other public ABI surfaces.

- `MIN_EMA_SAMPLES`: 2 textual references, `src/strategies/usdc-lending/gas/ReadOnlyGasEstimator.sol`
- `MAX_EMA_AGE`: 2 textual references, `src/strategies/usdc-lending/gas/ReadOnlyGasEstimator.sol`
- `MIN_MAX_FEED_AGE_SEC`: 2 textual references, `src/strategies/usdc-lending/swap/RewardSwapHelper.sol`
- `MAX_MAX_FEED_AGE_SEC`: 2 textual references, `src/strategies/usdc-lending/swap/RewardSwapHelper.sol`
- `MAX_BOOTSTRAP_DURATION`: 2 textual references, `src/strategies/usdc-lending/controller/StrategyStorageLayout.sol`
- `MAX_BACKFILL`: 2 textual references, `src/strategies/usdc-lending/controller/StrategyStorageLayout.sol`
- `degradedModeEnteredAt`: 2 textual references, `src/strategies/usdc-lending/controller/StrategyStorageLayout.sol`
- `estimatedGasCostUSDC`: 1 textual references, `src/strategies/usdc-lending/controller/StrategyStorageLayout.sol`
- `exitDriftBps`: 2 textual references, `src/strategies/usdc-lending/controller/StrategyStorageLayout.sol`
- `minLiquidityReadinessBps`: 2 textual references, `src/strategies/usdc-lending/controller/StrategyStorageLayout.sol`
- `regimeHysteresisMultBps`: 2 textual references, `src/strategies/usdc-lending/controller/StrategyStorageLayout.sol`
- `regimeBudgetMultBps`: 2 textual references, `src/strategies/usdc-lending/controller/StrategyStorageLayout.sol`
- `MAX_EXTERNAL_TVL`: 2 textual references, `src/strategies/usdc-lending/controller/StrategyParamsModule.sol`
- `MARKET_QUARANTINE_THRESHOLD`: 2 textual references, `src/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol`
