# USDC Lending Strategy — Deployment Guide

> **Target chain**: Arbitrum One (`chainId = 42161`)
> **Prerequisite**: Core system deployed via `multyr-core/script/DeployCoreSystem.s.sol`
> **Deploy script**: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:202`

---

## Architecture Overview

The USDC Lending Strategy uses a **V9.1 3-contract split** pattern where strategy logic is factored across
delegatecall modules. The main controller (`UsdcMultiLendingVault`) holds no logic bytecode of its own —
it delegates to four core modules and three optional modules.

```
UsdcMultiLendingVault (controller)
├── StrategyParamsModule        — stores all tunable parameters
├── StrategyScoringModule       — computes allocation scores + effectiveAbsCapBps
├── StrategyAdapterOpsModule    — executes adapter operations (deposit/withdraw/poke)
├── StrategyRebalanceGateModule — guards rebalance cadence + drift checks
├── StrategySettingsModule      (optional) — settings management
├── StrategyAllocCalcModule     (optional) — pure allocation computation
└── StrategyRebalancePlanModule (optional) — rebalance plan generation

StrategyBootstrapper (one-shot) — registers 7 adapters, then self-destructs BOOTSTRAP_ROLE
StrategyUpkeep                  — Chainlink-compatible automation keeper
```

The strategy interacts with **7 lending adapters** across 5 protocols:
- **Aave V3** — 1 market (USDC pool)
- **Morpho** — 5 markets (Gauntlet Core, Hyperithm Apex, Steakhouse HY, Gauntlet Prime, Yearn Degen)
- **Compound III (Comet)** — 1 market (USDC V3)
- **Euler V2** — 4 markets
- **Dolomite** — 1 market (dUSDC)
- **Fluid** — 1 market (fUSDC)
- **Venus** — 1 market (vUSDC)

---

## Prerequisites

| Requirement | Source | Notes |
|---|---|---|
| Core system deployed | `multyr-core/script/DeployCoreSystem.s.sol:202` | `VAULT_ADDRESS`, `STRATEGY_ROUTER_ADDRESS`, `BUFFER_MANAGER_ADDRESS`, `HEALTH_REGISTRY_ADDRESS` from its output |
| Governance Safe deployed | existing Arbitrum 3-of-5 Safe | `GOVERNANCE_ADDRESS` — direct admin; no timelock required initially |
| Deployer has ≥0.001 USDC | Euler Permit2 dust | `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:393-400` — transfered to Euler adapter before `initializeMarkets()` |
| Deployer EOA | `DEPLOYER_PRIVATE_KEY` env var | Must be `owner` on CoreVault and StrategyRouter -- neither uses AccessControl/`hasRole` (CoreVault is a Diamond-lite thin proxy with a plain two-step `owner()`/`pendingOwner()`/`acceptOwnership()`; calling `hasRole()` on it reverts `ModuleNotSet()`) |
| Arbitrum archive RPC | `RPC_URL` | Block confirmation times matter for broadcast |

---

## Environment Variables

### Required

```bash
DEPLOYER_PRIVATE_KEY      # deployer private key (hex, with 0x prefix)
VAULT_ADDRESS             # CoreVault address from DeployCoreSystem output
STRATEGY_ROUTER_ADDRESS   # StrategyRouter address
BUFFER_MANAGER_ADDRESS    # BufferManager address
HEALTH_REGISTRY_ADDRESS   # StrategyHealthRegistry address
GUARDIAN_ADDRESS          # guardian multisig
```

### Required when `DO_SEAL=true`

```bash
GOVERNANCE_ADDRESS        # deployed Gnosis Safe (direct owner/admin)
SELECTOR_REGISTRY_ADDRESS # SelectorRegistry
SYSTEM_SEALER_ADDRESS     # SystemSealer
```

### Optional

```bash
INCENTIVES_ADDRESS        # default: address(0) -- see note below
VETOER_ADDRESS            # default: address(0) -- see note below
DO_SEAL                   # "true" → Phase 5 runs (seal + role transfer)
DEPLOY_UPKEEP             # default: true
DEPLOY_LENDING_ADAPTERS   # default: true
UNPAUSE_BUFFER            # default: true
ADAPTER_MAX_EXPOSURE_BPS  # uint16, default: 5000 (50%)
STRATEGY_OUTPUT_JSON      # output path; default: broadcast/strategy-addresses.json
```

> `INCENTIVES_ADDRESS`/`VETOER_ADDRESS` only take effect if `CoreVault`'s ecosystem is not
> already configured (`setEcosystem` is idempotent, gated on `eco.bufferManager == address(0)`).
> In the standard core-then-strategy deploy order, `DeployCoreSystem.s.sol` already calls
> `setEcosystem` itself, so these two are no-ops in practice — set them for documentation
> consistency with whatever the core deploy used, not because this script will apply them.
>
> `GLOBAL_CONFIG_ADDRESS`, `PRICE_ORACLE_ADDRESS`, `VAULT_FACTORY_ADDRESS`, and
> `FEE_COLLECTOR_ADDRESS` were removed — they were loaded but never used. This strategy
> does not register with `VaultFactory` (that registry tracks `CoreVault` instances only;
> `DeployCoreSystem.s.sol` already registers the relevant `CoreVault` during the core
> deploy). A strategy becomes known to the system via `StrategyRouter.register()` instead
> (Phase 2.1).

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol`, `_loadConfig()`

