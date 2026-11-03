# Independent review reconciliation — 2026-11-01

Original independent input: 86 files at candidate manifest SHA256
`5a989edd92063fcfef12f9a1daf85481f82b471c5f84b778bfd4f085232225a1`.
Each A/B/C session used a separately verified worktree. Subsequent coordinator
changes are a delta requiring final validation; the original reports do not
automatically certify that delta. Core and existing deployments remain frozen.

| Finding | Coordinator decision | Resolution / required evidence |
|---|---|---|
| A-1 Comet liquidity scoring | Accepted: token quantity was multiplied into an otherwise BPS score | Bound readiness to 10000 BPS using market cash / managed adapter assets. Actual optimize decisions must agree for 6 and 18 decimals and equivalent quantities of an expensive asset |
| A-2 safety fallback clipped by governance | Rejected proposed removal of global ceilings | Dedicated fallback caps replace structural tiers, not the explicitly configured global governance ceiling. Zero remains the documented disabled-global-ceiling sentinel. Preserve existing risk tests; clarify misleading comments |
| A-3 Dolomite internal APY always zero | Accepted: lastAPYBps had no writer | Share the canonical per-market PPS/rate-provider reader across public APY, scoring and benefit gate; preserve storage. Regress actual optimize movement for distinct provider rates and distinct observed PPS rates; one failed provider read returns zero |
| A-4 Comet totalsBasic ABI | Accepted; increase priority to medium from review's low | Official ABI has eight fields and uint104 principals. Live Arbitrum USDC passed pre-fix but WETH principal exceeded uint64 and decoding reverted. Correct interface and mock ABI; require both published-market supply checks |
| A-5 Morpho cached NAV | Operational scope, not established new defect | Existing pokeAPYSnapshots refreshes NAV and refreshNavCache exists. Harvestable profit is zero, so adding a harvest refresh alone would not fix maintenance. Any Morpho deployment needs an authorized NAV/PPS maintenance cadence; no live Morpho support claim |
| A-6 Dolomite PoolLike external TVL proxy | Disclosed limitation; no invented total-supply API | Cash-only proxy is intentional and conservative. ERC4626 branch uses totalAssets. PoolLike is not certified by the real Aave lifecycle matrix |
| C-F1 missing unmocked end-to-end acceptance | Accepted | New four-profile production Core/GlobalConfig/OracleMiddleware/BufferManager/Router test uses real holder transfers, actual swaps/Aave, canonical historical feeds, two withdrawal epochs and full recall |
| C-F2 missing safety module in matrix fixture | Accepted fixture defect | Install actual five-argument SafetyOverflow module through Settings selector; rerun original 19-case matrix |
| C-F3 deprecated safeApprove in Aave | No demonstrated defect | Existing zero-first approval is valid for current tokens. Do not churn approval policy solely because the API is deprecated |
| C-F4 legacy SOURCE_STRATEGY/upkeep dependency | Legacy scope disclosure | Generic typed manifest is the supported deployment path; legacy script is not generic acceptance |
| C-F5 legacy Morpho index assumption | Legacy scope disclosure | Generic typed manifest does not call the old index-based preservation routine |
| C-F6 Camelot V1/Base route limitations | Explicit support boundary | Do not claim unsupported routers/venues merely from generic interfaces |
| B-01 empty AdapterOps revert swallowed | Accepted for observability and keeper semantics | Bubble nonempty revert and use existing QueryFailed for empty failure. Preserve normal protocol-level best-effort recall and shortfall semantics; unit fault injection covers keeper and both withdrawal overloads |
| B-02 atomic failure/success recording | Reject suggested best-effort telemetry patch | Failure counters/quarantine are risk state, not expendable telemetry. Immutable validated Ops and deterministic selectors have no demonstrated reachable mismatch. Module/OOG failure rolling back a plan step is intentional atomicity; do not weaken accounting to manufacture availability |
| B-03 unconfigured safety module | Accepted defensive failure mode; harden meaningfully | Missing/failed/empty risk module must revert QueryFailed during deposit/harvest rather than report healthy. Generic deployment also wires all nine modules. Unit tests inject missing/reverting risk code and prove idle withdrawal remains available. Review's proposed return(false,0) guard had identical behavior and would fix nothing |
| B-04 advisory lock range/finalization | Accept concrete arithmetic bound, reject unsupported freeze-policy claim | Degraded advisory view multiplies uint64 by seven. Bound setter to uint64.max/7, test exact boundary and rejection. This advisory operational setter does not enforce Core withdrawal lock; preserve its existing post-finalization governance scope |
| B-05 slippage comment mismatch | Accepted documentation defect | Correct 1000/10% comments to actual enforced 500/5%. Keep the tighter runtime limit |
| B-06 rescue error name | Informational, runtime correct | Enabled reward tokens remain protected. Preserve existing error ABI; misleading name alone is not a reason for an ABI migration |
| B-07 fallback empty-revert attribution | Known dispatch limitation | Selectors remain collision-checked. Unknown selector versus empty failure has a shared fallback error; no demonstrated authorization bypass or lost funds |
| Coordinator L-01 Morpho registry cardinality | Accepted during complete cast-warning triage | addMarket enforces max255 but _loadFromRegistry did not. Reject oversized registry batches before downstream uint8 market indexes/counters can wrap; malformed registry regression requires failure before allocation |

