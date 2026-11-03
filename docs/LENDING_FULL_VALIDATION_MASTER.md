# Full Lending validation — qualified release 2026-11-03

**All technical qualification gates pass for the named candidate matrix. Production activation requires approved operational manifests and dependencies.**

The corrected strategy converts the suffix gas quote into the same asset units
as its expected yield. Three regression counterexamples fail on the previous
source and pass on the fix. Post-fix 2,998-test / 204-suite regression, 50/21
cross-chain real-market acceptance, 58 Arbitrum cases, 34 runtime templates,
296 selectors and nine storage-layout/prefix checks pass. Fresh Native
qualification passes twelve profiles (eleven positive and one required economic
rejection), including Euler. All fourteen local-fork profiles pass together with
72 operation receipts; fresh Linux expanded Arbitrum CI also passes. Execution
control at `7203247` adds strict transport-only retries with preserved failures;
all compiled and Native financial inputs equal qualified `3fcc4d4`. Its final
pinned-market CI and general build both pass. All 34 runtime templates match
the independent Windows build. See `lending-arbitrum-assets-20261103/CANDIDATE_READINESS.json`
and `ci-final-acceptance.json` for the current authoritative state. Earlier qualification
records below are historical and do not approve this edited tree.

The requested expanded Arbitrum USDC/WETH/USDT0/WBTC matrix and final cleanup
have passed financial qualification on `codex/lending-final-cleanup-20261103`. The baseline
status below does not qualify these new combinations or the edited working tree.
See `lending-arbitrum-assets-20261103/README.md` for the separate acceptance scope.

Expanded Arbitrum functional acceptance now closes all28 cells explicitly:
25 real adapter lifecycles, 22 invested Core paths, three correct risk exclusions,
four weighted portfolio/rebalance/exit paths and four nonempty frozen Aave-warm
paths. All58 executed cases pass; three protocol/asset markets are unavailable
and are not counted as passing tests. Post-fix regression is2998/204 with zero
failure/skip; all34 runtime templates,296selectors and9layout/prefix checks pass.
The post-fix audit scope is10558NLOC/45 strategy files. See
`lending-arbitrum-assets-20261103/RESULTS.md`. Approved per-asset production
manifests and deployment-time dependencies remain
separate release gates; the expanded working tree is not declared production ready.

Qualified functional source: `03596ac4e5c0d0c37b33c90573456656bda22343` on `codex/lending-multitoken-multichain`.
All124 functional inputs match that commit. Subsequent documentation-only changes
carry the same qualified code. Core/main/shadow remain frozen; no merge or live
activation is authorized by this qualification.

- Regression:2995 tests/203 suites; actual no-mock markets:50/21, with48 positive
  cases and2 required rejections. Zero failures or skips in the required gates.
- All7adapter families have2named chain rows each:14profiles/72real local-fork
  transaction receipts, independently matched in Linux CI.
- Genuine Nitro:8USDC profiles plusUSDT0/Aave, using fresh isolated full-project
  compilation and verified creation bytecode plus encoded constructor arguments.
  Ordinary withdrawal EMA, economic quotes and full recall pass.
- All34 canonical runtime templates match fresh independent Windows and Linux
  production builds; all fit23552bytes.296selectors,9shared layouts and9preserved
  prefixes pass. Compiler-context variance and its remediation are documented in
  `lending-production-remediation-20261101/r44-compiler-provenance-remediation.json`.