---

## Arbitrum One Constants

| Symbol | Address | Note |
|---|---|---|
| `USDC` | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` | Native bridged USDC |
| `AAVE_POOL` | `0x794a61358D6845594F94dc1DB02A252b5b4814aD` | Aave V3 Pool |
| `AAVE_AUSDC` | `0x724dc807b04555b71ed48a6896b6F41593b8C637` | aUSDC receipt token |
| `COMET_USDC_V3` | `0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf` | Compound III USDC |
| `DOLOMITE_dUSDC` | `0x444868B6e8079ac2c55eea115250f92C2b2c4D14` | Dolomite dUSDC |
| `FLUID_FUSDC` | `0x1A996cb54bb95462040408C06122D45D6Cdb6096` | Fluid fUSDC |
| `VENUS_VTOKEN` | `0x7D8609f8da70fF9027E9bc5229Af4F6727662707` | Venus vUSDC |

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:115-135`

---

## Deploy Sequence

```mermaid
graph TD
    A[Phase 1: Deploy AdapterFactory<br/>+ 4 core modules: Params/Scoring/AdapterOps/RebalanceGate] --> B
    B[Phase 1.1: Deploy UsdcMultiLendingVault<br/>assembly CREATE nonce control] --> C
    C[Phase 1.2: Deploy StrategyBootstrapper<br/>atomic CREATE2 deploy+init via AdapterFactory] --> D
    D[Phase 1.5: Deploy 7 adapters<br/>atomic deployAndInit via AdapterFactory<br/>Euler: USDC dust + initializeMarkets FIRST] --> E
    E[Phase 1.6: Deploy 2 rate providers<br/>AaveRP + DolomiteRP, wire to adapters] --> F
    F[Phase 1.7: Deploy optional modules<br/>Settings + AllocCalc + RebalancePlan] --> G
    G[Phase 2: Wire strategy<br/>register in router + setEcosystem] --> H
    H[Phase 2.5: Bootstrap ONE-SHOT<br/>register 7 adapters, BOOTSTRAP_ROLE renounced] --> H2
    H2[Phase 2.6: Poke external TVL + liquidity<br/>required before first deposit will succeed] --> I
    I[Phase 3: Deploy StrategyUpkeep<br/>grant KEEPER_ROLE] --> J
    J[Phase 3.4: Grant PARAM_ROLE<br/>Morpho + Dolomite + Fluid + AaveRP] --> K
    K[Phase 3.5: Transfer adapter admin roles<br/>to Timelock] --> L
    L[Phase 4: Unpause BufferManager] --> M
    M[Phase 5: Seal optional<br/>DO_SEAL=true] --> N
    N[Address book written<br/>broadcast/strategy-addresses.json]

    style D fill:#ffcccc
    style J fill:#ffcccc
    style H fill:#ffffcc
    style H2 fill:#ffffcc
```

> **V10 note**: adapter deployment now goes through `AdapterFactory.deployAndInit()` —
> a CREATE2 deploy and the adapter's `initialize()` call execute atomically in one
> transaction, closing the front-runnable window a separate `new X(); x.initialize(...)`
> pair leaves open. `StrategyBootstrapper` is deployed the same way. See
> `src/strategies/usdc-lending/factory/AdapterFactory.sol`.

