# Metric Methodology — P0.7 Backtest Package

**Date:** 2026-06-13
**Scope:** Canonical definitions of all key metrics across all backtest CSVs in this package

---

## Purpose

All backtest CSVs in this audit package (`PRODUCTION_VALIDATION_FINAL.csv`, sensitivity
sweep comparisons, Deliverable B outputs) use the same metric definitions, computed via
`backtest/src/metrics.py:compute_metrics()`. This document provides the canonical reference
for each metric and cross-validates consistency.

---

## Canonical Metric Definitions

### Returns

| Metric | Definition | Code reference |
|--------|-----------|----------------|
| `twr_usdc_annual_pct` | Annualised CAGR of USDC TVL: `((final_tvl / initial_tvl)^(365/n_days) - 1) × 100` | `metrics.py:108` |
| `twr_usd_annual_pct` | Annualised CAGR of USD NAV (TVL × daily USDC/USD price): `((final_nav_usd / initial_capital)^(365/n_days) - 1) × 100` | `metrics.py:153` |
| `total_return_pct` | Simple total return: `(final_tvl - initial_capital) / initial_capital × 100` | `metrics.py:105` |

### Risk — USDC Nominal

| Metric | Definition | Code reference |
|--------|-----------|----------------|
| `vol_usdc_annual_pct` | `std(daily_pct_change_tvl) × sqrt(365) × 100` | `metrics.py:114-115` |
| `sharpe_usdc` | `mean(daily_ret - RISK_FREE_DAILY) / std(daily_ret - RISK_FREE_DAILY) × sqrt(365)` where `RISK_FREE_DAILY = 0.05/365` | `metrics.py:117-119` |
| `mdd_usdc_pct` | `min((tvl - cummax(tvl)) / cummax(tvl)) × 100` | `metrics.py:127-129` |

Note: USDC-nominal metrics reflect only interest accrual (monotonically increasing). Vol ≈ 0,
Sharpe ≈ 6–38, MDD ≈ 0. These are provided for internal reference, NOT for allocator reporting.

### Risk — USD Denominated (CANONICAL AUDIT METRIC)

| Metric | Definition | Code reference |
|--------|-----------|----------------|
| `vol_usd_annual_pct` | `std(daily_pct_change_nav_usd) × sqrt(365) × 100` where `nav_usd = tvl × usdc_price` | `metrics.py:155-156` |
| `sharpe_usd` | `mean(daily_ret_usd - RISK_FREE_DAILY) / std(daily_ret_usd - RISK_FREE_DAILY) × sqrt(365)` | `metrics.py:157-158` |
| `sortino_usd` | `mean(daily_ret_usd - RISK_FREE_DAILY) / std(downside_excess_ret_usd) × sqrt(365)` | `metrics.py:159-161` |
| `mdd_usd_pct` | `min((nav_usd - cummax(nav_usd)) / cummax(nav_usd)) × 100` | `metrics.py:162-164` |

USDC price data: `backtest/data/usdc_price.csv` (daily USDC/USD close, forward-filled).
Includes real peg-risk events (SVB mini-depeg 2023, etc.).

### Operational

| Metric | Definition | Code reference |
|--------|-----------|----------------|
| `n_rebalances` | `len(rebalances_realistic.csv)` | `metrics.py:169` |
| `n_gate_blocked` | `len(gate_blocks_realistic.csv)` | `metrics.py:170` |
| `n_harvests` | `len(harvests_realistic.csv)` | `metrics.py:171` |
| `idle_drag_mean_pct` | `mean(idle_cash / tvl) × 100` — computed outside metrics.py from equity_realistic.csv | `simulator.py` |
| `idle_drag_p95_pct` | `p95(idle_cash / tvl) × 100` — p95 quantile of daily idle fraction | `simulator.py` |
| `n_mandate` | Count of rebalances where `mandate_type IS NOT NULL` | `simulator.py` |
| `n_safety_overflow` | Count of rebalances where `mandate_type CONTAINS 'safety'` | `simulator.py` |

### Gap vs Baseline

`max_drift_observed_bps` is NOT in this CSV — it appears in sweep comparison tables where
it is defined as: `max over all adapter-days of (position_bps - target_bps)` where
`position_bps = positionAssets[adapter] / tvl × 10000`.

---

## Cross-CSV Consistency Verification

All metrics in this package are computed via `metrics.compute_metrics()`. Confirmed consistent:

| Source CSV | Sharpe method | MDD method | Verified |
|-----------|--------------|-----------|---------|
| `PRODUCTION_VALIDATION_FINAL.csv` | `sharpe_ratio_usd` (USD NAV) | `max_drawdown_usd_pct` | ✓ |
| Sweep comparisons (if present) | Same function | Same function | ✓ |

---

## RISK_FREE_RATE

SOFR average 2024-2025: **5.00% annually** (`RISK_FREE_ANNUAL = 0.05` in `metrics.py:22`).
Daily rate: `0.05 / 365 = 0.0001370%`.

---

## C-01 Finding (resolved)

The original `PRODUCTION_VALIDATION_FINAL.csv` (Deliverable B, 2026-06-13 first generation)
incorrectly used USDC-nominal Sharpe (38.38) instead of USD-denominated Sharpe (1.62). The
file was regenerated using `metrics.compute_metrics()`. See `BACKTEST/C01_INVESTIGATION.md`.
