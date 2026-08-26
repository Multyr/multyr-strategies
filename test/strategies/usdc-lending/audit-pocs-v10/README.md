# USDC Lending Strategy — Audit PoCs (feature/v10.0-storage-initialize)

Re-audit of `src/strategies/usdc-lending/` on branch `feature/v10.0-storage-initialize`
(a large V10 rewrite vs `main`: 30 files / ~1,572 insertions changed in the
strategy alone, plus a new `StrategySafetyOverflowModule`, a shared
`StrategyConfigLib`, and a new `AdapterFactory` + multichain config system).
This is a follow-up to the audit performed against `main`
(`test/strategies/usdc-lending/audit-pocs/`, on branch `audit-stratergies`) —
none of those findings were assumed to still apply; every one was re-verified
against this branch's actual current code.

```
forge test --match-path "test/strategies/usdc-lending/audit-pocs-v10/*" -v
```

All 12 PoC tests pass.

## New findings on this branch

### 1. CRITICAL — `StrategyBootstrapper.initialize()` is front-runnable; the shipped deploy script hits the window for all 7 adapters + the bootstrapper
**Files:** `BootstrapperFrontRun_AdapterHijack.t.sol`, `AdapterInitializeFrontRun_Comet.t.sol`

V10 converted every adapter and `StrategyBootstrapper` from constructor-args
to an OpenZeppelin `Initializable` + `initialize()` pattern. `initialize()`'s
`initializer` modifier only prevents a *second* call — it does not check who
calls it *first*. `StrategyBootstrapper.initialize(address,address)` takes
`deployer_` as a plain, caller-supplied parameter (no longer captured from
`msg.sender` in an immutable constructor as in the pre-V10 design).

The codebase already contains the correct fix for this exact class of bug —
`src/strategies/usdc-lending/factory/AdapterFactory.sol` bundles CREATE2
deploy + initialize into one atomic transaction, explicitly "to eliminate the
front-run window between deploy and initialize" (its own docstring). But
**`script/DeployUsdcLendingStrategy.s.sol`, the actual deployment script, does
not use it** — for the bootstrapper (lines 291-292) or any of the 7 adapters
(lines 341, 346-347, 352-353, 364-365, 379-380, 385-386, 391-392), it does
`new X(); x.initialize(...)` as two separate top-level calls, which `forge
script --broadcast` submits as two separate on-chain transactions.

