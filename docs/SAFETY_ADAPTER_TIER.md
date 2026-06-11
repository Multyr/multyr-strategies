# Safety Adapter Cap Tier (P0.7)

> Audit-grade design specification.
> Implemented in commits `8e846a9..e60d873` on branch
> `feature/p0.7-safety-adapter-tier`.
> Backtest validation: `iter-3b` of the 10-iteration sweep, 2024-01-01 →
> 2026-05-31 (882 days) on real Arbitrum data.

## 1. Definition

A **Safety Adapter Cap Tier** is a governance-approved, second cap layer for
adapters explicitly designated as **liquidity-parking venues**. For adapters in
this tier, two paths of the protocol — the safety-overflow deposit path and the
cap-drift mandate gate — honour an elevated **fallback** absolute/relative cap
instead of the normal `adapterMaxExposureBps` and dynamic relative cap band.

The tier is **not** a cap bypass. The normal scoring path (`_targetAllocations`)
continues to use the regular caps, so opportunistic allocation can never push a
safety adapter above its normal cap by itself. The overflow path is the **only**
deposit channel that can grow the position above the normal cap, and it self-
regulates at `fbCeiling - current` per deposit.

## 2. Why not a bypass

A naive solution to the rotation loop diagnosed during iter-2 of the backtest
sweep would have been to exempt one adapter from the mandate entirely. This was
rejected because:

1. **Cap exemption silently weakens the risk framework.** Other modules that read
   the abs/rel cap (deploy gate, sync logic, off-chain monitoring) would have to
   special-case the exempted adapter or accept inconsistent semantics.
2. **Audit narrative.** An exempted adapter is a single point of governance
   failure: if the exempt set is wrong, there is no second-level constraint.
3. **Backtest evidence.** Iter-3 attempted "exempt-Aave-from-mandate" and the
   loop returned at twice the frequency because the mandate fought the
   overflow path on every adjacent block.

The fallback caps are **explicit, separate governance parameters** stored
per-adapter in `safetyFallback[a]`. They are bounded (`abs ∈ [1, 8000] bps`,
`rel ∈ [0, 10000] bps`) and event-emitting (`SafetyFallbackAdapterAdded`,
`SafetyFallbackCapsUpdated`). The risk framework remains a two-cap system: every
adapter has a normal cap and may additionally have a fallback cap.

## 3. Architectural surface

Five paths on-chain use cap information. The Safety Adapter Cap Tier modifies
the contract behaviour as follows:

| Path                              | Normal adapter           | Safety adapter (e.g. Aave)              |
|-----------------------------------|--------------------------|-----------------------------------------|
| Normal scoring (`_targetAllocations`) | normal abs+rel cap   | **normal** abs+rel cap (NOT fallback)    |
| Deploy idle (`_checkAdapterEligibility`) | normal caps; skip if in mandate cooldown | normal caps; **never in cooldown**       |
| Safety overflow (`_executeSafetyOverflow`) | N/A                | **fbAbsCap + fbRelCap**                  |
| Mandate gate (`_checkCapDriftMandate`) | normal caps; set cooldown ts on hit | **fbAbsCap + fbRelCap**; no cooldown ts  |
| Plan target (preserve safety tranche) | normal logic         | **hold if target < curr ≤ fbCeiling**    |

### 3.1 Preserve Safety Tranche — the critical rule

When a safety adapter's position sits between its normal scoring target and the
fallback ceiling (computed as `min(fbAbsCap × tvl, fbRelCap × extTVL)`), the
plan builder must **hold** the position. The rationale:

```text
target = normal_scoring_target(adapter)          // uses normal caps
if (isSafetyFallback(adapter)) {
    fbCeiling = min(fbAbsCap × tvl, fbRelCap × extTVL)
    if (current > target && current ≤ fbCeiling) {
        target = current   // preserve tranche
    }
}
```

