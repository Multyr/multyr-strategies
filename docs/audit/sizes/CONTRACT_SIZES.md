# Contract Sizes -- post Wave 1+2 refactors

EIP-170 hard limit: **24,576 B** | Project 1KB-safety rule: **23,552 B**

Updated: 2026-06-20 (post F-SIZE-01 + F-SIZE-02 Wave 2 refactors)

## Production contracts

| Contract | Runtime (B) | EIP Margin | Proj Safety | Status |
|---|---:|---:|:---:|:---:|
| StrategySettingsModule | 22,901 | 1,675 | PASS | YELLOW |
| StrategyRouter | 22,091 | 2,485 | PASS | YELLOW |
| MorphoUsdcMultiMarketAdapter | 21,851 | 2,725 | PASS | YELLOW |
| UsdcMultiLendingVault | 21,299 | 3,277 | PASS | GREEN (was RED pre-F-SIZE-02) |
| StrategyScoringModule | 21,528 | 3,048 | PASS | GREEN (was RED pre-F-SIZE-01) |
| DolomiteUsdcMultiMarketAdapter | 20,843 | 3,733 | PASS | GREEN |
| EulerUsdcMultiMarketAdapter | 19,367 | 5,209 | PASS | GREEN |
| StrategyRebalancePlanModule | 18,895 | 5,681 | PASS | GREEN |
| CometUsdcMultiMarketAdapter | 18,709 | 5,867 | PASS | GREEN |
| StrategyAllocCalcModule | 18,035 | 6,541 | PASS | GREEN |
| StrategyAdapterOpsModule | 16,336 | 8,240 | PASS | GREEN |
| StrategyRebalanceGateModule | 14,152 | 10,424 | PASS | GREEN |
| StrategyParamsModule | 13,992 | 10,584 | PASS | GREEN |
| StrategySafetyOverflowModule | 13,424 | 11,152 | PASS | GREEN (new in F-SIZE-01) |
| AaveV3USDCAdapter | 13,020 | 11,556 | PASS | GREEN |
| VenusUsdcMultiMarketAdapter | 10,836 | 13,740 | PASS | GREEN |
| StrategyExplainabilityLens | 9,765 | 14,811 | PASS | GREEN |
| StrategyStorageLayout | 9,747 | 14,829 | PASS | GREEN |
| RewardSwapHelper | 9,185 | 15,391 | PASS | GREEN |
| FluidUsdcMultiMarketAdapter | 8,801 | 15,775 | PASS | GREEN |
| StrategyUpkeep | 8,663 | 15,913 | PASS | GREEN |
| StrategyHealthRegistry | 3,044 | 21,532 | PASS | GREEN |
| AdapterFactory | 2,817 | 21,759 | PASS | GREEN |
| StrategyBootstrapper | 2,276 | 22,300 | PASS | GREEN |
| StrategyConfigLib | 3 | 24,573 | PASS | GREEN (pure library, inlined) |

## Summary

| Metric | Pre-Wave 2 | Post-Wave 2 |
|---|---|---|
| EIP-170 BLOCKER (> 24,576 B) | 0 | 0 |
| RED (margin < 1,000 B) | 2 | 0 (FIXED) |
| YELLOW (margin 1,000-5,000 B) | 4 | 3 |
| Project 1KB-safety violations (> 23,552 B) | 2 | 0 (FIXED) |
| Largest contract | StrategyScoringModule 24,426 B | StrategySettingsModule 22,901 B |

## Refactors that closed RED status

| Finding | Contract | PRE | POST | Fix |
|---|---|---:|---:|---|
| F-SIZE-01 | StrategyScoringModule | 24,426 B | 21,528 B | Extracted to StrategySafetyOverflowModule |
| F-SIZE-02 | UsdcMultiLendingVault | 24,048 B | 21,299 B | Extracted realizeLiquidity + degraded mode to modules |

Note: CoreHarness (45,047 B) is a test-only harness, not deployable -- excluded.
