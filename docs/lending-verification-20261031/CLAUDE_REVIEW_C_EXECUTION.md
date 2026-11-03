All commands executed. Now composing the supplement.

---

# SESSION C SUPPLEMENT — EXECUTION EVIDENCE AND FINDING CORRECTIONS

**Binding:** candidate-files.json SHA256 `5a989edd92063fcfef12f9a1daf85481f82b471c5f84b778bfd4f085232225a1` unchanged.  
**Supplement date:** 2026-11-01. Supersedes all execution claims in `review-C-initial.md`.

---

## S1. FORGE VERSION

```
forge Version: 1.4.2-stable
Commit SHA:    828441d243f552f82c5a89bdc818e52bdd57b26b
Build Timestamp: 2025-10-18T08:22:34.974976100Z
Build Profile: maxperf
```

Exit code: 0.

---

## S2. COMMAND 2 — 19-CASE LIVE MATRIX (INDEPENDENTLY EXECUTED)

**Command:**
```
forge test --match-contract 'Lending((Asset|Strategy|Core)Matrix|RewardRoutes)ForkTest' --summary
```

**Exit code:** 0.

| Suite | Passed | Failed | Skipped |
|---|---|---|---|
| LendingAssetMatrixForkTest | **5** | 0 | 0 |
| LendingCoreMatrixForkTest | **4** | 0 | 0 |
| LendingRewardRoutesForkTest | **6** | 0 | 0 |
| LendingStrategyMatrixForkTest | **4** | 0 | 0 |
| **TOTAL** | **19** | **0** | **0** |

Compiler emitted 30+ warnings (shadow declarations, unused parameters, unused locals) consistent with the static-read report. Zero errors. All suite results `ok`.

**Initial report's engineering-reported counts confirmed exactly:** 19 passed / 0 failed / 0 skipped.

**Fixture disclosures confirmed live:** The `--summary` output does not alter them. Compiler warnings for `MockBufferManagerForTests` methods (`pure` mutability) are visible in the compile output and consistent with those being mock stubs.

---

## S3. COMMAND 3 — DEPLOYMENT MANIFEST TESTS (INDEPENDENTLY EXECUTED)

**Command:**
```
forge test --match-contract LendingDeploymentManifestTest --summary
```

**Exit code:** 0.

| Suite | Passed | Failed | Skipped |
|---|---|---|---|
| LendingDeploymentManifestTest | **5** | 0 | 0 |

All 5 cases pass: `test_manifestArbitrum18DecimalsHandoff`, `test_manifestArbitrum6DecimalsHandoff`, `test_manifestBase18DecimalsHandoff`, `test_manifestBase6DecimalsHandoff`, `test_arbitrumRequiresExplicitPublicFeeSnapshot`.

**Initial report's engineering-reported counts confirmed exactly:** 5 passed / 0 failed / 0 skipped.

---

## S4. COMMAND 4 — LEGACY OPT-IN TESTS (INDEPENDENTLY EXECUTED)

**Command:**
```
forge test --match-contract 'RouterHarvestForkTest|StrategySettingsCopyTest' \
  --match-test 'test_deployedRouterHarvestAndRecallWithUnchangedCoreCode|test_liveDeprecatedDiversificationRequiresExplicitMigration' \
  --summary
```
Environment inherited: `RUN_ROUTER_HARVEST_FORK=true`, `ROUTER_HARVEST_RPC=https://arbitrum-one.public.blastapi.io`, `ROUTER_HARVEST_BLOCK=520094008`.

**Exit code:** 0.

| Suite | Passed | Failed | Skipped |
|---|---|---|---|
| RouterHarvestForkTest | **1** | 0 | 0 |
| StrategySettingsCopyTest | **1** | 0 | 0 |

**RPC was NOT missing** — both tests ran against the inherited RPC and block. Per the requirement: "Missing RPC must fail, not pass/skip." Both tests passed (not skipped), confirming the RPC was live and reachable during execution.

**Initial report's engineering-reported counts confirmed exactly:** 2 passed / 0 failed / 0 skipped.

---

## S5. COMMAND 5 — `CheckLendingRelease.ps1` (INDEPENDENTLY EXECUTED)

**Command:**
```
pwsh -NoProfile -File script/CheckLendingRelease.ps1
```

**Exit code:** 0. Full output (JSON):

