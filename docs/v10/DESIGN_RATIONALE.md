# V10 Design Rationale

## Mission

V10 ("storage+initialize refactor") enables byte-identical deployment of the USDC Lending
Strategy across multiple EVM chains from a single compiled artifact. The same bytecode
deployed via CREATE2 with a chain-specific salt produces the same contract address on each
chain, with chain-specific configuration loaded post-deploy via initializer.

---

## Core changes from V9.2

### 1. Modular delegatecall architecture (EIP-170 pressure)

Two production contracts approached the EIP-170 24,576 B hard limit:
- `StrategyScoringModule`: 24,426 B (150 B margin) — CRITICAL
- `UsdcMultiLendingVault`: 24,048 B (528 B margin) — HIGH

**Solution**: Extract hot logic into deployed satellite modules with `onlyDelegateCall` guards:
- `StrategySafetyOverflowModule` (new, 13,424 B) — safety overflow + degraded mode checks
- `StrategyAdapterOpsModule` extended (16,336 B) — realizeLiquidity + view diagnostics

Result: both contracts now under 22,000 B (margin > 2,500 B). See `docs/audit/sizes/CONTRACT_SIZES.md`.

### 2. StrategyConfigLib (single source of truth)

`StrategyExplainabilityLens` previously duplicated parameter-reading logic from
`StrategyStorageLayout`. V10 extracts shared reads into `StrategyConfigLib` — a pure
`library` inlined at compile time. All three lens files (`StrategyExplainabilityLens`,
`StrategyHealthRegistry`, `StrategyRouter`) now read from a single implementation.

Benefits:
- No duplicated storage reads
- Lens output is provably consistent with module behavior
- Zero bytecode cost (library functions are inlined, `StrategyConfigLib` deploys as 3 B stub)

### 3. Deterministic build

All floating pragmas pinned to exact `0.8.28`. `foundry.toml` additions:
```toml
evm_version = "cancun"      # Arbitrum One compatible; explicit across Foundry upgrades
bytecode_hash = "none"      # removes IPFS metadata hash from bytecode
cbor_metadata = false       # removes CBOR trailer
```
Result: `forge build` is fully reproducible — byte-identical artifacts across machines
and Foundry versions (given same solc 0.8.28).

### 4. Per-chain blocksPerYear (C-04 fix)

Venus protocol uses per-block interest rates. The V9.2 adapter hardcoded
`BLOCKS_PER_YEAR = 126_144_000` (Arbitrum 0.25s blocks). V10 makes this configurable:
```solidity
uint256 public blocksPerYear; // set via setBlocksPerYear(uint256) onlyAdmin
```
Default: `126_144_000` (Arbitrum). Overridable at deploy for other chains:
- Optimism/Base: 15,768,000 (2s blocks)
- Ethereum L1: 2,628,000 (12s blocks)
- Polygon: 14,891,802 (2.12s average)

### 5. SCORING-INV-2 cap enforcement at all TVL tiers

`_effectiveAbsCapBps()` previously returned 100% unconditionally at T1 TVL (< 25,000 USDC),
ignoring the `adapterMaxExposureBps` governance parameter. V10 enforces the cap at all tiers:
```solidity
if (dMax == 1) {
    uint16 globalCeiling = adapterMaxExposureBps;
    return globalCeiling > 0 ? uint256(globalCeiling) : 10000;
}
```
This ensures governance-set caps are respected from the first USDC deposited.

---

## F-SIZE-01 extraction rationale

`StrategyScoringModule._executeSafetyOverflow()` is a 140-line function triggered only
during degraded-mode deposits (rare path). Extracting it to `StrategySafetyOverflowModule`
reduces ScoringModule from 24,426 B to 21,528 B without any behavioral change.

The `onlyDelegateCall` guard prevents direct calls to the satellite module:
```solidity
modifier onlyDelegateCall() {
    require(address(this) != _self, "DIRECT_CALL_FORBIDDEN");
    _;
}
```
where `_self = address(this)` is set in the constructor (module's own address). Any
delegatecall from the vault sets `address(this)` to the vault's address, satisfying the guard.

## F-SIZE-02 extraction rationale

`UsdcMultiLendingVault._realizeLiquidity()` (~80 lines), `_checkDegradedModeLocally()`,
and three view diagnostics were extracted to existing modules. The vault now holds only
selector constants and delegatecall relay stubs.

Solidity 0.8.28 rejects `delegatecall` in assembly inside `view` functions (Error 8961).
The three relay stubs therefore dropped `view` from the vault — the module implementations
remain `view` (read-only), and staticcall-via-interface still works at runtime.

---

## Storage layout invariants

V10 does not introduce new storage slots in the vault (`UsdcLendingStrategy`). All
additions are:
1. `safetyOverflowModule_addr` in `StrategyStorageLayout` — offset by reducing `__gap[2]`
   to `__gap[1]` (slot count preserved)
2. No new storage in `StrategyAdapterOpsModule`, `StrategySafetyOverflowModule` (stateless
   satellite modules; all state is in the vault via delegatecall)

Storage slot map: see `StrategyStorageLayout.sol` for the authoritative slot ordering.