## Unmocked evidence and limits

The four new scenarios use standard USDC/WETH on Arbitrum/Base, actual funded EOA
balances, actual Chainlink round data and Aave supply/withdraw operations. A normal
user distinct from governance deposits and claims. Router allowlisting waits the
actual two-day timelock; the one-day withdrawal lock, seven-day epochs, 10% epoch
cap and published shadow reserve BPS are preserved. The second claim exceeds hot
cash and must recall invested capital. Interest must increase the Aave position.
All instantiated production components must satisfy EIP-170.

This is a historical counterfactual portfolio, not a replay of every canonical
transaction: scenario contracts and affected real token/pool/aToken state persist
while historical feeds advance. Gas cost is static USD6=1; dynamic ArbOS fee
precompile acceptance is separate. The warm sleeve is legitimately empty. Core
bootstrap configures real public APIs but is not a complete SystemSealer migration
or an exact-runtime proof for every deployed core module.

The captured pre-fix WETH Comet principal was 780694851164122267142 at Arbitrum
520094008, greater than uint64 max. The official struct is available in
[CometStorage.sol](https://github.com/compound-finance/comet/blob/f766f51583c23acc33b2a7824654ef2029a96804/contracts/CometStorage.sol).
The WETH deployment is recorded in
[official Arbitrum roots](https://github.com/compound-finance/comet/blob/f766f51583c23acc33b2a7824654ef2029a96804/deployments/arbitrum/weth/roots.json).
The pinned-chain regression uses the deployed getter, not an inferred mock layout.

## Execution accounting

C independently executed matrix19, manifest5, legacy opt-ins2, layout/selector/size
checks and all nine exact runtime reproductions. Its first report's claim that
shell execution was unavailable is superseded by actual successful receipts.
An explicit dependency-qualified forge-inspect source lookup failed; the valid
bare-contract ABI lookup succeeded. The initial pseudocode's nonexistent Params
setter and incorrect safety constructor are not implementation instructions.

A's broad background test and B's broad background test are not accepted as final
regression evidence without their actual exit/counts. Two verified duplicate B
compiler jobs were canceled by the coordinator; cancellation is not a code failure.
Final coordinator runs use the explicit fork-directory exclusion and enabled
legacy opt-ins. B's report incorrectly expands the 19-case Aave matrix into
seven live adapter families; that claim is rejected. Live acceptance only covers
the actually executed contracts. Final reviewed-source validation passes:
2789 regression and25 explicit real-market cases, with zero failures/skips.

## Independent C delta review

C statically reviewed the ten hash-bound first-delta files and found no functional
blocker. This was source review only, not a test execution. Its suggested change
to public `ppsSnap` from 1e18 to 1e24 shares is rejected: that would change legacy
telemetry units. The internal rate sample deliberately uses 1e24 for precision;
comments now document both denominations. The E2E comment now explicitly says
Arbitrum's published reserve profile is reused intentionally for Base simulation,
without claiming parity to a deployed Base vault.

The reviewer did not catch the first Comet unit regression's insufficient APY
benefit: 200M/400M per-second WAD rates produced a difference below the unchanged
2 BPS gate, so three tests initially failed. Coordinator traces established this
fixture error. Synthetic unit-test rates were raised to 2B/4B (equivalent to
approximately 6.3%/12.6% annualized rates, not observed market quotes);
the production economic gate remains unchanged. Static assertions were not
accepted as evidence of execution. All six Comet/Dolomite unit decision cases
now pass on the final source. Availability/Morpho guards were separately reviewed by B.

## Independent B delta review

B cleared the actual realization failure branches, fail-closed risk relays, advisory
lock arithmetic bound and Morpho registry limit, with no storage/ABI defect found.
Its coverage request for a nonempty Ops revert is accepted: a sentinel error
regression now verifies exact bubbling as well as the empty QueryFailed branch.
It proposed a new advisory-lock event or documentation of the existing omission.
The legacy setter's event behavior is preserved: monitor successful governance
transaction calldata and the public withdrawalLockSeconds getter. This advisory
signal does not automatically change the frozen Core's actual lock period.
No new event or economic/finalization policy change is required to close the
overflow defect. The bounded review made no execution claim.

## Whole-regression fixture correction

The first completed whole-regression attempt executed all 2789 cases: 2787
passed, two failed, zero skipped. All 16 new remediation tests passed. The two
failures were the existing cooldown tests in UsdcMultiLendingVault_GateParams:
its overridden setUp omitted SafetyOverflow even though the common fuzz base
installed it. Fail-closed risk checks correctly rejected that incomplete setup.
The override now installs the actual five-argument module through Settings,
asserts its binding, and observes liquidity as well as TVL before exercising
cooldown. No cooldown assertion, production risk condition or source guard was
weakened. The failed run is retained separately and is not final acceptance.
Both focused cooldown tests then passed. The complete final rerun passed all2789
cases; the subsequent real-market acceptance passed25/0/0, including strict
unmocked E2E4 and actual Comet ABI2. All sixteen remediation unit cases pass.
