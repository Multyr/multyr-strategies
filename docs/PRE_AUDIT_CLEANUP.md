# Lending pre-audit cleanup

Scope: F0-F13 from the review of deployed tag a3f15a2. This is a new source candidate, not a mainnet patch. The existing deployment tag remains immutable. Single-adapter operation remains supported.

## Decisions

- F0: PR #14 targets main and includes deployed commit history; cleanup PR #15 is stacked separately and must be retargeted to main after #14 merges. Main is not aligned until reviewers merge; no direct merge is authorized. Audit scope must name the resulting exact commit, not just a branch.
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

## Validation — 28 October 2026

Final command: `forge test --match-path 'test/strategies/usdc-lending/*.t.sol'` with Solidity 0.8.28 and the repository configuration. Result: **2,717 passed, 0 failed, 15 skipped** across 195 suites (2,732 tests). This includes allocator/scoring tier parity, gate, adversarial/invariant, bytecode-size and adapter admission coverage. Conditional fork/deployment tests were skipped; this run is local regression evidence, not live deployment acceptance.

The storage-layout source was compared with parent `df9f8fc` after removing comments and whitespace: identical. Occupied slots and declaration order are preserved. `git diff --check` passes. A post-test warning about writing the local Foundry signature cache does not affect the successful test result.

PR #14 must still be reviewed and merged to resolve main-branch alignment. PR #15 contains the separately reviewed, undeployed fixes; no mainnet configuration or bytecode was changed.
