# Lending remediation finding register

Candidate base `211f1a0a4cb9c63232ae18dac24ccb921e5a4699`, branch
`codex/lending-multitoken-multichain`. This register concerns the candidate, not a
retroactive modification of the frozen shadow deployment. Final test counts and
release gates are recorded in `LENDING_MULTITOKEN_EXECUTION.md`.

| ID | Defect and consequence | Candidate resolution | Evidence |
|---|---|---|---|
| MT-01 | Six-decimal asset thresholds apply wrong economic tiers to other assets | Complete underlying quantities valued in USD6 through fresh core oracle; whole USD thresholds converted once, rounding up | OracleAssetValuation; literal tier replay; four strategy fork rows |
| MT-02 | Scaling a rounded one-dollar token quote overstates thresholds for low-precision expensive assets | Central Params tier valuation; MAX_EXTERNAL_TVL compares the complete USD value instead of a rounded token upper bound | Low-decimal/high-price tier and TVL-bound regressions |
| MT-03 | Dust/drift bounds, overflow market minimum, idle caps and retry floors retain raw dollar literals | Convert economic limits at use; guarded Settings executors centralized in Params to preserve bytecode margin | Oracle, vault, plan and unauthorized executor tests |
| MT-04 | Gas cost denominated in USDC quantities changes with USDC peg and blocks on an unrelated feed | USD6 quote marker; native ETH/USD cost only; no USDC feed call; OP fee provider and chain-bound preflight | ReadOnlyGasEstimator26, OPStackFeeInfo4, GasIntegration26; manifest without USDC feed |
| MT-05 | Reward conversion returns only USDC; wrong Algebra path assumptions reject valid fallback | Generic output asset and USD feed; full-precision conversion; explicit legacy selector; separate Uniswap/Camelot V1 validation | Reward unit/fuzz tests and six actual router/feed fork swaps |
| MT-06 | A failed optional redeployment rolls back an otherwise completed withdrawal | Both withdrawal overloads defer redeployment failure, reserve caller gas and bound revert-data copying; emergency recall remains independent | Missing-oracle withdrawal tests for both overloads, full recall and strategy fork matrix |
| MT-07 | Deployment assumes one asset/chain and tolerates constructor-only invalid settings | Typed manifest pins chain/core/asset/modules/adapter hashes; guarded setter validation, fee preflight, reward wiring, identity/size checks and complete role handoff | Five deployment tests: 6/18 decimals on each chain plus explicit Arb fee-snapshot failure; real Core/Router lifecycle on four fork rows |
| MT-08 | Lens cap display diverges from allocation when global ceiling is zero | Canonical effective cap including overlays | LendingLensCapParity and existing lens regressions |
| MT-09 | Existing CI filters can display green without executing the intended fork tests | Explicit matrix19, unmocked E2E4, Comet2, legacy2, manifest5 and full regression; strict expected pass/suite counts and zero skipped/failed required | Summary guard accepts actual 2789/25 logs and rejects failed, empty and skipped controls; YAML parsed; remote CI execution is not claimed |
| MT-10 | Historical source record does not establish deployed bytecode identity | GitHub source blobs at actual source commit, complete compiler graph and immutable-bound exact runtime reproduction | Nine positive pinned-chain proofs; reproduction scripts |
| MR-01 | Comet totalsBasic uses a six-field ABI and narrows supply principal to uint64; real WETH call reverts | Exact official eight-field ABI and uint104 supply principal; corrected mock ABI | CLOSED: both actual USDC/WETH supply checks pass; pre-fix WETH decoding failure captured |
| MR-02 | Comet absolute token cash swamps BPS score and changes market ranking by asset value | Readiness BPS bounded at 10000 using cash / managed assets | CLOSED: three actual optimize-decision unit regressions pass for 6/18 decimals and equivalent quantities |
| MR-03 | Dolomite scoring and benefit gate read never-written lastAPYBps | Canonical per-market observed PPS/provider rate, bounded and failure-isolated; unchanged storage | CLOSED: three provider/PPS optimize-decision unit cases pass |
| MR-04 | Core acceptance uses mocked Params, oracle and warm NAV | Additional unmocked production-component E2E with real funding, swaps, historical prices, interest, two epochs and recall | CLOSED: four strict historical production-component profiles pass; real funding/swap/price/interest/recall records retained |
| MR-05 | Empty Ops module failure silently reports keeper realization success | Bubble failure; QueryFailed when empty; normal protocol shortfall handling preserved | CLOSED: keeper, withdrawal and exact nonempty-revert bubbling regressions pass |
| MR-06 | Advisory lock multiplication can overflow uint64 | Bound setter to largest safe value for degraded multiplier | CLOSED: exact boundary and overflow rejection tests pass |
| MR-07 | Safety module missing in matrix and overridden cooldown fixtures; slippage documentation disagrees with runtime | Install actual module through Settings, observe fixture liquidity, correct 5% comments | CLOSED: original matrix19 and repaired cooldown2 pass; 20 size checks pass |
| MR-08 | Missing/failed risk check reports healthy; oversized Morpho registry bypasses manual market bound | Fail closed for deposit/harvest risk checks while preserving exits; enforce registry max255 | CLOSED: risk fault injection, idle-withdrawal availability and malformed-registry rejection pass |

## Baseline policy reconciliation

Historical F1–F5 are not new fixes in this diff: the candidate base already rejects
non-neutral values for the four deprecated controls and fixes `minAdaptersActive`
to 1. It does not promise a diversification floor. The frozen deployment's value
of 2 remains a historical observation, not a guarantee implemented by this candidate.
Preserve this distinction when interpreting old handoffs or configuring manifests.
The pinned old source at `0x7bF0f446BB20b54597E66a602cB94D0F231D24E2` returns 2.
Its copy test now asserts the actual candidate constructor rejects that value;
it cannot silently normalize old governance policy and claim clone parity. Five
positive local copy tests still cover supported configurations. This release uses
fresh explicit manifests, not automatic migration from incompatible settings.

Historical N1 strict-deposit atomic failure and N2 failure-decay/cooldown interaction
remain separate operational-policy observations. A reverted transaction cannot
persist an onchain failure counter; monitor transaction failures externally.
Quarantine reachability depends on the configured decay and operation cadence.
Do not assert guaranteed repeated-failure quarantine for every keeper schedule.
No live parameter change or speculative risk-policy rewrite is part of this release.

## Support and approval limits

Executed integration support is Aave with standard fixed-balance USDC/WETH on
Arbitrum/Base at the pinned blocks, plus the documented real reward routes.
Other adapters have local regressions; other venue/asset/chain combinations still
need their own manifests, liquidity and lifecycle evidence. Generic extensibility
does not certify every EVM chain, token or lending market.

Independent Claude A/B/C reviews ran after authentication was restored. Their
claims and proposed patches are critically reconciled in
`lending-verification-20261031/REVIEW_RECONCILIATION.md`; findings are not accepted
merely because a reviewer proposed them. Final reviewed-source validation passes:
2789 regression plus25 real-market cases, zero failed/skipped.
Local successful checks and AI reviews are not a formal external audit certificate
or live release approval. Existing core/shadow contracts are unchanged.
