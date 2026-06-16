# Changelog

All notable changes to `Multyr/multyr-strategies` are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.1.0] — V10.0 — 2026-06-16

### Breaking changes

All adapter contracts (`AaveV3USDCAdapter`, `CometUsdcMultiMarketAdapter`,
`DolomiteUsdcMultiMarketAdapter`, `EulerUsdcMultiMarketAdapter`,
`FluidUsdcMultiMarketAdapter`, `MorphoUsdcMultiMarketAdapter`,
`VenusUsdcMultiMarketAdapter`, `RewardSwapHelper`, `StrategyBootstrapper`)
have the following constructor-time behaviour changed:

| V9.x (immutable) | V10.0 (storage + initialize) |
|---|---|
| `constructor(address asset, address vault, ...)` — addresses accepted at deploy time via constructor args | `constructor()` empty — no args |
| No `initialize()` function | `initialize(address asset, address vault, ...)` — must be called atomically after deployment |
| Addresses stored as `immutable` | Addresses stored as `public` storage variables |
| Chain-specific bytecode (immutables baked in) | Byte-identical bytecode across all EVM chains |

Migration: existing Arbitrum deployments are unaffected (previously deployed, immutable bytecode stays live). New deployments on any chain use the V10 path via `AdapterFactory.deployAndInit()`.

### Added

- `src/strategies/usdc-lending/factory/AdapterFactory.sol` — CREATE2 factory with atomic deploy+initialize (eliminates front-run window between deploy and init). Emits `AdapterDeployed(adapter, initiator, salt, codehash)`.
- `script/keepers/safety_adapter_monitor.py` — off-chain monitoring script for P0.7 Safety Adapter Cap Tier signal families (cap utilisation, mandate frequency, cooldown saturation, idle drag).
- `script/MULTI_CHAIN_PLAYBOOK.md` — 7-step per-chain deployment sequence; audit perimeter table.
- `script/DeployAdapterFactory.s.sol` — broadcast script for AdapterFactory deployment.
- `test/strategies/usdc-lending/adapters/StorageLayoutV10Adapters.t.sol` — 45 storage layout verification tests (27 field, 9 Initializable placement, 9 snapshot).
- `test/strategies/usdc-lending/adapters/snapshots/*.storage.json` — 9 `forge inspect storageLayout` JSON snapshots.
- `docs/coverage/` — coverage breakdown, exclusions, and unreachable-code analysis.

### Changed

- All 9 adapter/helper/bootstrapper contracts: `immutable` address fields → `storage` variables; empty `constructor()`; `initialize()` with `initializer` modifier.
- `StrategyBootstrapper`: Initializable-only (no AccessControl/ReentrancyGuard) — slot 0 packed: `_initialized` + `strategy`.

### Invariants preserved

- Controller module storage layout (slots 78–81, P0.7 critical) unchanged — verified by `StorageLayoutP07.t.sol` 5/5 PASS post-V10.
- 23 Halmos symbolic proofs: 23/23 PASS (pure arithmetic, semantically transparent to V10 refactor).
- 15 Echidna invariants (I01–I12): 0 counter-examples at 1M sequence baseline.
- Fork tests (V92): 5/5 PASS at block 472761449.

---

## [1.0.0] — V9.2 + P0.7 — 2026-06 baseline

Initial public release. V9.1 scoring architecture + P0.7 Safety Adapter Cap Tier.

Key features:
- 7 adapters (Aave V3, Compound V3/Comet, Dolomite, Euler V2, Fluid, Morpho Blue, Venus)
- P0.7 dual-anchor safety architecture (6-dimensional mandate engine)
- 2063 tests: unit, fuzz, invariant (Echidna + Halmos), fork
- Chainlink keeper (`StrategyUpkeep`) for periodic rebalance + upkeep
