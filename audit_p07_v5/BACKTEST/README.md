# BACKTEST -- audit_p07_v5

## Status

V10.0 is a **deployment-pattern refactor** only. It introduces no changes to:
- Rebalance logic (StrategyRebalancePlanModule, StrategyRebalanceGateModule)
- Scoring algorithm (StrategyScoringModule)
- Allocation calculation (StrategyAllocCalcModule)
- Safety adapter tier mechanics (StrategySettingsModule, StrategyStorageLayout)

**V10 has zero impact on backtest results.** The backtest measures the allocator's
historical performance, which depends exclusively on the controller modules listed
above -- none of which changed in V10.

## Reference

V9.2+P0.7 backtest results from audit_p07_v4 (PRODUCTION_VALIDATION_FINAL.csv,
equity_realistic.csv, etc.) are valid and unchanged for V10.

If the audit_p07_v4 backtest artifacts are required, request from:
  - Pierre Bertola (pierbertola@hotmail.com)
  - Or Cowork session archive: vault-usdc2-brain / Multyr/multyr-research

## V10 Regression Tests (substitute for backtest)

The V10 fork tests (EVIDENCE/forktest/V92_SafetyTierE2E.t.sol,
V92_AdversarialScenarios.t.sol) verify E2E lifecycle behavior against
real Arbitrum state at block 472761449. These are the operational regression
tests for V10.