> Superseded for the 17 October replacement: the user explicitly instructed **not to copy settings**. The release uses `COPY_SOURCE_SETTINGS=false`, fresh TVL-tier exposure defaults, and Aave/Fluid safety fallback configuration. The preservation workflow below remains optional documentation and is not the selected release path. See `deployments/replacement-20261017/RELEASE.md` for current status.

# Replacement strategy configuration

The replacement deployment now requires `SOURCE_STRATEGY` and `SOURCE_STRATEGY_UPKEEP`. For this deployment these are:

```sh
SOURCE_STRATEGY=0x7bF0f446BB20b54597E66a602cB94D0F231D24E2
SOURCE_STRATEGY_UPKEEP=0x05202b06647d4597fB851162A1E32AA8437EeFc3
```

`results/current-strategy-settings.json` is a read-only inventory at Arbitrum block 515526090. It contains the block hash, 82 scalar values (including runtime state for inspection), seven adapter identities and strategy-level controls, safety-fallback order, and upkeep configuration. Refresh it before release with `script/snapshot-strategy-settings.py`; it needs a public RPC and `cast`, never a private key.

`StrategySettingsCopy.sol` takes constructor settings directly from the source, applies the remaining strategy settings through existing setters, and verifies parity. It covers allocation/risk weights and caps, ramp policy, gate and harvest parameters, cooldowns, staleness limits, gas-EMA smoothing, hysteresis, regime and coordination parameters, plan limits, withdrawal lock, idle/safety controls, deposit disablement, and each adapter's enablement, whitelist, flag, quarantine, deposit mode, risk score and cap override. Safety fallback caps and order are mapped to the replacement adapters. Adapter count and names must match in the same order; mismatches stop simulation. Values already equal are not rewritten, preserving valid legacy zero defaults even where current setters reject zero.

The replacement upkeep inherits the current poke interval, enabled status and ordered poke targets, mapped to replacement adapter addresses. Pool and token identities must match. Constructor bootstrap duration uses only the remaining source period; an expired period stays inactive. Pause and parameter-finalization status are preserved before handoff. A frozen source stops deployment because freezing the replacement before deployer-role revocation would retain those roles permanently; it needs a governance freeze after handoff. The current source has neither roles nor parameters frozen/finalized.

The deployment also wires the safety-overflow module. Source Core and USDC identity are checked. The postflight rechecks strategy configuration and mapped adapter/upkeep parity. Run normal Forge simulation and postflight; do not use `--skip-simulation`. Deployment is a sequence of transactions, so a failed broadcast can be partial: reconcile the address book and on-chain state before any retry or migration.

## Deliberate state boundaries

Balances, positions, pending plans, previous gas quotes, EMA measurements, accounting snapshots and failure counters are not configuration. They are not cloned. New adapters start with fresh ramp/seasoning state and measured caches must be refreshed. The gas estimator address/calibration is new and separately reviewed. Risk scores with an active staleness policy stop copying and require re-attestation rather than silently refreshing an old assessment. The current source has zero risk scores and no risk-score expiry policy.

Role holders come from the reviewed deployment environment: Core and Router retain CORE_ROLE, governance receives admin/PARAM roles, guardian and keeper signer retain their intended roles, and the old upkeep address is replaced by the new upkeep. The copier does not enumerate arbitrary historical AccessControl grants. Review grant/revoke history and role-admin configuration before migration.

## Remaining deployment gates

This covers strategy-level configuration and upkeep, not every setting inside lending protocols, adapter market registries or rate-provider contracts. The deployment still builds those components from chain configuration. Their internal market lists, capacities, risk settings, reward routing, overrides and protocol-registry state need an explicit old/new comparison before release; a strategy-level parity pass alone is not a full migration sign-off.

The harvest interface now supports the deployed Router's CORE_ROLE and returns `(int256 pnl, uint256 realized)`. Local integration and a pinned fork verify harvest plus recall with unchanged deployed Core/Router/native-USDC code. The fork uses a funded reward adapter fixture; it does not establish seven-adapter migration readiness.

Production approval still requires calibrated estimator inputs, cold keeper-wrapper/full-plan receipt comparisons (including failure/cancellation costs), a full seven-adapter funding/recall rehearsal with copied settings, and the AWS keeper cutover. No deployment, Safe transaction or fund transfer was submitted during this review.

## Cutover order

1. Refresh the source inventory and resolve adapter-internal configuration/role parity. Supply reviewed feed addresses and calibrated gas-model configuration.
2. Dry-run the complete replacement deployment against the intended Core, with copied settings; run postflight and the migration rehearsal. Review all new addresses and transaction outputs.
3. Deploy the replacement modules/strategy/adapters/upkeep and verify code and settings. Complete the Router allowlist delay without activating intake prematurely.
4. Stop the old strategy worker from preparing new plans; finish/cancel any current plan. Drain and reconcile old-strategy assets while it remains visible to Router accounting. Zero weight alone does not prevent PRIORITY-mode intake, and disabling a funded strategy excludes its assets from Router NAV.
5. Apply the reviewed Router registration/priority/weight/loss-cap configuration and activate the replacement only after funding/recall and accounting checks. Retire the old strategy only after its assets are reconciled.
6. On AWS, deploy the keeper build with updated event decoding/ABIs and replace strategy/upkeep addresses in the existing service configuration. Keep the same reviewed KMS signer, RPC and unrelated Core/claim-keeper settings; verify KEEPER_ROLE on the replacement. No quote-publishing job is needed. Avoid overlapping old/new rebalance workers during cutover; compare estimated and actual total plan costs in logs. Live ECS configuration could not be inspected in this workspace because AWS credentials were unavailable.
