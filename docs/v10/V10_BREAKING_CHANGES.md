# V10 Breaking Changes

**Version**: v10.0.0 (Storage + Initialize Refactor)  
**Branch**: feature/v10.0-storage-initialize  
**Date**: 2026-06-21  
**Base**: v9.2.x (immutable constructor pattern)

This document lists every breaking change introduced by V10 relative to V9.2.
Integrators, fork maintainers, and auditors must review each section before upgrading.

---

## 1. Storage Layout Changes

### 1.1 Immutable -> Storage+Initialize migration (all adapters)

**Impact**: BREAKING for any code that assumes adapter constructor arguments are immutable.

All 7 adapters migrated from immutable variables (constructor-only) to storage
variables (initialize-once via `initialize()` call):

| Adapter | Old (V9.2) | New (V10) |
|---|---|---|
| `AaveV3USDCAdapter` | `constructor(address, address, ...)` | `initialize(address, address, ...)` |
| `CometUsdcMultiMarketAdapter` | constructor | initialize |
| `DolomiteUsdcMultiMarketAdapter` | constructor | initialize |
| `EulerUsdcMultiMarketAdapter` | constructor | initialize |
| `FluidUsdcMultiMarketAdapter` | constructor | initialize |
| `MorphoUsdcMultiMarketAdapter` | constructor | initialize |
| `VenusUsdcMultiMarketAdapter` | constructor | initialize |

**Migration**: Replace `new Adapter(args)` with:
```solidity
Adapter adapter = Adapter(factory.create2(salt));
adapter.initialize(args);
```

### 1.2 AdapterFactory required

**Impact**: BREAKING for direct adapter deployment.

Adapters must be deployed via `AdapterFactory.sol` (CREATE2 + initialize pattern).
Direct `new Adapter(args)` deployment is no longer supported — `initialize()` can only
be called once (guarded by `_disableInitializers()` equivalent pattern).

### 1.3 Venus `blocksPerYear` storage variable

**Impact**: BREAKING for Venus adapter integration.

`VenusUsdcMultiMarketAdapter.BLOCKS_PER_YEAR` (compile-time constant) replaced by
`blocksPerYear` (storage variable, set in `initialize()`).

```solidity
// V9.2 (removed)
uint256 private constant BLOCKS_PER_YEAR = 126_144_000; // Arbitrum-only hardcode

// V10 (required)
uint256 public blocksPerYear; // set per-chain via initialize()
```

Fix for **C-04** — Venus interest computation was wrong on all non-Arbitrum chains.

---

## 2. Compiler / Build Changes

### 2.1 Solidity pragma pinned to exact 0.8.28

**Impact**: Non-breaking for auditors; breaking for integrators using different solc.

All 76 Solidity files changed from floating `^0.8.x` to exact `pragma solidity 0.8.28`.

### 2.2 Foundry deterministic build config (foundry.toml)

**Impact**: Non-breaking for functionality; required for byte-identical audits.

```toml
# V10 required settings (breaks non-deterministic builds)
evm_version   = "cancun"       # was default (not pinned)
bytecode_hash = "none"         # was "ipfs" (added 43-byte IPFS suffix)
cbor_metadata = false          # removes CBOR metadata tail from bytecode
```

Integrators using Hardhat or other tools must apply equivalent settings.

---

## 3. ABI / Interface Changes

### 3.1 New `initialize()` on all adapters

All adapter ABIs now include:
```solidity
function initialize(/* chain-specific args */) external;
```

This function is gated (callable once, reverts thereafter). Do NOT include it in
production caller ABIs — it is a deployment-only function.

### 3.2 New `StrategySafetyOverflowModule` module (F-SIZE-01)

`StrategyScoringModule` no longer contains overflow logic. A new module is required:
```solidity
vault.setSafetyOverflowModule(address(new StrategySafetyOverflowModule(...)));
```

Omitting this wiring causes vault deployment to revert on overflow paths.

### 3.3 `StrategyAdapterOpsModule` extended

New public functions added (F-SIZE-02 refactor):
- `realizeLiquidity(uint256 amount)` — moved from vault internals
- View diagnostics: `adapterPositionAssets(address)`, `adapterIdleCash(address)`

### 3.4 `setRebalanceParams` bounds enforced (C-03)

`setRebalanceParams()` now reverts on out-of-range inputs:
- `minSecondsBetweenRebalances` must be within governance-defined bounds
- Calls that previously silently accepted bad values now revert with `ParamOutOfRange()`

### 3.5 `positionAssets` accounting updated (H-03)

`positionAssets` now tracks `actualDeposited` (balance delta), not pre-deposit TVL.
Any off-chain accounting relying on the old semantics must be updated.

---

## 4. Architectural Changes

### 4.1 `StrategyConfigLib` — shared constants (Wave 1 item 14)

Adapter-specific constants (liquidation thresholds, fee tiers, etc.) moved to
`src/strategies/usdc-lending/lib/StrategyConfigLib.sol`. Direct imports from
adapter files are deprecated.

### 4.2 `RewardSwapHelper` — `KEEPER_ROLE` gate (HIGH-R1)

`RewardSwapHelper` functions now require `KEEPER_ROLE`. Direct calls from non-keeper
EOAs revert. Governance / integrator flows must route through a keeper.

