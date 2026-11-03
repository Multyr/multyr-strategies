# Independent Claude review reconciliation

Independent sessions review frozen source copies, never edit the canonical
feature branch. Unexecuted A/B/C suggestions are not acceptance evidence.

| Review finding | Coordinator disposition | Proof |
|---|---|---|
| D: Morpho optimization principal drifts after yield | Fixed; emergency panic was blocking despite Claude's contrary severity claim | Actual uint arithmetic panic and cost-basis regression; successful move, failed target/restoration, retry and emergency exit tests |
| D2: Morpho withdraws highest APR first | Fixed; withdrawals sort ascending, deposits retain descending selection | Controlled observed-PPS ordering test |
| D2: destructive registry reload can orphan funded receipts | Fixed with principal **and raw receipt** emptiness guards, duplicate rejection and cache/index cleanup; simply resetting counters is insufficient | Real funded reload rejection plus donated-receipt fault tests for Morpho/Comet/Dolomite; Euler append remains allowed |
| D2: Comet 255-entry bound missing | Fixed on both manual add and registry load | Source checks plus structural/runtime regression |
| D2: Comet optimization threshold uses gross numerator | Promoted from INFO to a proved economic guard defect; fixed to net benefit after costs, with full-precision multiplication | Before-fix moves 500 USDC despite sub-threshold net return; after-fix rejects it and executes the positive boundary case (`CometNetBenefitTest`) |
| D3 F1: liquidity helper hash self-referential in deployment | Fixed; `Manifest.morphoLiquidityViewRuntimeHash` independently pins helper code before deployment/bootstrap | Six deployment wiring tests, including zero/wrong manifest pin, wrong deployed code, explicit configuration and authority rejection |
| D3 F2: native DolomiteMargin balance ABI | Actual Arbitrum `balanceOf(address)` reverts. `asset()`/`baseToken()` are incompatible too: the native Margin contract is rejected by market-type detection and is **unsupported**, not a passing PoolLike integration | Actual ERC4626 dTokens pass; no claim that the separate native Margin interface is implemented |
| D3 F3: `<255` before push vs `<=255` on loaded length | Rejected as a false positive. Both permit exactly 255 entries. Suggested changing registry bound to `<255` would remove a valid boundary without fixing a defect | Direct bounds arithmetic; no policy/bound reduction applied |
| D3: Morpho role check and appended storage | Confirmed by coordinator; no permission predicate changed | Unauthorized role/account assertion and append-only layout comparison |
| D4: small negative net return rounds into accepted zero BPS | Fixed by checking the raw signed net amount before accepting the threshold | Before-fix real USDT/PYUSD/WETH all accept a loss; after-fix all reject it while positive real-data economic plans execute |
| D4: Comet TVL denominator differs from controller turnover denominator | Rejected as an unproved policy-change request. The existing adapter sub-gate measures return on total adapter TVL; this is a stricter portfolio hurdle. No requirement says the two scopes share a denominator. Replacing TVL with moved capital would lower the existing hurdle, so it is not silently applied | Net-versus-gross defect is fixed while preserving the original denominator; positive/negative boundary regression explicitly measures portfolio BPS |
| D4: helper semantics outside its four-file snapshot | Scope limitation closed by independent D2/D3 helper review and matching frozen source hash, not by pretending D4 reviewed it | Stateless helper source, actual V2 lifecycle/production allocation tests, controlled fail-closed tests and runtime/manifest pin checks |

The stateless V2 helper provides an immediate **idle cash lower bound** and
honors sender/receiver gates. It does not price arbitrary force-deallocation
penalties or claim allocated funds as immediately liquid. Morpho's real Gauntlet
Core Arbitrum market at `0x7e97fa6893871A2751B5fE961978DCCb2c201E65`
rejects deposits with `AllCapsReached` at block 520094008; its atomic rollback is
tested separately from the working Gauntlet Prime lifecycle at
`0x7c574174DA4b2be3f705c6244B4BfA0815a8B3Ed`.

Primary address provenance for the latter:
[Morpho's Gauntlet USDC Prime page](https://app.morpho.org/arbitrum/vault/0x7c574174DA4b2be3f705c6244B4BfA0815a8B3Ed/gauntlet-usdc-prime).
Actual historical calls and lifecycle assertions, rather than the current page's
displayed yield/liquidity, determine acceptance at the pinned block.

All three real-data economics profiles execute at one pinned block per
observation, with `_fresh()` before evaluation. The reference uses raw actual
positions and independent weighted-rate/cost calculations. No intervening fork
roll occurs between the reference and gate call. These prove the configured
fixed-cost benefit model and execution, not realized future profitability or
native ArbOS fee-precompile execution inside Forge.
