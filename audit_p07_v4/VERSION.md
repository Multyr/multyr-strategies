# Strategy Version Lineage

## Current submitted version

**Strategy**: UsdcLendingStrategy  
**Version**: **V9.2 + P0.7**  
**Codename**: Safety Adapter Cap Tier  
**Branch**: `feature/p0.7-safety-adapter-tier`  
**HEAD commit**: per `SIGNOFF/R12_AUDIT_TABLE.md`

## Lineage

| Version | Status | Scope | Audit |
|---|---|---|---|
| V8.x | Historical | Pre-cap-discipline baseline | Internal |
| V9.0 | Historical | Cap discipline introduction | Internal review |
| V9.1 | Deployed (Arbitrum testnet) | Public reference for storage layout | Spearbit (separate engagement) |
| V9.2 | Pre-deployment | Safety margin on cap-binding targets (P0.6) | Internal review v1+v2 (Cowork) |
| **V9.2 + P0.7** | **Current submission** | **Safety Adapter Cap Tier (dual-anchor)** | **Tier-1 external (pending engagement)** |

## What P0.7 changes vs V9.2

### New storage fields (packed in slot 78)

- `capDriftToleranceBps` (uint16) — drift tolerance over soft cap before mandate fires
- `maxIdleBps` (uint16) — maximum idle cash before safety overflow triggers
- `targetSafetyMarginBps` (uint16) — margin applied to cap-binding target allocations
- `mandateRedeployCooldownSeconds` (uint32) — per-adapter post-mandate redeploy block window

### New storage fields (separate slots)

- `safetyFallbackAdapters` (address[], slot 79) — ordered priority list of safety adapters
- `safetyFallback` (mapping(address => SafetyFallbackConfig), slot 80) — per-adapter abs/rel cap override
- `lastRelCapMandateTs` (mapping(address => uint64), slot 81) — per-adapter mandate timestamp

### New behavior

- **Dual-anchor safety architecture**: Multiple safety adapters in priority order. Idle cash overflow routes to first eligible safety adapter; if at cap, routes to next.
- **Cap-drift mandate gate**: When any adapter exceeds its hardCeiling (cap × 1 + tolerance), the gate forces a rebalance to reduce position to within cap.
- **Preserve safety tranche**: If a safety adapter's current position is within the tolerance band (`normalTarget < current ≤ fallbackCeiling`), the target stays at current (no unnecessary unwind).
- **Cooldown semantic**: Cooldown blocks idle cash redeploy to a recently-mandated adapter, not future mandates from firing on it.
- **Promotion clears cooldown** (H-03 fix): When governance promotes a non-safety adapter to safety, any prior `lastRelCapMandateTs` is cleared.
- **Quarantine check on promotion** (L-01 fix): Cannot promote a quarantined adapter to safety.

### Removed / deprecated

None. P0.7 is strictly additive over V9.2 baseline.

## Compatibility with V9.1

V9.2 + P0.7 is **storage-layout-compatible with V9.1** through delegate-call pattern (7 modules share the same `StrategyStorageLayout`). The new P0.7 fields occupy slots 78-81, which were unused in V9.1.

Upgrade from V9.1 to V9.2 + P0.7 requires:
1. Deploy V9.2 + P0.7 module implementations
2. Owner calls `setImplementation()` for each module to point to new bytecode
3. Owner calls `setMaxIdleBps()`, `setTargetSafetyMargin()`, `setMandateRedeployCooldown()`, and `addSafetyFallbackAdapter()` per the production-confirmed setpoint

No state migration of pre-existing storage slots is required.

## Production-confirmed setpoint

Per `BACKTEST/PRODUCTION_PARAMETERS.json` and `BACKTEST/CONFIG_HASH.txt`:

```
mandateRedeployCooldownSeconds = 259200  (3 days)
capDriftToleranceBps           = 250     (2.5%)
maxIdleBps                     = 500     (5%)
targetSafetyMarginBps          = 300     (3%)
safetyFallbackAdapters         = [aave_v3_usdc 5000/5000, compound_v3_usdc 4000/4000]
```

This setpoint is the result of 3 sensitivity sweeps + 3 methodological checks documented in the fact sheet appendix.