### 4.3 `RewardSwapHelper` — slippage cap 5% (HIGH-R2)

Slippage parameter capped at 500 bps (5%). Calls with `slippageBps > 500` revert
with `SlippageTooHigh()`. Prior: uncapped (MEV / sandwich attack vector).

### 4.4 Dolomite `withdraw` — proportional principal reduction (HIGH-D-01)

`DolomiteUsdcMultiMarketAdapter.withdraw()` now proportionally reduces principal
tracking. Off-chain NAV calculations assuming full-principal withdrawal must be updated.

### 4.5 Euler adapter — `forceApprove` replaces `safeApprove` (HIGH-E-01)

`EulerUsdcMultiMarketAdapter` uses `IERC20.forceApprove()` for Permit2 allowances.
`safeApprove()` on non-zero → non-zero transitions reverted with certain tokens.

### 4.6 Venus — `accrueVenusInterest()` keeper helper (HIGH-V1)

New keeper-callable `accrueVenusInterest()` forces Venus interest accrual before
NAV reads. Off-chain keeper infrastructure must call this periodically (recommended
cadence: every 4-6 hours on Arbitrum).

### 4.7 Allocator T1 cap enforcement — F-SCORING-INV2

**Impact**: BREAKING for any deploy with TVL < 25K USDC initial seed.

`StrategyAllocCalcModule._effectiveAbsCapBps()` now respects
`adapterMaxExposureBps` governance ceiling even in T1 single-adapter mode
(`dynamicMax=1`, TVL < 25K USDC). Previously bypassed silently.

```solidity
// V9.2 / pre-fix: T1 always returns 10000 (100%) -- bypassed governance setter
// V10 / post-fix: T1 returns min(adapterMaxExposureBps, 10000)
if (dMax == 1) {
    uint16 globalCeiling = adapterMaxExposureBps;
    return globalCeiling > 0 ? uint256(globalCeiling) : 10000;
}
```

Sentinel preservation: `globalCeiling == 0` = no constraint (T1 original behavior).
Production impact: zero (TVL >> 25K USDC always at deployment).
Bootstrap impact: cap now respected from first deposit.

Decision rationale: Pierre Option B (2026-06-18) — governance setter
consistency principle. Auditor preferred over silent override.

---

## 5. Test Infrastructure Changes

### 5.1 All fork tests env-var gated

Fork tests require explicit RPC env vars:
- `ARBITRUM_RPC_URL` — V92 Arbitrum fork tests (block 472761449)
- `OPTIMISM_RPC_URL` — Optimism sample fork (block 136_000_000)
- `BASE_RPC_URL` — Base sample fork (block 30_000_000)

Tests skip gracefully (`vm.skip(true)`) when env vars absent — CI without secrets
still produces 0 failures.

### 5.2 New test files (V10 additions)

| File | Purpose |
|---|---|
| `test/strategies/usdc-lending/deploy/UsdcLendingDeploy.t.sol` | Chain config + deterministic build |
| `test/strategies/usdc-lending/fork/V92_MultichainFork.t.sol` | Optimism + Base lifecycle fork |
| `test/strategies/usdc-lending/echidna/EchidnaSafetyAdapterCapTier.sol` | Echidna harness |
| `test/strategies/usdc-lending/StorageLayoutP07.t.sol` | Storage consistency |

---

## 6. Deployment Changes

### 6.1 `UsdcLendingChainConfig` struct (Wave 3)

All deploy scripts must use `UsdcLendingChainConfig` from
`src/strategies/usdc-lending/config/UsdcLendingConfig{Chain}.sol`:

```solidity
UsdcLendingChainConfig memory cfg = UsdcLendingConfigArbitrum.get();
// cfg.usdc, cfg.aavePool, cfg.venusBlocksPerYear, cfg.deploySalt, cfg.permit2 ...
```

Direct constant definitions in deploy scripts are removed.

### 6.2 `governanceMultisig` required before deploy

`UsdcLendingChainConfig.governanceMultisig` must be set to a non-zero address before
deploy. Deploying with `address(0)` grants `DEFAULT_ADMIN_ROLE` to the zero address
(catastrophic — vault becomes permissionless).

### 6.3 CREATE2 salt scheme

Each chain uses a deterministic salt:
```solidity
bytes32 deploySalt = keccak256(abi.encode("UsdcLendingV10", uint256(chainId)));
```

Salts are pre-computed in each `UsdcLendingConfig{Chain}.sol` library.

---

## 7. Migration Guide (V9.2 -> V10)

1. **Update deploy scripts**: Replace hardcoded constants with `UsdcLendingChainConfig`.
2. **Update Venus integration**: Pass `blocksPerYear` to `VenusUsdcMultiMarketAdapter.initialize()`.
3. **Set governance multisig**: Fill `governanceMultisig` in chain config before deploy.
4. **Wire new modules**: `setSafetyOverflowModule()` required after vault deploy.
5. **Update keeper**: Add periodic `accrueVenusInterest()` call (HIGH-V1).
6. **Update slippage callers**: Cap reward swap slippage at 500 bps.
7. **Verify foundry.toml**: `bytecode_hash=none + cbor_metadata=false` for deterministic builds.