# USDC Lending Strategy — Adapter Reference

**Version**: 1.0.0 — code-first, audit-grade citations
**Scope**: All 9 lending adapters + 2 rate providers + RewardSwapHelper in `src/strategies/usdc-lending/`
**Commit**: b15aeb63

---

## Table of Contents

1. [Adapter Abstraction](#1-adapter-abstraction)
2. [AaveV3USDCAdapter](#2-aavev3usdcadapter)
3. [CometUsdcMultiMarketAdapter](#3-cometusdcmultimarketadapter)
4. [DolomiteUsdcMultiMarketAdapter](#4-dolomiteusdcmultimarketadapter)
5. [EulerUsdcMultiMarketAdapter](#5-eulerusdcmultimarketadapter)
6. [FluidUsdcMultiMarketAdapter](#6-fluidusdcmultimarketadapter)
7. [MorphoUsdcMultiMarketAdapter](#7-morphousdcmultimarketadapter)
8. [VenusUsdcMultiMarketAdapter](#8-venususdcmultimarketadapter)
9. [Rate Providers](#9-rate-providers)
10. [RewardSwapHelper](#10-rewardswaphelper)

---

## 1. Adapter Abstraction

### 1.1 ILendingAdapter

All lending adapters implement `ILendingAdapter` defined at
`src/strategies/usdc-lending/interfaces/ILendingAdapter.sol:5`.

```
Interface ILendingAdapter
├── Metadata
│   ├── name()                  → string          L6
│   └── underlying()            → address         L7
├── Accounting
│   ├── totalAssets()           → uint256         L8
│   └── withdrawableAssets()    → uint256         L9
├── Lifecycle
│   ├── deposit(assets)                           L10
│   └── withdraw(assets, receiver) → withdrawn   L11
├── Yield
│   ├── currentAPYBps()         → uint16          L12
│   ├── incentiveAPYBps()       → uint16          L13
│   ├── harvestableProfit()     → uint256         L14
│   └── harvest(receiver)       → realized        L15
├── Limits
│   └── maxCapacity()           → uint256         L16
├── Deposit Pattern
│   └── isPushMode()            → bool            L22
├── Idle Asset Accounting (V7 fix)
│   ├── idleAssetBalance()      → uint256         L28
│   ├── investedAssets()        → uint256         L31
│   ├── sweepIdleAssetToVault()                   L35
│   └── emergencyPullAllToVault()                 L38
└── External TVL (V9.1)
    └── externalMarketTVL()     → uint256         L47
```

Emergency dispatch interface `IAdapterEmergency` is also defined at
`src/strategies/usdc-lending/interfaces/ILendingAdapter.sol:51`, used by
`UsdcMultiLendingVault.emergencyRecallAll()` and `selectiveRecall()`.

### 1.2 Deposit Patterns

| Pattern | Mechanism | Adapters |
|---------|-----------|---------|
| **PULL** | Adapter calls `safeTransferFrom(strategy → adapter)` at deposit time | Aave, Comet, Dolomite, Fluid, Morpho, Venus |
| **PUSH** | Strategy pre-transfers USDC to adapter via Permit2 internal allowance before `deposit()` | Euler V2 only |

The pattern is reported by `isPushMode()` at
`src/strategies/usdc-lending/interfaces/ILendingAdapter.sol:22`.
`UsdcMultiLendingVault.deposit()` checks this flag to choose between PULL
(`safeTransfer` before calling adapter) and PUSH (adapter pulls from Permit2) at
`src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol:392`.

### 1.3 Common Access Control Pattern

| Role | Holder | Capability |
|------|--------|-----------|
| `DEFAULT_ADMIN_ROLE` | Timelock | Grant/revoke roles, set caps, set override params |
| `PARAM_ROLE` | `LendingStrategyUpkeep` + Timelock | Keeper-write: APY cache updates, market management |
| `VAULT_ROLE` / `onlyVault` | `UsdcMultiLendingVault` | Capital operations: `deposit`, `withdraw`, `harvest`, emergency |

### 1.4 Emergency Recovery

All adapters implement:
- `sweepIdleAssetToVault()` — transfers locally-held idle USDC back to vault without touching invested positions
- `emergencyPullAllToVault()` — full withdrawal: invested + idle → vault

Called by `UsdcMultiLendingVault.emergencyRecallAll()` at
`src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol:669` and
`selectiveRecall()` at `src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol:700`.

### 1.5 Reward Pipeline Pattern (M1 + M2)

Applied consistently across Aave, Comet, and Venus adapters:

```
M1 — canSwap() oracle freshness gate (avoids LINK burn on stale-oracle tx)
M2 — graceful try/catch on claimRewardsToSelf() and swapToUSDC()
     (never reverts on claim/swap failure — defers rather than blocks)
```

Implemented in `RewardSwapHelper.canSwap()` at
`src/strategies/usdc-lending/swap/RewardSwapHelper.sol:71`.

---

## 2. AaveV3USDCAdapter

**File**: `src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol:85` (contract `AaveV3USDCAdapter`)
**Protocol**: Aave V3 USDC market on Arbitrum One
**Deposit mode**: PULL

### 2.1 Immutable Storage

| Field | Type | Line | Description |
|-------|------|------|-------------|
| `asset` | `address` | L92 | USDC token address |
| `pool` | `IPool` | L93 | Aave V3 Pool |
| `aToken` | `address` | L94 | aUSDC V3 token |
| `vault` | `address` | L95 | Authorized strategy vault |

### 2.2 Configurable Parameters

| Field | Default | Line | Description |
|-------|---------|------|-------------|
| `maxCap` | 0 (unlimited) | L98 | Deposit cap in USDC |
| `maxRateStalenessSec` | 90_000 (25h) | L111 | Keeper cache staleness threshold |
| `apyOverrideBps` | 0 (disabled) | L100 | Manual APY override |
| `rateProvider` | address(0) | L101 | Optional `AaveLiquidityRateProvider` |
| `incentiveHaircutBps` | 7500 | L125 | 75% loss → retain 25% of realized reward APR |

`maxRateStalenessSec = 90_000` provides a 25h heartbeat buffer. The Aave V3
USDC/USD Chainlink feed heartbeat on Arbitrum is 86400s; the extra 3600s
prevents false fallbacks on slight keeper delays.

### 2.3 Deposit Flow

`deposit(uint256 assets)` at `src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol:221`:

1. `safeTransferFrom(msg.sender → adapter)` — PULL from strategy
2. `forceApprove(pool, assets)` — just-in-time exact approval
3. `pool.supply(asset, assets, address(this), 0)` — supplies to Aave V3
4. `forceApprove(pool, 0)` — revoke approval after operation

`withdraw(uint256 assets, address)` at `src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol:239`:
- `receiver` parameter is **ignored** — always sends to `vault`
- Clamps `want` to `withdrawableAssets()` before calling `pool.withdraw`

### 2.4 Hybrid APY Pattern

`currentAPYBps()` at `src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol:271` implements a 3-source hybrid:

```
Priority 1: apyOverrideBps (admin escape hatch, non-zero means active)
Priority 2: getLiquidityRateRayWithTs(asset) via AaveLiquidityRateProvider
            → staleness check: block.timestamp - ts ≤ maxRateStalenessSec
Priority 3: pool.getReserveData(asset).currentLiquidityRate (direct on-chain)
            → Aave V3 currentLiquidityRate updates only on pool activity (lazy)
Priority 4: return 0 (no source available)
```

Conversion: `bps = rateRay / 1e23`
(`rateRay` is Aave V3 APR in ray = 1e27; 1 bps = 0.01% = 1e4; 1e27 / 1e23 = 1e4 bps).

### 2.5 Reward Pipeline

`harvestableProfit()` at `src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol:351`:
- Iterates `_rewardTokens`, skips zero-balance and stale-oracle tokens (M1 gate)
- Calls `swapHelper.previewExpectedOut()` for non-zero balances — pure view

`harvest(address receiver)` at `src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol:369`:
- M2 graceful: `claimRewardsToSelf()` wrapped in try/catch; SLITHER-FIX-1 emits `RewardClaimed(token, amount)`
- M1 gate before swap: `canSwap(tok)` checks oracle freshness
- Revokes approval regardless of swap outcome

### 2.6 TVL Reporting

`externalMarketTVL()` at `src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol:418`:
returns `aToken.totalSupply()` — total USDC supplied to the Aave V3 USDC market.

`withdrawableAssets()` at `src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol:213`:
returns `min(aToken.balanceOf(adapter), IERC20(asset).balanceOf(pool))` — conservative,
accounts for pool liquidity constraints.

---

### 2.7 AaveV3USDCAdapter Security Properties

Constructor validation at
`src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol:154`:
- All five constructor params validated non-zero
- `IAToken(aToken_).UNDERLYING_ASSET_ADDRESS() == asset_` verified at L160 — prevents
  aToken/asset mismatch at deployment time

`withdrawableAssets()` at `src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol:213`
returns `min(aToken.balanceOf(adapter), IERC20(asset).balanceOf(pool))`.
The pool liquidity floor prevents requesting more than available — Aave V3 withdrawals
revert if pool liquidity is insufficient; this clamp avoids that revert path.

Just-in-time approval pattern (never leaves an open unlimited approval to the pool):
- `_approvePool(assets)` at L175 → sets exact amount
- `_revokePoolApproval()` at L180 → resets to zero after every operation

---

## 3. CometUsdcMultiMarketAdapter

**File**: `src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol:78` (contract `CometUsdcMultiMarketAdapter`)
**Protocol**: Compound III (Comet) USDC markets on Arbitrum
**Deposit mode**: PULL

### 3.1 Key Storage

| Field | Line | Description |
|-------|------|-------------|
| `underlying` (immutable) | L85 | USDC address |
| `vault` (immutable) | L86 | Authorized strategy vault |
| `registry` (immutable) | L87 | Optional `IProtocolRegistry` (can be address(0)) |
| `mkts[]` | L91 | Dynamic array of `Market` structs |
| `capacity` | L116 | Deposit cap (0 = unlimited) |

### 3.2 Market Struct

`Market` struct at `src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol:90`:

| Field | Type | Description |
|-------|------|-------------|
| `comet` | `address` | Comet USDC market address |
| `enabled` | `bool` | Included in allocation |
| `flagged` | `bool` | Defense/hold: do not increase allocation |
| `riskScoreBps` | `uint16` | 0..10000 (10000 = lowest risk) |

### 3.3 Internal Scoring Weights

Intra-adapter market scoring (Compound III specific):

| Weight Constant | Value | Line |
|-----------------|-------|------|
| `wAPY` | 4000 | L99 |
| `wLiq` | 2500 | L100 |
| `wRisk` | 2000 | L101 |
| `wStability` | 1000 | L102 |
| `wIncentive` | 500 | L103 |

### 3.4 IComet Interface

Interface at `src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol:52`:

| Function | Description |
|----------|-------------|
| `supply(asset, amount)` | Deposit USDC into Comet market |
| `withdraw(asset, amount)` | Withdraw USDC from Comet market |
| `balanceOf(account)` | Current balance including accrued interest |
| `getUtilization()` | Market utilization rate (scaled 1e18) |
| `getSupplyRate(utilization)` | Supply rate per second at given utilization |
| `totalsBasic()` | L60 — used for `externalMarketTVL()` calculation |
| `baseIndexScale()` | L61 — scale factor for index math |

### 3.5 Reward Pipeline

Reward token: COMP, claimed via `ICometRewards.claim(comet, src, shouldAccrue)` at
`src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol:64`.
Same M1+M2 pattern as Aave: `canSwap()` pre-flight + graceful try/catch on claim/swap.

---

## 4. DolomiteUsdcMultiMarketAdapter

**File**: `src/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol:107` (contract `DolomiteUsdcMultiMarketAdapter`)
**Protocol**: Dolomite Margin V9 on Arbitrum
**Deposit mode**: PULL

### 4.1 Key Storage

| Field | Line | Description |
|-------|------|-------------|
| `asset` (immutable) | L114 | USDC address |
| `vault` (immutable) | L115 | Authorized strategy vault |
| `registry` (immutable) | L116 | Optional `IProtocolRegistry` |
| `capacity` | L119 | Deposit cap (0 = unlimited) |

### 4.2 Dual Market Type Support

Dolomite supports two market interface patterns:

**ERC-4626-like** (`IERC4626Like` at `src/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol:53`):
- `deposit(assets, receiver) → shares`, `withdraw(assets, receiver, owner) → shares`
- Asset-denominated deposits/withdrawals

**Pool-like / Dolomite Margin V9** (`IDolomiteMargin` at `src/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol:77`):
- `getAccountWei(AccountInfo, marketId) → Wei` — returns signed balance
- `getMarketTokenAddress(marketId) → address` — verifies market is USDC

Custom errors guard against ambiguous or unsupported market configurations:
- `AmbiguousMarketType(market)` at L100
- `UnsupportedMarketType(market)` at L101
- `InvalidDolomiteConfig(market, marketId, accountNumber)` at L102

### 4.3 Rate Provider

Dolomite supply rates are keeper-fed via `IDolomiteRateProvider` at
`src/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol:95`:
```
getSupplyRatePerSecond(market) → WAD per second (1e18)
```

External rate provider: `DolomiteSupplyRateProvider` at
`src/strategies/usdc-lending/adapters/rates/DolomiteSupplyRateProvider.sol:9`.

---

## 5. EulerUsdcMultiMarketAdapter

**File**: `src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol:73` (contract `EulerUsdcMultiMarketAdapter`)
**Protocol**: Euler V2 (EVault) USDC markets on Arbitrum
**Deposit mode**: **PUSH** — unique among adapters

### 5.1 PUSH Mode and Permit2

Euler V2 uses the Permit2 internal allowance system for deposits.
The adapter holds a one-time unlimited Permit2 approval set in the constructor:

`USDC.safeApprove(PERMIT2, type(uint256).max)` at
`src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol:180`

Permit2 canonical address (AllowanceTransfer) at
`src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol:89`:
`0x000000000022D473030F116dDEE9F6B43aC78BA3`

Per-market Permit2 internal allowances are set via `initializeMarkets()` at
`src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol:200`.
**This function MUST be called after constructor and BEFORE admin role transfer to Timelock.**
Failure to call `initializeMarkets()` prevents all deposits via Euler EVK.
(Deploy checklist item from v8-euler-fix-report.)

### 5.2 Key Storage

| Field | Line | Description |
|-------|------|-------------|
| `PERMIT2` (constant) | L89 | Permit2 AllowanceTransfer canonical address |
| `PERMIT2_TTL` (constant) | L91 | 10 years (`365 days * 10`) |
| `USDC` (immutable) | L93 | USDC ERC20Metadata |
| `vault` (immutable) | L94 | Authorized strategy vault |
| `registry` (immutable) | L95 | Optional `IProtocolRegistry` |
| `mkts[]` | L97 | Dynamic array of `Market` structs |

### 5.3 Market Struct

`Market` struct at `src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol:78`:

| Field | Type | Description |
|-------|------|-------------|
| `addr` | `address` | EVault address (ERC-4626 compliant) |
| `enabled` | `bool` | Included in allocation |
| `flagged` | `bool` | Defense/hold |
| `riskScoreBps` | `uint16` | 0..10000 |

### 5.4 IEulerUsdcMarket Interface

Interface at `src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol:26`:

| Function | Description |
|----------|-------------|
| `deposit(assets, receiver) → shares` | ERC-4626 style deposit |
| `withdraw(assets, receiver, owner) → shares` | ERC-4626 style withdrawal |
| `convertToAssets(shares) → assets` | Share pricing |
| `maxWithdraw(owner)` | Max withdrawable (supply cap constraint) |
| `interestRate() → uint256` | APR in ray (1e27) |
| `totalAssets() → uint256` | Total USDC in vault |

`effectiveAPYBps()` is an additional extension (not in base `ILendingAdapter`) that
returns a market-weighted APY across active markets. Defined in the extended interface
at `src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol:60`.

### 5.5 Registry Integration

All multi-market adapters (Comet, Euler, Morpho, Dolomite) support optional integration
with `IProtocolRegistry` at
`src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol:11`.
When `registry != address(0)`, `_loadFromRegistry()` is called in the constructor to
populate the initial market list.

---

### 5.6 Euler Multi-Market Intra-Rebalance

`EulerUsdcMultiMarketAdapter` supports intra-adapter optimization via `optimize()` —
defined in the extended interface at
`src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol:56`.
This allows capital to rotate between Euler EVault markets without involving the
main strategy's rebalance engine.

Gate parameters:
- `minSecondsBetweenOptimize = 3 hours` at
  `src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol:101`
- `subMoveMinBps = 25` (0.25%) at L102 — minimum move size
- `subGateMinNetBenefitBps = 2` (0.02%) at L103 — minimum net APY benefit

`marketFallback` event: if primary market has insufficient capacity, adapter
falls back to next-best market. Emits `MarketSelectionFallback(failedMarket, fallbackMarket)` at
`src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol:114`.

`positions()` view at
`src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol:59` returns
per-market asset breakdown for explainability/monitoring.

---

## 6. FluidUsdcMultiMarketAdapter

**File**: `src/strategies/usdc-lending/adapters/lending/FluidUsdcMultiMarket.sol:49` (contract `FluidUsdcMultiMarketAdapter`)
**Protocol**: Fluid fUSDC (ERC-4626) on Arbitrum
**Deposit mode**: PULL

### 6.1 Immutable Storage

| Field | Line | Description |
|-------|------|-------------|
| `asset` | L56 | USDC token address |
| `vault` | L57 | Authorized strategy vault |
| `fToken` (IERC4626) | L58 | Fluid fUSDC ERC-4626 vault |

### 6.2 PPS-Snapshot APY

Fluid does not expose an on-chain APR endpoint. APY is computed from share price (PPS) delta:

| Field | Line | Description |
|-------|------|-------------|
| `lastSnapshotPPS` | L66 | Share price (1e18 scale) at last keeper poke |
| `lastSnapshotTs` | L67 | Timestamp of last poke |

`pokeAPYSnapshots()` (callable by `PARAM_ROLE`) stores the current PPS from
`fToken.convertToAssets(1e18)`. `currentAPYBps()` at
`src/strategies/usdc-lending/adapters/lending/FluidUsdcMultiMarket.sol:233` computes:

```
annualGrowth = (currentPPS - lastSnapshotPPS) × 1e18 / lastSnapshotPPS
APYBps = annualGrowth × 10000 / (elapsed_seconds / 365 days)
```

`apyOverrideBps != 0` takes priority over the snapshot calculation.

Initial snapshot is set in the constructor at
`src/strategies/usdc-lending/adapters/lending/FluidUsdcMultiMarket.sol:116`:
`lastSnapshotPPS = fToken.convertToAssets(1e18)`.

### 6.3 Deposit and Withdrawal

`deposit()` at `src/strategies/usdc-lending/adapters/lending/FluidUsdcMultiMarket.sol:174`:
1. PULL: `safeTransferFrom(vault → adapter)`
2. `forceApprove(fToken, assets)` — just-in-time
3. `fToken.deposit(assets, address(this))` — returns shares
4. `forceApprove(fToken, 0)` — revoke

`withdraw()` at `src/strategies/usdc-lending/adapters/lending/FluidUsdcMultiMarket.sol:195`:
- Clamps `want` to `fToken.maxWithdraw(address(this))` to prevent reverting on over-withdraw
- Measures actual received via balance delta before/after `fToken.withdraw()` — Fluid may
  return slightly fewer assets than requested due to precision
- Transfers actual received (not requested amount) to vault

---

## 7. MorphoUsdcMultiMarketAdapter

**File**: `src/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol:58` (contract `MorphoUsdcMultiMarketAdapter`)
**Protocol**: Morpho vaults (ERC-4626-like) on Arbitrum
**Deposit mode**: PULL

### 7.1 Constants

| Constant | Value | Line | Description |
|----------|-------|------|-------------|
| `MARKET_QUARANTINE_THRESHOLD` | 3 | L70 | Auto-quarantine after N consecutive failures |
| `PPS_SNAP_TTL` | 2 days | L71 | PPS snapshot time-to-live for APY staleness |
| `apyStalenessSeconds` | 1 day | L105 | Max APY cache age before stale flag |

### 7.2 Market Struct

`Market` struct at `src/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol:79`:

| Field | Type | Description |
|-------|------|-------------|
| `addr` | `address` | Morpho ERC-4626-like vault |
| `enabled` | `bool` | Included in allocation |
| `flagged` | `bool` | Defense/hold: no new deposits |
| `riskScoreBps` | `uint16` | 0..10000 (10000 = min risk) |

### 7.3 Internal Market Scoring Weights

| Constant | Value | Line | Factor |
|----------|-------|------|--------|
| `wAPY` | 4000 | L109 | Yield priority |
| `wLiq` | 2000 | L110 | Market liquidity |
| `wRisk` | 2000 | L111 | Operator/collateral risk |
| `wStability` | 1000 | L112 | Historical rate stability |
| `wIncentive` | 1000 | L113 | Incentive yield |

These weights sum to 10000 and govern the adapter-internal optimization across
Morpho vaults. Different from the strategy-level scoring weights in
`StrategyAllocCalcModule`.

### 7.4 Failure Tracking

Per-market failure counters at
`src/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol:97`:
- `marketFailures[market]` — consecutive failure count
- `marketLastFailureTs[market]` — last failure timestamp
- `marketFailureDecaySeconds = 1 hours` at L99 — decay period for failure count

When `marketFailures[market] >= MARKET_QUARANTINE_THRESHOLD (3)`, the market is
automatically quarantined (treated as flagged) to prevent repeated failed operations.

### 7.5 APY Caching

`lastGoodApyBps[market]` at L102 — fallback APY used when rate provider reverts.
`lastApyUpdateTs[market]` at L104 — APY last-update timestamp.
`apyStalenessSeconds = 1 day` at L105 — mark stale when cache is older.
No auto-unflag: governance must explicitly clear after inspecting the market state (Audit #2 P1.9).

### 7.6 Optimization

`rebalanceMinMoveBps = 50` (0.5%) at L116 and
`minSecondsBetweenOptimize = 6 hours` at L117 govern intra-adapter market rotation.

---

## 8. VenusUsdcMultiMarketAdapter

**File**: `src/strategies/usdc-lending/adapters/lending/VenusUsdcMultiMarket.sol:62` (contract `VenusUsdcMultiMarketAdapter`)
**Protocol**: Venus vUSDC_Core on Arbitrum (Compound-fork)
**Deposit mode**: PULL

### 8.1 Constants

| Constant | Value | Line | Purpose |
|----------|-------|------|---------|
| `blocksPerYear` | 126,144,000 (default) | constructor param | Per-chain configurable; default = Arbitrum 0.25s blocks (C-04 fix) |
| `ARBITRUM_CHAIN_ID` | 42161 | L75 | Chain guard: prevents deploy on BNB (3s blocks → 12× APY overreport) |

The chain guard is enforced in the constructor: if `block.chainid != ARBITRUM_CHAIN_ID`,
deployment reverts. This is a Quant Audit P0.L4 finding fix.

### 8.2 Immutable Storage

| Field | Line | Description |
|-------|------|-------------|
| `underlying` | L78 | USDC address |
| `vault` | L79 | Authorized strategy vault |
| `vToken` | L80 | Venus vUSDC_Core (IVToken) |

### 8.3 IVToken Interface

Interface at `src/strategies/usdc-lending/adapters/lending/VenusUsdcMultiMarket.sol:10`
(Compound-fork semantics, not ERC-4626):

| Function | Description |
|----------|-------------|
| `mint(amount) → 0` | Deposit USDC, receive vTokens (0 = success) |
| `redeemUnderlying(amount) → 0` | Withdraw exact USDC amount |
| `redeem(vTokens) → 0` | Withdraw by share count |
| `balanceOf(owner)` | vToken balance |
| `exchangeRateCurrent()` | Non-view — accrues interest, returns exchange rate |
| `exchangeRateStored()` | View version of exchange rate |
| `supplyRatePerBlock()` | Raw supply rate per block (scaled 1e18) |
| `getCash()` | Available liquidity in pool |
| `totalSupply()` | Total vToken supply |

### 8.4 APY Computation

APY is computed from `supplyRatePerBlock()` and `blocksPerYear`:
```
apyRaw = supplyRatePerBlock × blocksPerYear (1e18 base)
apyBps = apyRaw × 10000 / 1e18
```

`blocksPerYear` is a constructor parameter (default: 126,144,000 for Arbitrum). This was
hardcoded as `BLOCKS_PER_YEAR = 126,144,000` prior to C-04; it is now configurable per chain
to avoid 12× APY overreport on BNB (~3s blocks). The `ARBITRUM_CHAIN_ID = 42161` chain guard
in the constructor enforces Arbitrum-only deployment on this version.

### 8.5 Reward Pipeline

Reward token: XVS (if configured), claimed via
`IVenusComptroller.claimVenus(holder, vTokens)` at
`src/strategies/usdc-lending/adapters/lending/VenusUsdcMultiMarket.sol:26`.

`incentiveHaircutBps = 7500` at L96: retain 25% of realized reward APR
(same convention as Aave, Comet adapters).

`rewardToken = address(0)` (L87) means pipeline is disabled by default until
governance configures it via `initRewardPipeline()`.

---

### 8.5 Venus Chain Guard Detail

The `ARBITRUM_CHAIN_ID = 42161` guard in the constructor at
`src/strategies/usdc-lending/adapters/lending/VenusUsdcMultiMarket.sol:75` is a
Quant Audit P0.L4 finding. Without it, the same Venus vToken contract deployed on
BNB Chain would produce inflated APY readings because:

- BNB Chain: ~3 second block time → ~10,512,000 blocks/year
- Arbitrum: ~0.25 second block time → 126,144,000 blocks/year

If `blocksPerYear = 126,144,000` (Arbitrum default) were applied to a BNB-cadence `supplyRatePerBlock()`:
```
BNB ratePerBlock = APY_BNB / 10,512,000 (approx.)
APY_reported = BNB_rate × 126,144,000 = APY_BNB × 12
```
This 12× overreport would cause the scoring engine to massively over-allocate to
Venus at the expense of better-yielding, correctly-reporting adapters.

Constructor chain check at
`src/strategies/usdc-lending/adapters/lending/VenusUsdcMultiMarket.sol:120`:
requires `block.chainid == ARBITRUM_CHAIN_ID` or deployment reverts.

---

## 9. Rate Providers

Rate providers are off-chain oracle bridges: keepers push rates on-chain so adapters
can compute APY without relying solely on lazy on-chain state.

### 9.1 AaveLiquidityRateProvider

**File**: `src/strategies/usdc-lending/adapters/rates/AaveLiquidityRateProvider.sol:14` (contract `AaveLiquidityRateProvider`)

Keeper-fed liquidity rate provider for the `AaveV3USDCAdapter` hybrid APY pattern.

| Field | Line | Description |
|-------|------|-------------|
| `PARAM_ROLE` | L15 | Write access for `LendingStrategyUpkeep` |
| `_rateRay[asset]` | L18 | APR in ray (1e27) per asset |
| `_lastUpdateTs[asset]` | L20 | Last update timestamp per asset |

| Function | Line | Description |
|----------|------|-------------|
| `setLiquidityRateRay(asset, rateRay)` | L35 | `PARAM_ROLE` only — stores rate + timestamp |
| `getLiquidityRateRay(asset)` | L43 | Returns rate in ray |
| `getLiquidityRateRayWithTs(asset)` | L49 | Returns `(rateRay, lastUpdateTs)` for staleness |

`getLiquidityRateRayWithTs` was added as FIX P1.L1 (Quant Audit) to enable the hybrid
staleness-check pattern in `AaveV3USDCAdapter.currentAPYBps()`.

**Role setup**: `DEFAULT_ADMIN_ROLE = Timelock`, `PARAM_ROLE = LendingStrategyUpkeep`.
Keeper (upkeep) writes rates during `OP_POKE_APY` operations.

### 9.2 DolomiteSupplyRateProvider

**File**: `src/strategies/usdc-lending/adapters/rates/DolomiteSupplyRateProvider.sol:9` (contract `DolomiteSupplyRateProvider`)

Minimal keeper-fed rate provider for Dolomite pool-like markets.
Uses `Ownable` (not `AccessControl`) — simpler governance for a purely off-chain
rate bridge.

| Function | Line | Description |
|----------|------|-------------|
| `setSupplyRatePerSecond(market, rateWad)` | L22 | Owner only — stores WAD rate |
| `getSupplyRatePerSecond(market)` | L29 | Returns rate per second in WAD (1e18) |

WAD conversion to APYBps: `apyBps = ratePerSecond × 365 days × 10000 / 1e18`.

---

## 10. RewardSwapHelper

**File**: `src/strategies/usdc-lending/swap/RewardSwapHelper.sol:71` (contract `RewardSwapHelper`)
**Purpose**: MEV-resistant reward token → USDC swap with multi-DEX fallback

### 10.1 Architecture

```mermaid
graph LR
    A[Adapter.harvest()] -->|transferFrom reward| B[RewardSwapHelper]
    B -->|canSwap() oracle check| C{Oracle fresh?}
    C -->|No| D[Defer: SwapDeferred event]
    C -->|Yes| E[Uniswap V3 exactInput]
    E -->|revert| F[Camelot V3 fallback]
    E -->|success| G[USDC to receiver]
    F -->|success| G
```

### 10.2 Immutable Storage

| Field | Line | Description |
|-------|------|-------------|
| `usdc` | L78 | USDC output token |
| `uniswapV3Router` | L79 | Primary DEX (SwapRouter02 canonical Arbitrum) |
| `camelotV3Router` | L80 | Fallback DEX (address(0) = disabled) |
| `sequencerUptimeFeed` | L90 | Arbitrum sequencer uptime feed (RA-10 defense) |

### 10.3 RewardConfig Struct

At `src/strategies/usdc-lending/swap/RewardSwapHelper.sol:95`:

| Field | Type | Description |
|-------|------|-------------|
| `chainlinkFeed` | `address` | `<rewardToken>/USD` Chainlink aggregator |
| `feedDecimals` | `uint8` | Chainlink decimals (typically 8) |
| `tokenDecimals` | `uint8` | Reward token ERC20 decimals |
| `maxFeedAgeSec` | `uint32` | Staleness threshold (floor 3600s, ceiling 7 days) |
| `uniswapV3Path` | `bytes` | ABI-encoded Uniswap V3 path |
| `camelotV3Path` | `bytes` | Fallback path (empty = disabled) |
| `slippageBps` | `uint16` | Slippage cap (max 1000 = 10%) |
| `enabled` | `bool` | Token is configured and active |

`configs[rewardToken]` mapping at `src/strategies/usdc-lending/swap/RewardSwapHelper.sol:105`.

### 10.4 Oracle Heartbeat Configuration

From inline documentation at
`src/strategies/usdc-lending/swap/RewardSwapHelper.sol:57` (operational note):

| Feed | Heartbeat | Recommended `maxFeedAgeSec` |
|------|-----------|----------------------------|
| USDC/USD | 24h | 90,000 |
| COMP/USD | 24h | 90,000 |
| AAVE/USD | 24h | 90,000 |
| LINK/USD | 1h | 4,000 |
| XVS/USD | Verify on Arbitrum | — |

### 10.5 MEV Defenses

- **Chainlink price anchor**: `minAmountOut` computed from oracle price, not pool spot.
  Prevents sandwich attacks by requiring oracle-anchored minimum output.
- **Slippage cap per token**: `slippageBps` max 1000 (10%) at `RewardConfig`.
- **Stale oracle skip** (`canSwap()`): adapter M1 gate checks oracle freshness before
  attempting a swap — avoids burning Chainlink Automation LINK on a tx that would revert.
- **Sequencer uptime guard** (`sequencerUptimeFeed`): when set, `swapToUSDC` and
  `canSwap` require sequencer up AND past `SEQUENCER_GRACE_PERIOD_SEC` since last restart.
- **Multi-DEX fallback**: Uniswap V3 → Camelot V3 (single attempt each, no retry loop).
- **ReentrancyGuard**: protects against reentrancy in `swapToUSDC`.

### 10.6 Roles

| Role | Holder | Capability |
|------|--------|-----------|
| `DEFAULT_ADMIN_ROLE` | Timelock | Grant/revoke PARAM_ROLE |
| `PARAM_ROLE` | Timelock / governance | `configureRewardToken`, `disableRewardToken`, `setSequencerUptimeFeed` |

---

## Appendix A: APY Computation Methods

Each adapter uses a distinct APY computation strategy suited to the protocol's data availability:

| Adapter | Method | Source | Notes |
|---------|--------|--------|-------|
| **Aave V3** | 3-source hybrid | (1) admin override → (2) keeper-pushed `rateRay` from `AaveLiquidityRateProvider` with staleness check → (3) `pool.getReserveData().currentLiquidityRate` | `src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol:271` |
| **Comet** | Keeper-calculated utilization | `IComet.getSupplyRate(getUtilization())` — per-second rate converted to annual | `src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol:52` |
| **Dolomite** | Keeper-fed WAD rate | `IDolomiteRateProvider.getSupplyRatePerSecond(market)` in WAD (1e18) | `src/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol:95` |
| **Euler V2** | On-chain ray | `IEulerUsdcMarket.interestRate()` in ray (1e27) — EVault native | `src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol:33` |
| **Fluid** | PPS snapshot delta | `(currentPPS - lastPPS) / lastPPS × annualized` via `pokeAPYSnapshots()` | `src/strategies/usdc-lending/adapters/lending/FluidUsdcMultiMarket.sol:233` |
| **Morpho** | PPS snapshot with staleness | Per-market PPS delta; APY cached in `lastGoodApyBps[market]` with `apyStalenessSeconds = 1 day` | `src/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol:102` |
| **Venus** | Block-rate annualized | `supplyRatePerBlock × BLOCKS_PER_YEAR (126,144,000)` → APY bps | `src/strategies/usdc-lending/adapters/lending/VenusUsdcMultiMarket.sol:70` |

**Ray to bps conversion** (Aave, Euler): `bps = rateRay / 1e23`
(ray = 1e27 base, bps = 1e4 base: `1e27 / 1e4 = 1e23` divisor)
Used in `AaveV3USDCAdapter._rateRayToBps()` at
`src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol:309`.

**WAD per-second to bps** (Dolomite): `apyBps = ratePerSec × 365 × 86400 × 10000 / 1e18`

**Incentive APY haircut**: All adapters with reward pipelines apply
`incentiveHaircutBps = 7500` (retain 25% of measured reward APR) by default.
The haircut accounts for swap slippage, gas cost, and uncertainty in realized yield.

---

## Appendix: Adapter Comparison Matrix

| Adapter | Protocol | Mode | APY Source | Reward | Multi-Market |
|---------|----------|------|------------|--------|-------------|
| AaveV3USDCAdapter | Aave V3 | PULL | 3-source hybrid (keeper+staleness+on-chain) | AAVE (claimRewardsToSelf) | No |
| CometUsdcMultiMarketAdapter | Compound III | PULL | keeper-pushed utilization rate | COMP (ICometRewards) | Yes |
| DolomiteUsdcMultiMarketAdapter | Dolomite Margin V9 | PULL | keeper-pushed WAD rate | No | Yes |
| EulerUsdcMultiMarketAdapter | Euler V2 (EVault) | **PUSH** | interestRate() in ray | No | Yes |
| FluidUsdcMultiMarketAdapter | Fluid fUSDC | PULL | PPS snapshot delta | No | No (single) |
| MorphoUsdcMultiMarketAdapter | Morpho vaults | PULL | PPS snapshot + staleness | No | Yes |
| VenusUsdcMultiMarketAdapter | Venus vUSDC_Core | PULL | supplyRatePerBlock × BLOCKS_PER_YEAR | XVS (claimVenus) | No |

---

## Appendix B: Adapter Role Summary

| Adapter | Admin role | Keeper role | Vault role | Role constants |
|---------|-----------|------------|-----------|---------------|
| AaveV3USDCAdapter | `DEFAULT_ADMIN_ROLE` (Timelock) | — | `VAULT_ROLE` | `src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol:89` |
| CometUsdcMultiMarketAdapter | `DEFAULT_ADMIN_ROLE` (Timelock) | `PARAM_ROLE` (upkeep) | `onlyVault` modifier | `src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol:82` |
| DolomiteUsdcMultiMarketAdapter | `DEFAULT_ADMIN_ROLE` (Timelock) | `PARAM_ROLE` (upkeep) | `onlyVault` modifier | `src/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol:111` |
| EulerUsdcMultiMarketAdapter | `DEFAULT_ADMIN_ROLE` (Timelock) | `PARAM_ROLE` (upkeep) | `onlyVault` modifier | `src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol:86` |
| FluidUsdcMultiMarketAdapter | `DEFAULT_ADMIN_ROLE` (Timelock) | `PARAM_ROLE` (upkeep) | `onlyVault` modifier | `src/strategies/usdc-lending/adapters/lending/FluidUsdcMultiMarket.sol:53` |
| MorphoUsdcMultiMarketAdapter | `DEFAULT_ADMIN_ROLE` (Timelock) | `PARAM_ROLE` (upkeep) | `onlyVault` modifier | `src/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol:62` |
| VenusUsdcMultiMarketAdapter | `DEFAULT_ADMIN_ROLE` (Timelock) | `PARAM_ROLE` (upkeep) | `onlyVault` modifier | `src/strategies/usdc-lending/adapters/lending/VenusUsdcMultiMarket.sol:66` |
| AaveLiquidityRateProvider | `DEFAULT_ADMIN_ROLE` (Timelock) | `PARAM_ROLE` (upkeep) | — | `src/strategies/usdc-lending/adapters/rates/AaveLiquidityRateProvider.sol:15` |
| DolomiteSupplyRateProvider | `Ownable.owner()` | `onlyOwner` | — | `src/strategies/usdc-lending/adapters/rates/DolomiteSupplyRateProvider.sol:9` |
| RewardSwapHelper | `DEFAULT_ADMIN_ROLE` (Timelock) | `PARAM_ROLE` (governance) | — | `src/strategies/usdc-lending/swap/RewardSwapHelper.sol:75` |

`PARAM_ROLE = keccak256("PARAM_ROLE")` is the keeper-write role across all adapters.
`LendingStrategyUpkeep` is the primary holder of `PARAM_ROLE`.
`DEFAULT_ADMIN_ROLE` always points to the Timelock contract.

---

## Code Reference Index

| Artifact | Reference |
|----------|-----------|
| `ILendingAdapter` interface | `src/strategies/usdc-lending/interfaces/ILendingAdapter.sol:5` |
| `IAdapterEmergency` interface | `src/strategies/usdc-lending/interfaces/ILendingAdapter.sol:51` |
| `AaveV3USDCAdapter` contract | `src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol:85` |
| `AaveV3USDCAdapter.deposit()` | `src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol:221` |
| `AaveV3USDCAdapter.withdraw()` | `src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol:239` |
| `AaveV3USDCAdapter.currentAPYBps()` | `src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol:271` |
| `AaveV3USDCAdapter.harvestableProfit()` | `src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol:351` |
| `AaveV3USDCAdapter.harvest()` | `src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol:369` |
| `AaveV3USDCAdapter.externalMarketTVL()` | `src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol:418` |
| `CometUsdcMultiMarketAdapter` contract | `src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol:78` |
| `CometUsdcMultiMarketAdapter.Market` struct | `src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol:90` |
| `CometUsdcMultiMarketAdapter` scoring weights | `src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol:99` |
| `IComet` interface | `src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol:52` |
| `DolomiteUsdcMultiMarketAdapter` contract | `src/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol:107` |
| `IDolomiteMargin` interface | `src/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol:77` |
| `IDolomiteRateProvider` interface | `src/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol:95` |
| `EulerUsdcMultiMarketAdapter` contract | `src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol:73` |
| `EulerUsdcMultiMarketAdapter.initializeMarkets()` | `src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol:200` |
| `PERMIT2` constant | `src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol:89` |
| `IEulerUsdcMarket` interface | `src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol:26` |
| `FluidUsdcMultiMarketAdapter` contract | `src/strategies/usdc-lending/adapters/lending/FluidUsdcMultiMarket.sol:49` |
| `FluidUsdcMultiMarketAdapter.deposit()` | `src/strategies/usdc-lending/adapters/lending/FluidUsdcMultiMarket.sol:174` |
| `FluidUsdcMultiMarketAdapter.withdraw()` | `src/strategies/usdc-lending/adapters/lending/FluidUsdcMultiMarket.sol:195` |
| `FluidUsdcMultiMarketAdapter.currentAPYBps()` | `src/strategies/usdc-lending/adapters/lending/FluidUsdcMultiMarket.sol:233` |
| `MorphoUsdcMultiMarketAdapter` contract | `src/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol:58` |
| `MorphoUsdcMultiMarketAdapter.Market` struct | `src/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol:79` |
| `MARKET_QUARANTINE_THRESHOLD` constant | `src/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol:70` |
| `PPS_SNAP_TTL` constant | `src/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol:71` |
| `MorphoUsdcMultiMarketAdapter` scoring weights | `src/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol:109` |
| `VenusUsdcMultiMarketAdapter` contract | `src/strategies/usdc-lending/adapters/lending/VenusUsdcMultiMarket.sol:62` |
| `BLOCKS_PER_YEAR` constant | `src/strategies/usdc-lending/adapters/lending/VenusUsdcMultiMarket.sol:70` |
| `ARBITRUM_CHAIN_ID` constant | `src/strategies/usdc-lending/adapters/lending/VenusUsdcMultiMarket.sol:75` |
| `IVToken` interface | `src/strategies/usdc-lending/adapters/lending/VenusUsdcMultiMarket.sol:10` |
| `AaveLiquidityRateProvider` contract | `src/strategies/usdc-lending/adapters/rates/AaveLiquidityRateProvider.sol:14` |
| `AaveLiquidityRateProvider.setLiquidityRateRay()` | `src/strategies/usdc-lending/adapters/rates/AaveLiquidityRateProvider.sol:35` |
| `AaveLiquidityRateProvider.getLiquidityRateRayWithTs()` | `src/strategies/usdc-lending/adapters/rates/AaveLiquidityRateProvider.sol:49` |
| `DolomiteSupplyRateProvider` contract | `src/strategies/usdc-lending/adapters/rates/DolomiteSupplyRateProvider.sol:9` |
| `DolomiteSupplyRateProvider.setSupplyRatePerSecond()` | `src/strategies/usdc-lending/adapters/rates/DolomiteSupplyRateProvider.sol:22` |
| `RewardSwapHelper` contract | `src/strategies/usdc-lending/swap/RewardSwapHelper.sol:71` |
| `RewardSwapHelper.RewardConfig` struct | `src/strategies/usdc-lending/swap/RewardSwapHelper.sol:95` |
| `RewardSwapHelper.configs` mapping | `src/strategies/usdc-lending/swap/RewardSwapHelper.sol:105` |
| `RewardSwapHelper` heartbeat notes | `src/strategies/usdc-lending/swap/RewardSwapHelper.sol:57` |

---

## Footer

**Code reference commit**: b15aeb63 (pierdev, post CITATIONS-FIX merge)

**Sources used**:
- `src/strategies/usdc-lending/interfaces/ILendingAdapter.sol:1-54` (54L)
- `src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol:1-543` (543L)
- `src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol:1-816` (816L)
- `src/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol:1-1106` (1106L)
- `src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol:1-1039` (1039L)
- `src/strategies/usdc-lending/adapters/lending/FluidUsdcMultiMarket.sol:1-362` (362L)
- `src/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol:1-1037` (1037L)
- `src/strategies/usdc-lending/adapters/lending/VenusUsdcMultiMarket.sol:1-446` (446L)
- `src/strategies/usdc-lending/adapters/rates/AaveLiquidityRateProvider.sol:1-54` (54L)
- `src/strategies/usdc-lending/adapters/rates/DolomiteSupplyRateProvider.sol:1-32` (32L)
- `src/strategies/usdc-lending/swap/RewardSwapHelper.sol:1-411` (411L)

**Discrepancies found during code-first read**:
1. `CometUsdcMultiMarketAdapter.wLiq = 2500` (L100), not 2000 as in Morpho/internal notes. Comet weights are slightly different from Morpho weights — both sum to 10000.
2. `EulerUsdcMultiMarketAdapter` ILendingAdapter copy (L39-L61 in EulerUsdcMultiMarket.sol) does not include `isPushMode()` in its inline interface definition, but Euler is PUSH mode per deploy checklist. The canonical `interfaces/ILendingAdapter.sol` is authoritative.
3. Fluid is documented as "multi-market" in contract name but is currently single-market — comment at `FluidUsdcMultiMarket.sol:46` notes "can be extended to multi-market pattern later."
                                                       