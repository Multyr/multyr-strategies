# Lending multi-token / multi-chain execution master

> Reopened 2026-11-01: the user requires all seven adapters, additional underlying
> tokens and independent scoring verification with real values. Previous closure
> below is historical evidence for Aave USDC/WETH × Arbitrum/Base only.
> The active master is `LENDING_FULL_VALIDATION_MASTER.md`; overall completion is OPEN.

Date: 2026-11-01. Branch: `codex/lending-multitoken-multichain`.
Base: `211f1a0a4cb9c63232ae18dac24ccb921e5a4699`.
Status: confirmed findings remediated and final validation complete for the
declared USDC/WETH × Arbitrum/Base profile. Independent A/B/C reviews and bounded
B/C delta reviews are reconciled. 2789 regression +25 real-market cases pass,
zero failed/skipped. Unreleased; core/main/live shadow contracts remain frozen.

This tracked master supersedes stale candidate status in the historical handoff.
Core and existing deployments are frozen. Candidate requires a new strategy, its
complete module set and new adapter instances. Existing live modules must never
be replaced with these candidate modules.

| Gate | Required result | State |
|---|---|---|
| E1 | Whole-amount USD valuation, low-decimal tiers, literal USDC parity and lens agreement | CLOSED: oracle/boundary, literal tier, lens and strategy tests executed |
| E2 | Generic reward output, explicit legacy USDC semantics, correct router path validation | CLOSED: unit/fuzz tests and six actual router/feed swaps |
| E3 | Typed generic deployment, explicit enabled adapters, two assets on two chains | CLOSED for declared matrix: five manifest cases; four strategy and four Core/Aave lifecycles |
| E4 | Withdrawals and emergency recall remain available when valuation fails | CLOSED: both withdrawal overloads, emergency recall and oracle-failure fork exits executed |
| E5 | Layout, selector dispatch and project size buffer | CLOSED: 20 runtimes below 23552; nine identical layouts; 296 distinct signatures, no selector collisions |
| E6 | GitHub commit / deployed runtime / pinned state reconciliation | CLOSED for nine existing strategy/module contracts; exact proofs under docs/lending-verification-20261031 |
| E7 | Local regression, invariants, actual fork execution and CI accounting | CLOSED: final source 2789 regression +25 explicit real-market cases, zero failures/skips; legacy opt-ins enabled |
| E8 | Security reconciliation and deployment evidence bundle | CLOSED: A/B/C and B/C delta reviews reconciled; complete patch/hash bundle checked against the clean exact base |
| E9 | Unmocked production core, real funding/oracles/markets, historical simulation and actual recall | CLOSED: four unmocked production Core/Aave historical lifecycles and two published Comet supply ABI checks executed |

## Implementation decisions

- Params values entire underlying quantities in USD6 using the frozen core oracle.
  Tier tables run against USD6; seeds/costs convert whole USD amounts back with
  upward rounding. A rounded one-dollar token quantity is never multiplied into
  a financial tier. Whole-token `referenceUnit` remains only for token policies.
- Tier evaluation lives in Params to avoid duplicating tables across modules near
  the project size buffer. The lens reads the same canonical entry points.
- Gas estimator quotes are USD6. Historical `costUSDC` names preserve ABI only.
  Deployment checks require `quoteCurrency() == bytes32("USD6")` so an old
  USDC-denominated estimator cannot be silently accepted.
- Residual dollar literals in safety overflow, idle-deploy caps/retry floors and
  plan drift defaults are converted at use. Dust/drift inputs remain raw underlying;
  monetary bounds are validated centrally. Settings checks roles before forwarding;
  Params executors accept only calls from the strategy itself.
- Lens exposure reports use the canonical effective cap, including the zero
  governance-ceiling sentinel and risk/failure/liquidity overlays.
- `RewardSwapHelper.initializeAsset` disables `swapToUSDC`; legacy `initialize`
  explicitly retains USDC integration semantics. New adapters use `swapToAsset`.
  Camelot integration targets Algebra V1 token/token paths; other Algebra versions
  are outside this router integration until separately validated.
