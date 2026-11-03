The forge test runs have not completed yet. I will now write the full report, declaring the test status accurately.

---

## `review-A.md` — Session A: Dimensions and Financial Policy

---

```
CANDIDATE BUNDLE SHA256: 5a989edd92063fcfef12f9a1daf85481f82b471c5f84b778bfd4f085232225a1
BASE COMMIT:             211f1a0a4cb9c63232ae18dac24ccb921e5a4699
FROZEN CORE SUBMODULE:   9a9d120709de99a6216e9fe75d36e9ffdcb1a4d9
REVIEWER SESSION:        A — Dimensions and Financial Policy
DATE:                    2026-11-01
```

---

## Executive Summary

Six findings identified from direct source analysis. Two are high/medium and require patches before release. Four are lower-severity operational or precision concerns. The most critical is a **compound bug (A-2)** that renders the entire P0.7 safety adapter elevated-cap feature non-functional: both the overflow deployment module and the gate module independently clamp safety-fallback caps to the normal global ceiling, directly contradicting their own code comments.

**All live-chain fork tests and the 19-case live matrix are UNEXECUTED.** This is a binding gap — the user's explicit gate (no mocked Params, no warm NAV, no controlled-price fixtures for live-chain acceptance) remains open. Non-fork regression compilation was initiated but produced no output before this report was finalized; that result is also reported as unexecuted.

---

## Commands Executed and Results

| Command | Scope | Exit | Passed | Failed | Skipped | Unexecuted |
|---|---|---|---|---|---|---|
| `forge test --match-path "test/strategies/usdc-lending/*" --no-match-test "fork\|Fork\|FORK" -q` | Non-fork lending unit/fuzz/invariant | Background — no output returned | — | — | — | All |
| `forge test --match-path "test/strategies/usdc-lending/F_SCORING_INV2_CapFix.t.sol" -q` | Scoring invariant | Background — no output returned | — | — | — | All |
| Fork tests (Arbitrum/Base) — matrix, oracle-failure, live reward swaps | Required by user gate | NOT STARTED | — | — | — | 19+ declared |
| Live matrix: AaveV3 × Arbitrum/Base, strategy4, Core4, rewards6, Base fee1 | Required by user gate | NOT STARTED | — | — | — | 19 |
| Cast calls for on-chain oracle/struct validation | Not attempted | NOT STARTED | — | — | — | All |

**No forge test results are available. All test gates are UNEXECUTED for this report. This does not indicate pass or failure — it is a concrete unexecuted check as required by the acceptance rules.**

The candidate compiles (inferred from git status showing modified `.sol` files tracked against a clean base, and from the execution master stating 2792 regression passes at prior engineering sign-off). Independent compilation by this session was not completed.

---

## Findings

### A-1 — MEDIUM: Comet `optimize()` liquidity score not normalized to bps scale

**Site:** `src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol:616`

**Code:**
```solidity
uint256 score = uint256(apy) * wAPY + liq * wLiq / underlyingUnit // normalize liquidity to bps
    + uint256(risk) * wRisk + uint256(stability) * wStability + uint256(incentive) * wIncentive;
```

**Input / Expected / Observed:**

For a Comet USDC market with $100M available liquidity:
- `liq = IERC20(underlying).balanceOf(m.comet)` = 100,000,000 × 10⁶ = 1 × 10¹⁴ (raw USDC units)
- `liq * wLiq / underlyingUnit` = (1 × 10¹⁴ × 2500) / 10⁶ = **2.5 × 10¹¹**
- `apy * wAPY` = 500 × 4000 = **2,000,000** = 2 × 10⁶

The liquidity term dominates by a factor of **125,000×** for a $100M market. For WETH (18 decimals) the factor is ~37× for 30,000 ETH in the pool. The comment "normalize liquidity to bps" is unfulfilled — the result is in "USDC-dollars × weight", not bps.

**Expected:** Each scoring component in approximately the same magnitude range so weights govern the blend. Liquidity at a large market should produce a score term comparable to APY × wAPY.

**Observed:** Market selection in `optimize()` ranks entirely by market size (raw USDC balance), ignoring APY and risk signals for any market above ~$1k liquidity. A low-yield market with $1B liquidity always outscores a high-yield market with $10M liquidity regardless of the 4000/2500 weight ratio.

