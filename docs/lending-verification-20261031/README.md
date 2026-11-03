# Pinned deployed-source verification

Current candidate acceptance records are adjacent to these deployed-runtime proofs:
`final-validation.json` (2789 regression +25 real-market cases, zero failed/skipped),
`candidate-structure.json` (20 runtime sizes, nine layouts and selector
inventory), `base-fee-observation.json`, `core-oracle-observation.json`,
`excluded-historical-forks.json`, and `claude-review-status.json`.
`REVIEW_RECONCILIATION.md` records all A/B/C decisions and the bounded delta reviews.
`published-shadow-profile.json` and `unmocked-canonical-blocks.json` pin the real
reserve/withdrawal profile and historical simulation headers.
`unmocked-e2e-proof.json` records 16 real historical snapshots, four actual holder
funding transfers and two actual funding swaps for the four unmocked profiles.
`comet-abi-source-proof.json` pins the official eight-field Comet source and the
published WETH-market ABI failure; `lint-cast-triage.json` assesses all 40 cast sites.
`reviewed-input-86.json` and `reviewed-input-86.patch` retain readable original
review input, distinct from the final candidate. `reviewed-input-86-bytes.json`
preserves their exact original bytes and SHA256 values across Git line-ending
conversion: decode each bytesBase64 field and verify sha256. These files reconstruct
that historical input at the pinned base; do not apply them over the final tree.
`reviewed-B-delta-input.json` / `reviewed-C-delta-input.json` bind the subsequent
bounded reviews; `claude-execution-receipts.json` records successful CLI terminals
and raw transcript hashes. Reconciliation and final tests supersede incorrect
claims in those historical reports.
The existing nine-contract reproduction was rerun end to end successfully.
The runtime proofs concern the frozen existing lending deployment; they do not
attest that the candidate has been deployed or independently audited.

Nine deployed Lending contracts were independently reproduced and compared byte
for byte with Arbitrum state at block **520094008**, hash
`0xd0e4d2d28e0d9a60d819743930f9f2843409bf37a895a411620a632da53fa600`.
Every `*-proof.json` here has `exactRuntimeMatch: true`.

| Contract | Runtime bytes |
|---|---:|
| UsdcMultiLendingVault | 22786 |
| StrategyParamsModule | 14381 |
| StrategyScoringModule | 22085 |
| StrategyAdapterOpsModule | 18240 |
| StrategyRebalanceGateModule | 22939 |
| StrategySettingsModule | 23344 |
| StrategyAllocCalcModule | 21650 |
| StrategyRebalancePlanModule | 22869 |
| StrategySafetyOverflowModule | 13472 |

The source files were fetched independently through GitHub at commit
`407b3df677e97c8e523ae11948d534ec9fed11cc`. Their returned Git blob IDs
matched local Git. Their text also matched the complete historical compiler
input after normalizing line endings and trailing EOF whitespace. See
`github-sources.json` for the nine public source links and blob IDs.

Compiler: **0.8.28+commit.7893614a**, optimizer enabled/runs 200, via IR,
Cancun, no appended metadata. Complete original input:
`deployments/ema-first-20261023/allocator-exact-input.json`.
SHA256: `2965b721dc14de5cbe12667f883749b3a122ed1e247e5ada11ac0511507ec4d4`.
Git blob: `a2891f2169e94843ba523e971ed8c0035ea4a326`.

The complete source graph matters. The similarly named minimal
`allocator-verification-input.json` does **not** reproduce the deployed allocator:
it produces 23025 bytes instead of 21650. Keeping the full original source graph
resolves that discrepancy. Do not substitute a pruned input in this verification.

Run `script/ReproduceLendingRuntime.ps1 -SolcPath <local-0.8.28-binary>`.
It preserves the full source graph, selects runtime/AST outputs, invokes the
exact compiler and calls `script/VerifyPinnedRuntime.ps1` for every address.
Large generated compiler files go under `deployments/lending-source-review-20261031`;
small immutable-binding/runtime proofs are retained here for review.

The verifier identifies each immutable through its AST ID, reads its deployed
getter (or binds `_self` to that module's own address), verifies the observed
word, substitutes the compiler placeholder and compares the **entire runtime**.
It does not simply mask immutable regions and accept the rest.

Runtime reads were cross-checked through public Arbitrum providers. The Blast
archive endpoint was needed for reliable fork state; the official public gateway
occasionally returned missing-trie errors. No live state was written.

These proofs describe the existing USDC shadow deployment. The multi-token
candidate is separate and requires its own release artifact hashes and acceptance;
these proofs do not describe a deployed WETH strategy.