---

## Phase 1 — Deploy AdapterFactory + Core Modules + Strategy

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol`, `_phase1_deployModulesAndStrategy`

The deploy uses **nonce pre-computation** to wire cross-module addresses before deployment.
`AdapterFactory` is a plain deployer-nonce CREATE at `N+0`; everything CREATE2'd through
it afterward (the bootstrapper and all 7 adapters) is predicted via
`factory.computeAddress(...)`, not `vm.computeCreateAddress(...)`:

```
N+0 = AdapterFactory
N+1 = StrategyParamsModule
N+2 = StrategyScoringModule
N+3 = StrategyAdapterOpsModule
N+4 = StrategyRebalanceGateModule
N+5 = UsdcMultiLendingVault     ← assembly CREATE
      (StrategyBootstrapper is deployed via factory.deployAndInit() — a CREATE2
       from AdapterFactory, not a deployer-nonce CREATE, so it does not consume
       a nonce slot in this list)
```

### 1.-1 — AdapterFactory

```solidity
AdapterFactory factory = new AdapterFactory(cfg.deployer);
```

Deployed first so its address can be used to CREATE2-predict the bootstrapper's address
(needed for the vault constructor, which pre-grants `BOOTSTRAP_ROLE` to that predicted
address). `cfg.deployer` receives both `DEFAULT_ADMIN_ROLE` and `DEPLOYER_ROLE` on the
factory. Contract: `multyr-strategies/src/strategies/usdc-lending/factory/AdapterFactory.sol`.

### 1.0a — StrategyParamsModule

```solidity
StrategyParamsModule params = new StrategyParamsModule(USDC, cfg.vault);
```

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:264`
Contract: `multyr-strategies/src/strategies/usdc-lending/controller/StrategyParamsModule.sol:38`

Holds all 32 `StrategyInitParams` fields. Initialized with `_defaultParams()` values from
`multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:701-739`.

### 1.0b — StrategyScoringModule

```solidity
StrategyScoringModule scoring = new StrategyScoringModule(
    USDC, cfg.vault, result.paramsModule, address(0), predictedOps
);
```

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:270-274`
Contract: `multyr-strategies/src/strategies/usdc-lending/controller/StrategyScoringModule.sol:44`

Note: `address(0)` placeholder for rebalancePlanModule — wired in Phase 1.7 after
`StrategyRebalancePlanModule` is deployed.

### 1.0c — StrategyAdapterOpsModule

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:277-283`
Contract: `multyr-strategies/src/strategies/usdc-lending/controller/StrategyAdapterOpsModule.sol:15`

### 1.0d — StrategyRebalanceGateModule

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:285-291`
Contract: `multyr-strategies/src/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol:21`

### 1.1 — UsdcMultiLendingVault (assembly CREATE)

```solidity
bytes memory code = abi.encodePacked(type(UsdcMultiLendingVault).creationCode, args);
assembly { deployed := create(0, add(code, 0x20), mload(code)) }
```

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:303`
Contract: `multyr-strategies/src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol:23`

**Assembly CREATE is required** to maintain the exact nonce layout so StrategyBootstrapper
receives `BOOTSTRAP_ROLE` in the constructor before being deployed.

### 1.2 — StrategyBootstrapper

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol`, `_phase1_deployModulesAndStrategy`
Contract: `multyr-strategies/src/strategies/usdc-lending/StrategyBootstrapper.sol`

`BOOTSTRAP_ROLE` is granted automatically in the `UsdcMultiLendingVault` constructor to the
predicted bootstrapper address (`predictedBootstrap = factory.computeAddress(creationCode, salt)`,
where `salt = keccak256(abi.encodePacked(chainCfg.deploySalt, "bootstrapper"))`). The bootstrapper
itself is then deployed via `factory.deployAndInit(...)` — CREATE2 + `initialize()` atomically in
one transaction — and the deploy asserts `hasRole(BOOTSTRAP_ROLE, bootstrapper)` immediately after.

---

## Phase 1.5 — Deploy 7 Lending Adapters

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol`, `_phase1_5_deployAdapters`

### ProtocolRegistry

