# Strategy Metadata Schema — Changelog

The schema is versioned independently of the repo. Each version is a separate,
immutable file: `strategy-metadata-<version>.schema.json` (the current version
is also available unsuffixed as `strategy-metadata.schema.json`). A metadata
document selects its schema via the `schemaVersion` field.

Versioning rules:

- **Patch** (`1.0` → `1.0`, doc unchanged): editorial only — descriptions,
  `$comment`s. No new/removed/retyped fields.
- **Minor** (`1.0` → `1.1`): backward-compatible additions — new **optional**
  fields, new enum members. Existing `1.0` documents still validate under
  `1.1` unchanged.
- **Major** (`1.0` → `2.0`): breaking — a new required field, a removed field,
  a retyped field, a removed enum member, or the introduction of a formal
  risk-rating block.

When a new version ships, add the new schema file, bump
`properties.schemaVersion.const`, keep every prior version file in place, and
migrate metadata documents deliberately.

---

## 1.0 — 2026-09-01

Initial version. Static, descriptive metadata only.

- Required: `schemaVersion`, `id`, `slug`, `name`, `tagline`, `description`,
  `category`, `asset`, `network`, `principalGuaranteed`, `yieldVariable`,
  `protocols`.
- Optional: `symbol`, `type`, `allocationModel`, `management`, `yieldSource`,
  `anchorProtocols`, `objective`, `allocation`, `riskControls`, `riskFactors`,
  `disclosures`, `links`, `status`, `tags`.
- **Excluded by design:** all runtime/dynamic metrics (APY, TVL, capacity,
  utilization, current allocations, share price, …) and any risk rating,
  risk score, or safety label. `riskFactors` is an unordered set of exposure
  categories, not a severity assessment. `riskControls` names mechanisms, not
  a grade.
