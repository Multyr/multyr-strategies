# docs/ — Documentation Index

Documentation for the USDC Lending Strategy V10 (`multyr-strategies`).

## Core docs

| File | Description |
|---|---|
| [overview.md](overview.md) | Architecture: vault, modules, adapters, scoring |
| [adapters.md](adapters.md) | Per-adapter specs (Aave, Comet, Dolomite, Euler, Fluid, Morpho, Venus) |
| [audit-scope.md](audit-scope.md) | In-scope file list, LOC counts, waivers |
| [invariants.md](invariants.md) | Formal invariants: Halmos (23) + Echidna (15) |
| [threat-model.md](threat-model.md) | Attack surface and mitigations |
| [deployment.md](deployment.md) | Deploy procedure and wiring |
| [wiring.md](wiring.md) | Module wiring lifecycle |

## Specialized docs

| File | Description |
|---|---|
| [GOVERNANCE_POLICY_TRACK.md](GOVERNANCE_POLICY_TRACK.md) | Governance parameter policy |
| [SAFETY_ADAPTER_TIER.md](SAFETY_ADAPTER_TIER.md) | P0.7 Safety Adapter Cap Tier design |

## Strategy specs

| File | Description |
|---|---|
| [strategy/USDC_LENDING_V92_ALLOCATOR_SPEC.md](strategy/USDC_LENDING_V92_ALLOCATOR_SPEC.md) | Allocator spec (V9.2 baseline) |

## V10 refactor

| File | Description |
|---|---|
| [v10/DESIGN_RATIONALE.md](v10/DESIGN_RATIONALE.md) | V10 storage + initialize refactor rationale |
| [v10/MULTICHAIN_PLAYBOOK.md](v10/MULTICHAIN_PLAYBOOK.md) | Multichain deploy guide |

## Coverage

| File | Description |
|---|---|
| [coverage/COVERAGE_BREAKDOWN_PER_FILE.md](coverage/COVERAGE_BREAKDOWN_PER_FILE.md) | Per-file coverage |
| [coverage/COVERAGE_EXCLUSIONS.md](coverage/COVERAGE_EXCLUSIONS.md) | Coverage exclusions |
| [coverage/COVERAGE_UNREACHABLE.md](coverage/COVERAGE_UNREACHABLE.md) | Unreachable code analysis |

## Ops

| File | Description |
|---|---|
| [ops/SAFETY_TIER_RUNBOOK.md](ops/SAFETY_TIER_RUNBOOK.md) | Safety tier operational runbook |

## Audit evidence

| Folder | Description |
|---|---|
| [audit/](audit/README.md) | Audit submission evidence (Wave 1+2 fixes, Echidna 1M, Halmos, sizes) |
