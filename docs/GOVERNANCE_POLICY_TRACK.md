# Governance Policy Track (GP)

> Governance procedures for the USDC Multi-Lending Strategy. Each policy is
> referenced from the relevant source/test artefacts.

## GP-10: Safety Adapter Tier Management

> Established 2026-06-11 alongside the P0.7 Safety Adapter Cap Tier
> implementation. See [SAFETY_ADAPTER_TIER.md](./SAFETY_ADAPTER_TIER.md) for the
> technical design.

### Default safety adapters

Initial safety set on the v9.2 Arbitrum deployment:

- **Aave v3 USDC** — `safetyFallback.absCapBps = 5000`, `relCapBps = 5000`.

Aave v3 was selected on the strength of (a) its $4B+ external USDC TVL on
Arbitrum, (b) its institutional risk profile (governed Aave DAO, two-year
incident-free record on this chain), and (c) backtest evidence that 99% of
the rotation-loop pressure observed in iter-2 of the P0.6 sweep originated on
the *adjacent* small-pool adapters (Dolomite, Compound v3, Euler v2), with
Aave never appearing as a mandate target in iter-3b.

### Procedure to extend the safety set

A second safety adapter (typically Compound v3 once it has demonstrated 6
months of production stability under the v9.2 setpoint) may be considered
once it satisfies §4 of [SAFETY_ADAPTER_TIER.md](./SAFETY_ADAPTER_TIER.md):

1. ≥ 6 months production with ≤ 5 rel-cap-mandate hits observed off-chain.
2. extTVL ≥ $5M sustained over the prior 90 days.
3. `cachedLiquidityBps[adapter]` ≥ 8000 sustained for 90 days.
4. No outstanding high or critical audit finding.

The 6-month minimum is a soft floor; a shorter window may be considered if a
formal verification campaign (Halmos / Echidna) on the candidate adapter
returns clean.

### Review cadence

- **Quarterly review of fallback caps.** The risk committee re-derives
  optimal cap values using a refreshed backtest sweep on the prior 12 months
  of on-chain data. Cap changes go through `updateSafetyFallbackCaps` via
  the timelock.
- **Annual review of the safety set.** Membership is re-justified against
  §4 with up-to-date measurements; adapters that no longer satisfy the
  criteria are removed via `removeSafetyFallbackAdapter`.

### Emergency removal triggers

The emergency multisig may invoke the removal path **without timelock**
when any of the following occurs:

- Confirmed exploit (smart-contract or admin-key) on the underlying
  protocol.
- Oracle manipulation evidence: > 30 bps deviation between independent
  external price feeds sustained for > 1 hour.
- Liquidity collapse: external `withdrawableAssets / totalAssets` drops
  below 30% for > 24 hours.
- Adapter contract or operator unresponsive on the off-chain monitoring
  channel for > 72 hours.

The emergency removal atomically performs:

```text
setFlaggedAdapter(adapter, true)
removeSafetyFallbackAdapter(adapter)
```

After flagging, the safety overflow path skips the adapter and the
position can be withdrawn through the standard rebalance flow. Existing
LP withdraw flows remain operational.

### On-chain events watched by monitoring

- `SafetyFallbackAdapterAdded(adapter, absCapBps, relCapBps)`
- `SafetyFallbackAdapterRemoved(adapter)`
- `SafetyFallbackCapsUpdated(adapter, oldAbs, newAbs, oldRel, newRel)`
- `SafetyOverflowDeployed(adapter, amount, idleBefore, idleAfter)`
- `RelCapMandateCooldownStarted(adapter, timestamp, cooldownSeconds)`
- `CapDriftMandate(adapter, current, hardCeiling)` (legacy, still emitted)
