# Governance Policy Track (GP)

> Governance procedures for the USDC Multi-Lending Strategy. Each policy is
> referenced from the relevant source/test artefacts.

## GP-10: Safety Adapter Tier Management

> Established 2026-06-11 alongside the P0.7 Safety Adapter Cap Tier
> implementation. See [SAFETY_ADAPTER_TIER.md](./SAFETY_ADAPTER_TIER.md) for the
> technical design.

### Default Safety Adapters (Production Setpoint V9.2)

The V9.2 Arbitrum deployment ships with a **dual-anchor** safety set:

| Adapter            | Address           | Abs Cap | Rel Cap | Initial Status              |
|--------------------|-------------------|--------:|--------:|------------------------------|
| Aave V3 USDC       | (deploy-time)     |    50%  |    50%  | Production-ready             |
| Compound V3 USDC   | (deploy-time)     |    40%  |    40%  | Initial conservative tier    |

**Aave V3** is the **primary** safety venue (index 0 in `safetyFallbackAdapters`).
Selection criteria met: $4B+ external USDC TVL on Arbitrum, institutional risk
profile (governed Aave DAO, two-year incident-free record on this chain), and
backtest evidence that 99% of the rotation-loop pressure observed in iter-2
of the P0.6 sweep originated on *adjacent* small-pool adapters, with Aave
exhibiting only 1 mandate hit in 882 days at full 50% caps.

**Compound V3** is the **secondary** safety venue (index 1), assigned a
conservative initial tier (40% caps vs Aave's 50%) for two reasons:

- Compound V3 has shorter Arbitrum production history.
- In iter-2/iter-3 of the sweep Compound participated in the opportunistic
  rotation alongside Dolomite and Euler v2; its mandate frequency was
  meaningfully above Aave's.

### Compound Elevation Procedure

Compound V3 is eligible for elevation from 40/40 to 50/50 caps after ALL of
the following criteria are met simultaneously:

1. Minimum 6 months of production operation under V9.2.
2. Fewer than 5 rel-cap-mandate hits on Compound during the observation
   period (measured from the `CapDriftMandate` event channel filtered on
   the Compound adapter address).
3. No security incidents affecting Compound V3 on Arbitrum.
4. Compound's Arbitrum extTVL remains above $50M throughout the observation
   period.

Elevation goes through the standard 7-day timelock — NOT the emergency path.
On-chain atomic call:

```text
StrategySettingsModule(strategy).updateSafetyFallbackCaps(COMPOUND, 5000, 5000)
```

### Procedure to extend the safety set further

Adding a third safety adapter (e.g. Spark, if/when deployed on Arbitrum,
or a hypothetical USDC-native protocol) follows the same eligibility
criteria of §4 of [SAFETY_ADAPTER_TIER.md](./SAFETY_ADAPTER_TIER.md):

1. ≥ 6 months production with ≤ 5 rel-cap-mandate hits observed off-chain.
2. extTVL ≥ $5M sustained over the prior 90 days.
3. `cachedLiquidityBps[adapter]` ≥ 8000 sustained for 90 days.
4. No outstanding high or critical audit finding.

The 6-month minimum is a soft floor; a shorter window may be considered if a
formal verification campaign (Halmos / Echidna) on the candidate adapter
returns clean.

### Emergency De-elevation Procedure

If any safety adapter experiences:

- Smart-contract exploit or oracle manipulation evidence (> 30 bps deviation
  between independent external price feeds sustained for > 1h).
- Liquidity collapse: external `withdrawableAssets / totalAssets` < 30% > 24h.
- Multi-day extTVL volatility > 20% per day.

Then the safety adapter MUST be removed via the emergency-multisig 24h
timelock (or no-timelock for confirmed exploits). Operational runbook:
RB-03 in [docs/ops/SAFETY_TIER_RUNBOOK.md](./ops/SAFETY_TIER_RUNBOOK.md).

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
