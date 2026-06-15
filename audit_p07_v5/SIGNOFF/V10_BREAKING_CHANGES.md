# V10.0 Breaking Changes — Audit Submission Reference

**Destination**: `audit_p07_v5/SIGNOFF/V10_BREAKING_CHANGES.md`  
**Audience**: External auditors, integrators, governance, downstream consumers.  
**Purpose**: Authoritative reference for all backward-incompatible changes in V10.0 vs V9.x baseline.

---

## Summary

V10.0 introduces **ABI-breaking changes** to all adapter contracts and the strategy bootstrapper, plus a new `AdapterFactory` contract. Existing V9.x deployments cannot be upgraded in-place because the strategy preserves the V9.1 "no proxy" invariant. V10.0 requires fresh deployment.

| Category | Count | Severity |
|---|---:|---|
| ABI breaking changes (constructor signatures) | 9 contracts | HIGH (incompatible deployment scripts) |
| New contracts | 1 (AdapterFactory) | INFO |
| Storage layout changes | 9 contracts (adapter side only) | MEDIUM (controller side unchanged) |
| Functional behavior changes | 0 | (no semantic changes) |
| Test surface | 49 instantiation sites + 45 new tests | INFO |

**No functional behavior changes**: V10.0 is a deployment-pattern refactor for chain portability. The runtime semantics of every contract are preserved; the verification surface (23 Halmos proofs + 15 Echidna invariants + 5 fork tests) confirms this with zero divergence vs V9.x baseline.

---

## 1. Constructor signature changes (9 contracts)

Every refactored contract now has an **empty parameterless constructor** plus a new `initialize(args)` function.

### Affected contracts

| Contract | V9.x constructor | V10 constructor | V10 initialize |
|---|---|---|---|
| `AaveV3USDCAdapter` | `(address, address, address, address, address, uint256)` | `()` | same 6 args as V9.x |
| `CometUsdcMultiMarketAdapter` | `(address, address, address, uint256, address)` | `()` | same 5 args |
| `DolomiteUsdcMultiMarketAdapter` | `(address, address, address, uint256, address)` | `()` | same 5 args |
| `EulerUsdcMultiMarketAdapter` | `(address, address, EulerMarketRegistration[], address)` | `()` | same + explicit admin param |
| `FluidUsdcMultiMarketAdapter` | `(address, address, address, uint256, address)` | `()` | same 5 args |
| `MorphoUsdcMultiMarketAdapter` | `(address, address, address, uint256, address)` | `()` | same 5 args |
| `VenusUsdcMultiMarketAdapter` | `(address, address, address, uint256, address)` | `()` | same 5 args |
| `RewardSwapHelper` | `(address, address, address, address)` | `()` | same 4 args |
| `StrategyBootstrapper` | `(address)` (deployer = msg.sender) | `()` | `(address, address)` -- explicit deployer |

### Migration semantics

**V9.x deployment**:
```solidity
AaveV3USDCAdapter adapter = new AaveV3USDCAdapter(
    USDC, AAVE_POOL, AUSDC, admin, vault, MAX_CAP
);
```

**V10 deployment (direct, e.g. tests)**:
```solidity
AaveV3USDCAdapter adapter = new AaveV3USDCAdapter();
adapter.initialize(USDC, AAVE_POOL, AUSDC, admin, vault, MAX_CAP);
```

**V10 deployment (production, via factory)**:
```solidity
bytes memory creationCode = type(AaveV3USDCAdapter).creationCode;
bytes32 salt = keccak256(abi.encodePacked(
    "MULTYR_V10_ADAPTER", "AAVE_V3_USDC", block.chainid, deploymentNonce
));
bytes memory initData = abi.encodeWithSelector(
    AaveV3USDCAdapter.initialize.selector,
    USDC, AAVE_POOL, AUSDC, admin, vault, MAX_CAP
);
address adapter = factory.deployAndInit(creationCode, salt, initData);
```

### StrategyBootstrapper -- special note

V9.x: `deployer = msg.sender` inside constructor.  
V10: `deployer` must be passed explicitly to `initialize()` because in factory deployment context, `msg.sender = AdapterFactory`, not the actual deployer EOA / multisig.

### Downstream impact

- **Deployment scripts**: V9.x `script/DeployUsdcLendingStrategy.s.sol` (constructor-based) -> V10 (direct + `initialize()` or factory). Already refactored in V10 commit `98e7006`.
- **Integration libraries**: any third-party code or off-chain tooling that instantiates adapters directly will need updates.
- **Test suites**: 49 instantiation sites refactored in V10 Phase 2 (commit `98e7006`).
- **Audit scope**: per `docs/audit-scope.md` V10 section, the constructor + initialize pair is treated as a single logical deployment unit.

---

## 2. New contract: AdapterFactory

`src/strategies/usdc-lending/factory/AdapterFactory.sol`

Net new contract introducing CREATE2 deterministic deployment + atomic initialization pattern. Detailed in:

- `audit_p07_v5/SIGNOFF/V10_ADAPTER_FACTORY_SPEC.md` -- design specification
- `audit_p07_v5/SRC_SNAPSHOT/AdapterFactory.sol` -- frozen V10 source

Key public API:

```solidity
function deployAndInit(
    bytes calldata creationCode,
    bytes32 salt,
    bytes calldata initData
) external onlyRole(DEPLOYER_ROLE) returns (address adapter);

function computeAddress(
    bytes calldata creationCode,
    bytes32 salt
) public view returns (address);
```