Without this clause, a mandate triggered on Dolomite (a non-safety adapter)
would generate a plan that withdraws from Aave (the safety adapter) too —
because the normal scoring target sits below the current position. The overflow
path would then have to refill Aave the very next deploy tick, defeating the
entire purpose of the tier.

The clause is implemented in `StrategyAllocCalcModule._targetAllocations` and is
verified by unit test `test_D1f_06_valid_safety_tranche_preserved` and property
test `testFuzz_I10_preserve_safety_tranche_no_unwind` (256 fuzz runs).

## 4. Eligibility criteria for safety status

Granting safety status to an adapter is a **governance action**. The criteria
codified for the v9.2 deployment (Arbitrum, USDC Lending) are:

1. **Pool depth.** External TVL ≥ $5M over a rolling 90-day window. Empirically,
   pools below $5M cannot absorb a $1M parking deposit without distorting the
   rate; the backtest enforces a runtime floor of $500K extTVL inside
   `_executeSafetyOverflow` as a belt-and-braces guard.
2. **Mandate history.** ≤ 5 rel-cap mandate hits over the prior 12 months on
   the protocol's own monitoring (measured via the `RelCapMandateCooldownStarted`
   event channel when applicable, plus the legacy `CapDriftMandate` event).
3. **Liquidity readiness.** `cachedLiquidityBps[adapter]` ≥ 8000 (the top tier
   of the liquidity overlay), sustained for 90 days.
4. **Smart-contract risk.** No outstanding audit finding of high or critical
   severity, no public on-chain incident in the last 12 months, and an active
   bug bounty programme on the underlying protocol.
5. **Code path symmetry.** The adapter must implement the full
   `ILendingAdapter` interface including `effectiveAPYBps()` (or the legacy
   `currentAPYBps()` fallback) and must be `whitelistedAdapters[a] == true`.

A safety adapter that subsequently fails any of these criteria over its review
window is recalled by the governance procedure in
[GOVERNANCE_POLICY_TRACK.md](./GOVERNANCE_POLICY_TRACK.md) (GP-10).

## 5. Default Production Configuration (V9.2 — June 2026)

The deployment ships with the **dual-anchor** setpoint ratified after iter-4
of the backtest sweep.

| Parameter                        | Value             | Rationale                                                                                    |
|----------------------------------|-------------------|----------------------------------------------------------------------------------------------|
| `safetyFallbackAdapters`         | [Aave V3, Compound V3] | Two deepest USDC venues on Arbitrum, both > $5B TVL across chains.                          |
| `safetyFallback[Aave].absCapBps` | 5000 (50%)        | Established cap, validated through 882-day iter-3b backtest.                                  |
| `safetyFallback[Aave].relCapBps` | 5000 (50%)        | Symmetric rel cap, consistent ceiling.                                                       |
| `safetyFallback[Compound].absCapBps` | 4000 (40%)    | Conservative initial tier; eligible for elevation to 50% per GP-10 after 6 months operation. |
| `safetyFallback[Compound].relCapBps` | 4000 (40%)    | Symmetric with abs cap.                                                                      |
| `maxIdleBps`                     | 500 (5%)          | Threshold above which idle is routed through the overflow path.                              |
| `targetSafetyMarginBps`          | 300 (3%)          | Buffer applied to cap-binding scoring targets — prevents the post-rebalance loop.            |
| `mandateRedeployCooldownSeconds` | 259_200 (3 days)  | Per-adapter cooldown after mandate hit; safety adapters are exempt.                          |
| `capDriftToleranceBps`           | 250 (2.5%)        | Mandate trigger band (unchanged from P0.4).                                                  |

### 5.1 Why Dual Anchor (Aave + Compound)

In iter-4 of the backtest sweep, adding Compound V3 as a secondary safety
adapter reduced idle drag from 8.28% (single Aave anchor) to ≈5.88% (dual
anchor), improving gross TWR from 5.62% to **≈6.249%** (+62 bps gross). The two
adapters share the safety-venue role with explicit priority ordering: Aave
fills first to its 50% cap, then Compound to its 40% cap. Combined dual-anchor
capacity of ~90% TVL is sufficient to absorb overflow even when 3-4
opportunistic adapters are simultaneously in cooldown.