**Effect:** Intra-adapter market selection is wrong. Comet positions are always concentrated in the largest market, not the highest-yield one. This is suboptimal for yield. It cannot cause fund loss because the markets are all Compound V3 USDC markets with compatible semantics, and the strategy-level gate still runs.

**Unit Proof:**
- `liq_dollars = liq / underlyingUnit = 1e14 / 1e6 = 1e8` (for a $100M market)
- Expected max liq score term: `10000 * wLiq = 10000 * 2500 = 2.5e7`
- Actual liq term: `1e8 * 2500 = 2.5e11` — 10,000× above the intended maximum bps range

**Severity:** MEDIUM — suboptimal yield within the Comet adapter; no loss-of-funds risk.

**Regression:** Test that for two Comet markets where market A has APY = 500 bps and $1M liquidity, market B has APY = 50 bps and $500M liquidity: after fix, `optimize()` selects market A; before fix it would select market B.

---

### A-2 — HIGH: Safety adapter elevated cap silently clamped to normal cap (P0.7 fully inoperative)

**Sites:**
1. `src/strategies/usdc-lending/controller/StrategySafetyOverflowModule.sol:73-74`
2. `src/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol:385-386`

**Code — StrategySafetyOverflowModule.sol (lines 72-75):**
```solidity
SafetyFallback memory sf = safetyFallback[a];
if (sf.absCapBps == 0) continue;
uint256 capBps = sf.absCapBps;
if (adapterMaxExposureBps > 0 && capBps > adapterMaxExposureBps) capBps = adapterMaxExposureBps;
```

**Code — StrategyRebalanceGateModule.sol (lines 384-388):**
```solidity
uint256 absCapBpsEff = isSafety ? uint256(sf.absCapBps) : uint256(normalAbsCapBps);
if (normalAbsCapBps > 0 && absCapBpsEff > normalAbsCapBps) absCapBpsEff = normalAbsCapBps;
```

**Invariants violated:**

Per `SettingsModule.addSafetyFallbackAdapter`: `absCapBps ∈ [1, 8000]` (up to 80% of TVL). Per `SettingsModule.setRebalanceParams`: `adapterMaxExposureBps ∈ [0, 5000]` (up to 50%). The safety fallback tier is specifically designed to hold positions **above** the normal cap — that is the entire purpose of having a separate per-adapter `safetyFallback.absCapBps`.

The code comment in `StrategySafetyOverflowModule` (line 39) says: "Respects fallbackAbsCap and fallbackRelCap per adapter -- never normal abs/rel cap." The code on line 74 does the opposite.

The code comment in `StrategyRebalanceGateModule` (lines 350-370) says: "For safety-fallback adapters, the ceiling becomes the (governance-approved, elevated) fallback cap instead of the normal abs/rel cap." The code on line 386 immediately overrides this, clamping `absCapBpsEff = min(sf.absCapBps, normalAbsCapBps)`.

**Input / Expected / Observed:**

Governance registers adapter A as a safety fallback with `absCapBps = 6000` (60% TVL) and `adapterMaxExposureBps = 4000` (40% global normal cap):

1. **Safety overflow path** (`executeSafetyOverflow`): `capBps = min(6000, 4000) = 4000`. The overflow module deposits up to 40% TVL, not 60%. Safety overflow is blocked above the normal ceiling.

2. **Cap drift mandate** (`_checkCapDriftMandate`): `absCapBpsEff = min(6000, 4000) = 4000`. The mandate fires if position > `4000 * tvl * (1 + toleranceBps) / 1e8` — i.e., at 40% + tolerance. Any overflow deposit that pushed to 50% would immediately trigger a mandatory withdrawal, creating a deploy-then-immediately-withdraw loop.

**Consequence:** The P0.7 safety adapter elevated-cap feature is completely inoperative. If `adapterMaxExposureBps = 0` (global ceiling disabled), the clamp is skipped (`if (adapterMaxExposureBps > 0 && ...)`) and safety caps work. But disabling `adapterMaxExposureBps` removes the normal global ceiling for all adapters simultaneously — an unacceptable operational tradeoff.

