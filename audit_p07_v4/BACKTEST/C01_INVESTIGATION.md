# C-01 — Sharpe/MDD Anomaly Investigation Report

**Date:** 2026-06-13
**Finding:** Deliverable B reported Sharpe=38.38, MDD=0.0%; baseline (iter4) had Sharpe=1.28, MDD=-0.1422%
**Resolution:** Scenario C — methodology mismatch in ad-hoc CSV generation. No code bug, no data corruption. **Fixed.**

---

## Step 1 — CSV comparison

| Column | Baseline (iter4) | Deliverable B (v92 original) |
|--------|-----------------|------------------------------|
| `sharpe` (key name) | `sharpe_usd = 1.2786` | `sharpe = 38.3754` |
| `vol` (key name) | `vol_usd_annual_pct = 0.6483%` | `vol_annual_pct = 0.1579%` |
| `mdd` (key name) | `mdd_usd_pct = -0.1422%` | `mdd_pct = 0.0%` |
| `twr` | `twr_usd_annual_pct = 5.8289%` | `twr_annual_pct = 6.2371%` |
| `n_rebalances` | 436 | 424 |
| `n_gate_blocked` | 446 | 458 |

The column names already reveal the cause: baseline uses `*_usd` metrics; Deliverable B used pure USDC-nominal metrics.

---

## Step 2 — Root cause

**`metrics.py` provides two flavors:**

1. `sharpe_ratio` / `max_drawdown_pct` — computed from raw USDC-denominated TVL series. Since USDC accrual is monotonically increasing (interest only), vol ≈ 0, Sharpe is inflated to ~38, and MDD = 0.

2. `sharpe_ratio_usd` / `max_drawdown_usd_pct` — computed after multiplying TVL by `data/usdc_price.csv` (USDC/USD daily close). This introduces real peg-risk volatility (SVB mini-depeg, etc.), giving vol ≈ 0.65% and meaningful Sharpe ≈ 1.6.

The baseline (`PRODUCTION_VALIDATION_iter4.csv`) used the USD-denominated metrics (canonical for allocator reporting). Deliverable B's ad-hoc Python script computed Sharpe directly from `equity['tvl']` (USDC nominal), bypassing `metrics.py` and producing the USD-denominated computation.

**This is a reporting methodology mismatch, not a simulator bug.** The underlying simulation data (equity_realistic.csv) is correct and unchanged.

---

## Step 3 — Git history of metrics.py

```
git log --since="2026-05-15" -- backtest/src/metrics.py
```

Result: no commits in this window. `metrics.py` has not been modified since 2026-04-22 (header comment: "Added USD-denominated Sharpe / MaxDD / vol metrics"). The function `compute_metrics()` and its USD-path are stable.

---

## Step 4 — Corrected metrics (using `metrics.compute_metrics()`)

| Metric | Baseline (iter4) | v92 CORRECTED | Delta | Explanation |
|--------|-----------------|---------------|-------|-------------|
| `twr_usd_annual_pct` | 5.8289% | **6.2401%** | +0.41% | P0.7 safety overflow deploys idle more efficiently → higher yield |
| `vol_usd_annual_pct` | 0.6483% | **0.6520%** | +0.04% | Same USDC/USD peg-risk component; marginal change from different rebalance timing |
| `sharpe_usd` | 1.2786 | **1.6214** | +0.34 | Higher TWR with similar vol → higher Sharpe. P0.7 is a net improvement. |
| `sortino_usd` | 1.876 | **2.4894** | +0.61 | Same direction: lower downside frequency |
| `mdd_usd_pct` | **-0.1422%** | **-0.1422%** | 0 | Exact match — confirmed by `metrics.compute_metrics()` |

### Operational differences (expected)

| Metric | Baseline (iter4) | v92 | Delta | Explanation |
|--------|-----------------|-----|-------|-------------|
| `n_rebalances` | 436 | 424 | -12 | P0.7 `mandateRedeployCooldownSeconds=259200` prevents redundant mandate redeployments (3-day cooldown). This is intended behavior. |
| `n_gate_blocked` | 446 | 458 | +12 | Fewer mandatory rebalances → more gate evaluations happen that reach "blocked" state (no net benefit). Consistent with P0.7 logic. |
| `idle_drag_mean_pct` | 12.04% | 6.09% | -5.95% | P0.7 `maxIdleBps=500` + safety overflow actively deploys idle → less mean idle. Significant improvement. |

---

## Resolution

**Fix applied:** `PRODUCTION_VALIDATION_FINAL.csv` regenerated using `metrics.compute_metrics()` with USD-denominated metrics matching the baseline methodology. File updated in `reports_PRODUCTION_FINAL_v92/`.

**No simulator re-run needed.** The simulation data (equity_realistic.csv) is correct. Only the validation summary CSV was wrong.

**No metrics.py change.** The function was correct; it was not called in the original Deliverable B script.

**P0.7 performance conclusion:** The corrected Sharpe (1.62 vs 1.28 baseline) and identical MDD (-0.1422%) confirm that P0.7 is a net improvement over baseline: the safety overflow mechanism reduces idle drag and increases TWR without increasing peg-risk exposure.

---

## Scenario classification

**Scenario C** (methodology mismatch in reporting) — the simulation data is correct; the audit-submission CSV used the wrong flavor of Sharpe/MDD metrics.

Corrected `PRODUCTION_VALIDATION_FINAL.csv` includes both flavors for completeness:
- `twr_usdc_annual_pct`, `sharpe_usdc`, `mdd_usdc_pct` — USDC-nominal (internal reference)
- `twr_usd_annual_pct`, `sharpe_usd`, `sortino_usd`, `mdd_usd_pct` — USD-denominated (canonical audit metric)
