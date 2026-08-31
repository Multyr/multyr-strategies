# USDC Lending Strategy — Audit PoCs (feature/v10.0-storage-initialize)

Re-audit of `src/strategies/usdc-lending/` on branch `feature/v10.0-storage-initialize`,
followed by fixes for every finding. This is a follow-up to the audit
performed against `main` (`test/strategies/usdc-lending/audit-pocs/`, on
branch `audit-stratergies`) — none of those findings were assumed to still
apply; every one was re-verified against this branch's actual code before
being fixed here.

```
forge test --match-path "test/strategies/usdc-lending/audit-pocs-v10/*" -v   # 88/88 pass
forge test                                                                    # full suite: 2446/2446 pass, 11 pre-existing skips
```

Every PoC below is now a **regression test**: it demonstrates the attack
failing / the invariant holding, with the original vulnerable behavior kept
in the file's doc comment for context. Where the vulnerability required a
contract-level change plus reused/existing infrastructure, a companion test
proves both "the raw unsafe pattern is still unsafe in isolation" (so nobody
reintroduces it) and "the actual fixed flow is safe."

## Findings and fixes

### 1. CRITICAL — Front-runnable `initialize()` across the deploy script (bootstrapper + all 7 adapters)
**Files:** `BootstrapperFrontRun_AdapterHijack.t.sol`, `AdapterInitializeFrontRun_Comet.t.sol`

V10's `Initializable`/`initialize()` pattern (replacing constructor args) is
only as safe as the deployment sequence: `initializer` only blocks a
*second* call, not an unauthorized *first* one. The shipped
`script/DeployUsdcLendingStrategy.s.sol` deployed the bootstrapper and all 7
adapters as `new X(); x.initialize(...)` — two separate on-chain
transactions each, leaving a window where anyone could call `initialize()`
first and take `deployer`/`DEFAULT_ADMIN_ROLE`/`PARAM_ROLE` (and, via the
bootstrapper, register and permanently lock in an arbitrary "trusted"
adapter — `whitelistAdapter()` accepts `BOOTSTRAP_ROLE`).