Before deploying the adapters, the production `ProtocolRegistry` is deployed under temporary
deployer ownership and configured with all market addresses. Every mutation is `onlyOwner`, and
the mandatory final handoff transfers ownership directly to `GOVERNANCE_ADDRESS`:
- 5 Morpho vaults: Gauntlet USDC Core, Hyperithm USDC Apex, Steakhouse HY USDC, Gauntlet USDC Prime, Yearn Degen USDC
- 1 Comet (Compound III USDC V3)
- 4 Euler V2 vaults
- 1 Dolomite dUSDC

### Adapter deploy order

Every adapter is deployed via `AdapterFactory.deployAndInit(creationCode, salt, initCalldata)` —
CREATE2 + `initialize()` execute atomically in one transaction, closing the front-runnable window
a separate `new X(); x.initialize(...)` pair would leave open (an unrelated caller taking
`DEFAULT_ADMIN_ROLE`/`PARAM_ROLE` on the adapter first). Each adapter's salt is
`keccak256(abi.encodePacked(chainCfg.deploySalt, "<name>"))`.

| Step | Adapter | `initialize(...)` highlight |
|---|---|---|
| 1.5.3 | `AaveV3USDCAdapter` | `(usdc, aavePool, aaveAUsdc, deployer, strategy, capacity)` |
| 1.5.4 | `MorphoUsdcMultiMarketAdapter` | `(usdc, deployer, strategy, capacity, registry)` |
| 1.5.5 | `CometUsdcMultiMarketAdapter` | `(usdc, deployer, strategy, capacity, registry)` |
| 1.5.6 | `EulerUsdcMultiMarketAdapter` | `(strategy, usdc, eulerMarkets[4], registry, deployer)` — **see critical note below** |
| 1.5.7 | `DolomiteUsdcMultiMarketAdapter` | `(usdc, deployer, strategy, capacity, registry)` — `marketId=17, accountNumber=0` configured in Phase 1.6 |
| 1.5.8 | `FluidUsdcMultiMarketAdapter` | `(usdc, deployer, strategy, capacity, fluidFUsdc)` |
| 1.5.9 | `VenusUsdcMultiMarketAdapter` | `(usdc, deployer, strategy, capacity, venusVToken, venusBlocksPerYear)` |

### ⚠ CRITICAL — Euler `initializeMarkets()` BEFORE role transfer

```solidity
IERC20(usdc).transfer(address(euler), EULER_DUST);  // 0.001 USDC
euler.initializeMarkets();
```

**v8-hotfix**: Euler uses Permit2 internal allowances. These must be initialized (via USDC dust transfer
+ `initializeMarkets()`) **before any role transfer**. Without this, the first strategy deposit to
Euler silently fails or quarantines the adapter. This happens right after the adapter's
`deployAndInit()` call in Phase 1.5.6, before Phase 3.5 role transfers. Note this
`initializeMarkets()` step is separate from — and unrelated to — the OZ `initializer` pattern that
`deployAndInit()` already closes the front-running window on; it is its own PARAM_ROLE-gated
post-init call, safe to run right after atomic deploy+init.

---

## Phase 1.6 — Rate Providers

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:433-459`

| Contract | Purpose |
|---|---|
| `AaveLiquidityRateProvider` | Supplies Aave liquidity rate for scoring |
| `DolomiteSupplyRateProvider` | Supplies Dolomite supply rate for scoring |

After deploy, rate providers are wired to their adapters:

```solidity
AaveV3USDCAdapter(payable(result.aaveAdapter)).setRateProvider(result.aaveRateProvider);
DolomiteUsdcMultiMarketAdapter(payable(result.dolomiteAdapter)).setRateProvider(result.dolomiteRateProvider);
```

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:446-448`

Dolomite also requires market configuration:
- `usdcMarketId = 17`
- `accountNumber = 0`

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:452-455`

---

## Phase 1.7 — Optional Modules (BEFORE Bootstrap)

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:464-492`

**⚠ MUST run before Phase 2.5 bootstrap.** Bootstrap calls `whitelistAdapter()` which reads module
addresses; if modules are wired after bootstrap, adapters will not see the updated configuration.