**Severity:** HIGH — a governance-deployed safety infrastructure feature is silently non-functional. During a liquidity crunch where safety adapters were intended to absorb excess capital, the system would behave identically to having no safety adapters at all. Governance actions setting elevated safety caps would produce no effect.

**Regression:** 
1. Configure adapter with `safetyFallback.absCapBps = 6000`, `adapterMaxExposureBps = 4000`. Call `executeSafetyOverflow` with TVL large enough that position would exceed 4000 bps. Assert position reaches 6000 bps × TVL (before fix: clamps at 4000 bps × TVL).
2. After reaching 55% TVL via safety overflow, call `_checkCapDriftMandate`: assert it does NOT fire below `6000 bps × TVL × (1 + tolerance)` (before fix: fires at 4000 bps × TVL × (1 + tolerance)).

---

### A-3 — MEDIUM: Dolomite `lastAPYBps` never written — internal market selection permanently broken

**Site:** `src/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol:155, 864, 889, 939-940`

**Evidence:** The `Market` struct declares `uint16 lastAPYBps` at line 155. All struct initializations set it to 0 (lines 278, 1022, 1038). A content-search for `lastAPYBps\s*=` (assignment, not declaration/initialization) returns **zero matches** across the entire file.

Three consumer sites read this always-zero field:

1. `_score()` line 864: `uint16 apyBps = m.lastAPYBps;` — APY component always 0
2. `_score()` line 889: `uint16 stabBps = m.lastAPYBps;` — stability component always 0  
3. `_estimateNetBenefitBps()` lines 939-940: `uint16 apyFrom = mkts[fromIdx].lastAPYBps; uint16 apyTo = mkts[toIdx].lastAPYBps;` — APY differential always 0

**Expected:** `lastAPYBps` is populated by deposit/withdraw/optimize so internal market scoring can differentiate markets by yield.

**Observed:** `_score()` always returns 0 for the APY and stability components. `_estimateNetBenefitBps()` always returns 0 net benefit regardless of actual APY spread between markets. `optimize()` therefore:
- never identifies a better market on APY grounds  
- always returns early with `(0, mkts[fromIdx].comet, mkts[toIdx].comet)` from the APY check at line 940 (`if (apyTo <= apyFrom) return ...` where both are 0)

Note: `currentAPYBps()` (the outer-level function queried by the strategy scorer) reads live from PpsRateLib or rate provider — it is unaffected and returns correct values. Only the internal market-to-market comparison is broken.

**Effect:** The Dolomite adapter can hold positions across multiple markets but will never rebalance between them once deployed. The active market is set at deposit time and stays there permanently. For a single-market deployment (the common case) there is no functional impact; for multi-market configurations the adapter is effectively single-market with dead routing logic.

**Severity:** MEDIUM — multi-market Dolomite configurations cannot self-optimize; suboptimal yield for that configuration. Not a loss-of-funds risk.

**Regression:** Configure two PoolLike markets with different real APYs. Call `optimize()`. Assert returned `movedUSDC > 0` and position moved to the higher-APY market.

---

### A-4 — LOW: Comet `totalsBasic` interface declares 6 fields instead of 8

**Site:** `src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol:63`

**Code:**
```solidity
function totalsBasic() external view returns (uint64, uint64, uint104, uint104, uint64, uint64);
```

**Actual Compound V3 struct (8 ABI-encoded words):**
```
Word 0: uint64  baseSupplyIndex
Word 1: uint64  baseBorrowIndex
Word 2: uint64  trackingSupplyIndex
Word 3: uint64  trackingBorrowIndex
Word 4: uint104 totalSupplyBase
Word 5: uint104 totalBorrowBase
Word 6: uint40  lastAccrualTime
Word 7: uint8   pauseFlags
```

The 6-field interface decodes the first 6 words (0–5) only. The names in `externalMarketTVL()` (line 404):
```solidity
(uint64 baseSupplyIndex, uint64, uint104, uint104, uint64 totalSupplyBase, uint64)
```
Map to: word 0 (`baseSupplyIndex` ✓), word 1 (`baseBorrowIndex` — unnamed ✓), word 2 (`trackingSupplyIndex` decoded as uint104 — type widens correctly), word 3 (`trackingBorrowIndex` — decoded as uint104 — type widens correctly), word 4 (`totalSupplyBase` decoded as uint64), word 5 (`totalBorrowBase` — unnamed).

