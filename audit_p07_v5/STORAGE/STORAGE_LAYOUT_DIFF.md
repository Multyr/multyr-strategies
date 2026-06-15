# Storage Layout Diff -- V10.0 vs V9.x baseline

**Generated**: 2026-06-16
**Branch**: feature/v10.0-storage-initialize
**Verification**: StorageLayoutP07.t.sol 5/5 PASS post-V10, StorageLayoutV10Adapters.t.sol 45/45 PASS

---

## Controller modules: NO CHANGES

The 7 controller modules (StrategySettingsModule, StrategyRebalancePlanModule,
StrategyRebalanceGateModule, StrategyParamsModule, StrategyAllocCalcModule,
StrategyScoringModule, StrategyExplainabilityLens) **inherit all state from
StrategyStorageLayout** and declare no independent state variables.

`forge inspect <ControllerModule> storageLayout` returns empty layout for each --
this is expected for pure mixin modules. The authoritative layout is
`StrategyStorageLayout.sol`, snapshotted in `snapshots/StrategyStorageLayout.storage.json`.

### P0.7 critical slots (verified unchanged)

```
Slot 78 (packed, 32 bytes total):
  bytes 0-1:  capDriftToleranceBps     (uint16)
  bytes 2-3:  maxIdleBps               (uint16)
  bytes 4-5:  targetSafetyMarginBps    (uint16)
  bytes 6-9:  mandateRedeployCooldownSeconds (uint32)
  bytes 10-31: (padding)

Slot 79: safetyFallbackAdapters  (address[]) -- dynamic array base
Slot 80: safetyFallback          (mapping(address => bool))
Slot 81: lastRelCapMandateTs     (mapping(address => uint64))
```

Test verification: `test/strategies/usdc-lending/StorageLayoutP07.t.sol`
- TC01a: capDriftToleranceBps at slot 78 offset 0
- TC01b: maxIdleBps at slot 78 offset 2
- TC01c: targetSafetyMarginBps at slot 78 offset 4
- TC01d: mandateRedeployCooldownSeconds at slot 78 offset 6
- TC01e: safetyFallbackAdapters at slot 79

---

## Adapter storage: NEW in V10 (was immutable in V9.x)

All AC+RG+Initializable adapters share inheritance slots 0-2:
- slot 0: `_roles` (mapping -- AccessControl)
- slot 1: `_status` (uint256 -- ReentrancyGuard)
- slot 2 packed: `_initialized`(uint8 @ byte0) + `_initializing`(bool @ byte1) + first_addr(@ byte2)

Slot-2 packed encoding:
```solidity
bytes32((uint256(uint160(firstAddr)) << 16) | 1)
```
Sets `_initialized = 1` and first address field simultaneously in one slot.

### Per-adapter slot map

| Adapter | slot 2 (packed) | slot 3 | slot 4 | slot 5 |
|---|---|---|---|---|
| AaveV3USDCAdapter | asset | pool | aToken | vault |
| CometUsdcMultiMarketAdapter | underlying | vault | registry | -- |
| DolomiteUsdcMultiMarketAdapter | asset | vault | registry | -- |
| EulerUsdcMultiMarketAdapter | USDC | vault | registry | -- |
| FluidUsdcMultiMarketAdapter | asset | vault | fToken | -- |
| MorphoUsdcMultiMarketAdapter | underlying | vault | registry | -- |
| VenusUsdcMultiMarketAdapter | underlying | vault | vToken | -- |
| RewardSwapHelper | usdc | uniswapV3Router | camelotV3Router | -- |

Note: Euler adapter retains `address internal constant PERMIT2` (not in storage --
same address on all chains, see V10_DESIGN_RATIONALE.md s.5).

### StrategyBootstrapper (Initializable only, no AC/RG)

- slot 0 packed: `_initialized`(uint8 @ byte0) | strategy(address @ byte2)
- slot 1: deployer(address) | used(bool @ byte20)

---

## AdapterFactory storage

AdapterFactory inherits AccessControl only (no ReentrancyGuard, no Initializable).
Slots 0+ are OZ AccessControl role storage. See `snapshots/AdapterFactory.storage.json`.
No V10-specific adapter state in factory.

---

## Multi-chain bytecode-deterministic claim

All 7 adapters + RewardSwapHelper + StrategyBootstrapper have **zero hardcoded
chain-specific addresses** in their source code (all addresses passed to `initialize()`).

Chain-specific content per contract:
- Constructor args: NONE (empty constructor)
- Immutables: NONE (all moved to storage)
- Constants: PERMIT2 (universal) + numeric constants (optimizer_runs 200, solc 0.8.28)

Therefore: `keccak256(deployedBytecode[AdapterX on Arbitrum]) == keccak256(deployedBytecode[AdapterX on Base])`

Verification procedure documented in `script/MULTI_CHAIN_PLAYBOOK.md` Step 6.

---

## Forge inspect files

See `snapshots/` for JSON storage layout per contract:
- AaveV3USDCAdapter.storage.json
- CometUsdcMultiMarketAdapter.storage.json
- DolomiteUsdcMultiMarketAdapter.storage.json
- EulerUsdcMultiMarketAdapter.storage.json
- FluidUsdcMultiMarketAdapter.storage.json
- MorphoUsdcMultiMarketAdapter.storage.json
- VenusUsdcMultiMarketAdapter.storage.json
- RewardSwapHelper.storage.json
- StrategyBootstrapper.storage.json
- AdapterFactory.storage.json
- StrategyStorageLayout.storage.json (authoritative controller layout)
- StrategySettingsModule.storage.json (empty -- pure mixin)
- StrategyRebalancePlanModule.storage.json (empty -- pure mixin)
- StrategyRebalanceGateModule.storage.json (empty -- pure mixin)
- StrategyParamsModule.storage.json (empty -- pure mixin)
- StrategyAllocCalcModule.storage.json (empty -- pure mixin)
- StrategyScoringModule.storage.json (empty -- pure mixin)