- Both current-source GitHub workflows pass:
  [matrix](https://github.com/Multyr/multyr-strategies/actions/runs/41566438866) and
  [build/test](https://github.com/Multyr/multyr-strategies/actions/runs/41566438905).

Scope is the named token/chain/market rows below, one underlying per instance.
wstETH/RLUSD Ethereum Aave and USDT0 Arbitrum Aave are qualified named rows;
other combinations require their own market/feed/configuration qualification.
USDT/USDT0 cold-buffer qualification does not qualify frozen warm adapters:
see CORE-WARM-002 in `LENDING_CORE_OBSERVATIONS.md`. External rewards remain
disabled; activation requires separate qualification. Reference gas calibration
binds its measured topology/policies. Guardian/keeper selection, approved market
caps, live manifest and Safe signing remain per-deployment inputs.

Machine evidence: `lending-full-validation-20261101/final-validation.json`.
Reproduction: clean-base patch application and all124 functional hashes pass.
The complete exported patch, file manifest, checksums and independent full-file
integrity record are placed in `deployments/lending-full-validation-20261101/final`.

## Historical remediation record

The chronological states below are superseded by this release record; earlier
pending/NOT_PRODUCTION_READY labels describe their own historical source cycles.

**Historical reopened state: NOT_PRODUCTION_READY (superseded below).**
R42-R44: both source53 CI workflows pass, including2995/203,50/21 andLinux14/72.
Final comparison exposed compilation-context-dependent AllocCalc templates:
21390bytes in the full integration graph,22765 in the production-only graph.
Fresh Windows/Linux production-only builds agree for all34templates; both
variants fit the unchanged23552buffer. The Native driver now forces an isolated
full-project compile and verifies fresh creation+encoded-constructor hashes.
R44Native requalification and current03596ac CI remain pending; oldNative
records are historical until the new constructor-bound driver passes.
2026-11-03 — R25: three further controlled counterexamples are fixed: readable
PoolLike ownership before first validation and aggregate principal after optimizing
accrued yield. All16 PoolGuard cases pass. New actual wstETH/RLUSD Ethereum
and USDT0 Arbitrum two-user full exits pass without weakening Core policy.
R24 trial runs recorded RPC429 failures; they are not complete acceptance.
R25 final-source acceptance passes50 actual tests/21suites,34 runtimes and
all14 local-fork receipt profiles/72receipts,2995regression tests/203suites
and8genuine Native profiles, all with zero failures/skips. Cold quotes cover
observed wrapper gas in all8profiles; ordinary EMA quotes cover actual wrapper
withdrawals in every dedicated family. Functional hashes are refreshed for R25.
R36 fixes Linux receipt-runner endpoint/process lifecycle and the Native
checkpoint receipt-token guard. Three Linux regression cases pass; the real
USDT0/Aave funded-receipt counterexample now rejects projection correctly.
USDT0/Aave genuine Native keeper, ordinary withdrawal EMA and full recall pass
on the corrected driver. The final default USDC eight-profile rerun also passes. The source patch
applies to a clean base worktree and all124functional hashes match. Exact
feature-source CI and final release export remain open; no merge.
R38 corrects Foundry 1.4.2 endpoint retry binding: vm.createSelectFork
overrides CLI retry/backoff settings with endpoint configuration. All seven
public CI URL keys now carry retries8/backoff2000ms. A cold-RPC rerun with
storage caching disabled passes all4 original real Core/Aave scenarios.
Guardian/keeper selection, market caps, deployment manifest and Safe signing
belong to deployment authorization; they are not extra source-code release gates.
The frozen Core/main/shadow will not be activated or changed by this work.
Qualification is restricted to the tested Core/buffer configurations.
`LENDING_CORE_OBSERVATIONS.md` separately records CORE-WARM-002: the Lending
USDT/USDT0 cold-buffer results do not qualify frozen warm adapters for tokens
with nonstandard ERC20 return data. External reward activation and unmeasured
chain/market/gas configurations require their own qualification.
2026-11-03 — R20/R21: strict Dolomite account/token validation, actual supply
credit, tuple/market ownership guards, retained failed-emergency principal and
disabled-market exits pass 13 controlled cases and 155 related tests. Three
real Ethereum/Arbitrum Dolomite lifecycles now recall with the market disabled.
The safety-plan recall/donation underflow is fixed; all 28 gas/plan integration
tests pass, including the unchanged economic cancellation control and no EMA
observation for a skipped withdrawal. Initial oversized Dolomite proposal23631
was rejected; the corrected isolated production build measures23338 (<23552).
R22 adds wstETH, USDT0 and RLUSD qualification. A new latest-data wstETH/USD
feed composes actual stETH/USD with native redemption conversion and preserves
source timestamps; 28 unit/fuzz cases pass. Independent oracle review found no concrete defect; two actual Ethereum/Core
integration cases pass, including rejection of the legacy roundless feed.
Current production structure passes34 runtimes,296selectors,9shared layouts
and9prefix checks; R25 Dolomite23372,plan23108,oracle1481 bytes.
Full new-token fork exits pass in R25 for the named Aave rows only. No token
is approved across all chains or adapters by name alone.
R18b's 2949/201 regression,43/18 actual,33 runtime,14 receipt profiles and8
Native profiles all passed on the frozen R18b source; they are historical until
all current changes receive matching final-source acceptance. No release approval.
R18 current source: Euler activation retry/poke budget, optimize approval and
atomic retry, failing capacity-view isolation, Dolomite capped active-market
fallback/partial fills, and registry ambiguity are fixed. Six failing-before
counterexamples now pass, together with three additional budget/rollback/loss
guards (9/9). Root corrected the independent proposals before acceptance.
Historical R18 measured runtimes: Euler21971 and Dolomite22863 bytes, both below23552.
Historical R18 gates and R19 review are superseded by R20/R21 fixes above.
R17's eight real Nitro Native profiles all pass, including ordinary withdrawal
EMA and recall in each dedicated family. That is historical source evidence
until the R18 changes receive matching final-source revalidation. No broadcast.
R17 supersedes the source acceptance below: all 43 actual-market tests in 18
suites pass after the Euler routing/bounds, Dolomite underlying and Venus
numeric-error fixes. All 33 production runtimes, 296 selectors and frozen
layout checks pass. Five controlled counterexamples pass after failing before.
Full regression passes 2940 tests in 200 suites with zero failures/skips.
All 14 mined local-fork profiles also pass, seven families on two chains each.
These source-bound R17 results supersede the historical counts below.
Native fixtures now warm Fluid PPS from genuine historical headers. The original
Euler Arbitrum market is correctly excluded below the unchanged $100k floor;
a separately identified real market above that floor is selected for positive
calibration, without production-market approval. Evidence: `r17-euler-eligibility.json`.
Independent Claude review found additional Euler retry/view isolation and
Dolomite capped-market routing issues; separate patch-only sessions are active
so the accepted source is not changed during ongoing Native simulation.
No release approval; these remaining findings still require counterexamples,
adjudication, fixes and final-source gate reruns.
R12: independent control-surface review exposed a genuine keeper starvation
default. Two failing-before tests prove that zero poke interval repeatedly
selects APY refresh ahead of ready harvest. The candidate now defaults to one
day and rejects zero interval updates. All52 upkeep tests pass. The changed
candidate also passes2935 regression tests/199suites,43 actual tests/18suites,
and33 runtime checks; all test gates have zero failures and skips. Existing
shadow upkeep already has86400seconds at block520384312; it was not modified.
R8: measured Polygon117gwei constructor compatibility is fixed, independently
reviewed and accepted. Historical R12 final-source gates pass2935 regression/199suites,
43 actual/18suites,79 focused fee tests/6suites and33 runtime checks.
The integrated candidate passes 43 actual-market fork tests in 18 suites, with
zero failures or skips. This includes Ethereum USDT/WETH user exits with native
fees, Base native fees, BSC USDT/Venus, Polygon USDC/Aave and Optimism USDT/Aave
native-fee and full-recall scenarios. Full regression passes 2935 tests in 199
suites, with both legacy opt-ins enabled and zero failures/skips. The four
original actual scenarios and nineteen separate controlled compatibility cases
also pass on matching strategy sources.
The full-receipt recall fix has failing-before evidence and 310 passing related
tests in 46 suites; the controller runtime is 22569 bytes. Morpho remains 23479
bytes (73 below the project limit). The fee-source dependency guard passes 49
component tests. These results supersede the corresponding pending R3 checks.

The portable canonical Anvil runner passes all seven adapter families on two chains each: 14
profiles and 72 successful operation receipts, using existing holder funds and real protocol
state. These representative adapter measurements do not close production wrapper
gas calibration. The current proof is `lending-production-remediation-20261101/transaction-gas.json`;
latest actual acceptance is `lending-production-remediation-20261101/r17-actual-43-acceptance.json`.

The actual deployed Arbitrum governance Safe passes proposal, a 20-call atomic
cutover and a nine-call rollback on the frozen Core and Router. A deliberately
failing final guard reverts the entire Safe batch, including balances, routing,
keeper flags and nonce. The 300-second observed router delay is preserved.
The exported unsigned batches are historical reference fixtures, not broadcast
instructions or an approved production deployment manifest. Evidence:
`lending-production-remediation-20261101/reference-safe-batches.json`.

The Polygon fee-source, zero-sequencer and native-price-band limitations are fixed
with separate failing-before evidence, 69 native component cases and actual
Polygon acceptance. Existing ETH/BNB bounds and L2 sequencer checks remain intact.
One hundred related tests cover these changes and the two corrected regression
fixtures without loosening the deposit policy. Current structural acceptance
still passes 33 runtimes, 296 selectors and both sets of nine layout checks.
Nineteen isolated real-protocol wrapper observations across USDT/PYUSD/WETH are
recorded; their gasleft deltas are not transaction receipts. Preparation reaches
1603083 gas, so the illustrative 400000 prototype coefficient is not approved.

Eight frozen-system executable templates match the public core pin. Router and
GlobalConfig match only with two documented shadow timing variants; these remain
separate core observations. Eighteen critical selectors and their module/role
bindings are verified against chain state. Current fixtures mirror the observed
external module authorization without granting extra Core/Queue/Liquidation access.

A nonempty Aave warm + two-adapter USDC exit passes through the unchanged
seven-day queue and pays all user shares exactly. Six Ethereum native economic
branches cover USDT/PYUSD/WETH with independent quoting and benefit checks;
three reject uneconomic plans, three accept funded surplus allocation, and the
USDT suffix is cancelled without movement when its remaining benefit is too low.
Accepted plans also pass through actual StrategyUpkeep.performUpkeep with
132-byte encoded calldata. Observed prepare reaches1715211gas and step2254567gas
in these three profiles; these gasleft deltas are not receipt measurements.
The benchmark coefficients do not constitute production gas calibration.

Euler now passes actual earned-interest harvest on Ethereum USDC/USDT and
Arbitrum USDC after genuine later headers, with exact payment and principal
preserved. All seven current Router-enabled shadow adapters were queried; Aave,
Comet and Venus reward-controller/helper pipelines are zero. Unavailable getters
remain unavailable; this does not validate future external reward activation.

Historical R0/R1 gate record (superseded by the current gates at the top):
keeper-wrapper transaction gas validation and
production calibration; external reward paths if enabled;
owner-specific operational migration/recovery manifest and review; whole-candidate independent
review, reproducible evidence, and CI on the exact feature commit. The current
source is uncommitted; historical R0 completion below is not release approval.

The historical R0
matrix results below remain evidence for frozen R0 only. A real-data counterexample
proved that valid zero Arbitrum posting prices disabled dynamic quotes and deployment
preflight. The two guards are corrected and 65 focused tests pass, including both
new counterexamples. Final integrated regression, native fee integration and
operational/security release gates remain open. The old R0 completion label must
not be used as approval of the changed candidate. Main, frozen Core and existing
shadow are untouched.

The previous closure applies only to Aave USDC/WETH on Arbitrum/Base. It does
not establish complete multi-token/multi-chain acceptance for all seven adapters.
The historical R0 expanded validation was complete for its named matrix only. No universal safety certificate or
absolute absence-of-defects guarantee is claimed.

Core, main and existing shadow deployments remain frozen. All production changes
belong on codex/lending-multitoken-multichain. The prior tested candidate is base
211f1a0a4cb9c63232ae18dac24ccb921e5a4699 plus the 112-file patch SHA256
5645e2bc685fbdda8256b375e3955f14697568a3e83ce974487b9c987042b6cc.

## Required closure evidence

| Gate | Required proof | State |
|---|---|---|
| F1 | Official market inventory and deployed API compatibility for Aave, Comet, Morpho, Euler, Fluid, Dolomite and Venus | PASS for the named validated matrix; capped/unsupported cases explicitly excluded |
| F2 | Actual deposit, yield/NAV observation, partial withdrawal and full recall for each adapter on compatible real markets | PASS: R25 acceptance50/21 (48 positive integration/lifecycle cases,2 negative rejections), plus14 market profiles/72 mined local-fork operation receipts |
| F3 | Additional underlying tokens, including USDT and PYUSD where markets exist; 6/18 and other available decimals; approval behavior | PASS for named USDC/USDT/PYUSD/WETH rows, BSC18-decimal stables, EthereumAave wstETH/RLUSD and ArbitrumAave USDT0. USDT0/Aave genuine Native keeper, ordinary EMA and full recall also pass (R36) |
| F4 | Multiple supported chains across the full adapter set; unsupported combinations proven, not quietly substituted | PASS: every family has at least two named chains; original Aave Arbitrum/Base final-candidate unmocked rerun 4/0/0 |
| F5 | Strategy scoring, USD tiers, caps, confidence, liquidity, APY and benefit gate checked against independent calculations using pinned real market/oracle observations | PASS: independent APR, USD/confidence/caps/seed, EMA, normalized scores and fixed-cost gate; dynamic gas quoting retains separate model/ArbOS limits |
| F6 | Real production core/strategy integrated multi-adapter allocation and rebalance with delivered amounts, accounting and recall assertions | PASS for all seven families; USDT/PYUSD/WETH execute both yield-driven and protection plans, epochs and recall |
| F7 | Compatibility/math/security fixes and complete regression, actual markets, size/layout/selectors and CI | PASS:2995/203,50/21,34runtimes,296selectors,9layouts+9prefixes; both source03596ac workflows green; Linux14profiles/72receipts |
| F8 | Independent Claude review, critical reconciliation and reproducible source-bound release | PASS: reviews reconciled;124functional inputs and clean-base source reproduction match; canonical constructor-bound Native9profiles pass; final artifact integrity accompanies the exported patch |

## Non-negotiable real-data acceptance

Every supported row records chain ID, canonical RPC block/hash/time, token and
market addresses, deployed implementations/API evidence, decimals, actual supply,
cash/liquidity, rate/PPS, price/feed timestamps and initial/final balances.
Use real holders/transfers or real swaps for initial funding. No deal, etch,
storage rewriting, mock successful call or fabricated price/rate/NAV closes a
live compatibility row. Legitimate local actors may impersonate funded accounts
on the local fork; no transaction is broadcast.

Scoring requires a separately implemented reference calculation and comparison
with the actual production module using those same observed values. Test at
different actual historical observations and economic portfolio sizes, preserving
production freshness, caps, epoch limits, dust rules and gas quote units. Record
counterfactual state persistence and fee-model limits explicitly. Missing markets,
RPC/history failures and ABI incompatibility are failed/unexecuted evidence,
never passing rows. Unit mocks remain useful only for isolated fault injection.

Native ETH is not ERC20. Determine the exact frozen-core and strategy interface
constraint before claiming support: wrapped ETH and native ETH must not be
conflated. Any required core change is reported separately and not implemented.

## Parallel Claude work orders

Use three independent isolated snapshots of the same 113-file reopened input. A reviews
Aave/Comet/Fluid/Venus real-market APIs and extra assets; B reviews Morpho/Euler/
Dolomite and native-ETH constraints; C reviews the complete scoring/allocation/
rebalance pipeline and independent real-data reference math. No session reads
another report or edits canonical source. Scratch reproductions and proposed
patches are reviewed and integrated serially by the coordinator. Full broad-suite
repeats are reserved for a stable corrected snapshot; no duplicate background runs.

## Executed additional real-market evidence

These are bounded acceptance rows; final F1–F8 closure is recorded in the ledger below.

| Venue / chain | Assets | Actual checks | Result |
|---|---|---|---|
| Aave / Ethereum | USDT, PYUSD | Real funded-holder transfers, actual Chainlink rounds, raw supply-rate and scaled-balance/index reference, deposit/partial withdrawal/full recall | 2 PASS |
| Production frozen Core + all nine Lending modules + Aave / Ethereum | USDT, PYUSD | Real feed/market integration, ordinary user deposit, two production epoch exits requiring investment recall, actual interest accrual, full exit; original reserve/cap/freshness guards retained | 2 PASS |
| Dolomite dTokens / Arbitrum | USDT, WETH | Actual historical PPS growth and independently annualized rate, authorized maintenance, holder funding, ERC4626 NAV, deposit/partial withdrawal/full recall | 2 PASS |
| Euler / Ethereum | USDC, USDT | Real push-mode funding and Permit2 initialization, independently calculated supplier APR from raw borrow rate/utilization/fee, deposit/NAV/partial/full recall | 2 PASS |
| Morpho / Ethereum | USDT, PYUSD V1 and V2, WETH | Canonical historical PPS reference, authorized maintenance, real funded holders, deposit/NAV/partial/full recall after emergency-NAV correction | 4 PASS |
| Comet / Ethereum and Arbitrum | USDT, WETH | Canonical accrued totalSupply, raw utilization/rate reference, real indexed positions and complete lifecycle | 3 PASS |
| Fluid / Ethereum and Arbitrum | USDT, WETH, USDC | Actual historical PPS, real transfers, share NAV and full lifecycle | 3 PASS |
| Venus / Arbitrum and BSC | USDC, USDT | Actual seconds/blocks interest model; lender-share TVL independently reconciled with reserves and bad debt; 6/18 decimal underlying | 3 PASS |
| Production Core + multiple real adapters / Ethereum | USDT, PYUSD, WETH | Independent USD scoring/targets, actual allocation, epoch exit and recall; risk rebalance after governance tightens concentration | 3 PASS |

Source/log hashes, raw observed values, funding deltas and persistence assumptions:
`docs/lending-full-validation-20261101/aave-usdt-pyusd-real-evidence.json`,
`ethereum-usdt-pyusd-production-core-evidence.json`, and
`dolomite-usdt-weth-real-evidence.json` in that same directory.
Dolomite measured historical simple APR is 504 bps for USDT and 296 bps for WETH
at RPC blocks 519994008 → 520094008. The wrappers hold zero idle underlying,
yet actual maxWithdraw and withdrawals succeed; wrapper cash is not protocol liquidity.
This does not validate the separate advertised PoolLike ABI or multi-market scoring.

Claude reports marked UNEXECUTED and a session terminated at its tool-turn budget
are rejected as acceptance. Execution follow-ups are required; no static inventory,
permission error on a different command, or expected test count constitutes a pass.

MORPHO-REAL-01: real Ethereum USDT and WETH exits returned the capital but retained
the entire recovered position in cached NAV. Corrected emergency bookkeeping clears
successfully redeemed positions and retains failed-redemption principal, followed by
a NAV refresh. All three real-token lifecycle tests pass after the correction;
isolated failed-redemption regressions and the refreshed release gates now pass.
Evidence: `morpho-emergency-nav-finding.json` and
`morpho-usdt-pyusd-weth-real-evidence.json` in the evidence directory above.

Do not count the old Steakhouse PYUSD market 0xbEEF02e5E13584ab96848af90261f0C8Ee04722a
as deposit-compatible at Ethereum26300000: the actual market reverts AllCapsReached
(0xded0652d) and reports flat historical PPS. Its failed attempt is retained separately.
The passing V1 PYUSD row uses actual Sentora 0x19b3cD7032B8C062E8d44EaCad661a0970DD8c55.
Its approximately $3 initial TVL has zero strategy confidence; adapter compatibility
does not make that market suitable for strategy allocation. Integrated PYUSD uses
the substantial real V2 vault 0xb576765fB15505433aF24FEe2c0325895C559FB2 instead.
No production market cap was changed to obtain that result.

Session C's unexecuted `ScoringEvidence.fork.t.sol` is rejected: future Arbitrum tags
521094008/522094008, one Aave adapter, locally computed targets rather than a comparison
to actual production targets, and an alleged Comet blocker caused by deliberately
omitting its required registry. It provides no F5/F6 closure. The coordinator
completed actual scoring/reference and multi-adapter execution instead of accepting it.

### Current execution ledger

The 24-test all-real run has zero failures/skips (`all-actual-markets.log`). All
seven adapter families have actual protocol lifecycle evidence. A subsequent
three-profile run (`actual-risk-rebalance.log`) also executes production
prepareRebalance/executeRebalanceStep, without modifying market balances or rates.
Governance tightens the exposure cap to 25%; protection mandates pass, actual
receipt positions redeem/reallocate and plans complete within the cap. This is
protection execution, not evidence of a profitable yield-driven rebalance.

Separate controlled fault/unit suites pass 228 tests. Confirmed fixes include
Morpho emergency NAV, optimization cost-basis conservation and failed restoration;
V2 conservative idle-liquidity integration; lower-rate-first withdrawal;
Comet accrued TVL; Venus lender-share TVL; Dolomite disabled-position NAV;
duplicate market/configuration and live-receipt replacement/reload guards.
No controlled fixture is counted among the real acceptance rows.

Ten real suites are maintained under `test/strategies/usdc-lending/fork/actual`.
The source-bound gate passes 32 tests in 10 suites with no failure/skip:
`actual-acceptance.json` records 201 source hashes, 213 raw observations and the
canonical-header ledger. Arbitrum Euler/Morpho and Ethereum Dolomite pass in
addition to earlier rows. Current BSC at 131080000 and legacy BSC at 45000000
both pass USDC/USDT lifecycles: actual annual model normalizations are respectively
70,080,000 and 10,512,000 blocks; Arbitrum Venus uses 31,536,000 seconds.
Native Margin is not substituted for Dolomite's actually tested ERC4626 wrappers.

Independent EMA, inverse USD/seed and whole-amount valuation references pass.
All three multi-adapter profiles also execute actual yield-driven plans using
real rates/quotes and the configured fixed USD6 cost; separately they execute
protection plans after concentration is tightened. A real-data counterexample
proved small negative benefits were incorrectly accepted after signed division
rounded to zero BPS. The raw sign guard fixes all three profiles, retaining
positive-plan execution and documented legacy exact-zero behavior.

The V2 helper deployment now has an independent manifest runtime pin; all six
wiring tests pass. The current structural gate verifies all 32 concrete Lending runtimes below 23552
bytes, nine identical module layouts, 296 selectors without collisions and all
nine adapter/helper/bootstrapper baseline storage layouts preserved. Full broad
regression now passes 2871/0/0 in 194 suites, and the separate legacy acceptance
passes 21/0/0. With the expanded 32 and original four actual scenarios, 2928
distinct qualified tests pass without skips. CI counts and compiler pin are
updated; the generic unit/coverage workflow excludes fork directories, while
the dedicated workflow explicitly gates the complete actual directory.

The final source-bound closure is
`docs/lending-full-validation-20261101/final-validation.json`, functional SHA256
`2fa6e42b093eb820ba075befe47279217b1cdb6edcff9080bfde5637f584a8b2`.
The old 2026-10-31 closure is historical and does not replace this expanded ledger.

The clean independent clone reproduces all 32 runtime templates and all 32
expanded actual tests. All 201 Solidity/build input files match after UTF-8 LF
normalization; all 91 changed functional files, including release scripts and
both CI workflows, match too. No release compiler limit, reserve/epoch constraint,
withdrawal haircut or slippage guard was lowered to obtain passing evidence.
The final review bundle is generated with `script/ExportLendingCandidate.ps1`;
it requires this completed ledger and rejects any functional source drift.