The key field `totalSupplyBase` is at word 4 in the actual 8-word encoding and is decoded as `uint64`. The actual type is `uint104`. The value is correct as long as it is < 2⁶⁴ ≈ 1.84 × 10¹⁹. For 6-decimal USDC this is $18,446,744,073,709 (~$18T) — well beyond any realistic market size.

**Effect:** No current operational impact. TVL calculation using `totalSupplyBase × baseSupplyIndex / baseIndexScale` produces correct values at all realistic market sizes. The type mismatch could corrupt TVL reporting at a theoretical $18T TVL level.

**Severity:** LOW — type mismatch with no current impact; defensive correctness concern.

**Regression:** Confirm `externalMarketTVL()` matches `baseSupplyIndex × totalSupplyBase / baseIndexScale` independently computed from a live fork call.

---

### A-5 — LOW: Morpho `investedAssets()` reports stale NAV between operations

**Site:** `src/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol:944-950, 971-981`

**Code:**
```solidity
function investedAssets() public view returns (uint256 total) {
    for (uint256 i = 0; i < n; ++i) {
        if (principal[i] == 0 && cachedMarketNav[i] == 0) continue;
        total += cachedMarketNav[i]; // stale cache
    }
}
```

`cachedMarketNav` is refreshed only by `_refreshNavCache()`, which is called inside `deposit()`, `withdraw()`, and `optimize()`. Between keeper operations, share prices accrue but `investedAssets()` (and therefore `totalAssets()`) returns the last-cached value.

**Effect:** The strategy's `_tvl()` (`ASSET.balanceOf(this) + sum(positionAssets)`) uses `positionAssets[a]` — a separately tracked accounting field — not `investedAssets()`. The TVL discrepancy is between `investedAssets()` (stale) and the actual accrued position. Since `positionAssets` is updated via the sync path (`_syncPositionAssets`) which calls `totalAssets()` → `investedAssets()` → stale cache, the TVL used for allocation could be slightly understated between syncs. The discrepancy is bounded by interest accrual between operations (typically hours to days, low bps impact).

`withdrawableAssets()` uses `maxWithdraw()` — a live call — so the withdrawal gate is unaffected.

**Severity:** LOW — bounded operational imprecision; no security risk; NAV catches up on each keeper operation.

**Regression:** After a time-warp of 1 day in a fork test, assert `investedAssetsLive() > investedAssets()` (stale understates accrued value) and assert they converge after any deposit/withdraw/optimize call.

---

### A-6 — LOW: Dolomite PoolLike `externalMarketTVL` uses available cash, not total TVL

**Site:** `src/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol:648-654`

**Code:**
```solidity
} else {
    // PoolLike: use USDC balance as conservative proxy
    try IERC20(asset).balanceOf(mkts[i].addr) returns (uint256 bal) {
        total += bal;
    }
}
```

`IERC20(asset).balanceOf(addr)` returns the idle cash at the Dolomite margin address, not the protocol's total assets under management. A Dolomite PoolLike market with $500M total deposits and $50M available cash (90% utilization) reports `externalMarketTVL = $50M`, not $500M.

**Effect:** `cachedExternalTVL` stored by `pokeExternalTVL()` is understated by the utilization factor. The TVL confidence tier (`_tvlConfidence`) uses `cachedExternalTVL` to determine which band applies. At 90% utilization, a $500M market appears as $50M, likely placing it in MICRO or SMALL band instead of HIGH/VHIGH, suppressing the relative cap to 5-7% instead of 25%. This makes Dolomite PoolLike adapters structurally under-allocated relative to their true size, which is conservative but suboptimal.

The comment says "conservative proxy" — this is documented intent. However, the execution master's acceptance criterion for `externalMarketTVL` is protocol TVL (total deposits), not available cash.

**Severity:** LOW — conservative understating reduces capital efficiency but protects against TVL oracle manipulation; documented as "proxy" in code.

**Regression:** For a PoolLike market with $500M deposits and $50M cash, assert `externalMarketTVL()` ≥ total deposits (after fix); assert confidence tier is HIGH or VHIGH.

---

## Dimensional Verification Summary