**Fix:** `script/DeployUsdcLendingStrategy.s.sol` now deploys the bootstrapper
and all 7 adapters via `AdapterFactory.deployAndInit()` (already present
in-repo, previously unused by the script), which bundles CREATE2-deploy and
`initialize()` into a single atomic transaction. A new `AdapterFactory` is
deployed as the first step of Phase 1 and its address is threaded through
`DeploymentResult.adapterFactory`; per-contract CREATE2 salts are derived
from `chainCfg.deploySalt`. Predicted addresses for role pre-grants (e.g. the
vault constructor needs the bootstrapper's future address) now use
`factory.computeAddress(...)` instead of nonce-based `vm.computeCreateAddress(...)`.

Each PoC file keeps its original "Test 1" demonstrating the raw two-step
pattern is still inherently unsafe (it's an OZ `Initializable` contract, not
a proxy — that can't be "fixed" at the contract level alone), and adds a
"Test 2" reproducing the actual fixed script flow and showing the identical
front-run attempt now fails against an already-initialized contract.

---

### 2. HIGH — Unauthenticated `checkGate()` could lock any adapter out of new deposits for up to 30 days
**File:** `UnauthenticatedCheckGate_AdapterLockout.t.sol`

`StrategyRebalanceGateModule.checkGate()` took `enabledAdapters`/`tvl` as
plain calldata and was reachable through the vault's fallback with no access
check. Firing the P0.4 cap-drift-mandate with a spoofed `tvl=1` collapsed the
hard ceiling to ~0, writing `lastRelCapMandateTs[hitAdapter]` for any adapter
with a nonzero position — which `StrategyAllocCalcModule._checkAdapterEligibility()`
then reads to exclude that adapter from all new capital for up to
`mandateRedeployCooldownSeconds` (governance max 30 days), repeatable
indefinitely for free.

**Fix:** `checkGate()` now requires `onlyRoleOrRevert(KEEPER_ROLE)` — its
only legitimate caller (`prepareRebalance()`) was already KEEPER-gated, so
this closes the hole with no legitimate-flow impact.

---

### 3. HIGH — Overlay-parity regression: T1 governance-ceiling fix was applied to only one of two parallel implementations
**File:** `OverlayParityRegression_T1GovernanceCeiling.t.sol`

`StrategyAllocCalcModule._effectiveAbsCapBps()` (the real allocation engine)
had already been fixed to respect a set `adapterMaxExposureBps` governance
ceiling even in the T1 (single-adapter) tier. The parallel, supposedly-
identical public getter `StrategyScoringModule.effectiveAbsCapBps()` still
hard-coded the stale pre-fix `10000` for T1, unconditionally — violating
`docs/invariants.md` I-ALLOC-06 (previously fixed once already as
AUDIT-FINDING-13). The existing `Overlay_Parity.t.sol` regression suite
didn't catch this because two of its own T1 assertions encoded the *stale*
value as correct.

**Fix:** `StrategyScoringModule.effectiveAbsCapBps()`'s T1 branch now
mirrors `StrategyAllocCalcModule` exactly. Also corrected the two
`Overlay_Parity.t.sol` tests that had baked in the stale expectation
(`test_parity_T1_respects_set_global_ceiling`,
`test_AUDIT_FINDING_13_T1_overlays_shortcircuit_but_ceiling_applies_in_both_paths`)
so they now assert the *correct* parity behavior (overlays still
short-circuit in T1; a set ceiling still applies).

---

### 4. HIGH — Missing access control on `StrategyAdapterOpsModule`/`StrategyScoringModule` externals
**File:** `AccessControlBypass_AdapterOpsAndScoring.t.sol` (5 PoCs)

`onlyDelegateCall` (`require(address(this) != _self)`) only rejects a direct
call to the standalone module contract — it never checked `msg.sender`. The
vault's `fallback()` delegatecalls any unrecognized selector to a fixed
module chain for any caller with no access check first, so
`safeAdapterDeposit`, `adapterDeposit`, `recordAdapterFailure`,
`recordAdapterSuccess`, `recordWithdrawGas`, `syncPositionAssets`,
`executeRealizeLiquidity` (`StrategyAdapterOpsModule`) and
`deployIdleToAdapters`, `computeInputsForPlan` (`StrategyScoringModule`)
were all reachable unauthenticated — letting anyone force-quarantine a
healthy adapter for free, bypass `pause()`, desync `positionAssets`
bookkeeping, or force capital out of a yield-bearing position.
`StrategyRebalancePlanModule`'s entry points already had the correct fix
pattern, proving the team knew it — it just wasn't applied to these two
modules.

**Fix:** added a shared `onlyKeeperOrCoreOrRevert` modifier to
`StrategyStorageLayout.sol` (inherited by every delegatecall module) and
applied the correct gate to each entry point — `onlyKeeperOrCoreOrRevert`
where both CORE_ROLE (deposit/withdraw) and KEEPER_ROLE (harvest/deployIdle/
rebalance) paths legitimately call in, `onlyRoleOrRevert(KEEPER_ROLE)` where
only keeper-driven paths do. `msg.sender` is preserved unchanged through the
whole delegatecall chain, so these gates correctly authorize every real
caller without breaking any legitimate flow (verified by the full existing
test suite, 2446/2446 passing).

---

### 5. MEDIUM-HIGH — Dead capacity-jump sanity check (Audit HIGH 1.6)
**File:** `DeadCapacityJumpLimiter.t.sol`

`cachedAdapterCapacity` was declared and read in
`StrategyAllocCalcModule._checkAdapterEligibility()` (to dampen a sudden
`maxCapacity()` swing) but never written anywhere — the guard could never
fire regardless of how wildly an adapter's reported capacity changed.

**Fix:** `StrategyParamsModule.pokeExternalTVL()` (an existing KEEPER_ROLE
poke already looping over enabled adapters) now also polls
`adapter.maxCapacity()` each cycle and writes `cachedAdapterCapacity`,
mirroring the existing `MAX_EXTERNAL_TVL_JUMP_BPS` pattern used for external
TVL, and emitting the previously-unreachable `AdapterCapacityJump`/
`AdapterCapacityDecreased` telemetry.

---

### 6. MEDIUM — Unbounded governance setters
**File:** `UnboundedDustTolerance_NoCashInvariantBypass.t.sol`

`setDustTolerance()` had no upper bound — PARAM_ROLE could set
`dustTolerance = type(uint256).max` and permanently lock it in via
`finalizeParameters()` (itself unvalidated), silently neutralizing the
"idle cash must deploy" NoCashInvariant forever. The same missing-bound
pattern existed on `setMaxIdleAfterDepositBps`, `setMaxIdleBootstrapBps`,
`setDegradedViewThresholdBps`, `setGateParams` (3 of its 5 fields), and
`setHarvestParams`'s `harvestThresholdBps`.

**Fix:** added `ParamOutOfRange` bounds to all of the above
(`dustTolerance <= 100_000e6`; the bps fields `<= 10000`), matching the
pattern every other setter in `StrategySettingsModule.sol` already used.
Updated `UsdcMultiLendingVault.fuzz.t.sol`'s `testFuzz_setGateParams` to
bound its fuzzed inputs accordingly.

---

### 7. HIGH — Comet: one broken sub-market bricked `withdraw()` for every healthy market on the adapter
**File:** `CometAdapter_SingleMarketRevertNoLongerBricksAdapter.t.sol`

`_getAPYBps()` called `IComet.getUtilization()`/`.getSupplyRate()`, and
`_assetsOn()` called `IComet.balanceOf()`, with no try/catch. `_marketsByAPY()`
(used by both `deposit()` and the standard `withdraw()` path) called
`_getAPYBps` on every registered market unconditionally, so one paused/
deprecated Comet market (an ordinary external protocol event, not
attacker-controlled) reverted withdrawal of funds sitting in every other,
perfectly healthy market on the same adapter.

**Fix:** both functions now wrap their external calls in try/catch. A
failing market reports APY=0 / assets=0 instead of reverting — it sorts
last / is skipped by the withdraw loop's `if (can < 1) continue;`.

---

### 8. MEDIUM — Dolomite: same unguarded-external-call pattern in `_score()`
**Source fix only (no dedicated PoC — same pattern as Comet, narrower scope: only affects `deposit()`/`optimize()`, not `withdraw()`).**

`_score()` called `IDolomiteLike.availableLiquidity()` unguarded for
non-ERC4626 markets, reachable from the deposit-routing and rebalance-pair
selection paths. Fixed the same way: wrapped in try/catch, treating a
failing market as zero liquidity (score naturally drops toward 0) instead of
reverting the whole call.

---

### 9. LOW — Morpho: `uint8` loop-counter wraparound trap
**Source fix only (operator-misconfiguration trap, not attacker-reachable under normal operation).**

`getBestMarket()`/`getRebalancePlan()`/`sortMarketsByAPY()` use `uint8` loop
counters against an unbounded market array; a 256th market would wrap the
counter and infinite-loop (OOG). `addMarket()` now reverts once
`mkts.length >= 255`.

---

### 10. MEDIUM — Euler-style PUSH-mode deposit failures stranded funds with no automatic recovery
**Source fix only (no dedicated PoC on this branch — same pattern already demonstrated on `main`'s `audit-pocs/PushModeAdapter_FundStranding.t.sol`).**

For PUSH-mode adapters, `StrategyAdapterOpsModule.safeAdapterDeposit()`
transfers USDC to the adapter *before* calling `deposit()`; if `deposit()`
reverts, that transfer can't be undone, and the funds previously just sat
there until a manual admin sweep (`AdapterFundsStranded` event only).

**Fix:** the failure path now makes a best-effort attempt to immediately
sweep the stranded balance back to the vault
(`IAdapterEmergency(adapter).sweepIdleAssetToVault()`) in the same
transaction. If that also fails, `AdapterFundsStranded` still fires for
off-chain alerting and the manual recovery path remains available — this
is additive resilience, not a claim that non-atomic push-then-deposit is
now fully eliminated.

## Governance-trust-level observation (not changed)

The P0.7 safety-fallback tier's cap ceiling (`addSafetyFallbackAdapter`,
`absCapBps` up to 8000/80%) exceeds the normal per-adapter ceiling
(`setRebalanceParams`, `adapterMaxExposureBps` up to 5000/50%). This is a
deliberate, backtest-validated design choice per the source comments (a
higher-trust "liquidity parking" tier), not a bug — noted here rather than
silently changed, since altering it would be an economic/risk-parameter
decision, not a fix.