| Module | Wire method | Contract |
|---|---|---|
| `StrategySettingsModule` | `strategy.setSettingsModule()` | `multyr-strategies/src/strategies/usdc-lending/controller/StrategySettingsModule.sol:30` |
| `StrategyAllocCalcModule` | `strategy.setAllocCalcModule()` | `multyr-strategies/src/strategies/usdc-lending/controller/StrategyAllocCalcModule.sol:29` |
| `StrategyRebalancePlanModule` | `strategy.setRebalancePlanModule()` | `multyr-strategies/src/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol:48` |

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:487-489`

---

## Phase 2 — Wire Strategy

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:495-543`

### 2.1 — Register in StrategyRouter

```solidity
router.register(address(result.strategy), 100, 10000);
router.setMaxStrategyBps(address(result.strategy), 10000);
router.setLossCapPerStrategy(address(result.strategy), 50);
```

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:503-505`

- `maxBps = 10000` (100% allocation allowed)
- `lossCap = 50 bps` (0.5% loss cap per rebalance cycle)

Registration is **idempotent** — skipped if already registered. If `router.owner() != deployer`,
registration must be done via Timelock.

### 2.2 — Verify CORE_ROLE

```solidity
require(result.strategy.hasRole(CORE_ROLE, cfg.vault), "DEPLOY_BUG: CoreVault missing CORE_ROLE");
require(result.strategy.hasRole(CORE_ROLE, cfg.strategyRouter), "DEPLOY_BUG: StrategyRouter missing CORE_ROLE");
```

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:516-523`

`CORE_ROLE` is granted in the `UsdcMultiLendingVault` constructor. This assertion verifies no
constructor regression.

### 2.3 — `setEcosystem`

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:526-542`

Configures `bufferManager`, `strategyRouter`, `healthRegistry`, `incentives`, `guardian`, `vetoer`
on `CoreVault`. Idempotent — skipped if ecosystem already set.

---

## Phase 2.5 — Bootstrap (ONE-SHOT)

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:547-565`

```solidity
StrategyBootstrapper(payable(result.bootstrapper)).bootstrap(adapters);
require(!StrategyBootstrapper(payable(result.bootstrapper)).hasBootstrapRole(), "BOOTSTRAP_ROLE not renounced");
```

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:559-563`

**ONE-SHOT**: `StrategyBootstrapper.bootstrap()` registers all 7 adapters in order:
`[Aave, Morpho, Comet, Euler, Dolomite, Fluid, Venus]`

After `bootstrap()` completes, it **permanently renounces `BOOTSTRAP_ROLE`**. No re-bootstrap is
possible. If you need to add adapters post-deploy, use the timelock upgrade path.

Contract: `multyr-strategies/src/strategies/usdc-lending/StrategyBootstrapper.sol:30`

---

## Phase 2.6 — Poke Adapter Data (required for deposit readiness)

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol`, `_phase2_6_pokeAdapterData`

```solidity
result.strategy.grantRole(KEEPER_ROLE, cfg.deployer);
strategy.pokeExternalTVL();
strategy.pokeLiquidityBatch(0, 10);
result.strategy.revokeRole(KEEPER_ROLE, cfg.deployer);
```

**Why this exists**: every adapter's `cachedExternalTVL` defaults to `0` right after bootstrap,
which reads as `CONFIDENCE_ZERO` ("< 100K -- NO ALLOCATION" per `StrategyStorageLayout.sol`).
With no adapter eligible for allocation, `deployIdleToAdapters()` can place nothing, idle stays
at ~100% of TVL, and the **first real deposit reverts with `BootstrapIdleTooHigh()`** — the
strategy is deployed but not deposit-ready. This was caught by running the actual deploy script
against a live Arbitrum fork
(`test/strategies/usdc-lending/fork/DeployAndDepositReadiness.fork.t.sol`).

Both `pokeExternalTVL()`/`pokeLiquidityBatch()` are `KEEPER_ROLE`-gated and the deployer EOA
doesn't hold that role by default, so this phase grants it temporarily (deployer still has
`DEFAULT_ADMIN_ROLE` at this point, pre-seal) and revokes it immediately after — the deploy
leaves no lasting `KEEPER_ROLE` grant on the deployer address.

If `cfg.deployer` has no admin role at this point (e.g. a re-run after partial admin transfer),
this phase logs a skip and a keeper must run both calls manually before the first deposit.

---

## Phase 3 — Automation

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:569-608`

### 3.1 — StrategyUpkeep

```solidity
StrategyUpkeep upkeep = new StrategyUpkeep(strategies);
```

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:575`
Contract: `multyr-strategies/src/strategies/usdc-lending/automation/LendingStrategyUpkeep.sol:198`