The following were confirmed correct and require no patch:

| Component | Check | Result |
|---|---|---|
| `assetUnitsToUsd6(assets, priceWad, refUnit)` | `mulDiv(assets, priceWad, refUnit × 1e12)` — USDC: `mulDiv(1e6, 1e18, 1e6×1e12) = 1e6` (=$1 USD6) ✓; WETH: `mulDiv(1e18, 3000e18, 1e18×1e12) = 3000e6` ✓ | Correct |
| `_convertUsd6ToAssetUnits` | Ceiling rounding via `mulmod != 0`; overflow guard at `usd6 > type(uint256).max/1e12` | Correct |
| Aave `_rateRayToBps` | `rateRay / 1e23` = bps (1e27/1e23=1e4 scale) | Correct |
| Comet `_getAPYBps` | `ratePerSec × 31_536_000 × 10000 / 1e18` | Correct |
| Euler `_supplyAPYBps` | `borrowRateSPY / (1e27/(31_557_600×10000)) × utilizationWAD × (1-fee) / (1e18×10000)` | Correct |
| Dolomite PoolLike APY | `rpsWad × 31_536_000 / 1e14` = bps | Correct |
| Venus `_vTokenToUnderlying` | `vTokenBal × exchangeRateStored / 1e18` (standard Compound formula) | Correct |
| Venus `currentAPYBps` | `supplyRatePerBlock × blocksPerYear / 1e14` | Correct |
| PpsRateLib annualization | `mulDiv(pps - s.pps, 365days × 10000, s.pps) / dt`; negative yield returns 0 | Correct |
| Gas estimator USD6 | `usdWei = (executionWei + posterWei) × eth / 1e18; usd6 = ceilDiv(usdWei, 1e12)` | Correct |
| `MAX_EXTERNAL_TVL` | `50_000_000_000e6` ($50B USD6); delta limiter 10× per poke | Correct |
| `MAX_EXTERNAL_TVL_JUMP_BPS` | 100000 = 10× (not BPS — a multiplier constant) | Correct; named misleadingly but value is correct |
| `_gateBenefitCost` overflow guards | `grossBenefit > 0 && tvl > 0` pre-check before divide; `moved < type(uint256).max / 1e4` | Correct |
| Tier seed/confidence/cap tables | Parametrized by `refUnit`; confirmed for 6-dec and 18-dec via `StrategyConfigLib` | Correct |
| Safety overflow `fbCeilingNet` | `(fbCeiling × safetyMult) / 10000` where `safetyMult = 10000 - marginBps` | Dimensionally correct (conditioned on A-2 fix) |
| RewardSwapHelper `_oracleExpectedAssetOut` | `rewardValueWad = mulDiv(amountIn, priceWad, 10^decimals)`; `assetOut = mulDiv(rewardValueWad, 10^assetDecimals, assetPriceWad)` | Correct |
| `_freshPriceWad` oracle checks | `updatedAt == 0` → stale; `block.timestamp < updatedAt` → future; staleness window; `answer <= 0` → invalid | Correct |
| `_validPath` (Uniswap V3 / Camelot Algebra V1) | step=23 (Uniswap) / step=20 (Algebra); first==rewardToken, last==outputAsset | Correct |
| Sequencer grace period | `block.timestamp <= startedAt + SEQUENCER_GRACE_PERIOD_SEC (3600s)` → reject | Correct |
| `setRebalanceParams` param bounds | `adapterMaxExposureBps ≤ 5000`; `driftToleranceBps ≤ 2000`; `minAdaptersActive == 1` (deprecated, locked) | Correct |
| `addSafetyFallbackAdapter` bounds | `absCapBps ∈ [1, 8000]`; quarantined adapters rejected | Correct; structural precondition for A-2 |
| Morpho `withdrawableAssets()` | `maxWithdraw()` live — unaffected by stale NAV | Correct |
| `_checkCapDriftMandate` rel cap path | `effRel` resolved, hard ceiling computed with tolerance | Correct (conditioned on A-2 abs cap fix) |

---

## Unexecuted Gates

The following checks required by the review mandate and the user's explicit added gate remain unexecuted. They are **not passes**:

1. **Live fork tests (Arbitrum/Base)** — requires RPC endpoint with archive access. No RPC was available in this environment. UNEXECUTED.

