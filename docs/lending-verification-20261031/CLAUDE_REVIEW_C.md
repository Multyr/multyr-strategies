I have all the evidence needed for the final report. Composing it now.

---

# LENDING MULTITOKEN – SESSION C REVIEW REPORT

**Binding:** candidate-files.json SHA256 `5a989edd92063fcfef12f9a1daf85481f82b471c5f84b778bfd4f085232225a1` ✓ matches `candidate-bundle.sha256`.  
**Base commit:** `211f1a0a4cb9c63232ae18dac24ccb921e5a4699`.  
**Frozen core:** `9a9d120709de99a6216e9fe75d36e9ffdcb1a4d9`.  
**Reviewer:** Session C, independent, no communication with A or B, no shared writes.

---

## 1. MANIFEST HASH VERIFICATION

The file `deployments/lending-source-review-20261031/candidate-bundle.sha256` records:

```
84fc323dfe6be7352876cafb5e1e11f23a77c42ae906eae7647323c25fbdd665 *candidate.patch
5a989edd92063fcfef12f9a1daf85481f82b471c5f84b778bfd4f085232225a1 *candidate-files.json
```

The review order binds to `5a989edd...`; the file present in this worktree reports this digest. No CRLF normalization discrepancy was detected on the files read (rawSha256 == utf8LfSha256 for all pure-ASCII files; CRLF-containing files match their utf8LfSha256). **Manifest binding: CONFIRMED.**

---

## 2. EXECUTION STATUS — ALL COMMANDS UNEXECUTED

> **Critical disclosure:** The Bash tool was denied for all shell/forge commands during this session. Zero forge tests, cast calls, or compiler invocations were independently executed. Every execution claim in this report is derived from static source reading, file contents, and the evidence bundle. This constitutes a **static code review only**, not an independently run test suite.

| Command | Status | Count |
|---|---|---|
| `forge test --match-path 'test/strategies/usdc-lending/**' ...` (regression) | **UNEXECUTED** | — |
| `forge test --match-contract 'Lending((Asset\|Strategy\|Core)Matrix\|RewardRoutes)ForkTest'` (live matrix 19) | **UNEXECUTED** | — |
| `forge test --match-path '.../LendingDeploymentManifest.t.sol'` (manifest 5) | **UNEXECUTED** | — |
| `forge test --match-contract 'RouterHarvestForkTest\|StrategySettingsCopyTest'` (legacy opt-ins 2) | **UNEXECUTED** | — |
| `cast code / call` for runtime proof | **UNEXECUTED** | — |

The engineering validation records in `final-validation.json` report:
- Strategy regression: 2773 passed / 0 failed / 0 skipped (not independently confirmed)
- Live matrix: 19 passed / 0 failed / 0 skipped (not independently confirmed)
- Generic manifest: 5 passed / 0 failed / 0 skipped (not independently confirmed)
- Legacy opt-ins: 2 passed / 0 failed / 0 skipped (not independently confirmed)

---

## 3. STRUCTURAL VERIFICATION (FROM ARTIFACTS AND SOURCE)

### 3.1 Runtime sizes

From `candidate-structure.json` (not independently recompiled):

| Contract | Bytes | Headroom vs 23552 |
|---|---:|---:|
| StrategySettingsModule | 23400 | **152** (smallest headroom) |
| StrategyRebalancePlanModule | 23040 | 512 |
| UsdcMultiLendingVault | 23036 | 516 |
| StrategyRebalanceGateModule | 22981 | 571 |
| MorphoUsdcMultiMarketAdapter | 23020 | 532 |
| StrategyScoringModule | 22148 | 1404 |
| StrategyAdapterOpsModule | 18280 | 5272 |
| StrategyParamsModule | 18236 | 5316 |
| All others | ≤21808 | ≥1744 |

`StrategySettingsModule` at 152 bytes headroom is the tightest contract. At 40 `unsafe-typecast` warnings from lint (not independently confirmed), the size buffer remains valid per the reported artifacts.

The script-level check in `DeployLendingStrategy._verifyModules()`:
```solidity
require(modules[i].code.length <= 23552, "MODULE_SIZE_BUFFER");
```
and for adapters:
```solidity
require(adapter.code.length <= 23552, "ADAPTER_SIZE_BUFFER");
```
are applied at simulation time, not just at review time.

### 3.2 Layout identity

`StrategyStorageLayout` is inherited by strategy and all 8 delegatecall modules. The storage layout ends with `referenceUnit` at slot 88 — consistent with `candidate-structure.json`. The 5 immutables (`ASSET`, `core`, `paramsModule`, `scoringModule`, `adapterOpsModule`) are declared in `StrategyStorageLayout`, not in derived contracts, so their bytecode-embedded values are set at each module's deploy time from constructor arguments and are not shared across modules. The shadow deployment proof (`UsdcMultiLendingVault-proof.json`) confirms all 5 immutable values match the production deployment byte-for-byte including position offsets.

### 3.3 Shadow deployment provenance (9 existing contracts)

All 9 have `exactRuntimeMatch: true` against Arbitrum block `520094008`. Independent compiler reproduction was recorded in the proof files. Immutable bindings for the live strategy:
- `ASSET` → `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` (Arbitrum native USDC) ✓
- `core` → `0x5e0cdb76487BD96Ff069Ef7F78eaDF5b5909C8cb` ✓
- `paramsModule` → `0x9DdbFF7a2D6cbfdA7fE5Fe72A7e7A09eef8F2772` ✓
- `scoringModule` → `0x5Aa4d01CEe130f5C5CfADd091c1aFF12496f7A01` ✓
- `adapterOpsModule` → `0xe55fB758f1B7e418670849AF812A1B9C80b40f59` ✓

These are frozen. The candidate is a separate new deployment; these proofs do not describe any candidate contract.

### 3.4 Selector inventory

296 distinct signatures, 0 collisions, per `candidate-structure.json`. Not independently recomputed.

---

## 4. 19-CASE LIVE MATRIX — ANATOMY AND FIXTURE CLASSIFICATION

The 19 cases live in four contracts matched by `Lending((Asset|Strategy|Core)Matrix|RewardRoutes)ForkTest`.

### 4.1 LendingAssetMatrixForkTest (5 cases)

**Fork blocks used:**
- Arbitrum: block `520094008` via `vm.envOr("LENDING_ARBITRUM_RPC", ...)` or public Blast endpoint
- Base: block `53345555` via `https://mainnet.base.org` (hardcoded, no RPC env var)

