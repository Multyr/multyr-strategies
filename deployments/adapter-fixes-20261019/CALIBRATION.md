# Adapter gas calibration — pending current fork validation

Per-adapter gas floors, excluding preparation/step/finalization overhead:

| Adapter | Deposit | Withdraw |
|---|---:|---:|
| Aave | 600,000 | 300,000 |
| Morpho | 1,100,000 | 4,000,000 |
| Comet | 550,000 | 300,000 |
| Euler | 900,000 | 450,000 |
| Dolomite | 1,200,000 | 600,000 |
| Fluid | 450,000 | 300,000 |
| Venus | 750,000 | 350,000 |

Derived by rounding upward with headroom over fork measurements. The current rehearsal measured Morpho withdrawal at 2,971,185 gas, materially above the earlier 1,456,245 sample; its floor is therefore 4,000,000. Final full-plan validation remains required. The existing 50% model safety margin and explicit transaction overhead remain. EMAs exceeding these floors still increase estimates. Unconfigured adapters retain conservative global defaults. Invalid price/fee data still fails conservatively.

These are modeled gas allowances, not guaranteed actual transaction costs. The USDC quote varies with the exact plan, Arbitrum fees and validated ETH/USDC prices. Calibration is applied to new adapter addresses by Safe, atomically with migration.
