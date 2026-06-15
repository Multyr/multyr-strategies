# V10 AdapterFactory -- Design Specification

**Status**: Implementation complete (V10 Phase 2, commit `b1a6aa5`).
**Pattern**: Direct deploy + Atomic factory init (CREATE2 + initialize in single tx).
**Audit context**: Re-init vulnerability prevention (Sherlock rova #414 reference).

---

## 1. Design rationale

The AdapterFactory eliminates the **front-run window** between contract deployment and initialization. Without it:

```
Block N:     [Adapter deployed via CREATE2 by Multyr]
Block N+1:   [Anyone calls Adapter.initialize(maliciousArgs)]  <- FRONT-RUN!
Block N+2:   [Multyr's intended initialize() reverts: already initialized]
```

With AdapterFactory's atomic `deployAndInit(...)`, deployment and initialization happen in the **same transaction**, gated by `DEPLOYER_ROLE`. The attacker has no window to inject malicious args.

This pattern is explicitly endorsed by tier-1 audit firms (Cantina x Morpho multi-chain rollout, OZ Upgrades Plugin documentation, EIP-7955 permissionless CREATE2 factory).

## 2. Contract interface

```solidity
contract AdapterFactory is AccessControl {
    bytes32 public constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");

    event AdapterDeployed(
        address indexed adapter,
        address indexed initiator,
        bytes32 salt,
        bytes32 codehash
    );

    error InitializeReverted(address adapter, bytes data);
    error AlreadyDeployed(address expected);

    constructor(address admin_);

    function deployAndInit(
        bytes calldata creationCode,
        bytes32 salt,
        bytes calldata initData
    ) external onlyRole(DEPLOYER_ROLE) returns (address adapter);

    function computeAddress(
        bytes calldata creationCode,
        bytes32 salt
    ) external view returns (address);
}
```

## 3. Why the factory itself uses constructor-immutable (intentionally)

The AdapterFactory is the **single chain-specific contract** in the V10 deployment. Its constructor receives `admin_` which is the Multyr Foundation Timelock multisig -- chain-specific by definition (different multisig per chain).

This is acceptable because:
1. **AdapterFactory deployment is one-time** per chain -- no future bytecode portability concern
2. **Factory is the GOVERNANCE entry point** -- the multisig address must be chain-specific
3. **All downstream adapters are byte-identical** across chains -- the factory's chain-specificity is contained

## 4. Salt derivation policy

Each adapter type uses a deterministic salt scheme:

```solidity
salt = keccak256(abi.encodePacked(
    "MULTYR_V10_ADAPTER",
    adapterType,              // e.g., "AAVE_V3_USDC"
    chainId,                  // 42161 for Arbitrum
    deploymentNonce           // bumped if re-deployment needed
))
```

This guarantees:
- Same adapter type + same chain = same deployed address (predictable for governance)
- Different chains = different addresses (avoids accidental cross-chain collision)
- Deployment nonce allows clean re-deploy after governance retirement

## 5. Security invariants

| # | Invariant | Verification method |
|---|---|---|
| F-01 | Only `DEPLOYER_ROLE` can call `deployAndInit` | Slither access-control + unit test |
| F-02 | After factory deploy+init, second `initialize()` reverts | Unit test |
| F-03 | Initialize reverts on second call (OZ Initializable enforces) | Invariant test |
| F-04 | If `initialize()` reverts inside `deployAndInit`, entire tx reverts | Foundry try/catch test |
| F-05 | CREATE2 deterministic address: `computeAddress(code, salt) == deployAndInit(code, salt, ...)` | Foundry test |
| F-06 | No re-deploy at same address possible (`AlreadyDeployed` revert) | Foundry test |
| F-07 | Event `AdapterDeployed` emitted with correct `codehash` | Foundry test event check |
| F-08 | Factory has no setter functions for protocol addresses (admin_ only) | Static review |

## 6. Gas budget

Factory operation `deployAndInit`:

| Step | Gas estimate |
|---|---:|
| `computeAddress()` view (CREATE2 derivation) | ~3,000 |
| `expected.code.length` check | ~2,100 (cold) |
| CREATE2 deploy of adapter (medium adapter ~30 KB bytecode) | ~150,000 + bytecode |
| Adapter constructor (empty body) | ~5,000 |
| `adapter.call(initData)` invocation | ~25,000 (call overhead) |
| Adapter `initialize()` body | varies per adapter (~50-100k typical) |
| Event emission | ~3,000 |
| **Total for typical adapter** | **~250-350k gas** |

Per chain deployment of 7 adapters: ~2M gas total. At Arbitrum prices (~$0.10/Mgas): **~$0.20 deployment cost**.

## 7. Multi-chain rollout playbook

See `script/MULTI_CHAIN_PLAYBOOK.md` for full 7-step deployment sequence.

Summary per new chain:
1. Verify same source code compiles to same bytecode
2. Deploy AdapterFactory on target chain (chain-specific admin = chain-specific multisig)
3. Pre-compute all adapter addresses via computeAddress()
4. Deploy each adapter atomically via deployAndInit()
5. Verify deployed bytecode hash matches Arbitrum bytecode hash
6. AUDIT REQUIREMENT: NONE. Same bytecode + same audit perimeter.

## 8. Test coverage

`test/strategies/usdc-lending/factory/AdapterFactory.t.sol` (14 tests):
- test_deployAndInit_success_path
- test_deployAndInit_revert_when_caller_lacks_role
- test_deployAndInit_revert_when_init_reverts
- test_deployAndInit_revert_already_deployed
- test_computeAddress_matches_actual_deployment
- test_deployment_atomicity_no_uninitialized_window
- test_event_AdapterDeployed_emitted_correctly
- test_deterministic_address_across_simulated_chains
- Per adapter: test_initialize_revertsOn_secondCall, test_initialize_args_validation_preserved

## 9. Preemptive auditor findings

| Likely finding | Severity | Pre-mitigation |
|---|---|---|
| "Initialize lacks access control beyond OZ initializer" | Medium | Factory atomically gates init, no tx-window. After factory call, initializer modifier prevents re-init. |
| "AdapterFactory salt collision risk if same code + same salt re-used" | Low | `AlreadyDeployed` revert explicitly handles. Nonce-bumping documented in salt policy s.4. |
| "CREATE2 deployment can be replayed on other chains by attacker" | Informational | Attacker can deploy same bytecode at same address on another chain. This is a FEATURE (chain portability). Attacker has no DEPLOYER_ROLE to call initialize. |
| "Factory itself upgradeable (admin can grant DEPLOYER_ROLE to attacker)" | Informational | Admin = Timelock multisig. Same trust assumption as existing strategy admin (V9.1 governance model). |

## Cross-references

- OZ Initializable: `@openzeppelin/contracts/proxy/utils/Initializable.sol`
- Sherlock rova #414 (front-run init): https://github.com/sherlock-audit/2025-02-rova-judging/issues/414
- EIP-7955 (CREATE2 factory standard): https://eips.ethereum.org/EIPS/eip-7955
- Cantina x Morpho multi-chain audit: https://cantina.xyz/blog/cantina-morpho-2025-modular-lending-security
- V10_DESIGN_RATIONALE.md ss.1-3 -- preemptive auditor Q&A
