# Production Setpoint — Safety Adapter Cap Tier (V9.2, June 2026)

Reference for the deployment team. The on-chain calls listed below must be
executed in order after the strategy contract is deployed and adapter registry
is populated. Each call goes through the `DEFAULT_ADMIN_ROLE`-gated path on
`StrategySettingsModule`; on the production multisig this means a timelock
proposal per call (or a single batched proposal containing all calls).

> Backtest validation: iter-3b single-anchor → TWR 5.62%, Sharpe +0.729.
> Production validation backtest of the dual-anchor setpoint (iter-4) is
> pending and will be linked from this file once available.

## Required dependencies

- Strategy proxy address (Vault): `STRATEGY_ADDRESS`
- Aave V3 USDC adapter address: `AAVE_V3_ADAPTER`
- Compound V3 USDC adapter address: `COMPOUND_V3_ADAPTER`

Both adapters MUST be:
- Registered via `addAdapter(adapter)`
- Whitelisted via `whitelistAdapter(adapter, true)`
- Enabled via `toggleAdapter(adapter, true)`

before the safety configuration is applied. Otherwise
`addSafetyFallbackAdapter` reverts with `AdapterNotEnabled()`.

## On-chain calls

```solidity
// === Production setpoint — Safety Adapter Cap Tier (dual anchor) ===========
// Architecture: Aave 50/50 primary, Compound 40/40 secondary.
// Backtest reference (iter-4 production validation pending):
//   Gross TWR ~6.249%, Net TWR (5y hold) ~5.83% (+46 bps over Aave net).

StrategySettingsModule(STRATEGY_ADDRESS).setMaxIdleBps(500);                       // 5% of TVL
StrategySettingsModule(STRATEGY_ADDRESS).setTargetSafetyMargin(300);               // 3%
StrategySettingsModule(STRATEGY_ADDRESS).setMandateRedeployCooldown(3 days);       // 259_200 s

// Primary safety: Aave V3 — deepest USDC market on Arbitrum.
// Backtest history: 1 mandate hit in 882 days (effectively zero) — full tier eligible.
StrategySettingsModule(STRATEGY_ADDRESS).addSafetyFallbackAdapter(
    AAVE_V3_ADAPTER,
    5000,   // fallback abs cap (50% strategy TVL)
    5000    // fallback rel cap (50% adapter extTVL)
);

// Secondary safety: Compound V3 — conservative initial tier.
// Eligible for elevation to 50/50 after 6 months of production stability per
// docs/GOVERNANCE_POLICY_TRACK.md GP-10 elevation procedure.
StrategySettingsModule(STRATEGY_ADDRESS).addSafetyFallbackAdapter(
    COMPOUND_V3_ADAPTER,
    4000,   // fallback abs cap (40% strategy TVL)
    4000    // fallback rel cap (40% adapter extTVL)
);
```

## Order of effects

1. `setMaxIdleBps(500)` — enables the safety-overflow path. Without this, the
   overflow code in `_executeSafetyOverflow` short-circuits before iterating
   `safetyFallbackAdapters`, making the subsequent adds a no-op for routing.
2. `setTargetSafetyMargin(300)` — buffer applied to cap-binding scoring
   targets. Documented in `docs/SAFETY_ADAPTER_TIER.md` section 3.1.
3. `setMandateRedeployCooldown(3 days)` — per-adapter cooldown after a
   mandate hit. Only non-safety adapters honour cooldown; safety adapters
   are exempt by design.
4. `addSafetyFallbackAdapter(AAVE, 5000, 5000)` — Aave becomes safety venue
   index 0 (the primary, filled first by overflow).
5. `addSafetyFallbackAdapter(COMPOUND, 4000, 4000)` — Compound becomes
   safety venue index 1 (the secondary, filled when Aave reaches its
   fallback ceiling).

## Verification after deployment

```solidity
// All four storage variables must return the configured values.
require(strategy.maxIdleBps() == 500, "maxIdleBps mismatch");
require(strategy.targetSafetyMarginBps() == 300, "targetSafetyMarginBps mismatch");
require(strategy.mandateRedeployCooldownSeconds() == 3 days, "cooldown mismatch");

// The ordered safety list must contain exactly Aave then Compound.
require(strategy.safetyFallbackAdaptersLength() == 2, "safety list count");
require(strategy.safetyFallbackAdapters(0) == AAVE_V3_ADAPTER, "primary != Aave");
require(strategy.safetyFallbackAdapters(1) == COMPOUND_V3_ADAPTER, "secondary != Compound");

// Per-adapter fallback struct must match.
(uint16 aAbs, uint16 aRel) = strategy.safetyFallback(AAVE_V3_ADAPTER);
require(aAbs == 5000 && aRel == 5000, "Aave fallback caps mismatch");

(uint16 cAbs, uint16 cRel) = strategy.safetyFallback(COMPOUND_V3_ADAPTER);
require(cAbs == 4000 && cRel == 4000, "Compound fallback caps mismatch");
```

## Reference

- Design: `docs/SAFETY_ADAPTER_TIER.md`
- Governance: `docs/GOVERNANCE_POLICY_TRACK.md` (GP-10)
- Allocator spec: `docs/strategy/USDC_LENDING_V92_ALLOCATOR_SPEC.md`
- Ops runbook: `docs/ops/SAFETY_TIER_RUNBOOK.md`
- Monitor: `scripts/keepers/safety_adapter_monitor.py`