Takes `address[] strategies` in constructor — one upkeep can cover multiple strategies if needed.

### 3.2 — Grant KEEPER_ROLE

```solidity
result.strategy.grantRole(KEEPER_ROLE, result.strategyUpkeep);
```

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:582`

If deployer no longer has `DEFAULT_ADMIN_ROLE` at this point, grant via timelock:
`strategy.grantRole(keccak256("KEEPER_ROLE"), upkeepAddress)`

### 3.4 — Grant PARAM_ROLE (v8-hotfix CRITICAL)

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:594-608`

**⚠ MUST happen BEFORE Phase 3.5 adapter admin transfers.** After Phase 3.5, deployer has no
admin role on adapters, so any later PARAM_ROLE grant must come from the governance Safe.

| Adapter / Contract | PARAM_ROLE grant to |
|---|---|
| `MorphoUsdcMultiMarketAdapter` | `StrategyUpkeep` |
| `DolomiteUsdcMultiMarketAdapter` | `StrategyUpkeep` |
| `FluidUsdcMultiMarketAdapter` | `StrategyUpkeep` |
| `AaveLiquidityRateProvider` | `StrategyUpkeep` |

Without `PARAM_ROLE`, `poke()` (APY refresh) silently does nothing on these adapters. Monitoring
will show stale APY data. Aave, Comet, Euler, Venus do not require PARAM_ROLE for their poke
implementations.

### 3.5 — Transfer Adapter Control to Governance Safe

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:612-656`

For each adapter, the script grants the Safe `DEFAULT_ADMIN_ROLE` plus `PARAM_ROLE` where
applicable, then renounces both deployer roles. The same handoff covers both rate providers.

Phase 3.6 then transfers the strategy, registry, adapter factory, and upkeep to the same Safe.
This is mandatory and does not depend on `DO_SEAL`.

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:628-633`

---

## Phase 4 — Unpause BufferManager

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:661-667`

```solidity
IBufferManager(cfg.bufferManager).setPaused(false);
```

Controlled by `UNPAUSE_BUFFER=true` env var (default: `true`). After unpause, the strategy can
receive allocation from CoreVault via the StrategyRouter.

---

## Phase 5 — Seal (optional, `DO_SEAL=true`)

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:672-688`

The strategy-side handoff has already completed. This optional phase only verifies:
1. `CoreVault.isRoutingFrozen() == true`
2. `IAdminModule(vault).isComponentsTimelocked() == true`

Both conditions must be true before seal succeeds. These are set during the core deploy Phase 6
(`multyr-core/script/DeployCoreSystem.s.sol`).

---

## StrategyInitParams Defaults

Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol`, `_defaultParams()`

32-field struct initialized with production defaults:

| Parameter | Value | Note |
|---|---|---|
| `maxAdaptersPerAllocation` | 3 | Max adapters active in one rebalance |
| `minAdaptersActive` | 2 | Degraded mode trigger |
| `rebalanceMinMoveBps` | 50 | 0.5% minimum capital move |
| `minSecondsBetweenRebalances` | 86400 | 24h cooldown |
| `driftToleranceBps` | 80 | 0.8% before rebalance trigger |
| `wAPY` | 4000 | APY score weight (40%) |
| `wLiq` | 2000 | Liquidity score weight (20%) |
| `wRisk` | 2000 | Risk score weight (20%) |
| `wStability` | 1000 | Stability score weight (10%) |
| `wIncentive` | 1000 | Incentive score weight (10%) |
| `incentiveDecayHalfLife` | 604800 | 7-day incentive half-life |
| `adapterMaxExposureBps` | 5000 | 50% cap per adapter (overridable via `ADAPTER_MAX_EXPOSURE_BPS` env) |
| `newAdapterRampBps` | 500 | 5% ramp for new adapters |
| `gateHorizonDays` | 30 | Gate evaluation window |
| `gateMinNetBenefitBps` | 10 | 0.1% minimum net benefit |
| `slippageBpsEstimate` | 2 | 0.02% slippage estimate |
| `withdrawalSpreadBpsEstimate` | 2 | 0.02% withdrawal spread estimate |
| `gasCostUSDC` | 1e6 | 1 USDC estimated gas cost (used in net-benefit gate math) |
| `harvestThresholdBps` | 100 | 1% before harvest trigger |
| `minSecondsBetweenHarvests` | 86400 | 24h harvest cooldown |
| `dustTolerance` | 1e4 | 0.01 USDC no-cash-invariant dust allowance (bounded `<= 100_000e6` by `setDustTolerance`) |
| `stabilityEMAPeriod` | 7 | EMA lookback days |
| `minNewAdapterSeed` | 100,000 USDC | Minimum for new adapter |
| `newAdapterRampDuration` | 259200 | 3-day ramp duration |
| `maxIdleAfterDepositBps` | 500 | 5% max idle post-deposit |
| `maxIdleBootstrapBps` | 5000 | 50% max idle during bootstrap |
| `degradedViewThresholdBps` | 2500 | 25% trigger for DegradedMode |
| `failureDecaySeconds` | 3600 | Failure score decay rate |
| `minSecondsBetweenDeployIdle` | 300 | 5-minute cooldown between `deployIdle()` calls |
| `bootstrapDuration` | 259200 | 3-day bootstrap window |
| `maxRelativeExposureBps` | 1000 | 10% max relative exposure |
| `externalTVLStalenessSeconds` | 100800 | 28h external TVL staleness |

---

## Standalone Upkeep Redeploy

If `StrategyUpkeep` needs redeployment without touching the strategy:

```bash
forge script multyr-strategies/script/DeployStrategyUpkeep.s.sol:DeployStrategyUpkeep \
  --rpc-url $RPC_URL --broadcast --verify