- Optional post-withdraw redeployment is best effort and emits
  `WithdrawalRedeployDeferred` on failure. The failed delegatecall rolls back its
  own effects, preserving the completed withdrawal and idle recovered assets.

## Generic deployment manifest

Use the typed `DeployLendingStrategy.run(Manifest)` entry point. The inherited
zero-argument entry point rejects execution. All amounts in `parameters` retain
their documented units: dust/seed are underlying raw units, economic costs USD6,
ratios BPS, durations seconds. No USDC defaults are applied to a generic deployment.

The reviewed manifest pins chain ID, asset/core/router, governance/guardian/keeper,
parameters, estimator config hash, fee source, native ETH/USD infrastructure
feed, output-asset USD feed, and each enabled adapter's creation/runtime hashes,
salt, atomic initializer and configuration calls. Adapter initializers must use
the predicted candidate strategy address. Compute this from the signer nonce
before simulation; the existing module deployment phase asserts predictions.

For Morpho adapters, `morphoLiquidityViewRuntimeHash` must independently pin the
reviewed `MorphoVaultV2LiquidityView` runtime. The script installs the stateless
helper before bootstrap if absent, preserves a valid explicit configuration,
and rejects a missing manifest pin or mismatched deployed code. This helper
reports conservative immediately withdrawable idle assets for V2; it does not
claim allocated assets or force-deallocation liquidity.

Creation/runtime hashes must be taken from the reviewed release artifacts. A hash
supplied by the same manifest is an integrity check, not independent approval of
arbitrary bytecode. Review every initializer and configuration call. Registries,
rate providers and other dependencies referenced there must have their own
verified chain/asset configuration and governance handoff evidence.

The script deploys candidate strategy components, enabled adapters and optional
reward helper, verifies actual underlying/vault/runtime identity, bootstraps,
pokes risk caches, and transfers strategy/adapter/helper/factory roles. It performs
no core registration or activation. Core governance activation remains a separate
reviewed operation after all gates pass. Run full simulation before broadcasting.
Arbitrum manifests must include the public ABI-encoded six-word fee snapshot for
local ArbOS simulation. It is included in the manifest hash and does not replace
the live precompile. Base uses `OPStackFeeInfo` with checked chain/size bounds.
The estimator never consults the historical USDC/USD field: USD6 is a unit of
account, and a missing, failed or depegged USDC feed cannot change native gas cost.
The legacy feed binding is optional. Initial manifest parameters are reapplied
through the actual guarded setters; constructor acceptance alone is insufficient.

Standard fixed-balance ERC20 assets with 1–18 decimals are the generic deployment
scope. Fee-on-transfer and rebasing assets require separate designs and tests.

## Candidate market matrix and evidence

`LendingAssetConfig` lists only Aave market identities for USDC/WETH on Arbitrum
and Base. Other venue protocols are explicitly absent from this initial matrix;
their adapters remain available through reviewed manifests. Identity entries are
not an assertion of operational support.

- Arbitrum snapshot: block `520094008`, hash
  `0xd0e4d2d28e0d9a60d819743930f9f2843409bf37a895a411620a632da53fa600`.
- Base snapshot: block `53345555`, hash
  `0x23f23c9ec0173765a675cac9c54af14d03d61d1e4efd19e0cb22721a0426d45e`.
- Public RPC calls reproduced the four aTokens' `UNDERLYING_ASSET_ADDRESS()`.
  Arbitrum native USDC uses aToken `0x724dc807b04555b71ed48a6896b6F41593b8C637`;
  `0x625E7708f30cA75bfd92586e17077590C60eb4cD` instead wraps bridged USDC.e.
- `LendingAssetMatrixForkTest` executes four explicit deposit/withdraw roundtrips.
  No RPC failure becomes a skipped or passing test. The dedicated CI job runs it.
  The separate strategy matrix exercises allocation, harvest, oracle failure exit
  and emergency recall. The Core matrix uses the unchanged CoreVault modules and
  StrategyRouter to deposit, deploy to real Aave, request an epoch withdrawal,
  close/fund the epoch, recall invested assets and claim the exact owed balance.
  Synthetic initial funding, controlled bounded core oracles, Params and warm-NAV
  fixtures are explicit; pool/token/adapter/router operations are real fork calls.
  Six reward cases exercise actual Uniswap swaps in both denominations on both
  chains and Camelot Algebra V1 fallback in both directions on Arbitrum.
  A fifth asset-matrix case checks the actual Base GasPriceOracle, native/USD feed
  and sequencer with a real USD6 estimator quote and explicit cold-start defaults.
