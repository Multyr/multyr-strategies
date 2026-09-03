# Multyr Strategy Metadata

Versioned, **static** descriptive metadata for Multyr strategies. This is the
base standard for every current and future strategy — not a one-off for USDC
Lending.

```
metadata/
├── schema/
│   ├── strategy-metadata.schema.json   # current schema (JSON Schema 2020-12)
│   └── CHANGELOG.md                    # schema versioning policy + history
├── strategies/
│   └── earn-usdc.json                  # one file per strategy, named <slug>.json
└── tools/
    ├── validate.py                     # schema + policy validator
    └── requirements.txt
```

## Static vs. dynamic — the hard rule

This directory holds **only** stable, descriptive facts about a strategy: its
name, asset, network, category, eligible protocols, the *mechanisms* it uses,
and the *categories* of risk it carries.

It must **never** contain runtime/dynamic values:

| Not allowed here (dynamic)                         | Where it lives instead        |
| ------------------------------------------------- | ----------------------------- |
| APY / APR / realised yield                        | runtime metrics API           |
| TVL / AUM / total assets                          | runtime metrics API           |
| Capacity / remaining capacity / utilization       | runtime metrics API           |
| Current allocations / weights / positions         | runtime metrics API           |
| Share price / price per share / NAV               | runtime metrics API / chain   |
| Holder counts, volumes, flows, performance series | analytics                     |

The runtime API joins to this document by `id` (e.g. `multyr-earn-usdc`).

The validator (`tools/validate.py`) enforces this: any key like `apy`, `tvl`,
`capacity`, `utilization`, `currentAllocation`, `sharePrice`, … anywhere in the
document is a hard failure, as is any performance/guarantee phrasing in a
string value.

## No risk ratings (yet)

There is **no** `riskRating`, `riskLevel`, `riskScore`, or safety label
("low risk", "safe", "conservative", …) in this schema, and the validator
rejects them. Multyr will add a risk-rating block only once a formal,
documented risk-rating methodology exists — at which point it gets its own
schema version (see `schema/CHANGELOG.md`).

Until then:

- `riskFactors` — an **unordered set** of exposure categories
  (`smart-contract`, `oracle`, `stablecoin-depeg`, …). Not a severity score.
- `riskControls` — the **names of mechanisms** in the strategy
  (`per-adapter exposure caps`, `adapter quarantine`, …). Not a grade.

## Adding a new strategy

1. Copy `strategies/earn-usdc.json` to `strategies/<your-slug>.json`.
2. Set `id` to `multyr-<your-slug>` (the validator enforces this pairing, and
   that the filename matches the slug).
3. Fill in the required fields; keep `schemaVersion` at the current value.
4. Run the validator locally:

   ```sh
   pip install -r metadata/tools/requirements.txt
   python metadata/tools/validate.py
   ```

5. Open a PR. CI (`.github/workflows/metadata-validate.yml`) runs the same
   validator over **every** file in `strategies/` and blocks merge on failure.

## Schema versioning

See [`schema/CHANGELOG.md`](schema/CHANGELOG.md). In short: additive changes
bump the minor version, breaking changes bump the major version, every past
version file is kept, and documents migrate deliberately.