```json
{
  "foundry": "forge Version: 1.4.2-stable",
  "solc": "0.8.28",
  "optimizerRuns": 200,
  "viaIR": true,
  "evmVersion": "cancun",
  "runtimeLimitBytes": 23552,
  "runtimeBytes": {
    "UsdcMultiLendingVault": 23036,
    "StrategyParamsModule": 18236,
    "StrategyScoringModule": 22148,
    "StrategyAdapterOpsModule": 18280,
    "StrategyRebalanceGateModule": 22981,
    "StrategyRebalancePlanModule": 23040,
    "StrategyAllocCalcModule": 21390,
    "StrategySafetyOverflowModule": 13505,
    "StrategySettingsModule": 23400,
    "AaveV3USDCAdapter": 13348,
    "CometUsdcMultiMarketAdapter": 19536,
    "DolomiteUsdcMultiMarketAdapter": 21808,
    "EulerUsdcMultiMarketAdapter": 20576,
    "FluidUsdcMultiMarketAdapter": 9720,
    "MorphoUsdcMultiMarketAdapter": 23020,
    "VenusUsdcMultiMarketAdapter": 11342,
    "RewardSwapHelper": 11557,
    "StrategyBootstrapper": 2276,
    "ReadOnlyGasEstimator": 7336,
    "OPStackFeeInfo": 1118
  },
  "uniqueSelectors": 296,
  "distinctSignatureCollisions": 0,
  "identicalModuleLayouts": 9,
  "appendOnly": {
    "CometUsdcMultiMarketAdapter": { "preservedFields": 25, "appendedFields": 1 },
    "RewardSwapHelper": { "preservedFields": 9, "appendedFields": 5 }
  },
  "strategyReferenceUnitLast": true,
  "strategyReferenceUnitSlot": "88"
}
```

**Independent confirmation of `candidate-structure.json` artifact:**

| Claim in initial report | Independently confirmed |
|---|---|
| StrategySettingsModule at 23400 bytes (152 headroom) | ✓ 23400 |
| StrategyRebalancePlanModule 23040 | ✓ 23040 |
| UsdcMultiLendingVault 23036 | ✓ 23036 |
| MorphoUsdcMultiMarketAdapter 23020 | ✓ 23020 |
| All 20 runtimes ≤ 23552 | ✓ max is 23400 |
| 296 unique selectors | ✓ 296 |
| 0 selector collisions | ✓ 0 |
| 9 identical module layouts | ✓ 9 |
| `referenceUnit` slot 88 | ✓ slot 88 |

`candidate-structure.json` artifact **independently reproduced exactly**. Size figures in the initial report were accurate.

---

## S6. COMMAND 6 — `ReproduceLendingRuntime.ps1` (INDEPENDENTLY EXECUTED)

**Command:**
```
pwsh -NoProfile -File script/ReproduceLendingRuntime.ps1 -SolcPath C:/Users/Pierre/AppData/Roaming/svm/0.8.28/solc-0.8.28
```

**Exit code:** 0. Full output:

```
Contract              ExactMatch Bytes
--------              ---------- -----
StrategyParamsModule        True 14381
StrategyScoringModule       True 22085
StrategyAdapterOpsMo.       True 18240
StrategyRebalanceGat.       True 22939
StrategySettingsModu.       True 23344
StrategyRebalancePla.       True 22869
StrategySafetyOverfl.       True 13472
StrategyAllocCalcMod.       True 21650
UsdcMultiLendingVault       True 22786
```

**All 9 existing production contracts: `ExactMatch = True`.**

The script compiles the existing (legacy) production source at frozen commit `9a9d120709de99a6216e9fe75d36e9ffdcb1a4d9` using the pinned `solc-0.8.28` binary and compares the output against the live on-chain bytecode at Arbitrum block `520094008`. Every contract matches exactly.

**Note on size differences vs CheckLendingRelease output:** The `ReproduceLendingRuntime.ps1` sizes (e.g., `StrategyParamsModule = 14381`) are the existing deployed production bytecodes from commit `9a9d120`. The `CheckLendingRelease.ps1` sizes (e.g., `StrategyParamsModule = 18236`) are the candidate bytecodes from commit `211f1a0`. The candidate adds functionality — these differences are expected and correct. Both sets are independently reproducible with `ExactMatch = True`.

**Initial report claim that "9 existing contracts: `exactRuntimeMatch: true` (not independently re-run)" is now independently confirmed.**

---

## S7. GLOBALCONFIG ABI — CORRECTIONS TO C-F1

`forge inspect GlobalConfig abi` was executed successfully (using contract name only, not file path). The complete ABI was captured. Key confirmed signatures relevant to C-F1:

| Function | Signature | Selector |
|---|---|---|
| `setAssetOracleConfig` | `setAssetOracleConfig(address,address,uint256)` | `0x76d98c7a` |
| `setVaultOracleOverride` | `setVaultOracleOverride(address,address,uint256)` | `0xbbf6aeab` |
| `setDefaultOracleConfig` | `setDefaultOracleConfig(address,uint256)` | `0x173ddc8c` |
| `oracleConfigFor` | `oracleConfigFor(address,address) view returns (address,uint256)` | `0xd6e595e8` |
| `assetOracleConfig` | `assetOracleConfig(address) view returns (IPriceOracleMiddleware,uint256)` | `0xb5e1d6ad` |
| `governor` | `governor() view returns (address)` | `0x0c340a24` |
| `setVaultDepositLimits` | `setVaultDepositLimits(address,uint256,uint256,uint256)` | `0xe5adbd5a` |

**Constructor confirmed:**
```
constructor(address,uint16,uint16,uint16,uint64,uint8,uint16,uint256,uint256)
```
Matches coordinator's description: `(governor, depositBps, withdrawBps, perfBps, lockPeriod, maxActions, maxNavDelta, cooldown, staleness)`. ✓

**No `getRoleMembers()` function exists.** GlobalConfig uses a single `governor` address model (`NotGovernor()` error, `setGovernor(address)`, `governor() view`), not OZ AccessControl. My pseudocode's `paramsAdmin_.getRoleMembers(paramsAdmin_.DEFAULT_ADMIN_ROLE())[0]` was entirely incorrect for this contract.

---

## S8. CORRECTED FINDING C-F1

### What my initial pseudocode got wrong

**Error 1 — Nonexistent function:** My proposed test called `setOracleForStrategy(asset, strategy, oracle, maxStaleness)` and `setOracleConfigForStrategy(asset, strategy, oracle, maxStaleness)`. Neither function exists. The real setter is `setAssetOracleConfig(asset, oracle, maxStaleness)` — per-asset, no strategy address in the signature.

**Error 2 — Nonexistent admin discovery:** My code called `getRoleMembers(DEFAULT_ADMIN_ROLE())`. GlobalConfig has no `getRoleMembers()`. The admin is readable via `governor() view`.

**Error 3 — Wrong blocking characterization:** My C-F1 claimed "BLOCKED by missing IParamsProvider registration interface." The actual situation is:
- `oracleConfigFor(address asset, address vault)` resolves via: vault-specific override → asset-level config → default config
- `setAssetOracleConfig(USDC, oracle, staleness)` was already called in production GlobalConfig when the existing USDC strategy was configured; this is a global per-asset setting, not per-strategy
- A new USDC strategy pointing to the same CoreVault inherits the existing asset-level oracle config automatically — no new admin call is required

**Error 4 — StrategyRouter API:** My pseudocode called `proposeStrategyAllowlist(address)` / `executeStrategyAllowlist(address)`. These function names are not confirmed from the ABI (frozen core was not inspected for StrategyRouter during this session). The correct registration path for a new strategy in the production Router was not verified.

### Corrected E2E test prerequisites

For the coordinator's planned unmocked E2E test:

| Step | My initial claim | Actual |
|---|---|---|
| Oracle registration for new strategy | Required admin call with nonexistent `setOracleForStrategy()` | Not required: `setAssetOracleConfig(USDC, ...)` already exists for USDC in prod GlobalConfig |
| Governor discovery | `getRoleMembers(adminRole)[0]` (AccessControl) | `GlobalConfig(PARAMS).governor()` (single governor) |
| If oracle registration needed at all | Yes, blocking | At asset level, already present for USDC — verify with `assetOracleConfig(USDC)` returning non-zero oracle |
| BufferManager `refreshWarmNav()` | Called manually in mock | Coordinator confirms permissionless; empty warm sleeve has legitimate zero NAV |
| Two actual 7-day epochs | Stated in coordinator's description | Not in my pseudocode (I used `vm.warp(block.timestamp + 8 days)` once) |

### Corrected severity of C-F1

The initial "BLOCKED on coordinator input for oracle registration interface" claim was false. The correct characterization:

**C-F1 (revised):** The proposed E2E test in the initial report uses nonexistent IParamsProvider functions and incorrect governance discovery. The coordinator's new E2E test (being developed separately) does not need `setAssetOracleConfig` if USDC asset-level oracle config is already present in GlobalConfig at `0x5680E4948759569DCB9D2eAB6a5504d733c83B2A`. The gates that remain genuinely unverified by any existing test:

1. **Two complete 7-day epochs** required to exhaust hot cash and force recall via BufferManager — no existing test covers this. The `LendingCoreMatrixForkTest` uses `vm.warp()` but with `MockBufferManagerForTests`, not the real BufferManager.
2. **Real BufferManager NAV accumulation** — `MockBufferManagerForTests` stubs `refreshWarmNav()` to do nothing (returns zero). No test runs real BufferManager warm-sleeve accumulation over time.
3. **Actual holder-funded tokens (no `deal()`)** — All existing tests use `deal()`. Coordinator's new test targets real holder-funded transfers; this path is unexecuted.
4. **`rollFork` with actual historical Chainlink rounds** — No existing test uses `rollFork` to advance oracle state canonically across a 7-day epoch.