- The two historical opt-in tests outside the fork directory are also enabled
  explicitly. The frozen deployed router harvests and recalls synthetic rewards
  while core/router/token code hashes remain unchanged. The old source's deprecated
  minimum-adapter value 2 is explicitly rejected by the candidate constructor;
  unsupported legacy configuration is never silently copied or normalized.

## Shadow deployment provenance

At Arbitrum block `520094008`, public calls reproduced:

| Field | Value |
|---|---|
| Strategy | `0x2AD722B6241605481829E4B251AE8A4Ba8Be86cE` |
| ASSET | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |
| Core | `0x5e0cdb76487BD96Ff069Ef7F78eaDF5b5909C8cb` |
| Params | `0x9DdbFF7a2D6cbfdA7fE5Fe72A7e7A09eef8F2772` |
| Scoring | `0x5Aa4d01CEe130f5C5CfADd091c1aFF12496f7A01` |
| AdapterOps | `0xe55fB758f1B7e418670849AF812A1B9C80b40f59` |
| RebalanceGate | `0x7aa669f8Ef61071Cd5FA2b30f26B5ba5Cd741Fc2` |
| totalAssets | `116842563` raw USDC units |
| minAdaptersActive | `2` |

These module addresses agree with the historical address manifest under
`deployments/ema-first-20261023`. That manifest declares source commit `407b3df`;
`a3f15a2` is a later verification-record commit, not the deployed source.
All nine deployed strategy/module runtimes match
independent solc reproduction byte for byte, including checked immutable bindings.
GitHub source blobs and the complete compiler graph were reconciled. See
`docs/lending-verification-20261031/README.md` and the nine positive proof files.
Pinned `eth_getCode` followed by `web3_sha3` reproduced these runtime hashes:

| Contract | Bytes | Keccak256 |
|---|---|---|
| Strategy | 22786 | `0x0ca215f519e1f07888b19b51436dc989e297cfe25efbdbbc696c3ef7bf86cd49` |
| Params | 14381 | `0x831029cd6f2dfde91a80a3f40d194cfcc03d5dd33fbdd432d8cfea1972082727` |
| Scoring | 22085 | `0xfebf7179ee84e4fec235bc99d29ccb2ba3d5b6fd960bebdb49bb1f792a9c2dd8` |
| AdapterOps | 18240 | `0x66cf4f82ba31b8f42a98309c3cea5a7f21e908c5a96e2af29fa9cae67fa6b33d` |
| RebalanceGate | 22939 | `0x12505ebd462cefaf850e480a059745e54de1f4e9b632d1ec9f1f7a3a65b1033f` |

These observations were compared to independent compiler output, with every
immutable binding checked. Source commit
`407b3df677e97c8e523ae11948d534ec9fed11cc` exists locally and pins the
same frozen core `9a9d120709de99a6216e9fe75d36e9ffdcb1a4d9`. Public
`eth_getProof` was inconsistent across RPC backends; raw runtime hashing succeeded.

## Structural verification and release scope

`script/CheckLendingRelease.ps1` reproduces the structural report at
`docs/lending-verification-20261031/candidate-structure.json` using compiler
inspection, not manually read artifact files. Largest candidate runtime is Settings
at 23415 bytes: 137 bytes below the 23552 project buffer. All 20 checked production
components satisfy that buffer. Every strategy/module layout is identical;
`referenceUnit` is last. Comet preserves 25 existing fields and appends one; the
reward helper preserves nine and appends five. The cross-module selector inventory
contains 296 distinct signatures and no collisions between different signatures.