Test coverage: 14 tests in `test/strategies/usdc-lending/factory/AdapterFactory.t.sol` covering 8 invariants F-01 to F-08 + reinit protection + cross-chain determinism (V10 Phase 2 commit `b1a6aa5`).

---

## 3. Storage layout changes

### Adapter-side: NEW storage variables (was immutable)

Per adapter, the previously-immutable address fields now occupy storage slots. Exact slot offsets are inheritance-dependent (AccessControl + ReentrancyGuard + Initializable). Per-adapter detail:

| Adapter | New storage slots | Reference |
|---|---:|---|
| AaveV3USDCAdapter | 4 (asset, pool, aToken, vault) | `STORAGE/snapshots/AaveV3USDCAdapter.storage.json` |
| CometUsdcMultiMarketAdapter | 3 (underlying, vault, registry) | `STORAGE/snapshots/CometUsdcMultiMarketAdapter.storage.json` |
| DolomiteUsdcMultiMarketAdapter | 3 (asset, vault, registry) | same |
| EulerUsdcMultiMarketAdapter | 3 (USDC, vault, registry) -- PERMIT2 retains `constant` | same |
| FluidUsdcMultiMarketAdapter | 3 (asset, vault, fToken) | same |
| MorphoUsdcMultiMarketAdapter | 3 (underlying, vault, registry) | same |
| VenusUsdcMultiMarketAdapter | 3 (underlying, vault, vToken) | same |
| RewardSwapHelper | 3 (usdc, uniswapV3Router, camelotV3Router) | same |
| StrategyBootstrapper | 2 (strategy, deployer) | same |

Verification: 45 tests in `test/strategies/usdc-lending/adapters/StorageLayoutV10Adapters.t.sol` (V10 Phase 4 commit `5dec712`) confirm slot offsets are deterministic and consistent.

### Controller-side: NO CHANGES

V10 refactor did **not** touch the 7 controller modules. The P0.7 packed slot 78 + slots 79-81 are preserved:

- Slot 78 (packed): `capDriftToleranceBps`, `maxIdleBps`, `targetSafetyMarginBps`, `mandateRedeployCooldownSeconds`
- Slot 79: `safetyFallbackAdapters[]`
- Slot 80: `safetyFallback` mapping
- Slot 81: `lastRelCapMandateTs` mapping

Verification: `StorageLayoutP07.t.sol` 5/5 PASS post-V10 (no changes from V9.2 baseline).

---

## 4. Removed features

### Venus chain-id runtime check

V9.x `VenusUsdcMultiMarketAdapter` had:
```solidity
require(block.chainid == ARBITRUM_CHAIN_ID, "wrong chain");
```

V10 removes this check to preserve chain-portability. Chain-correctness validation moves to:

1. **Deploy script time**: `DeployUsdcLendingStrategy.s.sol` loads chain-specific config
2. **Initialize validation**: `vToken.underlying() == usdc_` check fails on incompatible chains
3. **Governance review**: Multyr Foundation Timelock approves per-chain config

Detailed rationale: `audit_p07_v5/SIGNOFF/V10_DESIGN_RATIONALE.md` s.4.

### Constructor-time access role grants

V9.x adapters granted `DEFAULT_ADMIN_ROLE` and `VAULT_ROLE` inside constructor. V10 moves these to `initialize()`. Functionally identical, but a side effect: the contract briefly exists between constructor (no roles granted) and initialize() (roles granted). In production deployment via `AdapterFactory.deployAndInit()`, both operations happen in the same transaction -- no observable intermediate state.

---

## 5. Compatibility matrix

| V9.x consumer | V10 compatibility |
|---|---|
| V9.x deployment scripts | Broken (constructor signature mismatch) -- must migrate to V10 pattern |
| V9.x test suites | Broken -- see V10 Phase 2 commit `98e7006` for migration template |
| V9.x integration libraries | Broken (constructor ABI changed) |
| V9.x adapter usage (post-init) | Identical runtime semantics -- `deposit()`, `withdraw()`, `harvest()`, etc. unchanged |
| V9.x on-chain deployed instances | Cannot be upgraded in-place (no proxy pattern) -- V10 requires fresh deployment |
| V9.x audit reports (V9.1, V9.2+P0.7) | Partial coverage -- V10 has separate audit perimeter |

---

## 6. Upgrade procedure for existing operators

If you have a V9.x deployment in production:

1. **Pause V9.x strategy** via governance (Timelock pause action)
2. **Migrate user funds** to V10 deployment (or stage migration window with allocator coordination)
3. **Deploy V10 stack** via `script/DeployAdapterFactory.s.sol` + `script/DeployUsdcLendingStrategy.s.sol`
4. **Verify deployment** via `script/MULTI_CHAIN_PLAYBOOK.md` Step 5 (byte-identical bytecode verification)
5. **Re-register Chainlink Automation upkeep** for V10 adapters
6. **Transfer funds** to V10 vault
7. **Unpause governance** + announce migration completion

No automated upgrade path exists. This is the cost of preserving the "no proxy" invariant from V9.1.

---

## 7. Audit perimeter implications

- **V10 audit replaces V9.2+P0.7 pre-submission perimeter**: any findings from the planned Q3-2026 audit apply to V10, not V9.x
- **Cross-chain deployment audit cost amortized**: future Optimism, Base, Polygon deployments use byte-identical bytecode, requiring only per-chain governance review (~1 day) rather than per-chain audit (~$40-70K)
- **Bug bounty perimeter unified**: Immunefi program (forthcoming) covers V10 bytecode across all chains where deployed
- **Single source-code review**: Spearbit/Sherlock/etc. audit Solidity source, which is identical across all V10 chain deployments