Compound's initial cap is set conservatively at 40% (vs Aave's 50%) for two
reasons:

- Compound V3 has shorter Arbitrum production history than Aave V3.
- Mandate frequency observed in backtest: Aave had 1 mandate hit in 882 days
  (effectively zero), while Compound was historically part of the
  opportunistic rotation. Elevation to 50/50 is gated on the GP-10 observation
  criteria.

### 5.2 Reference backtest numbers

**iter-3b — single-anchor reference (882 days):**

| Metric                        | Strategy | Aave standalone | Δ          |
|------------------------------|---------:|----------------:|-----------:|
| Annualized TWR (USD)         |    5.62% |           5.37% |  +25 bps   |
| Sharpe ratio USD (SOFR rf)   |   +0.729 |          +0.33  |  +0.40     |
| Max drawdown USD             |  -0.145% |         -0.153% |  +0.8 bps  |
| Idle drag                    |    8.28% |             N/A |     —      |
| Adapter mandate recurrence p95 | 45.2 d  |             N/A |     —      |
| Rebalances                   |     356  |               0 |     —      |

iter-3b already outperforms 5 of 6 single-market adapters on risk-adjusted
return. Dolomite outperforms standalone on nominal APY but is non-investable
at scale ($1.75M median external TVL).

**iter-4 — dual-anchor (pending production validation):**

- Gross TWR USD: ≈6.249% (+62 bps over iter-3b single anchor)
- Net TWR USD (5-year hypothetical hold, after 0.25% in/out + 6% perf fee): ≈5.83% (**+46 bps over Aave-net**)
- Idle drag: ≈5.88% (−240 bps vs iter-3b)
- Recurrence p95: maintained or improved vs iter-3b

Final numbers will be substituted after the production validation backtest run
using the deployed V9.2 setpoint. See `docs/strategy/USDC_LENDING_V92_ALLOCATOR_SPEC.md` for the allocator-facing summary.

## 6. Procedure to add or remove a safety adapter

**Side effect — cooldown state (audit finding H-03, fixed 2026-06-12).**
Calling `addSafetyFallbackAdapter` on an adapter that has an active rel-cap
mandate cooldown will **CLEAR** that cooldown (`lastRelCapMandateTs[adapter] = 0`)
and emit a `RelCapMandateCooldownCleared(adapter, msg.sender, priorTs)` event.

This is intentional: governance promotion to safety status is a stronger trust
signal than the prior mandate trigger. The event provides off-chain
observability for the lifecycle.

For audit clarity: if a Timelock-controlled governance wants to **preserve**
the mandate cooldown semantic (e.g. during emergency demotion-then-repromotion
of a still-suspect adapter), the explicit pattern is:

1. `removeSafetyFallbackAdapter(adapter)` — explicit demotion.
2. Wait `mandateRedeployCooldownSeconds` for natural expiry.
3. `addSafetyFallbackAdapter(adapter, ...)` — promotion AFTER cooldown elapsed.

This makes the cooldown lifecycle observable on-chain rather than implicit,
because the demotion + repromotion sequence is two separate Timelock txns
each emitting their own events.

**Other input validation (`addSafetyFallbackAdapter` reverts):**
- `ZeroAddress` if `adapter == address(0)`.
- `InvalidAdapter` if `!isAdapter[adapter]` OR `quarantined[adapter]`
  (audit finding L-01, fixed 2026-06-12 — quarantine is the protocol
  circuit breaker and must NOT be bypassable via safety promotion).
- `AdapterNotEnabled` if `!enabled[adapter]`.
- `InvalidFallbackCap` if `absCapBps == 0`, `absCapBps > 8000`, or `relCapBps > 10000`.
- `AlreadySafetyFallback` if `safetyFallback[adapter].absCapBps != 0`.



