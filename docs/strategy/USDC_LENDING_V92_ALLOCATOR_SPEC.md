# USDC Multi-Lending Strategy v9.2 — Allocator Spec

> Audience: institutional LPs evaluating an allocation. Read alongside
> `docs/audit-scope.md`, `docs/threat-model.md`, `docs/SAFETY_ADAPTER_TIER.md`.

## Executive summary

The strategy is an Aave-anchored, diversified USDC yield allocator deployed on
Arbitrum. It rebalances across up to 7 ERC-4626-compatible lending venues
(Aave v3, Compound v3, Fluid, Euler v2, Dolomite, Morpho Blue, Venus), using
governance-tunable scoring weights and a two-tier cap framework.

The v9.2 release (P0.7 Safety Adapter Cap Tier) introduces a governance-approved
elevated cap for Aave v3 USDC, enabling the protocol to park overflow liquidity
into the deepest, lowest-risk venue without weakening the per-adapter risk
framework on the other six.

**Backtest results — Realistic scenario, 2024-01-01 → 2026-05-31 (882 days):**

| Metric                          | Strategy   | Aave v3 standalone | Equal-weight*  |
|--------------------------------|-----------:|-------------------:|---------------:|
| Annualized TWR (USD)            | **5.62%**  |              5.37% |          7.37% |
| Sharpe USD (SOFR rf)            | **+0.729** |             +0.33  |          +3.04 |
| Max drawdown USD                |    -0.145% |            -0.153% |       -0.141%  |
| Idle drag (mean)                |     8.28%  |                  — |              — |
| Final NAV ($1M init)            | $1,141,283 |        $1,134,651  |     $1,187,560 |

> *Equal-weight uncapped is a non-investable benchmark — it ignores
>  per-adapter rel caps that the protocol enforces in production.

Strategy outperforms 5 of 6 individually-investable single-market adapters on
risk-adjusted return. Dolomite USDC nominal APY 10.6% is higher, but its
$1.75M median external TVL makes it non-investable at $1M+ scale.

## Architecture

Five execution surfaces, all enforced on-chain via delegatecall modules sharing
a single storage layout (`StrategyStorageLayout.sol`):

| Module                            | Purpose                                              |
|-----------------------------------|------------------------------------------------------|
| `StrategyScoringModule`           | adapter scoring, deploy-idle, harvest                 |
| `StrategyAllocCalcModule`         | pure-view computation: scores → targets → headrooms   |
| `StrategyAdapterOpsModule`        | safeAdapterDeposit / withdraw / record-failure        |
| `StrategyRebalanceGateModule`     | P0-P3 hysteresis + cap-drift mandate                  |
| `StrategyRebalancePlanModule`     | multi-step rebalance plan preparation + execution     |
| `StrategySettingsModule`          | governance setters (PARAM_ROLE + DEFAULT_ADMIN_ROLE)  |

## Risk framework

Four layers, in order of precedence:

1. **Deploy gate.** Per-adapter `_checkAdapterEligibility` rejects deposits
   into adapters that are flagged, quarantined, below MICRO confidence band,
   above abs/rel cap, or in mandate cooldown.
2. **Soft incentive.** `overCapRiskPremiumBps` tilts the benefit/cost gate to
   prefer divestiture moves on adapters above their relative cap, even if the
   APY uplift is negative.
3. **Mandate gate.** `_checkCapDriftMandate` forces a rebalance plan when any
   adapter exceeds `cap × (1 + capDriftToleranceBps / 1e4)`. The mandate
   bypasses the normal benefit/cost gate but never violates the cap framework
   itself — it forces the position back **toward** the cap.
4. **Safety tier (P0.7).** Governance-approved second cap for explicitly
   designated parking venues. See `docs/SAFETY_ADAPTER_TIER.md`.

## Capacity bands

The strategy scales sublinearly above $50M AUM because the relative cap on
small adapters (Euler, Morpho Blue, Dolomite) becomes binding earlier than
the absolute cap. Practical capacity at the v9.2 setpoint:

| AUM target  | Expected TWR USD | Rel-cap binding on                  |
|------------:|-----------------:|--------------------------------------|
|       $1M   |            5.62% | none — all adapters operable          |
|       $10M  |          ~5.45%  | Euler v2, Morpho Blue                 |
|       $50M  |          ~5.20%  | Euler v2, Morpho Blue, Compound v3    |
|      $250M  |          ~4.85%  | most adapters; Aave + safety tier carry |

Beyond $250M AUM the Aave safety tier becomes the dominant venue (60-70% of
TVL). The Sharpe ratio remains positive but the alpha vs Aave-standalone
narrows to single bps. The protocol governance has flagged $250M as the soft
capacity ceiling for the v9.2 contract; further scale requires additional
safety adapters (see `docs/GOVERNANCE_POLICY_TRACK.md` GP-10).

## Operating profile

| Metric                                | Value (steady-state) |
|---------------------------------------|---------------------:|
| Rebalance frequency                   | ~0.4 / day (~150/yr) |
| Harvest frequency                     | ~62 / year (~1 / 6d) |
| Average actions per rebalance         | 2.1                  |
| Average gas per rebalance (Arbitrum)  | ~280k gas (~$0.05)   |
| Mandate-driven rebalances             | < 10% under v9.2     |
| Adapter mandate recurrence p95        | 45 days              |

The keeper system runs on Chainlink Automation with a redundant secondary
keeper on a 6-hour cron fallback. LINK + gas operating cost (~$200/month at
$10M AUM, $1500/month at $100M AUM) is paid from a protocol treasury
allocation, NOT subtracted from LP yield.

## Comparison vs alternatives

| Alternative          | Net APY USD | Sharpe | Pros                              | Cons vs v9.2                              |
|---------------------|------------:|-------:|-----------------------------------|--------------------------------------------|
| **v9.2 strategy**    |   **5.62%** | +0.73  | diversified, automated, capped    | —                                          |
| Sky DSR              |       4.50% | +0.55  | T-bill-backed, regulator-friendly  | yield ceiling                              |
| Aave v3 USDC (raw)   |       5.37% | +0.33  | single-protocol simplicity         | concentration, manual cap mgmt             |
| Morpho curated vault |   varies    | varies | curator-tuned                      | no on-chain risk overlay, opaque selection |
| Gauntlet OCIO        |   varies    | varies | active risk management             | quarterly rebalance cadence, governance lag|

## Reading guide for an allocator

For a complete diligence pass:

1. `docs/overview.md` — protocol intent and high-level design.
2. `docs/wiring.md` — module wiring + delegatecall semantics.
3. `docs/audit-scope.md` — what auditors are asked to check.
4. `docs/threat-model.md` — adversarial scenarios + mitigations.
5. `docs/invariants.md` — formal properties + test coverage.
6. `docs/SAFETY_ADAPTER_TIER.md` — the P0.7 design rationale + backtest.
7. `docs/GOVERNANCE_POLICY_TRACK.md` — GP-10 governance procedures.
8. This document (allocator-facing summary).