Targeted Foundry high/medium lint execution exits 0 with 40 unsafe-typecast
warnings; this is not a zero-warning security attestation. The broader default
build lint previously hit a native Foundry panic. Compilation is proven by test
execution and clean isolated compiler inspection; no claim that the failed default
build/lint command passed is made. The warnings and this tooling limit remain
inputs to review, not reasons to waive contract size or risk controls. All 40
warning sites now have an explicit bounds assessment in `lint-cast-triage.json`;
that triage identified and fixed the missing Morpho registry cardinality guard.

Core observations are separate in `LENDING_CORE_OBSERVATIONS.md`; resolved strategy
findings and historical policy reconciliation are in `LENDING_FINDINGS_REGISTER.md`.
Other historical optional fork suites, other protocols/chains/assets, live activation
and remote GitHub CI execution are not claimed by this matrix.

## Final acceptance accounting

Final edited Solidity sources were executed, with no source changes after the
final regression started. `final-validation.json` records commands, exit codes,
log hashes, environment and a hash of the changed functional source snapshot.

| Run | Passed | Failed | Skipped | Required unexecuted |
|---|---:|---:|---:|---:|
| Whole lending regression, including fuzz/invariants, 16 new remediation cases and the two enabled historical opt-ins | 2789 | 0 | 0 | 0 |
| Explicit real-market acceptance: original matrix19 + unmocked production E2E4 + actual Comet ABI2 | 25 | 0 | 0 | 0 |
| Generic manifest 6/18 decimals on Arbitrum/Base plus missing-fee-snapshot guard | 5 | 0 | 0 | 0 |
| Actual frozen router recall and incompatible legacy-copy guard | 2 | 0 | 0 | 0 |

The last two rows are also included in the regression row: **2814 unique accepted
tests**. All final command exits are 0. The existing nine-runtime reproduction
script was also run end to end successfully. Twenty production runtime inspections,
storage comparison and selector inventory completed successfully.

Outside this acceptance profile, 12 historical fork files containing 29 directly
declared test cases were not run. `excluded-historical-forks.json` lists them;
its count is static declarations, not expanded inherited runner ABIs. They are not
counted as passes or as evidence of broader venue/migration/deployment support.
Remote GitHub CI has not been executed by this local work.

Record command exit codes and pass/fail/skip/unexecuted counts separately. Run the
final edited sources, not a compiler snapshot taken before later edits. Required:
whole strategy regression, oracle failure/low-decimal boundary tests, router
integration swaps, full strategy lifecycle on each supported matrix row,
generic deployment simulation and role handoff, production bytecode sizes/layout,
and source/runtime reconciliation. Unsupported or unexecuted cases block their
support claims; compilation alone never closes an integration gate.

Claude Code 2.1.142 resumed successfully on 2026-11-01 in three independent
worktrees, each verified against the same 86-file manifest
`5a989edd92063fcfef12f9a1daf85481f82b471c5f84b778bfd4f085232225a1`.
Actual reports and execution supplements are preserved in this verification
package. The earlier OAuth failure is resolved. See `REVIEW_RECONCILIATION.md`
for accepted defects, rejected risk-weakening proposals and review inaccuracies.
Coordinator semantic changes were reviewed in bounded B/C delta sessions and
executed in the final source-bound tests. The subsequent cooldown fixture repair
preserved all assertions and passed both focused cases and the full regression.
AI review and local tests do not constitute a formal external audit certificate
or approval to activate the strategy with live funds.

The final bundle includes all tracked modifications and new nonignored files;
HEAD alone does not contain the candidate. Generate it with
`script/ExportLendingCandidate.ps1` and verify `candidate-bundle.sha256` plus every
normalized file hash. The exporter reverse-checks the patch against the candidate.
Bundle location: `deployments/lending-source-review-20261031/`.

Primary protocol references:
[Aave address book](https://github.com/aave-dao/aave-address-book),
[Algebra V1 path encoding](https://github.com/cryptoalgebra/Algebra/blob/v1.0.0/src/periphery/contracts/libraries/Path.sol),
[OP GasPriceOracle](https://github.com/ethereum-optimism/optimism/blob/develop/packages/contracts-bedrock/src/L2/GasPriceOracle.sol).