Both directions are gated by `DEFAULT_ADMIN_ROLE` and go through the timelock
configured at deployment. The atomic on-chain operations:

```text
add:
    setRebalanceParams(... if normal cap change needed)
    addSafetyFallbackAdapter(adapter, absCapBps, relCapBps)

update:
    updateSafetyFallbackCaps(adapter, absCapBps, relCapBps)

remove:
    removeSafetyFallbackAdapter(adapter)
```

The off-chain governance procedure for each:

1. **Proposal.** Forum post citing the eligibility criteria of §4 with current
   measurements and the proposed cap values.
2. **Review window.** ≥ 7 calendar days for community + multisig signers.
3. **Multisig timelock submission.** Schedule the on-chain transaction.
4. **Execution.** After the timelock elapses, anyone may execute the
   scheduled transaction.
5. **Post-execution monitoring.** The off-chain monitor (S3.1) raises an
   alert if the safety adapter's allocation reaches `0.95 × fallback cap`
   or if the mandate frequency on any non-safety adapter spikes within
   24h of the change.

## 7. Off-chain monitoring KPIs

The keeper-side monitor surfaces four signal families:

1. **Cap utilisation.** `positionAssets[a] / (fbAbsCap × tvl)` per safety
   adapter, alert if ≥ 0.95.
2. **Mandate frequency.** Rolling count of `CapDriftMandate(a, ...)` events
   per adapter per week, alert if > 10/week.
3. **Cooldown saturation.** Count of non-safety adapters with active
   `lastRelCapMandateTs + cooldown > block.timestamp`. Sustained > 50% of the
   enabled set indicates a market-wide stress condition.
4. **Idle drag.** `ASSET.balanceOf(strategy) / totalAssets` time series, alert
   if 24h average > `maxIdleBps + 200 bps`.

## 8. Failure modes considered

1. **Safety adapter exploit.** Recall procedure invoked by emergency multisig:
   `flagAdapter(adapter, true)` and `removeSafetyFallbackAdapter(adapter)` in
   the same multisig batch (no timelock — emergency path). The overflow path
   short-circuits on `flagged[a] == true` so no further deposits go in. The
   user-facing withdraw path is unaffected.
2. **Oracle manipulation on the safety adapter.** Detected by the existing
   liquidity overlay and TVL confidence cache. The mandate gate continues to
   use the cached external TVL — a manipulated quote in one block does not
   immediately corrupt the cap computation. Sustained manipulation triggers
   the failure overlay (`adapterConsecutiveFailures`) and eventual
   auto-quarantine.
3. **Governance compromise.** The safety fallback caps are bounded
   (`abs ≤ 8000 bps`) by the storage-level setter. A malicious governance
   action can at most route 80% of TVL into a single safety adapter, which is
   the same bound a normal cap could express. The two-cap design does not
   widen the worst-case governance attack surface.

## 9. Test coverage

| Layer            | File                                                                 | Count | Result |
|------------------|----------------------------------------------------------------------|------:|--------|
| Unit             | `test/strategies/usdc-lending/CapDriftMandate.t.sol::CapDrift_D1f_*` | 7     | PASS   |
| Property (fuzz)  | `test/strategies/usdc-lending/SafetyAdapterCapTier.properties.t.sol` | 6 × 256 runs | PASS |

Forge command for the full P0.7 suite:

```bash
forge test --match-contract 'CapDrift_D1f|SafetyAdapterCapTier' -vv
```

## 10. References

- Branch `feature/p0.7-safety-adapter-tier`, commits `8e846a9..e60d873`.
- Backtest harness: `multyr/vault-usdc2-brain` repo, `iter-3b` sweep summary.
- Related: `docs/audit-scope.md`, `docs/threat-model.md`,
  `docs/GOVERNANCE_POLICY_TRACK.md` (GP-10).
