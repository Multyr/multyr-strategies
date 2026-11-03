I have read all ten delta files. Proceeding with the four-task analysis.

---

## Task 1 — Comet ABI, Liquidity Readiness BPS, Decimal Regressions

### ABI correctness

`CometUsdcMultiMarket.sol:63` declares:
```solidity
function totalsBasic() external view returns (uint64, uint64, uint64, uint64, uint104, uint104, uint40, uint8);
```
This matches the canonical Compound III `TotalsBasic` struct exactly: four `uint64` indexes (`baseSupplyIndex`, `baseBorrowIndex`, `trackingSupplyIndex`, `trackingBorrowIndex`), `uint104` supply and borrow principals, `uint40` lastAccrualTime, `uint8` pauseFlags. Decoding at `externalMarketTVL()` (line 404) extracts field 1 as `baseSupplyIndex` and field 5 as `totalSupplyBase`, both positionally correct. No ABI mismatch.

### externalMarketTVL formula

```solidity
total += (uint256(totalSupplyBase) * uint256(baseSupplyIndex)) / uint256(scale);   // line 409
```

`totalSupply = totalSupplyBase × index / scale` is the correct Comet accounting identity; at genesis `index = scale = 1e15` so the ratio is 1, and it grows with interest. The fork test `CometPublishedTotals.fork.t.sol:24–31` pins to Arbitrum block 520094008, reads both the USDC and WETH Comet markets, asserts the computed value **exceeds** `balanceOf(market)` (total supply > cash because of outstanding borrows), and asserts the adapter returns exactly the formula result. For WETH it also asserts `principal > type(uint64).max` confirming `uint104` is required. **No ABI regression.**

### Liquidity readiness BPS — decimal correctness

`optimize()` lines 611–619:
```solidity
uint256 liq = IERC20(underlying).balanceOf(m.comet);   // market cash, asset units
...
uint256 liquidityBps = managed == 0 || liq >= managed ? 10000 : (liq * 10000) / managed;
```

`managed = totalAssets()` (lines 606-607) — also in asset units. The ratio `liq/managed` is dimensionless; both numerator and denominator scale identically with decimal exponent, so `liquidityBps` is always in `[0, 10000]` regardless of `decimals`. The old hardcoded `1e6` denominator has been removed. `underlyingUnit` at line 153 is stored for potential future use; it is not referenced in the scoring formula — the fix is implemented entirely through the `managed` denominator.

`AdapterRateRemediation.t.sol` tests `_comet(6, 1000)`, `_comet(18, 1000)`, and `_comet(18, 1)` (high-price single-unit quantity). All three fund the source market with `amount × 1_000_000` excess cash, set `to` at a higher supply rate (400M vs 200M), and assert `moved == amount` and `source == from`. With excess cash the `liq >= managed` branch fires for `from` returning `liquidityBps = 10000`; `to` has `liq = amount == managed` → also `10000`. Both markets tie on liquidity, APY decides. **Decimal regression verified absent.**

**No blockers in Task 1.** Inspected scope: `CometUsdcMultiMarket.sol:63–65`, `399–419`, `606–628`; `CometUsdcMultiMarketAdapter.t.sol:94–124`, `663–682`; `AdapterRateRemediation.t.sol:31–63`; `CometPublishedTotals.fork.t.sol`.

---

## Task 2 — Dolomite PPS/Provider APY, Storage Unchanged, Failures, Gate

### Storage layout unchanged

The `Market` struct retains its `lastAPYBps` field (line 155) — the field is present but **never written** in the delta. It sits in storage unmodified, so no slots shift. The new `rateSamples` mapping (`mapping(address => PpsRateLib.Sample) internal rateSamples`, line 592) occupies its own keccak-derived slots; no existing mapping or array is displaced. ✓

### PPS rate reader (ERC4626 path)

`_marketAPYBps()` at lines 599–605 calls `convertToAssets(1e24)` and passes the result to `PpsRateLib.read()`. `PpsRateLib.read()` returns `0` until `PpsRateLib.update()` has been called at least once (guards `s.ts == 0`). `update()` is only called from `pokeAPYSnapshots()` (`onlyRole(PARAM_ROLE)`). An uninitialized market therefore silently scores 0 APY. This is by design (matches the comment "requires keeper/admin attention") but means a freshly added ERC4626 market will not attract deposits until a keeper pokes it.

### Finding T2-1 — `pokeAPYSnapshots()` inconsistent share quantity (non-blocking)

`DolomiteUsdcMultiMarket.sol:446–447`:
```solidity
uint256 pps = IERC4626Like(m.addr).convertToAssets(1e18);          // 1e18 shares
PpsRateLib.update(rateSamples[m.addr], IERC4626Like(m.addr).convertToAssets(1e24));  // 1e24 shares
ppsSnap[m.addr] = PpsSnap({ pps: pps, ts: nowTs });                 // stored at 1e18 denomination
```