- `BootstrapperFrontRun_AdapterHijack.t.sol` reproduces the two-transaction
  sequence exactly and shows an attacker's `initialize(strategy, attacker)`
  landing first: the attacker becomes `deployer`, the legitimate operator's
  own `initialize()` call reverts, and the attacker — now the only address
  that can call `bootstrap()` — registers an attacker-chosen adapter as a
  trusted, enabled strategy adapter and permanently renounces
  `BOOTSTRAP_ROLE`, locking legitimate governance out of this one-shot path
  forever. (`whitelistAdapter()` accepts `BOOTSTRAP_ROLE`, confirmed at
  `StrategySettingsModule.sol:426-434`, specifically so the bootstrapper can
  self-whitelist — that's what makes the hijack possible, not just a DoS.)
- `AdapterInitializeFrontRun_Comet.t.sol` shows the identical pattern against
  a real lending adapter (`CometUsdcMultiMarketAdapter`): an attacker who
  front-runs `initialize()` takes `DEFAULT_ADMIN_ROLE` + `PARAM_ROLE` on that
  specific, deterministically-addressed adapter contract and points its
  `onlyVault` gate at themselves, permanently bricking that market's
  deployment (the operator's own `initialize()` call then reverts). The same
  applies to Aave, Morpho, Euler, Dolomite, Fluid, and Venus — all 7 use the
  identical two-step deploy pattern in the shipped script.

**Fix direction:** route every `new X(); x.initialize(...)` pair in
`DeployUsdcLendingStrategy.s.sol` through `AdapterFactory.deployAndInit()`
(or an equivalent atomic pattern for the bootstrapper), which already exists
in-repo for exactly this purpose.

---

### 2. HIGH — `StrategyRebalanceGateModule.checkGate()` is unauthenticated and lets anyone lock a chosen adapter out of new deposits for up to 30 days, repeatably
**File:** `UnauthenticatedCheckGate_AdapterLockout.t.sol`

`checkGate(uint16[],address[],uint256[],uint256,uint256)` takes
`enabledAdapters` and `tvl` as plain calldata, guarded only by
`onlyDelegateCall` (blocks direct-to-module calls, not fallback-relayed
ones), and is reachable through `UsdcLendingStrategy.fallback()` with no
access check. New in this branch, the P0.4 cap-drift-mandate firing (with
`emitOnMandate=true`) now **writes state**:
`lastRelCapMandateTs[hitAdapter] = block.timestamp`
(`StrategyRebalanceGateModule.sol:145-153`), which
`StrategyAllocCalcModule._checkAdapterEligibility()`
(`StrategyAllocCalcModule.sol:361-370`) reads to make that adapter fully
ineligible for any new deposit while
`block.timestamp < lastTs + mandateRedeployCooldownSeconds` (governance
config, max 30 days).

By spoofing `tvl=1`, the hard-ceiling check collapses to `positionAssets[a] > 0`
— true for any adapter with a real, healthy position — so an attacker can
trigger this at will, for free, against any adapter, and simply repeat the
call before each cooldown expires to make the lockout indefinite. `canRebalance()`
correctly passes `emitOnMandate=false` on its STATICCALL path specifically to
avoid unwanted state writes — proving the team was aware writes here are
sensitive, but `checkGate` itself was left open to any caller.

---

### 3. HIGH — Overlay-parity regression: the F-SCORING-INV2 governance-ceiling fix landed in `StrategyAllocCalcModule` but not the parallel copy in `StrategyScoringModule`
**File:** `OverlayParityRegression_T1GovernanceCeiling.t.sol`

`docs/invariants.md` I-ALLOC-06 requires
`StrategyAllocCalcModule._effectiveAbsCapBps()` and
`StrategyScoringModule.effectiveAbsCapBps()` (the public getter) to return
byte-identical results — this exact class of divergence was previously fixed
once as AUDIT-FINDING-13. This branch fixed a bug in the T1 (single-adapter)
tier: `AllocCalcModule` now respects the `adapterMaxExposureBps` emergency
governance ceiling even at `dMax==1` (`StrategyAllocCalcModule.sol:486-489`,
tagged "Fix: F-SCORING-INV2"). `ScoringModule.effectiveAbsCapBps()`
(`StrategyScoringModule.sol:254-256`) still hard-codes the stale pre-fix
value `10000` for `dMax==1`, unconditionally.

The PoC deposits into a single T1-tier adapter with a 30% emergency ceiling
active and shows the real engine enforcing ≤30% while the public getter still
reports 10000 (100%, unconstrained) for the same adapter/state. The existing
`Overlay_Parity.t.sol` regression test (`"T1 ignores global ceiling"`) still
passes because it asserts the *stale* value as correct, so this ships
silently.

---

### 4. HIGH — Confirmed STILL PRESENT, larger blast radius: missing access control on `StrategyAdapterOpsModule`/`StrategyScoringModule` externals
**File:** `AccessControlBypass_AdapterOpsAndScoring.t.sol` (5 PoCs)

The exact `main`-branch finding (`onlyDelegateCall` mistaken for an
access-control gate; `fallback()` still performs zero access check before
dispatch) is unchanged. `StrategyRebalancePlanModule`'s entry points *do*
carry the correct `onlyRoleOrRevert(KEEPER_ROLE)` fix, proving the team knows
the pattern — it just was never applied to the two modules the original
finding named. This branch also *widened* the exposed surface: two more
unprotected functions now exist because logic that used to live directly in
the vault moved into `StrategyAdapterOpsModule`:

- **PoC D (new):** `executeRealizeLiquidity(uint256)` — the vault's
  `realizeLiquidity()` wrapper is correctly `onlyKeeperOrCore`-gated, but its
  entire implementation now lives in this unguarded module function,
  reachable directly. An unprivileged caller can force capital out of any
  yield-bearing position into idle cash at will (griefing: lost yield, forced
  withdrawal friction).
- **PoC E (new):** `syncPositionAssets(bool force)` — reachable directly with
  `force=true`, bypassing the `minSecondsBetweenSync` cooldown that gates
  every other sync path.
- PoCs A/B/C reproduce the original findings unchanged: permissionless forced
  quarantine via `recordAdapterFailure`, permissionless `deployIdleToAdapters`
  bypassing `pause()`, and permissionless `safeAdapterDeposit` desyncing
  `positionAssets` bookkeeping.

---

### 5. MEDIUM — Confirmed STILL PRESENT, unchanged: dead capacity-jump sanity check
**File:** `DeadCapacityJumpLimiter.t.sol`

`cachedAdapterCapacity` (the Audit HIGH 1.6 mitigation meant to dampen sudden
`maxCapacity()` swings) is still declared and read but never written
anywhere in the codebase — re-verified via grep on this branch. The PoC
drives a mock adapter's `maxCapacity()` from `1` to `1_000_000_000_000e6`
across two scoring passes and confirms the cache stays `0` throughout, with
neither `AdapterCapacityJump` nor `AdapterCapacityDecreased` ever firing.

---

### 6. MEDIUM — Confirmed STILL PRESENT, unchanged: `setDustTolerance` unbounded
**File:** `UnboundedDustTolerance_NoCashInvariantBypass.t.sol`

`setRebalanceParams` gained proper bounds on this branch (`C-03` comment:
`driftToleranceBps ≤ 2000`, `adapterMaxExposureBps ≤ 5000`,
`newAdapterRampBps ≤ 5000`, `rebalanceMinMoveBps ≤ 5000`) — a real, confirmed
fix. `setDustTolerance` was not touched and remains completely unbounded;
`finalizeParameters()` still performs zero validation before permanently
locking parameters. PARAM_ROLE can still set `dustTolerance = type(uint256).max`
and finalize, permanently neutralizing the "idle cash must deploy"
NoCashInvariant.

## Findings noted but not converted into a standalone PoC

- **Comet — one broken sub-market bricks `withdraw()` for all healthy
  sub-markets**: confirmed still present, unchanged logic
  (`CometUsdcMultiMarket.sol` `_getAPYBps()`/`_marketsByAPY()`); this branch's
  diff to that file was purely the constructor→`initialize()` conversion.
  Already demonstrated on `main` in the sibling `audit-pocs/` folder with an
  identical, still-valid PoC pattern — not reproduced here to avoid a
  near-duplicate.
- **Euler PUSH-mode fund stranding**: confirmed still present; this branch
  adds an `AdapterFundsStranded` event on the failure path, acknowledging but
  not fixing the non-atomic transfer-then-deposit. Already demonstrated on
  `main`'s `audit-pocs/PushModeAdapter_FundStranding.t.sol` with an identical
  pattern.
- Several additional unbounded bps setters (`setMaxIdleAfterDepositBps`,
  `setMaxIdleBootstrapBps`, `setDegradedViewThresholdBps`, `setGateParams`,
  `harvestThresholdBps` in `setHarvestParams`) — same class as Finding 6,
  each independently capable of disabling a safety check if set above 10000.
- Safety-fallback tier's cap ceiling (80%, `addSafetyFallbackAdapter`)
  exceeds the normal per-adapter ceiling (50%, `setRebalanceParams`) —
  governance-trust-level inconsistency between the tier's stated "safety"
  intent and its actual (higher) concentration allowance.
- Dolomite `_score()` unguarded external call and Morpho's `uint8` loop
  wraparound trap: both confirmed still present, unchanged, narrow/operational
  scope — same as documented in the `main`-branch audit.

## Areas re-checked with no issues found

`StrategySafetyOverflowModule` reachability (deliberately NOT in the
fallback dispatch array — reachable only via targeted internal delegatecalls,
so the "same bug as AdapterOps" pattern does not recur there), all P0.7
safety-tier setter bounds (correctly enforced), `AdapterFactory.deployAndInit()`
itself (properly atomic, correctly role-gated — the problem is that the
deploy script doesn't use it), `StrategyConfigLib` extraction (faithful,
byte-for-byte), `setRoleAdmin` access control, and the Dolomite rate-provider
unclamped-multiply finding from the `main` audit (could not be reproduced on
either branch — likely a stale finding against an earlier revision).
