# Candidate deployment sequence — unsigned preparation

Status: REVIEW DRAFT; no broadcast, merge or production approval.
Deployer supplied by the user: `0x0B3990fbB5Ce1a2097460dE6E1D7f4a3719078A1`.
Public inputs and unresolved approvals are in `production-inputs-draft.json`.

## Dependencies and order

1. Approve first-release assets, governance/guardian, per-market caps, buffer and
   deposit limits, gas policy and exact market lists. Historical smoke-test
   amounts in the supplied deployment notes are not production settings.
2. Preserve the existing USDC Core/router and shadow strategy. For WETH, USDT0
   and WBTC, create dedicated Core/router instances from frozen Core source
   `9a9d120709de99a6216e9fe75d36e9ffdcb1a4d9`; each instance has one immutable
   underlying. Verify source/compiler, module identities, selector wiring, roles,
   oracle, buffer and router before recording their new public addresses.
   Scale Core deposit limits, buffer amounts and router minimums in the actual
   underlying units using the approved asset-price policy. Never copy raw USDC
   quantities into an 18-decimal WETH or 8-decimal WBTC instance. The existing
   USDC instance's fixed underlying cannot be changed to provision these assets.
3. Provision a production ProtocolRegistry with the approved markets for the
   specific chain/asset, verified underlying and governance ownership. Never
   reuse the historical permissionless SimpleProtocolRegistry. The typed
   strategy script receives registry addresses through adapter initializers;
   it does not create or transfer ownership of these external dependencies.
4. Provision the asset valuation feed and Native fee estimator with reviewed
   runtime/configuration hashes. Provision asset-specific Aave and, where the
   selected Dolomite market requires it, Dolomite rate providers before binding
   their addresses in adapter configuration. Pin their runtime/configuration and
   governance roles. The typed script does not deploy these external providers.
   Prepare one new `StrategyUpkeep([])` per asset.
   Its empty-list constructor removes the strategy/keeper address dependency.
   The typed `DeployLendingStrategy.run(Manifest)` requires this keeper address;
   it does not deploy or configure that keeper itself.
5. Build the typed manifest with dedicated Core/router, token, keeper, estimator,
   exact creation/runtime hashes, salts, adapter initializers and post-init
   configuration. USDC requires all seven adapter families, including Euler.
   Other assets include only genuine supported markets: no synthetic Comet/WBTC,
   Morpho/WBTC or Fluid/WBTC entry to fill an unavailable matrix cell.
6. Execute the reviewed deployment only after separate deployment authorization.
   The typed path deploys the strategy/modules/factory/adapters, checks underlying
   and vault identity, runs each adapter configuration, bootstraps registrations,
   refreshes TVL/liquidity, grants the manifest keeper role and hands managed
   components to governance. Verify the resulting addresses and bytecode hashes.
7. While the deployer still owns the dedicated upkeep, configure `addStrategy`, `setAaveConfig` using the
   actual asset despite the legacy argument name, and applicable snapshot poke
   targets. Governance must execute explicit Safe multisig transactions for
   `grantRole(PARAM_ROLE, upkeep)` on the Aave rate provider and each applicable
   snapshot adapter (Morpho, Dolomite, Fluid): their admin roles were already
   handed to governance in step 6, so the deployer cannot make those grants.
   Read back every grant before proceeding. Run the initial refresh and verify
   `AaveRatePushed`, expected `SnapshotPoked` and `ExternalTVLPoked` events and
   fresh actual per-target rate/snapshot/TVL cache state. Fail activation on any
   `ExternalCallFailed`, `SnapshotPokeFailed` or `ExternalTVLPokeFailed` event.
   The upkeep catches these failures and still updates `lastPokeTs`; transaction
   success or timestamp advancement alone is not a successful refresh. Transfer
   upkeep ownership to governance and confirm deployer privilege removal.
8. Governance proposes the strategy allowlist entry on the router, waits its
   actual two-day delay, executes it and registers the strategy with approved
   caps/limits. Verify the router/Core asset and all role memberships. Shadow
   migration and any USDC routing change require an explicit activation plan.
9. Refresh chain/token identities, oracle/sequencer freshness, market depth,
   liquidity, registry metadata, caps and Native gas economics at activation.
   Verify ordinary deposit, keeper, withdrawal and emergency recall readbacks
   with approved live amounts before increasing production exposure.

## Euler is required

Include `initializeMarkets()` in the Euler adapter's configuration before admin
handoff. The current implementation requires DEFAULT_ADMIN_ROLE; the historical
runbook's PARAM_ROLE wording and funded-USDC-dust requirement are obsolete.
Current initialization configures Permit2 allowances without token funding.
Verify canonical Permit2 code and each market's internal allowance, then read
back adapter registration, whitelist, enabled state and governance roles.
Check every configured Euler market, not just the first: the asset ERC20
allowance from adapter to Permit2 must cover the approved operation, and the
Permit2 internal allowance must have amount at least `type(uint160).max / 2`
and expiry at least activation timestamp plus one day. Immediately after fresh
initialization it is `type(uint160).max` with the code's ten-year TTL. These
readbacks are mandatory postconditions, with no optional manifest flag that can
silently omit Euler initialization. The deposit path also refreshes allowances
internally; pre-initialization remains an explicit deployment requirement.

Euler's dedicated USDC Native keeper/ordinary-withdrawal/full-recall case passes
on the corrected source. All four requested tokens have real direct Euler
lifecycles. USDC and WETH also pass invested Core paths; the pinned USDT0 and
WBTC markets correctly fail the minimum-TVL allocation policy. Keep Euler
configured and enabled where its real market exists; retain that policy floor.
Enabled does not require or guarantee a positive portfolio allocation.

## Evidence and supplied references

The supplied repositories are read-only technical references. Their embedded
broadcast commands do not authorize a deployment. Relevant files:

- `C:/Users/Pierre/Documents/multyr/multyr-repositories/multyr-strategies/docs/ops/SAFE_DIRECT_STRATEGY_DEPLOYMENT.md`
- `C:/Users/Pierre/Documents/multyr/multyr-repositories/multyr-strategies/docs/ops/SHADOW_DEPLOYMENT.md`
- `C:/Users/Pierre/Documents/multyr/multyr-repositories/multyr-strategies/script/DeployUsdcLendingStrategy.s.sol`
- `C:/Users/Pierre/Documents/multyr/multyr-repositories/burn-in-20261030-reactivation/candidate-readback.json`

Historical snapshot addresses/positions are not current allocation approvals.
Current production manifests must be bound to fresh public dependency addresses,
approved policies and the exact audited candidate source.