`rateSamples` is correctly fed `1e24` (as `PpsRateLib`'s comment requires, to avoid 6-decimal rounding). `ppsSnap` stores the `1e18` value. `ppsSnap` has no on-chain consumers in this delta — no scoring, no gate, no event references it — so this is dead-code inconsistency only. Off-chain tooling reading `ppsSnap` would see a value 1e6× smaller than the rate-computation basis. **Minimally scoped fix**: either remove `ppsSnap` entirely or align its `pps` to `convertToAssets(1e24)`.

### Provider failures and clamps

`_marketAPYBps()` for PoolLike (lines 607–621): provider revert is caught and returns `0`. The overflow guard before the narrowing cast (`if (rpsWad > uint256(type(uint16).max) * 1e14 / 31_536_000) return type(uint16).max`) prevents unsafe downcast. The `unavailable` branch of `_dolomite()` in `AdapterRateRemediation.t.sol:125` sets `rates.setBroken(address(from))`, causing `apyFrom = 0`. The gate then sees `apyTo (1260 bps) > apyFrom (0)`, `grossBenefit = 50e6 × 1260 × 7 / 3_650_000 = 120_821`, `netBenefitBps = 120_821 × 10_000 / 50e6 = 24 ≥ gateMinNetBenefitBps (2)` → gate passes, move executes. ✓

### Benefit gate with PPS (ERC4626 path)

`test_dolomiteOptimizesUsingDistinctObservedPpsRates()`: After `pokeAPYSnapshots()` and a 1-day warp, `from` (2000e6 total) and `to` (1000e6 total) each receive 1e6 interest. `from` adapter position = ~1000.5e6; `to` rate ≈ 2× `from` rate due to smaller base. Optimize correctly identifies `to` as better. `assertGt(moved, 50e6)` passes because `tvl = 1000.5e6` → `minMove = 50.025e6 > 50e6`. ✓

**No blockers in Task 2.** One minor non-blocking finding (T2-1).

---

## Task 3 — Unmocked E2E Review

### Real production state, no mocks

The test header comment states "No mock/etch/store/deal/warp" and the code enforces it:
- `_fundFromRealHolder()` uses `vm.prank(HOLDER)` (not `deal()`); line 292 asserts `totalSupply()` unchanged — no synthetic minting.
- Line 279: `assertEq(HOLDER.code.length, 0)` — confirmed EOA, not contract.
- `vm.makePersistent(market.aavePool)` and `vm.makePersistent(market.aToken)` (lines 133–134) persist the real market contracts between `rollFork` calls; declared as "counterfactual portfolio" state.
- `vm.rollFork()` advances to real historical blocks with canonical Chainlink aggregator data.
- No `vm.mockCall` on any price-sensitive path (the one `vm.mockCall` in the delta is in `LendingStrategyMatrix.fork.t.sol:49`, absent from the E2E test).

### User distinct from governance

Lines 118–120:
```solidity
assertFalse(strategy.hasRole(bytes32(0), user));
assertFalse(strategy.hasRole(keccak256("CORE_ROLE"), user));
assertTrue(core.owner() != user && router.owner() != user);
```
`user = vm.addr(0xB0B)`, deterministic, never granted any role. ✓

### Holder transfer — supply unchanged

`_fundFromRealHolder()` asserts `totalSupply()` before equals after (line 292). Shares are real ERC20 transfer, not mint. ✓

### Actual Uni/Aave

Uniswap V3 router addresses are hardcoded canonical: `0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45` (Arbitrum) / `0x2626664c2603336E57B271c5C0b26F421741e481` (Base). The swap at line 301 uses `exactInput` with `expected * 9900/10000` minimum output. `AaveV3USDCAdapter` initialized with `market.aavePool` / `market.aToken` from `LendingAssetConfig.get()`. ✓

### Two 7-day epochs respecting 10% cap / buffer

Epoch 1: `requestEpochWithdrawal(shares * 950 / 10000)` = 9.5%. Epoch 2: `shares / 20` = 5%. Buffer config (line 243) uses exact published profile `(400, 200, 600, 800, 400, 50)` with no guard relaxation. Line 170 asserts `owed > balanceOf(core)` — second withdrawal provably requires recall from Aave. ✓

### Real Aave interest accrual

Line 177: `assertGt(investedBefore, originalInvestment, "real Aave interest must accrue over the historical interval")` — verifies actual accrual over the rolled period, not a tautology. ✓

### Aave recall

Lines 179–185: `realizeForQueue` loop with `assertLt(epochDeficit, beforeDeficit)` per iteration confirming real funding progress. Line 191: `assertLt(adapter.totalAssets(), investedBefore)`. ✓

### EIP-170

`_new()` (line 64): `assertLe(a.code.length, 24576)` called for every deployed component including `StrategySafetyOverflowModule`. ✓

### Disclosed limitations

- **Counterfactual portfolio / persistent market state**: explicitly disclosed in comment at line 130–131. Real aavePool/aToken state modified by scenario transactions persists between rolls; feed data remains canonical chain history.
- **staticUSD1gas**: `gasCostUSDC = 1e6` (`_candidate()`, line 268) is a static $1 estimate, not computed from L2 gas price. Used as gate input, not validated against actual Arbitrum/Base execution cost.
- **Empty warm sleeve**: `assertLe(strategy.idleCash(), 2)` at line 140. ✓
- **No complete SystemSealer migration**: `core.freezeRouting()` + `freezeParams()` (lines 115–116) is a partial freeze; `isRoutingFrozen()` asserted at line 198 post-recall. Full SystemSealer lifecycle not exercised.

### Finding T3-1 — Buffer comment chain mismatch (minor, non-blocking)

`LendingUnmockedE2E.fork.t.sol:242`:
```solidity
// Exact published shadow profile at Arbitrum block520094008; asset is parameterized.
IBufferManager.BufferConfig memory b = IBufferManager.BufferConfig(400, 200, 600, 800, 400, 50, ...);
```
This comment references Arbitrum block 520094008, but the same `b` object is used by the Base scenario (block 52500000, different epoch lengths). The value is intentionally shared across scenarios, but the comment scopes it to Arbitrum only. **Documentation issue only.**

### No invented APIs, no mocks on hot path, no unsupported broad claims

Every assertion is anchored to observable on-chain state (balances, share counts, deficit values). No oracle is stubbed on the deploy/harvest path. The `registry`/`selector` wiring uses real canonical selectors (line 68: `require(role <= 4, "canonical-selector-required")`).

---

## Task 4 — Safety Module Fixture: Constructor, Setter, Governance Ceiling

### Five-argument constructor

`StrategySafetyOverflowModule.sol:24–28`:
```solidity
constructor(address asset_, address _core, address _paramsModule, address _scoringModule, address _adapterOpsModule)
    StrategyStorageLayout(asset_, _core, _paramsModule, _scoringModule, _adapterOpsModule)
```
Five arguments. Matches `StrategyStorageLayout` constructor signature confirmed at line 665 of that file. ✓

### Settings setter

Both deployment fixtures call:

`LendingUnmockedE2E.fork.t.sol:274`:
```solidity
Settings(address(s)).setSafetyOverflowModule(_new("StrategySafetyOverflowModule.sol:...", abi.encode(market.asset,address(core),p,c,o)));
```

`LendingStrategyMatrix.fork.t.sol:95`:
```solidity
StrategySettingsModule(address(s)).setSafetyOverflowModule(address(new StrategySafetyOverflowModule(asset, core, address(params), address(scoring), address(ops))));
```

Both route through `StrategySettingsModule.setSafetyOverflowModule()` (set-once, `DEFAULT_ADMIN_ROLE`). ✓

### Global governance ceiling binding

`StrategyRebalanceGateModule._checkCapDriftMandate()`, line 385–386:
```solidity
uint256 absCapBpsEff = isSafety ? uint256(sf.absCapBps) : uint256(normalAbsCapBps);
if (normalAbsCapBps > 0 && absCapBpsEff > normalAbsCapBps) absCapBpsEff = normalAbsCapBps;
```
Safety adapters use their dedicated fallback cap (`sf.absCapBps`), but if that cap **exceeds** the governance ceiling (`normalAbsCapBps = adapterMaxExposureBps`), it is clamped down to the governance value. The governance ceiling therefore remains binding for safety adapters. The comment at lines 349–363 explains the design. ✓

### Comments and frozen artifacts

The P0.7 comment block (lines 349–363) is explanatory documentation. `core`/`main`/`live` are not in the delta and remain frozen. ✓

**No blockers in Task 4.**

---

## Consolidated Findings

| ID | Task | Severity | File:Line | Description |
|----|------|----------|-----------|-------------|
| T2-1 | 2 | Minor (non-blocking) | `DolomiteUsdcMultiMarket.sol:446–447` | `ppsSnap` stored at `convertToAssets(1e18)` denomination; `rateSamples` fed `convertToAssets(1e24)`. `ppsSnap` has no on-chain consumers in this delta; off-chain tooling reading it sees a 1e6× smaller value than the rate basis. **Fix**: align `ppsSnap.pps` to `1e24` or remove the field. |
| T3-1 | 3 | Documentation (non-blocking) | `LendingUnmockedE2E.fork.t.sol:242` | Comment "Exact published shadow profile at Arbitrum block520094008" applied to buffer config reused by Base scenario without annotation. **Fix**: note that the same config is intentionally used for all four scenarios. |

**No functional blockers found across all four tasks.** The Comet ABI is exactly matched, the liquidity BPS formula is decimal-independent, the Dolomite PPS reader correctly replaces the never-written `lastAPYBps`, provider failures are handled without bricking healthy markets, the E2E test uses no mocks on price-sensitive paths, and the safety module is installed with the correct five-argument constructor through the Settings setter with governance ceiling binding preserved.
