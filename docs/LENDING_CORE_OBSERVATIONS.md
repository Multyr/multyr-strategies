# Frozen core observations — separate from strategy remediation

Frozen source pin: `9a9d120709de99a6216e9fe75d36e9ffdcb1a4d9`.
No core source or submodule change is included in the candidate.

At Arbitrum block 520094008, the deployed core's public Params and oracle getters
were called independently. The resulting asset-specific bounded fresh quote is
recorded in `lending-verification-20261031/core-oracle-observation.json`.

The four Core matrix tests execute the frozen CoreVault modules and StrategyRouter
with the candidate strategy and real Aave markets. They assert capital reaches
the market and epoch funding actually recalls that invested capital before claim.
Params, bounded price oracle, warm-NAV provider and initial funding are fixtures.
The core's real allowlist timelock advances time; fixtures refresh oracle/NAV after
that delay rather than relaxing the production freshness policy.

No new core defect was established by these scenarios. This is not a complete core
audit, nor an exact-runtime reproduction of every deployed core module. The nine
exact runtime proofs cover the existing lending strategy and its modules only.
Any future suspected core defect must record exact source site, concrete input,
observable impact and reproduction here; fixes belong in a separately authorized
core review, never in this strategy patch.

## Real production configuration acceptance added 2026-11-01

`LendingUnmockedE2E.fork.t.sol` supplements the controlled matrix with four real
production Core/GlobalConfig/PriceOracleMiddleware/BufferManager/Router scenarios.
No mockCall, etch, store, deal or warp is used. Actual holder transfers and Uni
swaps fund an unprivileged user. Historical rolls retain counterfactual market
state while advancing canonical feeds. Two real seven-day epochs preserve the
10% cap and published reserve configuration and force an actual Aave recall.
The empty warm sleeve has a legitimate zero NAV; active warm-adapter yield is
outside this proof. Static gas pricing is disclosed separately.

Configuration observation: GlobalConfig's default raw deposit limits were sized
for a six-decimal dollar asset. They are configuration defaults, not token-agnostic
economic limits. The real bootstrap sets explicit asset-denominated limits through
the existing public `setVaultDepositLimits`, converting complete USD amounts using
the real oracle. Any new token deployment must supply these explicit limits; no
core code change or default-limit parity is claimed.

Published Arbitrum shadow profile at block 520094008: router per-strategy ceiling
10000 BPS and loss cap 50 BPS; withdrawal epoch cap 1000 BPS and lock 86400 seconds;
buffer targetHot/minHot/targetWarm/maxWarm/opsReserve/maxWarmSlippage are
400/200/600/800/400/50 BPS. The new scenarios preserve these quantities and
parameterize only the underlying asset. This does not establish complete runtime
identity for all frozen core components or validate a SystemSealer migration.

## CORE-DEPLOY-001 — exact shadow timing variants identified 2026-11-02

At Arbitrum block 520384312 (hash 0xe6beee34bcbb8e6876788b2fc361d85265e03189c059b03b6c28a082408c4bd7), five examined runtimes match the pinned public core source executable template: CoreVault, BufferManager, PriceOracleMiddleware, ERC4626Module and EpochedQueueModule. Compiler-reported immutable locations were separately checked against the actual USDC address, six decimals and the bound Core address. Compilation uses the public core pin's actual Solidity 0.8.28 / Shanghai / viaIR / optimizer200 settings; strategy Cancun settings are not valid evidence for core parity. Metadata hashes are explicitly excluded from executable equality.

Two deployed contracts differ from the unmodified public source pin. Compiler-input-only changes reproduce their complete executable bodies, without changing any repository Core source:

- StrategyRouter at 0x37847D2e12892e3298DEE695e7E971fba0Ca3e24: MIN_ALLOWLIST_DELAY is 300 seconds, compared with public source 86400 seconds. The public getter independently returns 300 at the same block.
- GlobalConfig at 0x5680E4948759569DCB9D2eAB6a5504d733c83B2A: the lower epoch-duration validation bound is 120 seconds, compared with public source 3600 seconds. This identifies the allowed minimum; it does not assert that every configured vault epoch actually lasts 120 seconds.

Disposition: this is a documented deployed-source identity difference, not a strategy patch or proof of a loss exploit. Do not describe the deployed shadow as identical to the unmodified frozen public pin. Candidate tests using the public core retain its original stricter timing bounds. Any decision to normalize or replace deployed Core components requires a separate Core review; Core and shadow remain untouched. This comparison does not yet cover every registered selector module, registry implementation, role history or future blocks.

Evidence: `lending-production-remediation-20261101/frozen-system-runtime.json`; raw compiler/RPC comparison and input-only variant proofs are referenced there and under `deployments/lending-full-validation-20261101/production/A-core-parity` in the verification workspace.

## CORE-WARM-002 — nonstandard ERC20 returns require separate warm compatibility review

Scope: unchanged frozen Core warm adapters, not the Lending strategy adapters.
The pinned public `AaveV3WarmAdapter_USDC` and `MorphoVaultWarmAdapter_USDC`
constructors call `IERC20.approve` expecting a returned boolean; their transfer
paths also use typed boolean-returning ERC20 calls. A read-only call to actual
Ethereum USDT at block 26165000 returns empty approval returndata. Such a token
requires optional-return handling; accepting an arbitrary underlying constructor
argument does not establish compatibility with Ethereum USDT.

This is a source/RPC compatibility observation. A complete frozen-warm deployment
counterexample has not yet been executed. It does not establish a loss exploit,
invalidate the strategy's SafeERC20 USDT scenarios, or imply that the currently
bound Arbitrum USDC warm adapter is incompatible. Current shadow warm identities,
USDC/Core/Buffer bindings, actual Aave pool/aToken and nonempty invested balance
were separately read from chain state. Its second Morpho warm position is empty.

Disposition: do not claim USDT compatibility for an enabled frozen warm sleeve
from the strategy-only tests. A separate Core review should use SafeERC20 optional
returns and real-token deployment/deposit/withdraw regressions if that warm profile
is required. No Core dependency, deployed Core or shadow source was changed.

Sources: pinned public Core `src/adapters/warm/AaveV3WarmAdapter_USDC.sol` and
`src/adapters/warm/MorphoBlueWarmAdapter_USDC.sol` at commit
`9a9d120709de99a6216e9fe75d36e9ffdcb1a4d9`. Raw read-only evidence is retained in
`production/coordinator/core-warm-usdt-approve.json`, `current-warm-identity.json`
and `current-warm-protocol-details.json` in the canonical validation workspace.
# wstETH price-feed interface constraint (2026-11-03)

This is an integration constraint, not a proven Core code defect. At Ethereum
block26300000 the Lido-listed wstETH/USD feed
`0x8b6851156023f4f5a66f68bea80851c3d905ac93` exposes `latestAnswer()` but reverts
on `latestRoundData()` and `latestTimestamp()`. It cannot be passed directly to
the frozen Core's latest-round feed interface. Core source and existing shadow
configuration remain unchanged.

The strategy-owned `WstEthUsdPriceFeed` instead reads the real stETH/USD feed
`0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8` and the native wstETH redemption
conversion. It forwards the underlying round metadata without manufacturing a
fresh timestamp. This applies to native-conversion wstETH; bridged variants
require their own validated feed profile. Historical `getRoundData` is explicitly
unsupported. Component tests pass; complete new-token qualification is pending.

