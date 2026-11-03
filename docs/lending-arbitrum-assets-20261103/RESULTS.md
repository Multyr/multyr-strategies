# Arbitrum USDC / WETH / USDT0 / WBTC — functional results

**58 executed real-data cases pass, zero failures and zero skips. All 28
adapter/token cells are classified. This is functional acceptance, not an
approval to deploy every cell or a new production-readiness declaration.**

| Adapter | USDC | WETH | USDT0 | WBTC |
|---|---|---|---|---|
| Aave V3 | PASS | PASS | PASS | PASS |
| Comet | PASS | PASS | PASS | No official base market |
| Morpho ERC4626 | PASS | Risk-excluded | PASS, V2 | No qualified production vault |
| Euler | PASS | PASS | Risk-excluded | Risk-excluded |
| Fluid fToken | PASS | PASS | PASS | No fToken at the recorded block |
| Dolomite ERC4626 | PASS | PASS | PASS | PASS |
| Venus | PASS | PASS | PASS | PASS |

PASS means genuine protocol investment through frozen Core + Lending, ordinary
deposits, queued partial/full user exit requiring invested-capital recall, and
final strategy recall. The three risk-excluded cells pass direct adapter
lifecycles but correctly receive no strategy capital below the unchanged
$100,000 market-TVL floor. Morpho WETH uses an existing unlisted tiny vault for
technical testing; it is not a production market approval. These exclusions do
not establish universal incompatibility of the underlying token.

## Evidence

- **25 direct adapter lifecycles**, with independent protocol APR/NAV references,
  actual receipts backing supplied capital, partial withdrawal and full recall.
- **22 invested Core/strategy/protocol lifecycles** and **3 policy-rejection +
  idle-capital Core exits**. All original deposit locks and epoch caps remain.
- **4 weighted portfolios**, one per token: independent score normalization,
  selection and clipped targets; actual multi-protocol investment, governance
  tightening/protection rebalance, full small-user exit and final recall.
- **4 nonempty frozen Aave-warm profiles**: actual warm investment and recall
  alongside Lending. This does not qualify every Morpho warm profile.
- **2,995 regression/fuzz/invariant tests in 203 suites**, zero failures/skips,
  with the two legacy fork opt-ins enabled.
- **34 production runtime templates** below 23,552 bytes; largest 23,479 bytes.
  **296 selectors**, no collision; **9 matching module layouts** and **9
  preserved storage-prefix checks**.
- All **113 original Lending events** retain parameter names/types/indexing and
  anonymous flags. Candidate has 114 events, adding
  `WithdrawalRedeployDeferred(uint256,bytes)`.

Reports: `direct-acceptance.json`, `core-acceptance.json`,
`portfolio-acceptance.json`, `warm-acceptance.json`, `results.json`,
`validated-matrix.csv`, `cleanup-structure.json`, `original-event-abi-parity.json`.
They bind source hashes, canonical headers, catalogues and per-case log hashes.

## Method and Core integration

Arbitrum chain ID 42161; canonical historical headers through block 520094008.
ERC20 funding uses actual holder transfers and actual Uniswap swaps when needed,
with balance/supply conservation. No financial-state mock, balance injection,
storage/code replacement or timestamp warp is used. Protocol state affected by
the scenario persists across canonical header rolls as a disclosed closed
counterfactual; these are not replays of intervening canonical transactions or
claims about historical earned returns.

Raw Chainlink answers independently verify the Core USD quotes. Calculations
exercise actual **6-, 8- and 18-decimal** tokens. Receipt rounding bounds come
from the actual exchange rate, not an arbitrarily increased tolerance.

Core source remains pinned at `9a9d120709de99a6216e9fe75d36e9ffdcb1a4d9`.
New asset tests deploy dedicated Core/strategy instances from that source with
the recorded test compiler settings. They do not claim that the existing USDC
shadow Core changed underlying, or that every deployed Core component has
identical executable code. The separate deployed-source timing differences
remain documented in `../LENDING_CORE_OBSERVATIONS.md`.

New instances require explicit asset-unit deposit limits through
`setVaultDepositLimits` and a correctly scaled buffer `minRebalanceAmount`
through `setRebalanceParams`. The warm cases preserve the $5,000 economic
threshold. Copying the raw USDC defaults to WETH/WBTC is not valid configuration.

## Cleanup and consumer compatibility

Cleanup removes 10 unreachable helper/modifier declarations, four unused
constants and 45 unused import aliases. Six configuration-library entry points
are retained deliberately. Public/external ABI and storage slots are preserved.
Audit scope: **10,557 NLOC / 45 strategy Solidity files**, versus 10,630 before;
operations add 2,481 NLOC / 13 files, total **13,038 / 58**. Tests, Core, vendors
and Python/PowerShell are excluded; `audit-scope-nloc.json` defines the metric.

Pinned subgraph source `d5751e4dfe13495c7c87f491d74758fe47f72548` has four ABI
events absent from both the original and candidate Lending. Only
`ScoringComputed` is subscribed in the inspected Arbitrum manifest. Its legacy
`ScoringSnapshot` handler therefore cannot be treated as original Lending
telemetry. The separate `CurrentScoringSnapshot` helper reads existing getters
for targets/rates/positions and stores raw integers without a six-decimal
conversion. This is pre-existing consumer drift, not an event removed by this
cleanup; no synthetic event was added to hide it.

## Remaining production gates

- Finish new-branch CI, including the new mandatory four-asset matrix job.
- Rebind genuine Native keeper/gas qualification to the cleanup source and
  qualify the expanded WETH/WBTC operational profiles. The functional cases
  above are not a substitute for that gate.
- Approve concrete per-asset deployment manifests, roles and operational caps;
  run activation-time market/oracle/cap preflight. Existing USDC Core/main/shadow
  remain untouched. Market availability at a historical pin is not a current
  liquidity guarantee.
- Complete final release packaging/provenance against those approved gates.

CI restores frozen real catalogues and headers, then verifies them against the
actual pinned chain state. All 28 cells and exact expected outcomes are required;
the three unavailable markets are reported explicitly, never counted as passed
or skipped tests. Infrastructure retries preserve their original failed logs.
