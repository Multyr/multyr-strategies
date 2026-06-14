# P0.7 Audit Package — Threat Model

This document describes the threat model for the Multyr UsdcLendingStrategy V9.2 + P0.7 (Safety Adapter Cap Tier) changeset. It enumerates privileged roles, assets at risk, the security invariants the protocol claims, and the assumptions made about external dependencies.

## 1. Scope of this threat model

**In scope** (P0.7 audit critical surface):
- `StrategySettingsModule.sol` — governance setters for safety adapter configuration
- `StrategyRebalancePlanModule.sol` — rebalance plan execution with safety overflow path
- `StrategyRebalanceGateModule.sol` — cap drift mandate gate
- `StrategyParamsModule.sol` — keeper-facing parameter pokes (extTVL, deployIdle)
- `StrategyStorageLayout.sol` — packed storage layout for P0.7 fields
- `StrategyAllocCalcModule.sol` — target allocation computation including safety tranche preservation
- `StrategyExplainabilityLens.sol` — read-only observability (refactored S2.4-bis)

**Out of scope** (pre-existing baseline, audited separately or upstream):
- `StrategyScoringModule.sol` (touched at edges; main scoring logic pre-P0.7 baseline)
- `lib/multyr-core/*` (external library, separate audit perimeter)
- `lib/openzeppelin-contracts/*` (audited by upstream)
- `lib/forge-std/*` (test framework, not deployed)
- Off-chain components (keeper bots, backtest harness, monitoring stack)

## 2. Privileged roles

The protocol implements three privileged roles. Each role's powers, restrictions, and intended operational model:

### 2.1 Owner

**On-chain identity**: Solidity `Ownable` pattern via `_owner` storage slot.

**Powers**:
- Add/remove safety fallback adapters (`addSafetyFallbackAdapter`, `removeSafetyFallbackAdapter`)
- Update safety fallback caps (`updateSafetyFallbackCaps`)
- Set governance parameters: `setMaxIdleBps`, `setTargetSafetyMargin`, `setMandateRedeployCooldown`, `setCapDriftTolerance`
- Transfer ownership (`transferOwnership`)
- Pause / unpause strategy (inherited from base)

**Assumed operational model**: Multisig with timelock. **The audit assumes the owner is a Safe multisig with 3-of-5 threshold behind a 48h timelock.** All parameter changes go through the timelock. No EOA owner is acceptable in production.

**Risk if compromised**: Owner can rapidly reconfigure safety adapter caps. Compromise allows reducing safety caps to zero (forcing capital into safety overflow that has nowhere to land) or expanding caps beyond `MAX_CAP_BPS` (allowing concentration risk). Timelock provides ~48h response window for emergency social-layer pause.

### 2.2 Keeper

**On-chain identity**: Chainlink Automation 2.x registry (Arbitrum) — multiple keeper EOAs whitelisted via on-chain config.

**Powers**:
- `pokeExternalTVL` — refresh cached external TVL for adapters
- `deployIdle` — route idle USDC to scored adapters
- `prepareRebalance` — compute rebalance plan when gate passes
- `executeRebalanceStep` — execute next pending step in plan

**Cannot**:
- Modify any governance parameter
- Transfer assets out of the vault
- Bypass the rebalance gate (gate decisions are deterministic given on-chain state)
- Execute steps from a stale plan if `rebalancePlanPhase` mismatches

**Assumed operational model**: Chainlink Automation 2.x with redundant registries. Keepers compete for upkeep registration; fees paid in LINK + ETH. **Audit assumes Chainlink Automation registry contract operates per its published security model.**

**Risk if compromised**: Compromised keeper can call no-revert paths only. Rebalance gate refusal (`gateMinNetBenefitBps`, `rebalanceMinMoveBps`, `minSecondsBetweenRebalances`) prevents griefing. Worst-case: keeper denial of service forces governance to register a replacement keeper.

### 2.3 Pauser

**On-chain identity**: Separate role from Owner, typically the same multisig but with lower threshold (e.g., 2-of-5) for emergency response.

