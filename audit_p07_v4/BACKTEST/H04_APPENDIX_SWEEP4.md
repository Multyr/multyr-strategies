# H-04 Appendix — Sweep #4: Dolomite Relative-Cap Sensitivity

**Date:** 2026-06-13  
**Simulator version:** Sweep #4 (adapterRelCapOverrideBps enforcement)  
**Scenario:** realistic  
**Grid:** `adapterRelCapOverrideBps[dolomite_usdc]` ∈ {100, 200, 400, 800, 1000} bps  

---

## Motivation

The production params.json does not set `adapterRelCapOverrideBps` — Dolomite's relative cap
is governed by the depth-table lookup (`effective_relative_cap_with_max(ext_tvl, 2000)`)
which for Dolomite's typical TVL yields ~2000 bps (20% of ext market TVL). Sweep #4 tests
the sensitivity of strategy performance to a governance decision that caps Dolomite's rel cap
at tighter values (100–1000 bps), e.g. to model risk-averse committee constraints.

**Day-0 enforcement fix included:** `adapterRelCapOverrideBps` is now applied from day 0 in
`_deploy_idle_to_adapters` (L774 area in simulator.py). Prior to this sweep, the override
path only existed for abs caps (Sweep #3). The rel cap gap is now closed.

---

## Results

| rel_cap_bps | sharpe_usd | mdd_usd_pct | vol_usd_annual_pct | twr_usd_annual_pct | rebalances | gate_blocked |
|---|---|---|---|---|---|---|
| 100 | 1.6014 | -0.1451% | 0.6521% | 6.2364% | 411 | 471 |
| 200 | 1.6148 | -0.1422% | 0.6520% | 6.2455% | 413 | 469 |
| 400 | 1.6179 | -0.1422% | 0.6518% | 6.2371% | 416 | 466 |
| 800 | **1.6214** | **-0.1422%** | 0.6520% | 6.2400% | 424 | 458 |
| 1000 | **1.6214** | **-0.1422%** | 0.6520% | 6.2401% | 424 | 458 |

Full CSV: `BACKTEST/sweep4_dolomite_relcap_realistic.csv`

---

## Interpretation

- The strategy performance **plateaus at 800 bps** — tightening rel cap below 800 bps reduces
  Sharpe (1.6014 at 100 bps vs 1.6214 at 800 bps, −1.2%) and increases MDD at 100 bps (−0.1451%
  vs −0.1422%, 2bp worse).
- The production baseline (no per-adapter rel cap override, effective ~2000 bps from depth table)
  is equivalent to or better than the 1000 bps grid point.
- This confirms the production configuration is not over-constrained: Dolomite's rel cap
  at depth-table levels (2000 bps) is within the plateau region.
- **Committee recommendation:** if governance wants a conservative margin, 800 bps is the
  minimum that preserves optimal performance. Below 400 bps starts reducing alpha.

---

## Code Changes (H-04)

### `src/scoring.py`
- Added field `rel_cap_override_bps_map: dict = None` to `ScoringParams` class (after
  `abs_cap_override_bps_map`), documented as Sweep #4 rel cap ceiling override.

### `src/simulator.py`
- `load_params()`: added `rel_cap_override_bps_map = dict(cfg.get("adapterRelCapOverrideBps", {}))` 
  to `ScoringParams` init.
- `_deploy_idle_to_adapters()` (day-0 enforcement fix): 
  - Added `rel_ceiling_map = getattr(sp, "rel_cap_override_bps_map", None) or {}` alongside
    `abs_ceiling_map`.
  - Added override clamp: `if a in rel_ceiling_map and rel_ceiling_map[a] < rel_bps: rel_bps = rel_ceiling_map[a]`
    immediately after `effective_relative_cap_with_max()` (applied on every day including day 0).

### `run_sweep4_dolomite_relcap.py` (new)
- Standalone sweep runner that sets `sp.rel_cap_override_bps_map = {ADAPTER: rel_cap_bps}` per grid
  point and captures USD-denominated metrics via `compute_metrics()`.