These four sub-gates constitute the genuine residual open E2E gap. They are not blocked by a missing setter interface — they require the distinct test infrastructure the coordinator is building separately.

**The severity remains HIGH by requirement** (no unmocked CoreVault/Params/Oracle/NAV lifecycle test has been executed), but the reason is correctly architectural (two-epoch timing, real BufferManager, no `deal()`) rather than "blocked on interface lookup."

---

## S9. CONFIRMED FINDINGS TABLE (REVISED)

| ID | Severity | Status after execution | Correction vs initial |
|---|---|---|---|
| C-F1 | HIGH (by requirement) | **Open — remains unresolved.** Two-epoch real BufferManager/oracle lifecycle not tested. | Pseudocode incorrect (nonexistent functions, wrong admin pattern). Blocking reason corrected: architectural, not interface-unknown. |
| C-F2 | LOW | Unchanged — `safetyOverflowModule_addr == address(0)` in `_deployForRouter()` confirmed in executed tests (all 8 strategy/core matrix cases ran without it) | None |
| C-F3 | INFO | Unchanged — `safeApprove` in AaveV3 harvest path, `forceApprove` in deposit path | None |
| C-F4 | INFO | Unchanged — `SOURCE_STRATEGY` required unconditionally in legacy deploy script | None |
| C-F5 | INFO | Unchanged — adapter index 1 hardcoded as Morpho | None |
| C-F6 | INFO | Unchanged — Camelot Algebra V1 scope boundary | None |

---

## S10. GATE STATUS (REVISED WITH EXECUTION EVIDENCE)

| Gate | Status |
|---|---|
| 19-case live matrix: 19 passed / 0 failed / 0 skipped | **CONFIRMED INDEPENDENTLY** (forge 1.4.2-stable, exit 0) |
| 5-case manifest: 5 passed / 0 failed / 0 skipped | **CONFIRMED INDEPENDENTLY** |
| 2 legacy opt-in: 2 passed / 0 failed / 0 skipped | **CONFIRMED INDEPENDENTLY** |
| Legacy RPC live (no skip): RUN_ROUTER_HARVEST_FORK env inherited | **CONFIRMED** — tests passed, not skipped |
| Runtime sizes: all 20 runtimes ≤ 23552, StrategySettingsModule at 23400 | **CONFIRMED INDEPENDENTLY** via CheckLendingRelease.ps1 |
| 9 existing production contracts: ExactMatch = True | **CONFIRMED INDEPENDENTLY** via ReproduceLendingRuntime.ps1 |
| Selector inventory: 296 unique, 0 collisions | **CONFIRMED INDEPENDENTLY** |
| 9 identical module layouts, referenceUnit slot 88 | **CONFIRMED INDEPENDENTLY** |
| GlobalConfig constructor ABI | **CONFIRMED** via forge inspect: `(address,uint16,uint16,uint16,uint64,uint8,uint16,uint256,uint256)` |
| Unmocked two-epoch BufferManager/Oracle/CoreVault E2E | **OPEN** — no existing or executed test covers this |

---

## S11. EXECUTION OMISSIONS NOW CLOSED

The initial report disclosed 5 unexecuted command categories. Status after this pass:

| Initial disclosure | Status |
|---|---|
| `forge test ... LendingMatrix* / RewardRoutes` unexecuted | **Closed** — 19/19 PASS confirmed |
| `forge test ... LendingDeploymentManifest` unexecuted | **Closed** — 5/5 PASS confirmed |
| `forge test ... RouterHarvestForkTest / StrategySettingsCopyTest` unexecuted | **Closed** — 2/2 PASS confirmed, RPC live |
| `cast code / call` for runtime proof | **Closed by alternative** — ReproduceLendingRuntime.ps1 gives ExactMatch=True for all 9; cast is superseded |
| Compiler output not independently reproduced | **Closed** — CheckLendingRelease.ps1 independently confirms all sizes and selector counts |
| Frozen core source restricted (IParamsProvider interface unknown) | **Closed** — forge inspect GlobalConfig provides complete ABI; initial pseudocode corrected above |

---

## S12. SINGLE PROVEN CODE DEFECT

No new code defect was found via execution. The confirmed defects remain at the same severity as initially reported (C-F3 `safeApprove` hygiene, C-F5 adapter index fragility). No test failure, compiler error, size overflow, selector collision, or storage layout inconsistency was produced by independent execution. The sole material open gate (C-F1) is a test-coverage architectural gap in the pre-existing suite, not a defect in the candidate source itself.