**Powers**:
- Trigger emergency `pause()` on strategy
- Cannot `unpause()` (that's Owner-only)

**Assumed operational model**: Emergency response team. Pauser is intentionally easier to trigger than Owner setter actions, on the principle that pausing is conservative (errs toward safety).

**Risk if compromised**: Compromised pauser can DOS the strategy until Owner intervenes. Asset loss is impossible from pause alone.

## 3. Assets at risk

### 3.1 Vault USDC

- Idle cash in `state.idle_cash` (vault balance not yet deployed)
- Position assets in 7 lending adapters: Aave V3, Compound V3, Dolomite, Euler V2, Fluid, Morpho Blue, Venus
- Bookkeeping invariant: `sum(positionAssets[i]) + idleCash == totalAssets` (modulo rounding tolerance)

**Scale assumption**: Production target $1M-$50M AUM. Backtest validated at $1M seed scale; storage layout and arithmetic tested up to 1T USDC stress bounds via Halmos P5 property.

### 3.2 Yield-bearing positions in external protocols

Each adapter holds aTokens (Aave), cTokens (Compound V3 base+rewards), or analogous receipt tokens. **Audit assumes these tokens are non-rebasing or rebasing in line with adapter implementation.**

### 3.3 Chainlink Automation pre-funded balance

Keeper upkeep balance held in Chainlink Registry. **Not protocol-controlled**; out of scope for safety claims but operational dependency.

## 4. Security invariants claimed

The protocol claims the following invariants. Each is verified through one or more of: Halmos symbolic proof, Echidna stateful fuzz, forge unit tests, fork tests.

### 4.1 Bookkeeping conservation

**Claim**: `sum(positionAssets[i]) + idleCash == totalAssets` (within 1000 wei tolerance for accumulated rounding).

**Verification**: Echidna invariant I06 (`echidna_I06_accounting_conserved`) over 1M sequences.

### 4.2 Safety cap discipline (hard ceiling)

**Claim**: For every safety adapter `i`, `positionAssets[i] <= hardCeiling_i` where `hardCeiling_i = fbCeiling_i * (1 + capDriftToleranceBps/1e4)`, with ±2 wei rounding tolerance.

**Verification**:
- Halmos property P1 (`check_safetyAdapterBelowFallbackCeilingNoMandate`) — symbolic
- Halmos property P3 (`check_overflowCannotExceedFallbackCap`) — symbolic
- Echidna invariant I03b (`echidna_I03b_position_within_hard_ceiling`) — 1M sequences

### 4.3 Safety tranche preservation (no unnecessary unwind)

**Claim**: If a safety adapter has `normalTarget_i < currentPosition_i <= fallbackCeiling_i`, then the next rebalance does NOT reduce `currentPosition_i` to `normalTarget_i`. Position is preserved within the tolerance band.

**Verification**: Halmos property P4 (`check_validSafetyTrancheNotUnwound`) — most critical safety property, symbolic verification of preserve-tranche logic.

### 4.4 Mandate completeness (over-ceiling implies detection)

**Claim**: If `positionAssets[i] > hardCeiling_i` for any safety adapter `i`, then the cap drift mandate is detectable on the next rebalance check.

**Verification**: Halmos property P2 + Echidna invariant I03c (`echidna_I03c_above_hard_implies_mandate`).

### 4.5 Non-safety adapter uses normal caps

**Claim**: For any non-safety adapter, the cap drift gate uses only the normal abs/rel cap path; the safety fallback caps never apply.

**Verification**: Halmos property P2 (`check_nonSafetyAdapterNeverUsesFallbackCap`) — symbolic.

### 4.6 Cooldown semantic (re-deploy only)

**Claim**: After a cap drift mandate fires on adapter `i`, subsequent calls to `deployIdle` skip `i` until `lastRelCapMandateTs[i] + mandateRedeployCooldownSeconds` has elapsed. The cooldown does NOT prevent future mandates from firing on `i` (e.g., from continued external TVL drift); it only blocks re-deployment.

**Verification**: Echidna invariants I04 and I05; forge unit tests in `CapDriftMandate.t.sol`.

### 4.7 H-03 cooldown bypass via promotion (resolved)

**Claim**: Promoting a non-safety adapter to safety (`addSafetyFallbackAdapter`) clears any prior `lastRelCapMandateTs[i]` cooldown stamp. This prevents an adversarial governance path where a recently-mandated adapter could be promoted to safety to bypass its cooldown.

**Verification**:
- Halmos property P6 (`check_cooldown_clear_idempotency`)
- Echidna invariant I10 (`echidna_I10_promotion_clears_cooldown`) over 1M sequences
- Forge unit test `test_D1f_10_promotion_clears_active_cooldown` in `CapDriftMandate.t.sol`

### 4.8 L-01 quarantined adapter cannot be promoted (resolved)

**Claim**: `addSafetyFallbackAdapter` reverts if the adapter is currently quarantined.

**Verification**: Forge unit test `test_D1f_09_quarantined_adapter_promotion_reverts` in `CapDriftMandate.t.sol`.

### 4.9 Storage layout invariance

**Claim**: All 7 controller modules share the identical storage layout via delegate-call pattern. The P0.7 packed slot (slot 78) contains exactly `capDriftToleranceBps` + `maxIdleBps` + `targetSafetyMarginBps` + `mandateRedeployCooldownSeconds` (80 bits total).

**Verification**: Forge test `StorageLayoutP07.t.sol` with 5 tests TC01a-e cross-checking offsets via `forge inspect` output.

### 4.10 Setter bounds

**Claim**:
- `maxIdleBps <= 2000` (20%)
- `targetSafetyMarginBps <= 2000` (20%)
- `mandateRedeployCooldownSeconds <= 30 days`
- For safety adapter: `absCapBps in [1, 8000]`, `relCapBps in [0, 10000]`

**Verification**: Echidna invariant I08 + I11 + setter unit tests in `P07NegativePathsSettings.t.sol` (12 tests, S2.4-ter).

### 4.11 Legacy non-regression

**Claim**: When no safety adapters are configured, the system behaves identically to pre-P0.7 baseline.

**Verification**: Echidna invariant I12 (`echidna_I12_legacy_when_disabled`).

## 5. External dependency assumptions

The protocol's safety claims rely on the correct operation of the following external dependencies. **A compromise of any of these breaks the corresponding assumption.**

### 5.1 Aave V3 Pool (Arbitrum)

Address: `0x794a61358D6845594F94dc1DB02A252b5b4814aD`

**Assumed**:
- USDC supply/withdraw operate per the published Aave V3 spec
- aToken balance is non-rebasing in terms of underlying USDC value over `block.timestamp` (scaled balances)
- No emergency action that locks deposits in a way that breaks adapter `withdraw()` semantics

**If violated**: Adapter `withdraw()` could revert or return less than expected. Mitigation: per-step rebalance with revert recovery (`H-02 test_safetyOverflow_handles_deposit_revert` and `H-01 test_E2E_failed_adapter_callback`).

### 5.2 Compound V3 Comet USDC (Arbitrum)

Address: `0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf`

**Assumed**:
- USDC supply/withdraw operate per the published Compound III spec
- `balanceOf(strategy)` returns USDC-equivalent reliably
- No emergency action breaking withdraw semantics

**If violated**: Same mitigation as Aave.

### 5.3 Other adapters (Dolomite, Euler V2, Fluid, Morpho Blue, Venus)

Each adapter wraps the respective protocol's deposit/withdraw/balance ABI. The audit assumes:
- Each protocol operates per its published documentation
- Adapter wrappers correctly translate between Multyr's USDC accounting and the protocol's native units
- For low-liquidity adapters (Dolomite median extTVL $1.75M), the relative cap mechanism prevents over-concentration

**If violated**: Adapter-specific failure. The strategy's defensive guards (covered by Echidna invariants I01, I02, I03b, I07, I11; tested directly in `P07NegativePathsScoring.t.sol`) limit blast radius to the affected adapter.

### 5.4 Chainlink Automation 2.x (Arbitrum)

Registry: per Chainlink Automation deployed addresses (refer to `EXTERNAL_DEPENDENCIES.md`).

**Assumed**:
- Keepers execute upkeep at the published latency targets (typically 1-5 blocks for high-priority upkeeps)
- LINK payment + ETH refund mechanism operates per Chainlink spec
- Registry contract is non-upgradeable or upgrades through governance-acceptable process

**If violated**: Strategy may operate with stale `cachedExternalTVL` or fail to redeploy idle cash timely. **Asset loss requires concurrent protocol vulnerability** — no fund-at-risk scenario from Chainlink alone.

### 5.5 USDC stablecoin (Arbitrum bridged)

Address: `0xaf88d065e77c8cC2239327C5EDb3A432268e5831`

**Assumed**:
- USDC peg holds within tolerable band
- Circle's compliance actions (e.g., blacklist) do not affect strategy's vault address

**If violated**: Hard depeg breaks the strategy's USD value proposition but not its USDC accounting. Soft depeg (e.g., 0.98) is exercised via `H-01 test_E2E_oracle_deviation_USDC_depeg` showing strategy continues operating on USDC unit accounting without panic withdraw.

## 6. Out-of-scope considerations

The following are explicitly **out of scope** for the P0.7 audit:

1. **Economic security of underlying protocols** (Aave bad debt, Compound liquidation cascades, Dolomite oracle manipulation). The strategy diversifies across these; failure of one within risk caps is absorbed.
2. **Off-chain keeper bot security** (Chainlink Automation registry security is upstream). The on-chain `_validateKeeper()` checks the registry address but does not audit registry behaviour.
3. **MEV extraction by sandwich attacks on rebalance transactions**. Rebalance plans are public; MEV is possible but the strategy uses lending pool deposit/withdraw (no AMM swap), so the MEV surface is limited to gas-price competition.
4. **Front-running of governance setter actions**. Mitigated by timelock assumption in §2.1.
5. **L2-specific risks**: Arbitrum reorg deeper than fork test assumes (`vm.warp` semantics under reorg). The protocol's accounting is reorg-tolerant by design (state derived from on-chain balances), but specific reorg scenarios are not formally proved.

## 7. Threat scenarios explicitly tested

| Scenario | Test reference | Status |
|---|---|---|
| Sustained cap-rel drift on single adapter | `CapDriftMandate.t.sol` | PASS |
| Mandate firing followed by recovery | `V92_SafetyTierE2E.t.sol` step 7-13 | PASS |
| Governance promotes mandated adapter (H-03) | `test_D1f_10_promotion_clears_active_cooldown` | PASS |
| Promotion of quarantined adapter (L-01) | `test_D1f_09_quarantined_adapter_promotion_reverts` | PASS |
| Governance pause mid-rebalance | `V92_AdversarialScenarios.t.sol::test_E2E_governance_pause_mid_rebalance` | PASS (H-01) |
| Safety adapter quarantine during overflow | `V92_AdversarialScenarios.t.sol::test_E2E_adapter_quarantine_during_overflow` | PASS (H-01) |
| USDC depeg simulation | `V92_AdversarialScenarios.t.sol::test_E2E_oracle_deviation_USDC_depeg` | PASS (H-01) |
| Failed adapter callback during rebalance | `V92_AdversarialScenarios.t.sol::test_E2E_failed_adapter_callback` | PASS (H-01) |
| Storage slot collision across modules | `StorageLayoutP07.t.sol` TC01a-e | PASS |
| Overflow above 1T TVL bounds | Halmos P5 `check_ceiling_arithmetic_no_overflow` | PASS |
| All 12 Echidna invariants over 1M sequences | `SafetyAdapterTierEchidna.sol` | PASS |

## 8. Acknowledged residual risks

Despite the formal verification + 1M sequences fuzz + 5 fork tests + 84% diff branch coverage, the following residual risks are acknowledged:

1. **Defensive guard paths in `_executeSafetyOverflow`** (9 branches) are exercised indirectly via 398k main-path hits during Echidna campaign. Direct unit tests for the remaining 6 (after H-02 covers 3 explicit) are deferred due to mock complexity. Documented in `COVERAGE_UNREACHABLE.md` and `DEFENSIVE_GUARDS.md`.

2. **Lens module** (`StrategyExplainabilityLens.sol`) is post-S2.4-bis refactor instrumented. 4 view-only branches remain uncovered (read-only, no state mutation, off-chain observability) — documented in `COVERAGE_EXCLUSIONS.md`.

3. **External library `lib/multyr-core/QueueModule.sol`** is out of P0.7 scope and not instrumented (stack-too-deep without `--ir-minimum`). Audited under separate perimeter.

4. **Halmos symbolic bounds**: P5 stress tested up to 1T USDC TVL. Beyond this scale, arithmetic safety is asserted by Solidity 0.8.24 overflow checks but not symbolically verified.

5. **Echidna assertion-mode coverage**: 1M sequences explored ~88% Echidna corpus coverage. The unexplored 12% is principally combinatorially-rare action sequences involving sequential demotion/re-promotion across all 3 mock adapters.