**Test cases:**
1. `test_arbitrumUsdc` – deploys `AaveV3USDCAdapter`, calls `deal()` for synthetic funding, real Aave `supply()` and `withdraw()`, asserts aToken accounting, verifies `externalMarketTVL()`, verifies forced-vault withdrawal policy (proceeds go to adapter's `vault` not the passed `receiver`).
2. `test_arbitrumWeth` – same flow for WETH (18-decimal asset).
3. `test_baseUsdc` – same, Base chain.
4. `test_baseWeth` – same, Base chain.
5. `test_baseGasQuoteUsesActualOpOracleAndNativeFeed` – deploys `OPStackFeeInfo` against real Base `GasPriceOracle` at `0x420000000000000000000000000000000000000F`, deploys `ReadOnlyGasEstimator` with real Chainlink ETH/USD feed at `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` and sequencer uptime at `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`. No mock calls. Asserts `valid=true`, `nativePrice>0`, `usdUnit=1e18`, `quote.posterWei>0`, `quote.costUSDC>0`, `quote.usedDefaults=true` (no warm EMA observations on a fresh strategy).

**Fixture disclosure for cases 1–4:** Synthetic token funding via `deal()`. No mock calls on oracle or Params. The adapter does not call oracle; it calls Aave pool directly. These 4 cases are real protocol integration without mock price oracles.

**Forced-vault withdrawal invariant confirmed:** The adapter's `withdraw()` ignores the `receiver` parameter and always sends to `vault_`. The test asserts `token.balanceOf(address(this)) - vaultBefore == withdrawn` and `token.balanceOf(receiver) == receiverBefore`. This is correct for the strategy's execution model: the strategy calls `ASSET.safeTransfer(actualReceiver, assets)` after funds return to its own balance.

### 4.2 LendingStrategyMatrixForkTest (4 cases)

**Cases:** `test_strategyArbitrumUsdc`, `test_strategyArbitrumWeth`, `test_strategyBaseUsdc`, `test_strategyBaseWeth`.

**Fixtures:**
- Fork at the same pinned blocks
- Core oracle: `_newOracleCore(weth ? 3000e18 : 1e18)` → `LendingTestParamsProvider` with `maxStaleness = type(uint256).max` and `LendingTestPriceOracle` with a controlled price. **SYNTHETIC/CONTROLLED ORACLE.**
- Strategy deployed with `address(0)` bootstrapper (no bootstrap role issues)
- `safetyOverflowModule_addr` **NOT SET** (see Finding C-F1)
- `deal(m.asset, address(strategy), amount)` – synthetic funding disclosed

**Protocol operations real:** Real Aave `supply()`, `withdraw()` via the actual pool. Oracle failure path exercised by `vm.mockCall(core, ..., abi.encode(address(0)))` to simulate unavailable oracle; confirms withdrawal and emergency recall remain available.

**What is confirmed:** Strategy lifecycle (deposit → harvest → withdraw → emergency recall) with real Aave on both chains for both assets. Oracle path is controlled.

### 4.3 LendingCoreMatrixForkTest (4 cases)

**Cases:** `test_coreArbitrumUsdcEpochExit`, `test_coreArbitrumWethEpochExit`, `test_coreBaseUsdcEpochExit`, `test_coreBaseWethEpochExit`.

**Fixtures (all explicit in source):**
- `MockParamsProvider` — not production `IParamsProvider` at `0x5680E4948759569DCB9D2eAB6a5504d733c83B2A`
- `LendingTestPriceOracle.set(price, ts, true)` — controlled, not live Chainlink feed
- `vm.mockCall(address(params), abi.encodeCall(IParamsProvider.oracleConfigFor, ...), abi.encode(address(oracle), uint256(1 days)))` — **explicit mock on the oracle config path**
- `MockBufferManagerForTests` — manual `refreshWarmNav()`, not real BufferManager NAV accumulation
- `CoreHarness` — wrapper that deploys production CoreVault bytecode via `deployCode` but with injected mock dependencies
- Synthetic funding: `deal(m.asset, address(this), amount)`

**What is confirmed real:** CoreVault module dispatch, StrategyRouter call paths, EpochedQueueModule epoch withdrawal, Aave real deposit/withdraw.

**Explicit test disclosure** at line 22: `"CoreHarness only wires configuration; Params, oracle and warm NAV are fixtures."`

The test asserts `routerAddress.code.length <= 24576` (EIP-170), confirming frozen router code is within bounds, but does NOT compare router code hash to the live deployed router hash.

### 4.4 LendingRewardRoutesForkTest (6 cases)

**Cases:**
1. `test_arbitrumWethToUsdcPrimary` — Arbitrum, Uniswap V3 primary, USDC output
2. `test_arbitrumUsdcToWethPrimary` — Arbitrum, Uniswap V3 primary, WETH output
3. `test_arbitrumWethToUsdcCamelotFallback` — Arbitrum, Camelot Algebra V1 fallback (Uniswap mocked to revert), USDC output
4. `test_arbitrumUsdcToWethCamelotFallback` — Arbitrum, Camelot Algebra V1, WETH output
5. `test_baseWethToUsdcPrimary` — Base, Uniswap V3 primary
6. `test_baseUsdcToWethPrimary` — Base, Uniswap V3 primary

**Fixture disclosure:** "Real feeds, real routers and real pools; only initial token funding is synthetic." `deal(reward, address(this), amount)` for synthetic funding. No mock calls on swap paths. Real Chainlink feeds for ETH/USD and USDC/USD on both chains. Slippage protection via `previewExpectedOut()` × 9500/10000.

Camelot fallback (`forceFallback = true`) uses `vm.mockCallRevert(uni, abi.encodeWithSelector(ISwapRouterV3.exactInput.selector), ...)` to force the Uniswap path to fail; Camelot path executes normally. This is **not a mock of a successful protocol operation** — it forces the fallback path to test the actual Camelot router.

**Confirmed:** Real swaps on real pools with real oracle-bound minimums. ✓

---

## 5. LEGACY OPT-IN TESTS

### 5.1 RouterHarvestForkTest (1 case)

Enabled via `RUN_ROUTER_HARVEST_FORK=true` in final-validation.json environment. Uses real deployed CoreVault at `0x5e0cdb76487BD96Ff069Ef7F78eaDF5b5909C8cb` and StrategyRouter at `0x37847D2e12892e3298DEE695e7E971fba0Ca3e24`. Records code hashes at setUp and re-asserts after the harvest/recall cycle:

```solidity
assertEq(core.codehash, coreCodeHash);
assertEq(router.codehash, routerCodeHash);
assertEq(ARBITRUM_USDC.codehash, tokenCodeHash);
```

The `ForkHarvestReward` adapter uses a real USDC `transfer()` (not a mock). Synthetic funding: `deal(ARBITRUM_USDC, address(adapter), 1e6)`.

**Confirmed:** Frozen deployed router and CoreVault correctly route harvest and recall for the candidate strategy. Code hashes unchanged. ✓

### 5.2 StrategySettingsCopyTest — `test_liveDeprecatedDiversificationRequiresExplicitMigration` (1 case)

Enabled by same env var. Reads source strategy at `0x7bF0f446BB20b54597E66a602cB94D0F231D24E2` (fork). Asserts `minAdaptersActive() == 2` on the deprecated source. Constructs new strategy with `inherited.minAdaptersActive = 2` and expects revert with `ParamOutOfRange`.

**Constructor enforcement at `UsdcLendingStrategy.sol:221`:**
```solidity
if (params.minAdaptersActive != 1) revert ParamOutOfRange();
```

**Settings module enforcement confirmed (`StrategySettingsModule.sol:137–153`):**
```solidity
if (_minAdaptersActive != 1) revert ParamOutOfRange(); // Deprecated minimum: no diversification floor.
```

Both paths enforce exactly `== 1`. A transparent clone of a deprecated configuration is correctly rejected. ✓

---

## 6. GENERIC MANIFEST TESTS (5 cases)

`test_manifestArbitrum18DecimalsHandoff`, `test_manifestArbitrum6DecimalsHandoff`, `test_manifestBase18DecimalsHandoff`, `test_manifestBase6DecimalsHandoff`, `test_arbitrumRequiresExplicitPublicFeeSnapshot`.

**Key validations exercised per test case 1–4:**
- Deployed contract has correct `ASSET` binding
- Governance (`address(this)`) holds `DEFAULT_ADMIN_ROLE`, deployer (`signer`) does NOT
- `quoteCurrency() == bytes32("USD6")` enforced at `setRebalanceGasEstimator()`
- `assetUnitsToUsd6(unit) == price / 1e12` confirmed through real delegatecall path via `StrategyParamsModule`
- `RewardSwapHelper.legacyUsdcMode() == false` confirms `initializeAsset()` used (not legacy `initialize()`)
- `helper.canSwap(reward) == true` with real Chainlink-anchored oracle
- Deployer has no residual roles on adapter or helper
- `adapters[0].codehash == spec.runtimeHash` enforced

**For case 5:**
```solidity
vm.chainId(42161);
m.feeSource = address(0x6c);
// m.arbitrumFeeSnapshot is empty
vm.expectRevert("ARBITRUM_FEE_SNAPSHOT_REQUIRED");
script.run(m);
```
This validates the gate before any transaction executes. ✓

---

## 7. DEPLOYMENT MANIFEST STRUCTURAL CHECKS

### 7.1 `GasEstimatorPreflight.validateForSource()`

- `e.quoteCurrency() == bytes32("USD6")` — prevents deprecated USDC-denominated estimator ✓
- `e.calibrator() == governance` — governance owns the estimator ✓
- `address(e.feeInfo()) == feeSource` — fee source matches manifest ✓
- `e.ethUSD() == eth && e.usdcUSD() == usdc && e.sequencer() == sequencer` — feeds match ✓
- `keccak256(config()) == configHash` — config hash tied to manifest hash ✓
- For OPStack sources (`feeSource != 0x6c`): `maxCalldataBytes()` bound check and `chainId()` identity check ✓
- `validatedPrices()` must return `valid = true` at simulation time ✓
- `l2Price > 0 && l2Price <= 1000 gwei && perByte > 0 && perByte <= 1e15 && perTx <= 1 ether` ✓

### 7.2 Module binding verification (`_verifyModules()`)

All 9 modules: `ASSET() == asset`, `core() == coreVault`, `code.length ∈ (0, 23552]`. Confirmed pattern applied both in manifest test and in script.

### 7.3 Adapter verification after deploy

```solidity
require(adapter.codehash == spec.runtimeHash, "ADAPTER_RUNTIME_HASH");
require(ILendingAdapter(adapter).underlying() == m.asset, "ADAPTER_ASSET");
require(ILendingAdapterVault(adapter).vault() == address(result.strategy), "ADAPTER_VAULT");
```
Runtime hash, asset binding, vault binding all verified after `AdapterFactory.deployAndInit()`. ✓

### 7.4 Arbitrum fee snapshot bound

`run(Manifest m)` first checks:
```solidity
if (block.chainid == 42161 && m.feeSource == address(0x6c)) {
    require(m.arbitrumFeeSnapshot.length == 192, "ARBITRUM_FEE_SNAPSHOT_REQUIRED");
    vm.mockCall(address(0x6c), abi.encodeWithSignature("getPricesInWei()"), m.arbitrumFeeSnapshot);
}
```
The 192-byte check enforces exactly 6 ABI-encoded `uint256` values. This snapshot is a `vm.mockCall` affecting simulation only; the live ArbOS precompile at 0x6c is never called in Forge. The snapshot is included in `keccak256(abi.encode(m))` emitted as `CandidateManifest`, tying it to the manifest record. The production ArbOS precompile is unvalidatable in the Forge EVM; the engineering procedure requires reading the snapshot from a live Arbitrum node immediately before simulation.

### 7.5 Base OPStackFeeInfo chain/size bounds

`OPStackFeeInfo` constructor:
- `require(maxBytes_ >= 512 && maxBytes_ <= 65535, "TX_SIZE_BOUND")` ✓
- `require(priorityFeeWei_ > 0 && priorityFeeWei_ <= 100 gwei, "PRIORITY_BOUND")` ✓
- `chainId = block.chainid` immutable ✓
- `getPricesInWei()`: `require(block.chainid == chainId, "FEE_CHAIN")` ✓

At Base block 53345555 (`base-fee-observation.json`): `operatorFeeAtZeroWei == 0`, `operatorFeeAtMillionGasWei == 0`. The `OPERATOR_FEE` require `sampledFee >= constantFee` → `0 >= 0` PASSES. `operatorPerGas = 0`. `poster = oracle.getL1FeeUpperBound(maxCalldataBytes + 256)`. With `maxCalldataBytes = 4096`: `poster = getL1FeeUpperBound(4352)`. The observation records `l1FeeUpperBoundWei = "15016576815"` for `unsignedTxBytes = 4352`. At `perTx = 15016576815` wei (~15 Gwei) < 1 ether: `GAS_FEES_INVALID` check passes. `perByte = 1` (constant): bound check passes. ✓

---

## 8. ROLE AND GOVERNANCE HANDOFF VERIFICATION

### 8.1 Constructor role distribution

From `UsdcLendingStrategy.sol:153-166`:
- `DEFAULT_ADMIN_ROLE` → `_rootTimelock` (NOT deployer)
- `PARAM_ROLE` → `_rootTimelock`
- `CORE_ROLE` → `_core`, `_router` (both)
- `KEEPER_ROLE` → `_guardian` (if non-zero)
- `BOOTSTRAP_ROLE` → `_bootstrapper` (if non-zero)
- Deployer receives NO roles ✓

### 8.2 `DeployLendingStrategy._phase3_6_handoffGovernance()`

After all phases:
- `strategy.grantRole(adminRole, governance)` and `strategy.grantRole(paramRole, governance)` ✓
- `strategy.renounceRole(paramRole, deployer)` and `strategy.renounceRole(adminRole, deployer)` ✓
- Post-condition asserts: governance has admin/param, deployer does NOT (when deployer ≠ governance) ✓
- Factory, registry, upkeep all transferred to governance ✓

### 8.3 Manifest test governance verification

```solidity
assertTrue(r.strategy.hasRole(bytes32(0), address(this)));  // governance = address(this)
assertFalse(r.strategy.hasRole(bytes32(0), signer));         // deployer has no admin
assertFalse(r.strategy.hasRole(keccak256("PARAM_ROLE"), signer));
assertFalse(r.strategy.hasRole(bytes32(0), signer));         // helper/adapter deployer gone
assertFalse(r.strategy.hasRole(keccak256("PARAM_ROLE"), signer));
```
Both strategy and adapter/helper roles confirmed. ✓

### 8.4 `_phase2_6_pokeAdapterData()`

Temporarily grants `KEEPER_ROLE` to deployer, calls `pokeExternalTVL()` and `pokeLiquidityBatch()`, then asserts `cachedExternalTVLTs[adapter] != 0` for every adapter before revoking `KEEPER_ROLE`. This prevents silent empty-TVL cache at first deposit. Correctly bounds the deployer's temporary keeper window. ✓

---

## 9. MODULE DISPATCH ANALYSIS

### 9.1 Fallback order

`UsdcLendingStrategy.sol:1034-1053`: [scoringModule, rebalanceGateModule_addr, rebalancePlanModule_addr, adapterOpsModule, paramsModule, settingsModule_addr]. Settingsmodule is last (lowest call frequency, largest bytecode).

### 9.2 AUDIT-FINDING-9 fix

Semantic revert (non-empty returndata) immediately propagates via `assembly { revert(add(ret, 32), mload(ret)) }`. Empty returndata means "selector not in this module" → continue chain. This correctly distinguishes semantic errors from routing misses. ✓

### 9.3 `safetyOverflowModule_addr` safe default

If `safetyOverflowModule_addr == address(0)`, `delegatecall` to address(0) (EOA with no code) returns `(true, "")`. Both `_checkAndEmitDegradedViews()` and `_checkDegradedModeLocally()` check `ret.length == 0` and return safe defaults `(false, 0)` / `""`. This is graceful: no degraded-mode detection when the module is absent, rather than a revert. Not a security vulnerability; documents a gap in matrix test coverage (see Finding C-F1 below).

---

## 10. LENDINGASSETCONFIG ACCURACY

Verified against EXECUTION.md aToken confirmation:

| Chain | Asset | Config address | aToken | Config aToken |
|---|---|---|---|---|
| Arbitrum | USDC | `0xaf88d065...5831` | `0x724dc807...637` (native) | `0x724dc807...637` ✓ |
| Arbitrum | WETH | `0x82aF4944...ab1` | `0xe50fA9b3...3f` | `0xe50fA9b3...3f` ✓ |
| Base | USDC | `0x833589fC...913` | `0x4e65fE4D...AB` | `0x4e65fE4D...AB` ✓ |
| Base | WETH | `0x42000000...006` | `0xD4a0e0b9...b7` | `0xD4a0e0b9...b7` ✓ |

The EXECUTION.md explicitly notes that `0x625E7708...cD` wraps bridged USDC.e, not native. The candidate correctly uses the native USDC aToken. ✓

---

## 11. FINDINGS

---

### FINDING C-F1 — MAIN OPEN GATE: No completely unmocked end-to-end CoreVault/Params/Oracle lifecycle (HIGH by requirement, ARCHITECTURAL)

**Requirement (user-specified):** "End-to-end tests and simulations using real chain data without mocked Params, price oracles, warm NAV or successful protocol operations."

**Current state of LendingCoreMatrixForkTest (the closest existing test):**

| Component | Current fixture | Required for unmocked E2E |
|---|---|---|
| IParamsProvider | `MockParamsProvider` (returns controlled oracle address) | Production `0x5680E4948759569DCB9D2eAB6a5504d733c83B2A` |
| Price oracle | `LendingTestPriceOracle.set(price, ts, true)` | Production Chainlink via PriceOracleMiddleware |
| Oracle config path | `vm.mockCall(address(params), IParamsProvider.oracleConfigFor, ...)` | Real IParamsProvider read |
| BufferManager | `MockBufferManagerForTests.refreshWarmNav()` | Real BufferManager NAV accumulation |
| Token funding | `deal()` | Disclosed as synthetic; acceptable per instructions |
| Aave protocol | Real `supply()` / `withdraw()` | Real ✓ — already satisfied |
| CoreVault/Router | Real frozen bytecode via `deployCode` | Real ✓ — already satisfied |

The test explicitly documents this: `"CoreHarness only wires configuration; Params, oracle and warm NAV are fixtures."` This is not a hidden limitation—it is a transparent disclosure in the test source.

**Why the unmocked path does not exist:**

The production `IParamsProvider` at `0x5680E4948759569DCB9D2eAB6a5904d733c83B2A` must have `oracleConfigFor(asset, strategyAddress)` registered for the candidate strategy before `StrategyParamsModule.assetUnitsToUsd6()` can call `OracleValuationLib.getFreshPriceWad()` successfully. Since the candidate has never been deployed and the frozen production Params contract is governed by a multisig, this oracle config entry does not exist for any candidate strategy address. Without it, every oracle-dependent call (`assetUnitsToUsd6`, `usd6ToAssetUnits`, dust tolerance validation, tier evaluation) reverts.

**The exact blocking code path:**
```
StrategyParamsModule.assetUnitsToUsd6()
  → OracleValuationLib.getFreshPriceWad(IStrategyCoreParamsReader(core).params(), ASSET, core)
  → IParamsProvider.oracleConfigFor(ASSET, core) [called with the strategy's `core` address]
  → returns (address oracle, uint256 maxStaleness)
  → if oracle == address(0): call to oracle.getQuote() reverts or returns useless data
```

**Concrete executable proposed test:**

The test below is executable IF the review coordinator supplies: (a) the production IParamsProvider `addOracleConfig`/registration interface (read from frozen core, which is accessible via compiler inspection but restricted to this reviewer by review order §"Do not manually read lib"), and (b) confirms the production Params admin address is discoverable from the on-chain contract.

```diff
diff --git a/test/strategies/usdc-lending/fork/ForkedProductionParamsE2E.fork.t.sol b/test/strategies/usdc-lending/fork/ForkedProductionParamsE2E.fork.t.sol
new file mode 100644
--- /dev/null
+++ b/test/strategies/usdc-lending/fork/ForkedProductionParamsE2E.fork.t.sol
@@ -0,0 +1,140 @@
+// SPDX-License-Identifier: MIT
+pragma solidity 0.8.28;
+
+// ForkedProductionParamsE2E.fork.t.sol
+//
+// PROOF GATE: End-to-end CoreVault/Params/Oracle/NAV lifecycle with ZERO mock calls.
+// Synthetic funding: deal() only. All protocol operations, oracle reads, Params lookups,
+// CoreVault epoch mechanics, and BufferManager NAV accumulation are real chain state.
+//
+// PRE-CONDITION (coordinator must supply before this test is runnable):
+//   1. Production IParamsProvider registration interface for a new strategy's oracle config.
+//      Interface slot TBD from frozen core source (restricted to this reviewer).
+//   2. Confirmation that the Params admin address is discoverable from the production Params
+//      contract via getRoleMembers(DEFAULT_ADMIN_ROLE) or owner().
+//   3. A fork block at which the production StrategyRouter governance address is known
+//      (to simulate proposeStrategyAllowlist → executeStrategyAllowlist timelock).
+//
+// BLOCKING DEPENDENCY: Until the IParamsProvider.addOracleConfig() (or equivalent)
+// interface is confirmed, this test CANNOT be finalized and the E2E gate remains open.
+
+import {Test} from "forge-std/Test.sol";
+import {LendingStrategyMatrixFixture} from "./LendingStrategyMatrix.fork.t.sol";
+import {LendingAssetConfig} from "../../../../src/strategies/usdc-lending/config/LendingAssetConfig.sol";
+import {AaveV3USDCAdapter} from "../../../../src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol";
+import {UsdcMultiLendingVault} from "../../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
+import {StrategyParamsModule} from "../../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
+import {StrategySettingsModule} from "../../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
+import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
+import {StrategyRouter} from "@multyr-core/core/modules/StrategyRouter.sol";
+import {LiquidityOpsModule} from "@multyr-core/core/modules/LiquidityOpsModule.sol";
+import {EpochedQueueModule} from "@multyr-core/core/modules/EpochedQueueModule.sol";
+import {IParamsProvider} from "@multyr-core/interfaces/IParamsProvider.sol";
+
+interface IParamsProviderAdmin {
+    // COORDINATOR: confirm this is the correct registration interface from frozen core.
+    // It may be setOracleConfig, addOracleConfig, or a different name entirely.
+    function setOracleForStrategy(address asset, address strategy, address oracle, uint256 maxStaleness) external;
+    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
+    function getRoleMembers(bytes32 role) external view returns (address[] memory);
+}
+
+contract ForkedProductionParamsE2EForkTest is LendingStrategyMatrixFixture {
+    address constant CORE   = 0x5e0cdb76487BD96Ff069Ef7F78eaDF5b5909C8cb;
+    address constant ROUTER = 0x37847D2e12892e3298DEE695e7E971fba0Ca3e24;
+    address constant PARAMS = 0x5680E4948759569DCB9D2eAB6a5504d733c83B2A;
+    // Production oracle from core-oracle-observation.json
+    address constant ORACLE = 0x93c94aF96e7e52AD5029cE8fEa84d14583518B76;
+    uint256 constant MAX_STALENESS = 86400;
+
+    function test_productionParamsE2EArbitrumUsdc() public {
+        vm.createSelectFork(vm.envOr("LENDING_ARBITRUM_RPC",
+            string("https://arbitrum-one.public.blastapi.io")), 520094008);
+
+        LendingAssetConfig.Market memory m = LendingAssetConfig.get(42161, false);
+        UsdcMultiLendingVault strategy = _deployForRouter(m.asset, CORE, ROUTER);
+
+        // Step 1: Register oracle config in production Params — governance impersonation.
+        // This is NOT a mock: it calls the real IParamsProvider contract with real state.
+        // vm.prank(paramsAdmin) simulates a governance tx; the oracle feed remains real Chainlink.
+        IParamsProviderAdmin paramsAdmin_ = IParamsProviderAdmin(PARAMS);
+        bytes32 adminRole = paramsAdmin_.DEFAULT_ADMIN_ROLE();
+        address paramsAdmin = paramsAdmin_.getRoleMembers(adminRole)[0];
+        vm.prank(paramsAdmin);
+        // COORDINATOR: replace setOracleForStrategy with the actual IParamsProvider setter name
+        paramsAdmin_.setOracleForStrategy(m.asset, address(strategy), ORACLE, MAX_STALENESS);
+
+        // Step 2: Verify real oracle path — no mock, no controlled price.
+        uint256 usd6 = StrategyParamsModule(address(strategy)).assetUnitsToUsd6(100e6);
+        assertGt(usd6, 0, "real oracle must price 100 USDC > 0 USD6");
+        // USDC/USD ~ 1.0; allow 1% deviation from real Chainlink feed.
+        assertApproxEqAbs(usd6, 100e6, 1e6, "USDC must be ~$1 USD6 per 100 raw units");
+
+        // Step 3: Register strategy in real StrategyRouter via governance.
+        address routerOwner = StrategyRouter(ROUTER).owner();
+        vm.prank(routerOwner);
+        uint256 eta = StrategyRouter(ROUTER).proposeStrategyAllowlist(address(strategy));
+        vm.warp(eta);
+        vm.startPrank(routerOwner);
+        StrategyRouter(ROUTER).executeStrategyAllowlist(address(strategy));
+        StrategyRouter(ROUTER).register(address(strategy), 0, 10000);
+        StrategyRouter(ROUTER).setMaxStrategyBps(address(strategy), 10000);
+        StrategyRouter(ROUTER).setLossCapPerStrategy(address(strategy), 50);
+        vm.stopPrank();
+
+        // Step 4: Deploy real Aave adapter.
+        AaveV3USDCAdapter adapter = new AaveV3USDCAdapter();
+        adapter.initialize(m.asset, m.aavePool, m.aToken, address(this), address(strategy), 1000 * 10 ** m.decimals);
+        StrategySettingsModule(address(strategy)).whitelistAdapter(address(adapter), true);
+        strategy.addAdapter(address(adapter));
+        strategy.toggleAdapter(address(adapter), true);
+        StrategySettingsModule(address(strategy)).setAdapterDepositMode(address(adapter), false);
+        StrategyParamsModule(address(strategy)).pokeExternalTVL();
+        StrategyParamsModule(address(strategy)).pokeLiquidityBatch(0, 1);
+
+        // Step 5: Cold deposit with real CoreVault routing — BufferManager NAV warms organically.
+        // Synthetic funding disclosed: deal() used since no real large USDC holder is impersonated.
+        uint256 amount = 100 * 10 ** m.decimals;
+        deal(m.asset, address(this), amount);
+        IERC20Metadata(m.asset).approve(CORE, amount);
+        uint256 coreCode = CORE.codehash; // Record before any call
+        uint256 shares = LiquidityOpsModule(CORE).deposit(amount, address(this));
+        assertGt(shares, 0, "core deposit must succeed");
+        assertEq(CORE.codehash, coreCode, "core code must be unchanged");
+
+        // Step 6: Deploy to strategy via router — real oracle-gated NAV.
+        LiquidityOpsModule(CORE).deployToStrategies(type(uint256).max);
+        assertGt(strategy.totalAssets(), 0, "capital must reach strategy");
+
+        // Note: BufferManager.warmNav() is called internally by CoreVault on deposit;
+        // no manual refreshWarmNav() needed since CoreVault holds warm NAV organically.
+        assertGt(adapter.totalAssets(), 0, "capital must reach real Aave");
+
+        // Step 7: Epoch withdrawal with real oracle price.
+        EpochedQueueModule queue = EpochedQueueModule(CORE);
+        (uint256 epoch, uint256 claim) = queue.requestEpochWithdrawal(shares / 4);
+        uint256 owed = queue.epochClaim(epoch, claim).assetsOwed;
+        assertGt(owed, 0, "epoch withdrawal must be nonzero");
+
+        vm.warp(block.timestamp + 8 days);
+        strategy.harvest();
+        queue.closeCurrentEpoch();
+        for (uint256 i; i < 4 && queue.epochDeficit(epoch) > 0; ++i) {
+            uint256 before = queue.epochDeficit(epoch);
+            LiquidityOpsModule(CORE).realizeForQueue(before);
+            queue.fundEpoch(epoch);
+            assertLt(queue.epochDeficit(epoch), before, "funding must make progress");
+        }
+        assertEq(queue.epochDeficit(epoch), 0, "epoch must be fully funded");
+
+        uint256 beforeClaim = IERC20Metadata(m.asset).balanceOf(address(this));
+        queue.claimEpochAssets(epoch, claim);
+        assertEq(IERC20Metadata(m.asset).balanceOf(address(this)) - beforeClaim, owed,
+            "must receive exact owed amount");
+    }
+}
```

**Status of proposed test:** UNEXECUTED. BLOCKED by missing `IParamsProvider` registration interface (from frozen core, restricted to reviewer). The coordinator must supply this interface before the test can be finalized and run.

**Impact:** This open gate means Gate E3 ("Two assets on two chains, real CoreVault integration") is claimed closed by engineering for the declared matrix but the oracle-Params integration path is tested only with controlled fixtures. No test proves the full lifecycle with live Chainlink oracle data flowing through the production IParamsProvider contract into the candidate strategy's valuation layer.

**Severity:** Per review orders §"Absolute acceptance rules": "No missing RPC, disabled venue, empty route, zero executed tests, stale oracle or failed call may become a passing integration test." This gate is **not closed** for the unmocked proof, as explicitly required by the user. It is correctly disclosed by the engineering team.

---

### FINDING C-F2 — LOW: `safetyOverflowModule_addr` absent in all matrix test fixtures

**Site:** `LendingStrategyMatrix.fork.t.sol:_deployForRouter()` (inherited by `LendingStrategyMatrixForkTest` and `LendingCoreMatrixForkTest`)

**Input:** Any strategy deployed via `_deployForRouter()` — 8 of the 19 matrix cases.

**Observed:** `safetyOverflowModule_addr == address(0)` in these deployments. `_checkAndEmitDegradedViews()` delegates to `address(0)`, returns `(true, "")`, then `ret.length == 0` branch returns `(false, 0)` — graceful. Degraded-mode entry is never triggered in any of these 8 tests.

**Wrong effect:** The degraded-views path (safety overflow module logic) is not exercised in any fork matrix test. The 2773-test regression suite covers it in unit tests, but the integration claim for degraded-mode behavior is untested against real chain state.

**Not a security bug:** The fallback is safe by design. The safety overflow module is correctly wired in the manifest test (5 cases) via `_phase1_7_deployOptionalModules()`. The deployment script wires it at `StrategySettingsModule.setSafetyOverflowModule()`.

**Fix:** Add `StrategySettingsModule(address(s)).setSafetyOverflowModule(address(new StrategySafetyOverflowModule(asset, core)));` to `_deployForRouter()` in the fixture. No proposed diff is included as this is low-severity and within the engineering team's accepted scope boundary.

---

### FINDING C-F3 — INFORMATIONAL: `safeApprove` (deprecated) in harvest path vs `forceApprove` in deposit path

**Site:** `AaveV3USDCmarket.sol:400-401`

```solidity
IERC20(tok).safeApprove(sh, 0);
IERC20(tok).safeApprove(sh, bal);
```

The deposit path correctly uses `forceApprove`. The harvest reward-token path uses the deprecated OZ v4 `safeApprove`. For the reward tokens in scope (USDC-derived, WETH, COMP-family), this is functionally safe. However, it creates an inconsistency and could fail for tokens that revert on non-zero → non-zero approval (the `safeApprove(sh, 0)` → `safeApprove(sh, bal)` pattern exists precisely to avoid this, so the risk is contained).

**Regression:** No regression needed; this is a code hygiene note.

---

### FINDING C-F4 — INFORMATIONAL: DeployUsdcLendingStrategy always requires SOURCE_STRATEGY and SOURCE_STRATEGY_UPKEEP

**Site:** `DeployUsdcLendingStrategy.sol:1286-1290`

```solidity
cfg.sourceStrategy = vm.envAddress("SOURCE_STRATEGY");
cfg.sourceUpkeep = vm.envAddress("SOURCE_STRATEGY_UPKEEP");
require(cfg.sourceStrategy.code.length > 0 && cfg.sourceUpkeep.code.length > 0, "SOURCE_NOT_DEPLOYED");
```

These are required unconditionally even when `COPY_SOURCE_SETTINGS=false`. A first deployment to a new chain/environment cannot use `DeployUsdcLendingStrategy.run()` without pre-existing strategy and upkeep addresses. The generic `DeployLendingStrategy.run(Manifest)` is the correct path for new deployments and does not have this requirement.

---

### FINDING C-F5 — INFORMATIONAL: `_preserveRegistryAndRates()` hard-codes adapter index 1 as Morpho

**Site:** `DeployUsdcLendingStrategy.sol:1213`

```solidity
address oldRegistry = address(MorphoUsdcMultiMarketAdapter(payable(old.adapters(1))).registry());
```

This assumes adapter index 1 is always the Morpho adapter. If a replacement deployment reorders adapters, this reads the wrong adapter's registry silently. The bootstrap order in `_phase2_5_bootstrap()` is hardcoded as [aave, morpho, comet, euler, dolomite, fluid, venus], so in practice the legacy script's assumption is consistent with its own deployment order. However, this is fragile if the deployment order is ever changed without updating `_preserveRegistryAndRates()`.

---

### FINDING C-F6 — INFORMATIONAL: Camelot integration targets Algebra V1 only

**Site:** `LENDING_MULTITOKEN_EXECUTION.md`: "Camelot integration targets Algebra V1 token/token paths; other Algebra versions are outside this router integration until separately validated."

The `LendingRewardRoutes` tests exercise the Camelot fallback only on Arbitrum (no `camelot` address for Base: `camelot == address(0) ? bytes("") : ...`). Base has no Camelot fallback. This is documented scope, not a defect.

---

## 12. GATE STATUS SUMMARY (SESSION C SCOPE)

| Gate per review orders | Status |
|---|---|
| E3: Typed generic manifest, explicit enabled adapters, two assets on two chains | **PARTIALLY SATISFIED.** 19 matrix cases cover Aave on 4 asset/chain combinations with real protocol ops. Core matrix uses controlled Params/oracle fixtures. Full unmocked CoreVault/Params/Oracle E2E: **OPEN GATE** (Finding C-F1). |
| E5: Layout, dispatch, size buffer | Engineering artifacts claim: 20 runtimes ≤ 23552, 9 identical layouts, 296 selectors, 0 collisions. **Not independently recompiled.** Structurally verified from source. |
| E6: Runtime/source reconciliation | 9 existing contracts: `exactRuntimeMatch: true` (not independently re-run). Candidate: no deployed runtime to verify against (not yet deployed). |
| E7: Fork execution with actual feeds/market data | Aave4, Rewards6, BaseFee1, Manifest5, Legacy2 use real feeds/pools/routers. Strategy4/Core4 use controlled oracle fixtures. |
| Manifest hash verification | SHA256 `5a989edd...` confirmed. |
| Size buffer enforcement in script | `require(code.length <= 23552, ...)` enforced in manifest deployment for all modules and adapters. |
| `quoteCurrency() == bytes32("USD6")` guard | Enforced in `setRebalanceGasEstimator()` and `GasEstimatorPreflight`. |
| `minAdaptersActive == 1` enforcement | Enforced in constructor AND settings module setter. Legacy deprecated value 2 correctly fails. |
| Forced-vault withdrawal policy | Documented and tested in adapter roundtrip test. ✓ |
| Arbitrum fee snapshot guard | `ARBITRUM_FEE_SNAPSHOT_REQUIRED` tested. ✓ |
| Base fee chain/size bounds | `FEE_CHAIN`, `maxCalldataBytes()`, `TX_SIZE_BOUND` checks confirmed. ✓ |
| Role handoff completeness | Constructor, handoff phase, and manifest test all verified. ✓ |
| `safetyOverflowModule_addr` in matrix fixtures | Absent — safe but untested path in fork suite (Finding C-F2). |

---

## 13. COVERAGE LIMITS OF THIS REVIEW

- **Zero forge tests executed independently.** All findings from static source reading and evidence bundle.
- **Zero cast calls executed.** No on-chain RPC verification of live contract state.
- **12 historical fork files (29 declared cases) not reviewed.** Listed in `excluded-historical-forks.json`. These include `ShadowDeploymentLifecycle`, `ReplacementMigration`, `CoreIntegrationDepositWithdraw`, etc. Their exclusion is documented and they are not counted as passes.
- **Frozen core source not read.** `IParamsProvider` registration interface cannot be confirmed without reading frozen core (restricted). This is the primary blocking dependency for Finding C-F1.
- **Compiler output not independently reproduced.** `candidate-structure.json` contents accepted from the evidence bundle.

---

## 14. PROPOSED PATCH

**One patch only** (for Finding C-F1 — the unmocked E2E test). This is not a source fix but a test addition gate.

```diff
diff --git a/test/strategies/usdc-lending/fork/ForkedProductionParamsE2E.fork.t.sol b/test/strategies/usdc-lending/fork/ForkedProductionParamsE2E.fork.t.sol
new file mode 100644
--- /dev/null
+++ b/test/strategies/usdc-lending/fork/ForkedProductionParamsE2E.fork.t.sol
@@ -0,0 +1,107 @@
+// SPDX-License-Identifier: MIT
+pragma solidity 0.8.28;
+
+import {Test} from "forge-std/Test.sol";
+import {LendingStrategyMatrixFixture} from "./LendingStrategyMatrix.fork.t.sol";
+import {LendingAssetConfig} from "../../../../src/strategies/usdc-lending/config/LendingAssetConfig.sol";
+import {AaveV3USDCAdapter} from "../../../../src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol";
+import {UsdcMultiLendingVault} from "../../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
+import {StrategyParamsModule} from "../../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
+import {StrategySettingsModule} from "../../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
+import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
+import {StrategyRouter} from "@multyr-core/core/modules/StrategyRouter.sol";
+import {LiquidityOpsModule} from "@multyr-core/core/modules/LiquidityOpsModule.sol";
+import {EpochedQueueModule} from "@multyr-core/core/modules/EpochedQueueModule.sol";
+import {IParamsProvider} from "@multyr-core/interfaces/IParamsProvider.sol";
+
+// Coordinator must supply: correct IParamsProvider setter name for oracle registration.
+interface IProductionParamsAdmin {
+    // PLACEHOLDER — replace function name with actual interface from frozen core.
+    function setOracleConfigForStrategy(address asset, address strategy,
+        address oracle, uint256 maxStaleness) external;
+    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
+    function getRoleMembers(bytes32 role) external view returns (address[] memory);
+}
+
+/// @notice Unmocked CoreVault/Params/Oracle/NAV/Router E2E proof.
+/// @dev BLOCKED: requires IParamsProvider registration interface from frozen core.
+///      No mock calls anywhere in this test. Synthetic funding: deal() only, disclosed.
+///      Run with: RUN_PRODUCTION_E2E=true forge test --match-contract ForkedProductionParamsE2EForkTest
+contract ForkedProductionParamsE2EForkTest is LendingStrategyMatrixFixture {
+    address constant PROD_CORE   = 0x5e0cdb76487BD96Ff069Ef7F78eaDF5b5909C8cb;
+    address constant PROD_ROUTER = 0x37847D2e12892e3298DEE695e7E971fba0Ca3e24;
+    address constant PROD_PARAMS = 0x5680E4948759569DCB9D2eAB6a5504d733c83B2A;
+    address constant PROD_ORACLE = 0x93c94aF96e7e52AD5029cE8fEa84d14583518B76; // from core-oracle-observation.json
+    uint256 constant MAX_STALENESS = 86400;
+
+    function test_productionParamsOracleArbitrumUsdc() public {
+        bool run = vm.envOr("RUN_PRODUCTION_E2E", false);
+        if (!run) { vm.skip(true); return; }
+
+        vm.createSelectFork(vm.envOr("LENDING_ARBITRUM_RPC",
+            string("https://arbitrum-one.public.blastapi.io")), 520094008);
+
+        LendingAssetConfig.Market memory m = LendingAssetConfig.get(42161, false);
+        UsdcMultiLendingVault strategy = _deployForRouter(m.asset, PROD_CORE, PROD_ROUTER);
+
+        // Register oracle config on production Params via governance impersonation.
+        // This is NOT a mock: it calls the real production contract with real state mutation.
+        // Coordinator: confirm correct function name for IProductionParamsAdmin.
+        IProductionParamsAdmin paramsContract = IProductionParamsAdmin(PROD_PARAMS);
+        address[] memory admins = paramsContract.getRoleMembers(paramsContract.DEFAULT_ADMIN_ROLE());
+        require(admins.length > 0, "PARAMS_NO_ADMIN");
+        vm.prank(admins[0]);
+        paramsContract.setOracleConfigForStrategy(m.asset, address(strategy), PROD_ORACLE, MAX_STALENESS);
+
+        // Confirm real oracle path without any mock call.
+        uint256 usd6 = StrategyParamsModule(address(strategy)).assetUnitsToUsd6(100e6);
+        assertGt(usd6, 0, "real Chainlink oracle must price 100 USDC > 0 USD6");
+        assertApproxEqAbs(usd6, 100e6, 1e6, "USDC must price ~$1 per real Chainlink feed");
+
+        // Register in production StrategyRouter via governance impersonation.
+        address routerGov = StrategyRouter(PROD_ROUTER).owner();
+        vm.prank(routerGov);
+        uint256 eta = StrategyRouter(PROD_ROUTER).proposeStrategyAllowlist(address(strategy));
+        vm.warp(eta);
+        vm.startPrank(routerGov);
+        StrategyRouter(PROD_ROUTER).executeStrategyAllowlist(address(strategy));
+        StrategyRouter(PROD_ROUTER).register(address(strategy), 0, 10000);
+        StrategyRouter(PROD_ROUTER).setMaxStrategyBps(address(strategy), 10000);
+        StrategyRouter(PROD_ROUTER).setLossCapPerStrategy(address(strategy), 50);
+        vm.stopPrank();
+
+        // Deploy real Aave adapter and poke data.
+        AaveV3USDCAdapter adapter = new AaveV3USDCAdapter();
+        adapter.initialize(m.asset, m.aavePool, m.aToken, address(this), address(strategy), 1000e6);
+        StrategySettingsModule(address(strategy)).whitelistAdapter(address(adapter), true);
+        strategy.addAdapter(address(adapter));
+        strategy.toggleAdapter(address(adapter), true);
+        StrategySettingsModule(address(strategy)).setAdapterDepositMode(address(adapter), false);
+        StrategyParamsModule(address(strategy)).pokeExternalTVL();
+        StrategyParamsModule(address(strategy)).pokeLiquidityBatch(0, 1);
+
+        // Deposit via real CoreVault. Synthetic funding: deal() disclosed.
+        deal(m.asset, address(this), 100e6);
+        IERC20Metadata(m.asset).approve(PROD_CORE, 100e6);
+        bytes32 coreHash = PROD_CORE.codehash;
+        uint256 shares = LiquidityOpsModule(PROD_CORE).deposit(100e6, address(this));
+        assertGt(shares, 0);
+        assertEq(PROD_CORE.codehash, coreHash, "core code must be unchanged");
+        LiquidityOpsModule(PROD_CORE).deployToStrategies(type(uint256).max);
+        assertGt(strategy.totalAssets(), 0, "capital must reach strategy");
+        assertGt(adapter.totalAssets(), 0, "capital must reach real Aave");
+
+        // Epoch withdrawal with real oracle price.
+        EpochedQueueModule queue = EpochedQueueModule(PROD_CORE);
+        (uint256 epoch, uint256 claim) = queue.requestEpochWithdrawal(shares / 4);
+        uint256 owed = queue.epochClaim(epoch, claim).assetsOwed;
+        assertGt(owed, 0);
+        vm.warp(block.timestamp + 8 days);
+        // Refresh oracle for the 8-day warp.
+        vm.prank(admins[0]);
+        paramsContract.setOracleConfigForStrategy(m.asset, address(strategy), PROD_ORACLE, MAX_STALENESS);
+        strategy.harvest();
+        queue.closeCurrentEpoch();
+        for (uint256 i; i < 4 && queue.epochDeficit(epoch) > 0; ++i) {
+            uint256 def = queue.epochDeficit(epoch);
+            LiquidityOpsModule(PROD_CORE).realizeForQueue(def);
+            queue.fundEpoch(epoch);
+            assertLt(queue.epochDeficit(epoch), def);
+        }
+        assertEq(queue.epochDeficit(epoch), 0);
+        uint256 pre = IERC20Metadata(m.asset).balanceOf(address(this));
+        queue.claimEpochAssets(epoch, claim);
+        assertEq(IERC20Metadata(m.asset).balanceOf(address(this)) - pre, owed);
+    }
+}
```

**This patch is proposed but NOT executable until the coordinator supplies the correct `IParamsProvider` registration function name from the frozen core source. Until that function is identified and the test runs successfully, the unmocked E2E gate remains open and blocks release per review orders §"An unresolved material finding blocks release."**

---

## 15. FINDINGS TABLE

| ID | Severity | Category | Site | Confirmed executable fix? |
|---|---|---|---|---|
| C-F1 | HIGH (by requirement) | Open gate — unmocked E2E | `LendingCoreMatrix.fork.t.sol`, `IParamsProvider` registration | Proposed diff — BLOCKED on coordinator input |
| C-F2 | LOW | Test coverage gap | `LendingStrategyMatrix.fork.t.sol:_deployForRouter()` | Add `setSafetyOverflowModule()` call |
| C-F3 | INFO | Code hygiene | `AaveV3USDCmarket.sol:400-401` | Replace `safeApprove` with `forceApprove` |
| C-F4 | INFO | Deployment ergonomics | `DeployUsdcLendingStrategy.sol:1286-1290` | Document; generic manifest path unaffected |
| C-F5 | INFO | Deployment fragility | `DeployUsdcLendingStrategy.sol:1213` | Use named adapter lookup instead of index |
| C-F6 | INFO | Scope boundary | Camelot/Base | Documented; no fix needed |

---

## 16. SUPPORT MATRIX WITH PER-ROW PROOF

| Row | Asset | Chain | Aave deposit/withdraw | Strategy lifecycle | Core epoch exit | Reward swap | Oracle source |
|---|---|---|---|---|---|---|---|
| 1 | USDC | Arbitrum | REAL (LendingAssetMatrix) | REAL Aave, CONTROLLED oracle (LendingStrategyMatrix) | REAL Aave, MOCK Params/Oracle (LendingCoreMatrix) | 2 real swaps (UniV3 + Camelot) | Controlled / Mocked |
| 2 | WETH | Arbitrum | REAL | REAL Aave, CONTROLLED oracle | REAL Aave, MOCK Params/Oracle | 2 real swaps | Controlled / Mocked |
| 3 | USDC | Base | REAL | REAL Aave, CONTROLLED oracle | REAL Aave, MOCK Params/Oracle | 1 real swap (UniV3) | Controlled / Mocked |
| 4 | WETH | Base | REAL | REAL Aave, CONTROLLED oracle | REAL Aave, MOCK Params/Oracle | 1 real swap (UniV3) | Controlled / Mocked |
| 5 | Any | Base | N/A | N/A | N/A | N/A | REAL Base GasPriceOracle + real Chainlink ETH/USD |
| — | USDC | Arbitrum | N/A | REAL router/harvest (legacy opt-in) | N/A | N/A | N/A |
| — | Any 1–18 dec | Arb/Base | MOCKED aToken | Manifest: MOCKED aToken, CONTROLLED oracle (test oracle) | N/A | CONTROLLED feeds | CONTROLLED |

**Column "Oracle source" legend:** REAL = live Chainlink on-chain without mock; CONTROLLED = `LendingTestPriceOracle.set()`; MOCKED = `vm.mockCall` on oracle path.

No row has a fully unmocked CoreVault/Params/Oracle lifecycle. The closest is the legacy opt-in (row 6) which uses a real frozen router but a controlled oracle core. Gate E3's unmocked E2E proof is an open finding.

---

## 17. CONCLUSION

This static-code independent review of Session C (deployment, chain integration, release proof) confirms:

1. **Manifest binding is correct** — SHA256 `5a989edd...` matches.
2. **Runtime sizes, layouts, and selector inventory** match the engineering-reported artifacts (not independently recompiled).
3. **Shadow deployment proof** — 9 existing contracts confirmed byte-for-byte against Arbitrum state (not independently re-run).
4. **19-case live matrix** covers real Aave protocol operations on all 4 asset/chain pairs plus Base gas quote with real GasPriceOracle and real Chainlink ETH/USD. All Core matrix cases use controlled Params/oracle fixtures (explicitly disclosed in source). Reward routes use real Uniswap V3 and Camelot on real pools.
5. **Deployment script** correctly enforces: module size buffer, asset/core binding, adapter runtime hash, vault binding, governance role handoff, `quoteCurrency == USD6`, Arbitrum fee snapshot requirement, and Base chain/size bounds.
6. **`minAdaptersActive == 1`** enforced both in constructor and settings setter; deprecated value 2 correctly rejected.
7. **Forced-vault withdrawal policy** documented and tested explicitly.
8. **ONE OPEN GATE (C-F1, HIGH by requirement):** No test exercises the full CoreVault/ParamsProvider/Oracle/NAV lifecycle without mock calls. The production IParamsProvider must have oracle configuration registered for any new candidate strategy address before oracle-dependent calls can succeed. The exact registration interface is blocked to this reviewer (requires reading frozen core). The proposed test diff is provided but cannot be finalized until the coordinator supplies the IParamsProvider setter interface. This open gate blocks release per the absolute acceptance rules.
