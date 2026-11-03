# Chain profile reconciliation — 2026-11-02

Status: NOT_PRODUCTION_READY. Source review; no address validation is implied.

The five legacy UsdcLendingConfig descriptors are not consumed by the generic
DeployLendingStrategy route. Its manifest supplies the actual asset and chain;
nonzero governance/keeper and validateForSource are enforced. Claims that the
current deploy route is Arbitrum-only, lacks governance validation or omits
validateForSource were rejected. Unused zero fields do not instantiate markets.

Optimism aUSDC and Base Comet legacy entries remain explicitly incomplete.
Governance is deployment-specific and must come from the reviewed manifest.
Existing NativeL1FeeInfo and OPStackFeeInfo constructors are deployable source;
absence of a historical deployment is an operational dependency, not missing
implementation. Base native-fee integration has passed actual-fork acceptance.
Optimism native-fee candidate integration is still unvalidated.

Polygon has a confirmed reachable-source limitation: the estimator permits zero
sequencer only on chains 1/56 and rejects native prices below USD100. Native fee
source also permits only 1/56. A bounded chain137 proposal is assigned to Claude
in pd; it is not integrated or accepted. It must preserve existing ETH/BNB
sanity bands, all L2 sequencer checks, dependency guards and replay rejection.
Both controlled failing-before tests and real-feed/protocol acceptance remain
mandatory before claiming Polygon support. No advertised profile is silently
accepted or removed on the basis of legacy descriptor comments.

Independent proposal: p0/deployments/lending-full-validation-20261101/production/
A-config-inventory/report.md. Its corrected G3/G4 descriptions still overstate
source absence: the fee helpers exist and Base has actual integration evidence.
This adjudication controls acceptance; the external proposal is not authority.
