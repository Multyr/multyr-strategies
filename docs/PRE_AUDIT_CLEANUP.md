# Lending pre-audit cleanup

Scope: F0-F13 from the review of deployed tag a3f15a2. This is a new source candidate, not a mainnet patch. The existing deployment tag remains immutable. Single-adapter operation remains supported.

## Decisions

- F0: PR targets main and includes deployed commit history. Main is not aligned until reviewers merge; no direct merge is authorized. Audit scope must name the resulting exact commit, not just a branch.
- F1-F4: deprecated ABI arguments now reject non-neutral values. exitDriftBps and minLiquidityReadinessBps accept only 0; regime hysteresis/budget accept only 10000. They introduce no new allocation restrictions. Storage slots and function/event signatures remain to avoid shifting delegatecall layout or silently breaking decoders. A caller cannot configure a fictional active control.
- F5: deprecated minAdaptersActive accepts only 1, in constructor and setter. No minimum-diversification invariant is introduced. TVL top-N and capacity constraints remain the policy. Deployment fixtures use 1. Legacy settings-copy tooling must not blindly copy non-neutral deprecated fields from older contracts: migrate them explicitly to neutral values and record that intentional difference.
- F6: StrategyConfigLib is the single source of max-adapter and seed tiers. Scoring, allocator and lens use it. Extracted per-adapter target cap calculation is behavior-preserving compiler stack relief, not a policy change. Internal functions still contribute to runtime size; compilation and existing size checks apply.
- F7: Euler initialize, update and registry admission validate asset() against USDC. Comet/Morpho registry loads also validate underlying assets, so a trusted registry cannot silently bypass adapter admission checks. Registry remains a catalog; asset compatibility is enforced by consumers.
- F8: fallback gas branch uses gasCostUSDC directly; the obsolete storage slot stays explicitly deprecated for layout compatibility. ReadOnlyGasEstimator remains the active dynamic path.
- F9: degradedModeEnteredAt is explicitly telemetry, not a timer input.
- F10-F13: removed unused Morpho decimal/TTL constants, Venus chain constant and Dolomite error. Morpho staleness remains controlled by apyStalenessSeconds; no live freshness check was deleted.

## Deployment consequences

This does not change contracts holding funds. A corrected lens can be deployed separately. Corrected strategy/modules and adapters require their own deployment/binding review and migration plan. Never attach newly compiled delegatecall modules to an old strategy merely because slot names match. Keep the existing burn-in candidate distinct; any replacement/configuration change requires acceptance-clock review. No Safe transaction, production deployment, branch merge or tag move is part of this change.

Existing constructor/setter consumers must supply the neutral compatibility values. Retained public getters are historical compatibility/telemetry, not new risk controls. Changes deliberately fail loudly on unsupported settings instead of accepting ineffective values.
