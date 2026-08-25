# USDC Lending Strategy — Audit PoCs

Ad-hoc security audit of `src/strategies/usdc-lending/` (independent of the
existing `docs/threat-model.md` / `docs/audit-scope.md` findings, which were
read first and are not re-litigated here). All PoCs below are runnable Foundry
tests, verified passing against the current codebase:

```
forge test --match-path "test/strategies/usdc-lending/audit-pocs/*" -v
```

All 7 new PoC tests pass (plus the 74 pre-existing Comet adapter tests pulled
in by reusing that file's test harness).

## Findings, by severity

### 1. HIGH — Missing access control on delegatecall-module externals, reachable via the vault's fallback dispatcher
**File:** `AccessControlBypass_AdapterOpsAndScoring.t.sol` (3 PoCs)

`StrategyAdapterOpsModule` and `StrategyScoringModule` expose several
`external` functions guarded only by `onlyDelegateCall` — a modifier that
only rejects calling the *standalone module contract* directly
(`address(this) == module`). It does **not** check `msg.sender`, `KEEPER_ROLE`,
`PARAM_ROLE`, or any other authorization. Because
`UsdcMultiLendingVault.fallback()` delegatecalls any unrecognized selector to
these modules for *any* caller, an attacker can call these functions on the
vault directly and have them execute with full effect:

- `StrategyAdapterOpsModule.recordAdapterFailure(address)` — anyone can
  force-quarantine any healthy adapter with zero cost and zero privilege
  (**PoC A**), which can cascade into strategy-wide DegradedMode
  (`MAJORITY_INELIGIBLE`) via `_isDegradedMode()`.
- `StrategyScoringModule.deployIdleToAdapters(uint256,bool)` — bypasses
  *every* guard on the intended `deployIdle()` entry point: `KEEPER_ROLE`,
  `whenNotPaused`, the `depositsDisabled` flag, `_degradedGuard()`, and the
  cooldown/dust threshold. **PoC B** shows it moving vault capital into an
  adapter while the vault is `pause()`d — defeating the emergency circuit
  breaker.
- `StrategyAdapterOpsModule.safeAdapterDeposit(address,uint256)` /
  `adapterDeposit(address,uint256)` — anyone can push real vault USDC into
  any registered adapter, bypassing every allocation cap/gate, while the
  bookkeeping increment (`positionAssets[adapter] += amount`) that normally
  accompanies a deposit is skipped entirely (that logic lives one call frame
  up, in code these entry points bypass). **PoC C** shows real funds moving
  while `positionAssets` never updates — a permissionless NAV/accounting
  desync.
- `recordAdapterSuccess(address)` / `recordWithdrawGas(address,uint256)` are
  similarly open (erase failure history / feed arbitrary values into the gas
  EMA that the P0 rebalance gate relies on) — not exercised in a dedicated
  PoC, same root cause as the above.

**Fix direction:** add `onlyRoleOrRevert(KEEPER_ROLE)` (matching the sibling
functions in `StrategyRebalancePlanModule`) to every externally-dispatchable
function in `StrategyAdapterOpsModule` and to
`StrategyScoringModule.deployIdleToAdapters`/`computeInputsForPlan`, or make
them reachable only via a `require(msg.sender == <trusted module address>)`
cross-module check.

---

### 2. HIGH — Comet adapter: one broken sub-market bricks withdraw() for every other healthy sub-market
**File:** `CometAdapter_SingleMarketRevertBricksAdapter.t.sol`

`CometUsdcMultiMarket._getAPYBps()` calls `IComet.getUtilization()` /
`.getSupplyRate()` with no try/catch. `_marketsByAPY()` (used by both
`deposit()` and the standard `withdraw()` path) calls `_getAPYBps` on *every*
registered market to sort them, with no isolation. If any one registered
Comet market is paused/deprecated (an ordinary Compound III governance
action — not attacker-controlled), `withdraw()` reverts entirely, even for
funds sitting untouched in other, perfectly healthy markets on the same
adapter. The PoC deposits into `comet1`, registers `comet2`, breaks
`comet2`'s view calls, and shows `withdraw()` of the `comet1`-only balance
reverting. Only the admin-gated `emergencyPullAllToVault()` (which does use
try/catch) remains usable.

---

### 3. MEDIUM (HIGH when chained with #1) — PUSH-mode deposit failures strand funds, invisible to every on-chain view
**File:** `PushModeAdapter_FundStranding.t.sol`

`StrategyAdapterOpsModule.safeAdapterDeposit()` pre-transfers USDC to a
PUSH-mode adapter (currently only Euler in production; any adapter reporting
`isPushMode() == true` qualifies) *before* calling `deposit()`. If `deposit()`
reverts for any reason, the transferred USDC cannot be un-sent — it sits at
the adapter, un-recorded in `positionAssets`, and **also excluded from
`totalAssets()`/NAV**, because that reads `adapter.totalAssets()` (protocol
accounting), not the adapter's raw idle balance. Recovery is 100% manual
(`StrategySettingsModule.callAdapterEmergencySweep()`, `DEFAULT_ADMIN_ROLE`
only) — nothing retries or auto-sweeps. Chained with Finding #1, an attacker
can trigger this deliberately and repeatedly via the unauthenticated
`safeAdapterDeposit`/`deployIdleToAdapters` paths, which additionally skip
the eligibility/cap checks that make this rare in normal operation.

---

### 4. MEDIUM-HIGH — The documented "Audit HIGH 1.6" adapter-capacity jump limiter is dead code
**File:** `DeadCapacityJumpLimiter.t.sol`

`StrategyStorageLayout.cachedAdapterCapacity` is declared with the comment
"cached adapter capacity for delta sanity checks" and read inside
`StrategyAllocCalcModule._checkAdapterEligibility()` to halve `headroom` when
an adapter's `maxCapacity()` jumps too far too fast — mirroring the (working)
`MAX_EXTERNAL_TVL_JUMP_BPS` limiter for `cachedExternalTVL`. Unlike that one,
`cachedAdapterCapacity` is **never written anywhere in the codebase**
(grep-verified: declaration + 2 reads, 0 writes), so the guard can never
fire, for any adapter, on any call. The dedicated telemetry events
(`AdapterCapacityJump`, `AdapterCapacityDecreased`) are likewise declared but
never emitted. The PoC drives an adapter's reported `maxCapacity()` from `1`
to `1_000_000_000_000e6` across two scoring passes and shows
`cachedAdapterCapacity` stays `0` throughout, and neither event fires.

---

### 5. MEDIUM — `setDustTolerance` has no upper bound; can permanently neutralize the "NoCashInvariant"
**File:** `UnboundedDustTolerance_NoCashInvariantBypass.t.sol`

Unlike every sibling setter in `StrategySettingsModule.sol` (which all
enforce a `ParamOutOfRange` sanity band), `setDustTolerance(uint256)` accepts
any value from `PARAM_ROLE` with no bound, and `finalizeParameters()`
performs no validation before permanently locking it in. Once set to e.g.
`type(uint256).max`, the "idle capital must deploy or the tx reverts"
invariant (I-ADAPTER-01 in `docs/invariants.md`) becomes permanently
unenforceable on-chain — contradicting the docs' claim that
`finalizeParameters()` verifies it (the real enforcement is an off-chain
deploy-script convention only). PoC 1 shows the value being set and then
permanently locked; PoC 2 shows a full 1M USDC deposit sitting 100% idle,
indefinitely, with the call succeeding silently.

*(Requires PARAM_ROLE — a trusted governance role — to trigger; included
because it is a missing on-chain guardrail around a documented invariant,
with no way to recover post-finalization, not because PARAM_ROLE itself is
assumed malicious.)*

---

## Findings noted but not converted into a standalone PoC

Lower severity / requires already-privileged or non-attacker-controlled
preconditions; documented here for completeness rather than padded with a
near-duplicate PoC of the same underlying pattern as one above:

- **`setRebalanceParams` doesn't bound `_rebalanceMinMoveBps` /
  `_driftToleranceBps` / `_adapterMaxExposureBps` / `_newAdapterRampBps` to
  ≤10000**, contradicting a comment in `StrategyRebalanceGateModule.sol`
  ("adapterMaxExposureBps ≤ 1e4 enforced by setter") — an oversized value
  silently disables the P0.4 cap-drift-mandate forced-rebalance and the
  new-adapter-ramp limiter. Requires `PARAM_ROLE`. Same class as Finding #5.
- **Dolomite adapter**: `_score()` calls `IDolomiteLike.availableLiquidity()`
  unguarded, same pattern as Comet Finding #2 but narrower impact (only
  DoSes new deposits/`optimize()`, not `withdraw()`). Structurally identical
  demonstration to the Comet PoC above.
- **Dolomite rate provider**: `currentAPYBps()` multiplies a keeper-pushed
  rate with no prior clamp (unlike the Aave rate path, which does clamp) —
  a keeper unit-error can hard-revert that market's yield reporting.
  Requires a careless/compromised keeper (accepted trust boundary).
- **Morpho adapter**: `uint8` loop counters against unbounded market-array
  length — wraps into an infinite loop only if `PARAM_ROLE` ever registers
  ≥256 markets. Operator-misconfiguration trap, not attacker-reachable.

## Areas checked with no issues found

Adapter-level `onlyVault`/role gating (all 7 adapters + 2 rate providers),
`StrategyAllocCalcModule` ↔ `StrategyScoringModule` overlay-parity (byte-for-byte
identical, confirmed independently), `_isDegradedMode()` vs
`_checkDegradedModeLocally()` (confirmed identical, not divergent),
`RewardSwapHelper` Uniswap→Camelot fallback slippage protection,
`StrategyBootstrapper` reentrancy/front-run surface, `setRoleAdmin` access
control, rebalance-plan MSB deposit/withdraw encoding, and backoff/DoS bounds
on rebalance-plan invalidation.