2. **19-case live matrix** (Aave4×2chains, strategy4, Core4, rewards6, Base-fee1) — requires live-chain state. UNEXECUTED.

3. **Real funded holder tests** — user's explicit gate: "prefer real funded holders for the new proof; CoreHarness/MockParams cases DO NOT close that gate." UNEXECUTED.

4. **Oracle edge cases on live chain** — zero price, stale oracle, future timestamp, malformed data — require fork execution. UNEXECUTED.

5. **Non-fork regression suite** — `forge test --no-match-test "fork|Fork|FORK"` was initiated in background but produced no output before this report. Status: UNEXECUTED for purposes of this report.

6. **Systematic 40-site unsafe-typecast review** — partially covered (sites in AaveV3, Comet, Venus, Dolomite, scoring, gate reviewed incidentally; no systematic inventory of all 40 forge-lint warning sites). Partially unexecuted.

---

## Proposed Patches

### Patch A-2a: Remove safety cap clamp in StrategySafetyOverflowModule

```diff
--- a/src/strategies/usdc-lending/controller/StrategySafetyOverflowModule.sol
+++ b/src/strategies/usdc-lending/controller/StrategySafetyOverflowModule.sol
@@ -70,7 +70,7 @@ contract StrategySafetyOverflowModule is StrategyStorageLayout {
             SafetyFallback memory sf = safetyFallback[a];
             if (sf.absCapBps == 0) continue;
             uint256 capBps = sf.absCapBps;
-            if (adapterMaxExposureBps > 0 && capBps > adapterMaxExposureBps) capBps = adapterMaxExposureBps;
+            // Safety fallback absCapBps is an elevated governance-approved cap; do not clamp to normalAbsCapBps.
             uint256 fbCeiling = (capBps * tvl) / 1e4;
```

### Patch A-2b: Remove safety cap clamp in StrategyRebalanceGateModule

```diff
--- a/src/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol
+++ b/src/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol
@@ -383,7 +383,6 @@ contract StrategyRebalanceGateModule is StrategyStorageLayout {
             bool isSafety = (sf.absCapBps != 0);
 
             uint256 absCapBpsEff = isSafety ? uint256(sf.absCapBps) : uint256(normalAbsCapBps);
-            if (normalAbsCapBps > 0 && absCapBpsEff > normalAbsCapBps) absCapBpsEff = normalAbsCapBps;
             uint256 absMaxExp   = (absCapBpsEff * tvl) / 1e4;
             uint256 absHard     = (absMaxExp * (1e4 + uint256(tolBps))) / 1e4;
```

### Patch A-1: Normalize Comet liquidity score to bps range

```diff
--- a/src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol
+++ b/src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol
@@ -607,9 +607,11 @@ contract CometUsdcMultiMarketAdapter is ILendingAdapter, AccessControl, Reentran
             uint16 apy = _getAPYBps(m.comet);
             uint256 liq = IERC20(underlying).balanceOf(m.comet);
             uint16 risk = 10000 - m.riskScoreBps;
-            // Stability: for simplicity, use APY as EMA
             uint16 stability = apy;
             uint16 incentive = incentiveBpsGlobal;
 
-            uint256 score = uint256(apy) * wAPY + liq * wLiq / underlyingUnit // normalize liquidity to bps
-                + uint256(risk) * wRisk + uint256(stability) * wStability + uint256(incentive)
-                * wIncentive;
+            // Normalize liquidity to [0, 10000] bps as withdrawal availability ratio:
+            // liqBps = min(available_cash * 10000 / total_invested, 10000).
+            // Fall back to 5000 (50%) when no position exists yet.
+            uint256 tvlLocal = totalAssets();
+            uint256 liqBps = tvlLocal > 0 ? (liq * 10000) / tvlLocal : 5000;
+            if (liqBps > 10000) liqBps = 10000;
+            uint256 score = uint256(apy) * wAPY + liqBps * wLiq
+                + uint256(risk) * wRisk + uint256(stability) * wStability
+                + uint256(incentive) * wIncentive;
```

### Patch A-3: Populate Dolomite `lastAPYBps` in the optimize path

