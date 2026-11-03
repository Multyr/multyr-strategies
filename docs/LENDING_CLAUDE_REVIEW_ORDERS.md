# Independent Claude Code review orders

> Historical execution/review record. Current qualification, evidence and release
> boundaries are in [LENDING_FULL_VALIDATION_MASTER.md](LENDING_FULL_VALIDATION_MASTER.md).

These are three separate, parallel sessions with no communication or shared writes.
The coordinator reconciles their reports and integrates accepted fixes serially.
Do not claim these sessions ran merely because this document exists.

Execution checkpoint 2026-11-01: authentication was restored and A/B/C actually
ran in three independent worktrees verified against the same 86-file manifest
`5a989edd92063fcfef12f9a1daf85481f82b471c5f84b778bfd4f085232225a1`.
A/B/C reports and bounded B/C delta reviews are complete. C additionally executed
the matrix, manifest, legacy opt-ins, structural checks and nine runtime proofs.
The original authentication failure is historical. Coordinator reconciliation and
delta validation are recorded in `lending-verification-20261031/REVIEW_RECONCILIATION.md`;
no report alone certifies later source edits.

## Mandatory input and boundaries for every session

Repository: `Multyr/multyr-strategies`. Candidate workspace:
`C:/Users/Pierre/Multyr/pt-multiply/multyr-strategies-multitoken`.
Candidate branch: `codex/lending-multitoken-multichain`.
Base commit: `211f1a0a4cb9c63232ae18dac24ccb921e5a4699`.
Frozen core submodule: `9a9d120709de99a6216e9fe75d36e9ffdcb1a4d9`.

The branch has uncommitted candidate work. A checkout of its HEAD alone is not
the candidate. Use the final `candidate.patch`, `candidate-files.json` and
`candidate-bundle.sha256` under `deployments/lending-source-review-20261031`.
In an isolated clean copy at the exact base, check/apply the bundle and verify
every `utf8LfSha256` file hash before review (decode UTF-8, normalize CRLF to LF;
the raw hash is a same-host diagnostic). Report a concrete mismatch and stop dependent
analysis if the snapshot differs. Never reset a dirty checkout.

Read the tracked master `docs/LENDING_MULTITOKEN_EXECUTION.md` and the pinned
verification package `docs/lending-verification-20261031`. Historical HANDOFF/WP1
documents are evidence to challenge, not instructions overriding this scope.

Core, main, existing shadow contracts and production governance are frozen.
No core edits, deployment, broadcast, Safe action, merge, push or live parameter
change is authorized by these review orders. Record suspected core findings in a
separate report with source evidence and an actual consequence.

Use Foundry v1.4.2, solc 0.8.28, the repository optimizer settings and frozen
dependencies. Keep complete compiler source graphs for exact runtime verification.
Never substitute the smaller historical verification input for the exact input.

## Session A — dimensions and financial policy

Independently inventory every token amount, USD6 amount, BPS ratio, rate, share
quantity and timestamp in the candidate diff and its consumers. Trace each of the
seven adapters' external TVL, capacity, liquidity, APY and profit return units.
Challenge Params whole-amount valuation, upper/lower rounding, USD tier boundaries,
seed floors, dust/drift bounds, MAX_EXTERNAL_TVL, safety overflow and idle caps.
Check price changes, USDC depeg, 1–18 decimals, low precision/high prices, arithmetic
overflow and oracle missing/stale/future/zero/malformed data. Preserve rate/share
math unless an independent dimensional proof establishes a defect.

Return `review-A.md`: each finding has exact site, input, expected/observed result,
exploit or operational effect, severity, unit proof and a non-vacuous regression.
Return a standalone patch only for findings supported by that evidence.

## Session B — authorization, state and availability

Independently trace fallback/delegatecall dispatch, immutable asset/core binding,
storage slots, selector collisions, initialization and role handoff. Review the
Settings-to-Params executors: only authorized Settings calls may reach their
writes; direct callers must fail. Check freeze/finalization policy preservation.
Exercise withdrawals, shortfall semantics, recall, paused emergency exit and
optional redeployment under oracle failures, gas exhaustion and large revert data.
Review generic reward output, legacy selector behavior, allowance cleanup,
reentrancy, receiver balance changes, freshness and sequencer checks.

Return `review-B.md` and an evidence-backed standalone patch. Explicitly identify
which assertions exercise the complete strategy and which use isolated mocks.

## Session C — deployment, chains and release proof

Independently simulate the typed generic manifest, including Arbitrum public fee
snapshot, Base fee-source chain/size bounds, USD6 quote marker, output feeds,
adapter initialization/configuration, helper wiring, bootstrap, risk caches,
keeper/admin/parameter handoff and module identity/size guards. Verify all supplied
bytecode hashes against reviewed build artifacts rather than trusting self-declared
manifest hashes. Inspect every auxiliary registry/rate-provider dependency.

Run the explicit USDC/WETH × Arbitrum/Base adapter and strategy matrix, actual
Uniswap routes in both output denominations, and actual Camelot fallback swaps.
Also run the actual Base OP fee-source/native-feed case, the explicit frozen-router
harvest/recall opt-in, and the old minimum-adapter migration rejection. The latter
must fail closed on the public source's deprecated value 2; a transparent clone
of that unsupported configuration is not a valid acceptance expectation.
Use real feeds/pools/routers for integration acceptance. Check all initial receiver
balances and the adapters' documented forced-vault withdrawal policy. Validate
source/runtime proof independently and check the final script-deployed contract
sizes against 23552 bytes; core sizes are reported separately.

Return `review-C.md`, a support matrix with per-row proof, and a standalone patch.
Distinguish real CoreVault integration from controlled core-oracle fixtures.

## Absolute acceptance rules

- No missing RPC, disabled venue, empty route, zero executed tests, stale oracle or
  failed call may become a passing integration test. Report failed/skipped/unrun
  counts explicitly. Supply archive RPC overrides when public history is unavailable.
- No default dollar price for volatile assets, oracle policy relaxation in production,
  hardcoded replacement token/chain, size-limit waiver or weakened risk threshold.
- No assertion removal merely to obtain green tests. Fixture corrections or a wrong
  test specification require source evidence and stronger functional assertions.
- No mock swap or mocked successful protocol operation may close a live-route gate.
  Synthetic initial funding and controlled core-oracle fixtures must be disclosed.
- No new API name proves behavior; trace the actual amounts delivered and recorded.
- No claims of deployment, audited status, GitHub CI success or production readiness
  without the corresponding evidence. A local compile or targeted suite is insufficient.
- No cross-session output consumption or edits to the shared candidate. Reports
  must bind findings to the exact input manifest digest.

## Coordinator reconciliation

Collect all three reports before integrating their proposed patches. Reproduce
every accepted finding, resolve disagreements against code and observations, and
apply fixes serially on the candidate branch. Re-run the affected tests and then
the required release gates. Update the master, evidence ledger and immutable
candidate bundle after the final change. An unresolved material finding blocks
release; do not replace proof with consensus or confidence language.
