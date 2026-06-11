# Safety Tier Runbook

> Operational procedures for the P0.7 Safety Adapter Cap Tier.
> Read alongside `docs/SAFETY_ADAPTER_TIER.md` (design) and
> `docs/GOVERNANCE_POLICY_TRACK.md` (GP-10 policy).

## RB-01: Add a safety adapter

**Prerequisite check** (manual, prior to proposal):

- Adapter satisfies the eligibility criteria of
  `SAFETY_ADAPTER_TIER.md` section 4 (extTVL >= 5M sustained 90d, <= 5 mandate
  hits last 12mo, liquidity >= 80%, no high audit findings, no
  12-month exploit).
- Adapter is already in `whitelistedAdapters` and `enabled`.
- Backtest sweep on the trailing 12 months of on-chain data shows
  net-positive TWR delta vs the current safety set.

**Execution path:**

1. Submit governance proposal with the cap recommendation and the four
   criterion measurements.
2. Wait >= 7 days for community + multisig review.
3. Multisig signers schedule the timelock tx:
   `addSafetyFallbackAdapter(adapter, absCapBps, relCapBps)`.
4. After the timelock elapses, anyone may execute the scheduled tx.
5. Within 1 hour of execution, run `scripts/keepers/safety_adapter_monitor.py`
   and verify:
   - `SafetyFallbackAdapterAdded` event is in the indexer.
   - The new adapter appears in the `safety_adapters` array of the
     monitor output.
   - Idle drag has not jumped abnormally.

## RB-02: Remove a safety adapter (planned)

For routine recall (adapter no longer meets eligibility criteria
after annual review):

1. Governance proposal citing the criterion gap.
2. >= 7 day review window.
3. Multisig schedules `removeSafetyFallbackAdapter(adapter)` via timelock.
4. Execute after timelock.
5. Verify `SafetyFallbackAdapterRemoved` event + monitor output absence.
6. The existing position is preserved on the adapter but no further
   overflow is routed there. Subsequent rebalances gradually unwind the
   position via normal scoring (now using normal caps, not fallback).

## RB-03: Remove a safety adapter (emergency)

Triggered by one of:

- Confirmed exploit on underlying protocol (smart-contract or admin-key).
- Oracle manipulation > 30 bps deviation > 1h.
- External liquidity ratio < 30% > 24h.
- Adapter operator unresponsive > 72h.

**Execution path (no timelock):**

1. Multisig assembles signing quorum (typically 4-of-7).
2. Submit a single tx containing both:
   - `setFlaggedAdapter(adapter, true)`
   - `removeSafetyFallbackAdapter(adapter)`
3. Verify both events on the next block.
4. Run the monitor and confirm:
   - The adapter no longer appears in `safety_adapters`.
   - The next `deployIdle()` call skips the adapter.
5. Publish a post-incident notice on the protocol forum within 24h.

## RB-04: Update fallback caps

Used in the quarterly cap review:

1. Governance proposal with the cap recommendation + backtest evidence.
2. >= 7 day review window.
3. Schedule timelock tx:
   `updateSafetyFallbackCaps(adapter, absCapBps, relCapBps)`.
4. Execute after timelock.
5. Verify `SafetyFallbackCapsUpdated` event in the indexer.
6. Within 6h, verify the safety adapter's allocation has migrated toward
   the new cap (positions above the new cap should NOT trigger the
   mandate -- the preserve-safety-tranche rule applies).

## RB-05: Monitor alert -- cap utilisation

Trigger: `cap_utilisation_bps >= 9500` on at least one safety adapter for
>= 1h.

Triage:

1. Determine cause: idle drag (more LP deposits) vs adapter-specific
   (extTVL contraction => fbRelCap dropped).
2. If idle drag:
   - Consider raising `maxIdleBps` via `setMaxIdleBps`.
   - Or add a second safety adapter (RB-01).
3. If extTVL contraction:
   - Verify underlying protocol is healthy.
   - Monitor or escalate to RB-03 as appropriate.

## RB-06: Monitor alert -- mandate frequency

Trigger: `hits_last_7d > 10` on any non-safety adapter.

Triage:

1. Identify which adapter is the mandate target.
2. Look at trailing 30-day externalTVL trend.
3. If TVL collapsing on healthy protocol: mandate-driven exit is correct.
4. If TVL collapsing on unhealthy protocol: invoke RB-03.
5. If repeats without TVL movement (stale cache), inspect
   `cachedExternalTVL` and confirm the keeper is poking it on cadence.

## RB-07: Monitor alert -- cooldown saturation

Trigger: `saturation_pct > 0.50`.

Systemic stress signal -- many adapters mandate-fired recently. Possible
causes:

1. Market-wide USDC liquidity drop.
2. Cross-protocol coordinated exploit attempt.
3. Protocol-level upgrade shifting multiple adapter caps at once.

Response:

1. Verify safety adapter positions are stable.
2. Check explorer for USDC TX flooding events.
3. Notify multisig signers -- be ready for RB-03 if cause is cluster (2).
4. Strategy self-heals: overflow continues into safety adapters;
   non-safety re-enter eligibility as cooldowns expire.

## RB-08: Monitor alert -- idle drag

Trigger: `avg_24h_idle_bps > max_idle_bps_config + 200`.

Triage:

1. Sustained idle drag above threshold means either:
   - Deploy-idle keeper is failing (most likely).
   - All eligible adapters are simultaneously above their normal cap
     and in cooldown.
2. Check Chainlink Automation upkeep dashboard for keeper failures.
3. If keeper healthy, the issue is structural -- consider lowering
   `targetSafetyMarginBps` (governance) to free up scoring capacity.

## Appendix: Reference monitor invocation

```bash
ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc \
STRATEGY_ADDRESS=0x... \
python scripts/keepers/safety_adapter_monitor.py \
    --lookback-blocks 50000 \
    | tee /var/log/multyr/safety-monitor-$(date +%s).json
```

For continuous monitoring deploy this as a Datadog Agent custom check or
a Grafana scraper polling every 5 minutes.