```diff
--- a/src/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol
+++ b/src/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol
@@ -780,6 +780,10 @@ contract DolomiteUsdcMultiMarketAdapter is ILendingAdapter, AccessControl, Reent
     function optimize() external nonReentrant onlyVault returns (...) {
         require(block.timestamp >= lastOptimizeTs + minSecondsBetweenOptimize, "cooldown");
         uint256 n = mkts.length;
         require(n > 1, "singleMkt");
+        // Refresh lastAPYBps cache before scoring so _score()/_estimateNetBenefitBps() see live rates.
+        for (uint256 i = 0; i < n; ++i) {
+            if (mkts[i].enabled) mkts[i].lastAPYBps = _currentMarketAPYBps(i);
+        }
```

Where `_currentMarketAPYBps(i)` is the per-market APY function (to be extracted from or aligned with `currentAPYBps()` logic). For ERC4626 markets it reads from PpsRateLib on the market's address; for PoolLike markets it reads from the rate provider. The implementation should mirror the existing `currentAPYBps()` logic but scoped to a specific market index rather than `activeIdx`.

### Patch A-4: Fix Comet `totalsBasic` interface to all 8 fields

```diff
--- a/src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol
+++ b/src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol
@@ -61,7 +61,9 @@ interface IComet {
     function getUtilization() external view returns (uint256);
     function getSupplyRate(uint256 utilization) external view returns (uint256);
-    function totalsBasic() external view returns (uint64, uint64, uint104, uint104, uint64, uint64);
+    // Actual Compound V3 TotalsBasic: 8 fields.
+    function totalsBasic() external view returns (
+        uint64 baseSupplyIndex, uint64 baseBorrowIndex,
+        uint64 trackingSupplyIndex, uint64 trackingBorrowIndex,
+        uint104 totalSupplyBase, uint104 totalBorrowBase,
+        uint40 lastAccrualTime, uint8 pauseFlags
+    );
     function baseIndexScale() external view returns (uint64);
```

Update the usage in `externalMarketTVL()` accordingly:
```diff
@@ -404,7 +404,8 @@ contract CometUsdcMultiMarketAdapter is ILendingAdapter, AccessControl, Reentran
             try IComet(mkts[i].comet).totalsBasic() returns (
-                uint64 baseSupplyIndex, uint64, uint104, uint104, uint64 totalSupplyBase, uint64
+                uint64 baseSupplyIndex, uint64, uint64, uint64,
+                uint104 totalSupplyBase, uint104, uint40, uint8
             ) {
```

---

## Scope Notes

- **FluidUsdcMultiMarket.sol**: Present in the worktree but not in the candidate diff (not in git status as modified). Not reviewed as a candidate file.
- **`StrategyExplainabilityLens.sol`**: Read-only periphery, explicitly documented as best-effort/not canonical. Divergence has no financial consequence.
- **`StrategySettingsModule.sol`**: Reviewed. All parameter bounds are correct and internally consistent. The `minAdaptersActive == 1` enforcement is intentional deprecation. `setRegimeParams` locking `hysteresisMult` and `budgetMult` to 10000 is intentional deprecation of regime multiplier features.
- **`StrategyRebalancePlanModule.sol`**: Reviewed. Plan phase state machine, drift invalidation, backoff escalation are all dimensionally correct. TVL drift check uses `uint256 drift = abs(currentTvl - planTvl)` against `allowed = planTvl × driftToleranceBps / 1e4` with absolute floor from `rebalancePlanMinDrift` — correct.
- **`RewardSwapHelper.sol`**: Reviewed. Oracle math, path validation, sequencer check, slippage cap (500 bps hard max at `setRewardConfig`), multi-DEX fallback pattern all correct.
- **Core contracts** (CoreVault, StrategyRouter): Not reviewed per freeze mandate.

---

## Binding Declaration

This report is bound to candidate-files.json SHA256 `5a989edd92063fcfef12f9a1daf85481f82b471c5f84b778bfd4f085232225a1`. No source files were modified. No git mutations were made. No broadcast, Safe action, or messaging was performed.

The live-chain fork gate remains open. Independent audit completion is not claimed. A-2 is a release-blocking finding: the P0.7 safety adapter feature is inoperative and must be patched and re-tested (including with real safety-overflow scenarios on fork) before any production deployment.