```

Script: `multyr-strategies/script/DeployStrategyUpkeep.s.sol:1`

Required env vars: `DEPLOYER_PRIVATE_KEY`, `STRATEGY_ADDRESS`.
After deploy: grant `KEEPER_ROLE` on the strategy to the new upkeep address.

---

## Post-Deploy State

After every successful deploy, including `DO_SEAL=false`:

| Contract | Admin | Notes |
|---|---|---|
| `UsdcMultiLendingVault` | Governance Safe | Deployer admin/PARAM renounced |
| `StrategyParamsModule` | — | No direct admin (owned by strategy) |
| `StrategyScoringModule` | — | No direct admin (owned by strategy) |
| `ProtocolRegistry` | Governance Safe | Production, `onlyOwner` mutations |
| All 7 lending adapters | Governance Safe | Deployer admin/PARAM renounced |
| `AaveLiquidityRateProvider` | Governance Safe | Deployer renounced |
| `DolomiteSupplyRateProvider` | Governance Safe | via `transferOwnership()` |
| `AdapterFactory` | Governance Safe | Admin + deployer roles; deployer renounced |
| `StrategyUpkeep` | Governance Safe | Configured; KEEPER_ROLE on strategy |

Address book written to `broadcast/strategy-addresses.json` (or `STRATEGY_OUTPUT_JSON`).
Source: `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:796-798`

---

## Security Invariants

These invariants must hold after every deploy. Source:
`multyr-strategies/src/strategies/usdc-lending/controller/StrategyStorageLayout.sol:91`

1. **BOOTSTRAP_ROLE renounced**: `bootstrapper.hasBootstrapRole() == false` — verified at line
   `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:560-563`
2. **CORE_ROLE assigned**: Both `CoreVault` and `StrategyRouter` hold `CORE_ROLE` on the strategy —
   verified at `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:516-523`
3. **PARAM_ROLE on 4 adapters**: `StrategyUpkeep` has `PARAM_ROLE` on Morpho, Dolomite, Fluid,
   AaveRP — verified at `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:604-607`
4. **Euler markets initialized**: `euler.isInitialized() == true` for all 4 vaults —
   `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:399`
5. **Optional modules wired BEFORE bootstrap**: modules set before `bootstrap()` call —
   `multyr-strategies/script/DeployUsdcLendingStrategy.s.sol:487-489` (Phase 1.7 before Phase 2.5)
6. **Adapter count**: 7 adapters registered in `UsdcMultiLendingVault` — exactly
   `adapters.length == 7` passed to `StrategyBootstrapper.bootstrap()`
7. **Adapter PARAM_ROLE / admin NEVER deployer**: all roles transfer to direct governance
8. **Registry binding**: Morpho/Comet/Euler/Dolomite point to the Safe-owned production registry

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `WRONG_CHAIN: DeployUsdcLendingStrategy is Arbitrum-only` | Not on Arbitrum One | Set `--rpc-url` to Arbitrum |
| `ParamsModule address mismatch` | Nonce out of sync | Ensure no other txs between nonce computation and deploy |
| `insufficient USDC for Euler Permit2 dust` | Deployer has <0.001 USDC | Fund deployer with USDC before deploy |
| `BOOTSTRAP_ROLE not renounced` | `bootstrap()` did not complete | Check adapters array — all 7 must be non-zero |
| `DEPLOY_BUG: CoreVault missing CORE_ROLE` | Constructor regression | Rebuild strategy contracts, check `UsdcLendingStrategy.sol` constructor |
| `SEAL: routing not frozen` | Phase 5 (`DO_SEAL=true`) ran before core Phase 6 | Run core `_phase6_assertions()` first |
| Poke silently does nothing on Morpho/Dolomite/Fluid/AaveRP | PARAM_ROLE missing | Re-grant via timelock: `adapter.grantRole(PARAM_ROLE, upkeep)` |
| Euler deposits silently fail | `initializeMarkets()` not called | Cannot fix post-deploy without upgrade — Euler adapter restart required |

---

## Quick Start

```bash
cp .env.example .env    # fill in the required addresses (see above)
./script/deploy-usdc-lending.sh              # dry run — simulate only
./script/deploy-usdc-lending.sh --broadcast  # actually deploy
```

`script/deploy-usdc-lending.sh` loads `.env`, validates the required variables (and the
`DO_SEAL=true` variables if set) are present before invoking `forge script`, so a missing
address fails fast with a clear message instead of a mid-deploy revert.

---

## Contract Source Verification

```bash
./script/deploy-usdc-lending.sh --broadcast --verify
```

Uses the **Etherscan V2 unified API** — one `ETHERSCAN_API_KEY` verifies contracts on any
chain it covers, including Arbitrum (chainId 42161); no Arbiscan-specific key or
`[etherscan]` block in `foundry.toml` is needed. This matches how `multyr-core`'s own core
system deploy was verified (confirmed: `CoreVault` at `0x685Ec439Fc62736934FF6A74301B50173E34446b`
is verified on Arbiscan with full source visible, using the same key convention).

`deploy-usdc-lending.sh` fails fast if `--verify` is passed without `ETHERSCAN_API_KEY` set.
Source it from `multyr-core/.env` rather than duplicating the key:

```bash
source /path/to/multyr-core/.env   # exports DEPLOYER_PRIVATE_KEY + ETHERSCAN_API_KEY
./script/deploy-usdc-lending.sh --broadcast --verify
```

**If `--verify` fails during a real broadcast** (block explorer indexing lag is common —
verification submission can race the transaction being indexed), re-verify any address
after the fact with a standalone command, no redeploy needed:

```bash
forge verify-contract \
  --chain 42161 \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  <deployed_address> <path/to/Contract.sol:ContractName> \
  --constructor-args $(cast abi-encode "constructor(...)" <args>)
```

Constructor args for each contract are visible in the console output / address-book JSON
this script prints and writes (`STRATEGY_OUTPUT_JSON`).

---

## Related Docs

- `multyr-core/docs/deployment.md` — core system prerequisite
- `multyr-strategies/docs/invariants.md` — invariant specification
- `multyr-strategies/docs/adapters.md` — adapter documentation
- `multyr-deployment/runbooks/full-system-deploy.md` — end-to-end multi-day deploy plan
- `multyr-strategies/script/MULTI_CHAIN_PLAYBOOK.md` — draft playbook for deploying to
  chains beyond Arbitrum. **Note**: as of this writing it describes calling
  `DeployUsdcLendingStrategy.s.sol` with `--sig "run(address)"` passing an existing
  `AdapterFactory` address, but the current `run()` takes no arguments and always deploys
  its own `AdapterFactory` inline, hard-gated to `block.chainid == 42161`. Multi-chain
  configs (`UsdcLendingConfigBase/Polygon/Ethereum`) are also still placeholders — see
  `test/strategies/usdc-lending/deploy/UsdcLendingDeploy.t.sol`. Treat that playbook as
  aspirational until the script is generalized to accept a chain config + factory address.
