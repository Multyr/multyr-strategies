# Arbitrum four-asset qualification

Status: **FUNCTIONAL MATRIX COMPLETE WITH EXPLICIT CONSTRAINTS — not production approval**.

Post-fix source: `3fcc4d405153a3b534daed98f92f836e6d61957c`.
Regression is 2,998 tests / 204 suites; all 58 expanded Arbitrum cases pass.
`post-fix-native-acceptance.json` seals 12 genuine Native profiles, including
Euler, with 11 positive keeper paths and one correct WBTC/Aave rejection.
`DEPLOYMENT_SEQUENCE.md` records the unsigned deployment dependencies and
mandatory Euler initialization. Operational manifests remain unapproved.

Final results and the 28-cell table are in [RESULTS.md](RESULTS.md).
All 58 executed real-data cases pass: 25 direct adapter lifecycles, 22 invested
Core paths, three correct policy rejections/idle exits, four weighted portfolios
and four nonempty Aave-warm paths. The three unavailable protocol/asset markets
are explicit exclusions, not passed or skipped tests.

The separate frozen Aave-warm integration gate currently passes **4/4** for
USDC, WETH, USDT0 and WBTC: actual funding, nonempty warm and Lending investment,
queued complete small-user exit and final Lending recall. See
`warm-acceptance.json`. This is not yet the complete seven-family acceptance and
does not qualify Morpho warm profiles or genuine Nitro fees for the new assets.

Scope: all seven current Lending adapter families against the exact Arbitrum
USDC, WETH, USDT0 and WBTC contracts. Frozen Core source stays unchanged; each
asset has its own Core/strategy instance. Existing deployed USDC Core cannot
change underlying. Work is on `codex/lending-final-cleanup-20261103`.

## Acceptance requirements

Every one of the 28 cells must have a recorded result. A read-only identity check,
adapter-only deposit or absence from a web listing is never a complete Core pass.
Separate results are required for: compatible market found; direct adapter
lifecycle; unchanged strategy eligibility; full Core/strategy lifecycle; native
Nitro fee gate; and frozen Core warm-sleeve compatibility.

Positive integration requires genuine holder transfers with supply conservation,
real canonical feeds, 6/8/18-decimal independent USD valuation/rounding, actual
protocol receipts/NAV, scoring/target checks, deployment, harvest, queue claim,
complete small-user exit within the existing 10% epoch cap and final capital
recall. No balance/storage/time/oracle mocks, no lowering economic/risk limits.
Historical rolls preserve affected protocol dependencies as a disclosed closed
counterfactual, not a replay of intervening canonical transactions.

If current markets fail the unchanged risk floor, document a policy rejection;
do not label the token universally unsupported and do not bypass the floor. A
network failure or untested case remains unresolved and prevents full acceptance.

## Discovery observations

Pinned read-only RPC identities at Arbitrum block **520094008** identify 25
candidate family/asset cells, including an unlisted WETH Morpho technical test
profile. No production candidate is identified for Comet/WBTC, Fluid/WBTC or
Morpho/WBTC in the queried inventories.

The complete Fluid factory `allTokens()` result at that block contains nine
tokens and no WBTC underlying. Compound's official deployment inventory provides
USDC, WETH and USDT bases on Arbitrum; collateral support does not imply a WBTC
interest-bearing base market.

Morpho's listed REST inventories contain four V1 and eight V2 vaults, whereas
the complete queried GraphQL inventories contain **111 V1 and 112 V2** including
unlisted vaults. The original REST-only discovery was incomplete. WETH vaults
exist. The observed WETH vaults have tiny or zero TVL; Gauntlet WETH Core and Yearn
OG WETH additionally report zero deposit capacity. The technical WETH test uses
unlisted `0x0623a67D69bB2F59D266897A15dC1509d291D631`; its ~$12 TVL must fail the
unchanged strategy floor. A passing adapter lifecycle does not approve its
curator, risk or production deployment. The indexed WBTC vault is empty, test
named and has zero deposit capacity; it is not a production candidate.

The full queried Blue index contains 265 markets, including 12 WETH loan markets.
The current adapter consumes ERC4626 vaults, not direct Blue market IDs. No WBTC
loan market occurs in the queried index; index results are not proof about every
permissionless contract.

The largest identified nondeprecated Euler USDT0 and the identified WBTC vault
are below the strategy's $100,000 TVL floor at the discovery pin. They require
separate technical-lifecycle and allocation-policy results.

## Reproduction

Use the already authorized `ARBITRUM_RPC_URL` environment variable; do not save
the endpoint in a committed file. Inventory retrieval is read-only:

```
python script/lending/validation/arbitrum-assets/discover.py
python script/lending/validation/arbitrum-assets/probe.py
python script/lending/validation/arbitrum-assets/run.py --stage direct
python script/lending/validation/arbitrum-assets/run.py --stage core
python script/lending/validation/arbitrum-assets/run.py --stage portfolio
python script/lending/validation/arbitrum-assets/run.py --stage warm
```

Raw catalogue snapshots, RPC headers/identities and execution logs are written
under `deployments/lending-full-validation-20261101/production/arbitrum-assets`.
The runner must retain all 28 statuses, source fingerprints, log fingerprints and
exact integer observations. Source changes during execution invalidate the run.
The initial committed inventory is discovery evidence only. The original
50-test actual gate retains its independent count and scope.

## Sources

- [Compound deployment source](https://github.com/compound-finance/comet/tree/main/deployments/arbitrum)
- [Fluid deployment source](https://github.com/Instadapp/fluid-contracts-public/tree/main/deployments/arbitrum)
- [Venus Arbitrum deployments](https://github.com/VenusProtocol/isolated-pools/blob/develop/deployments/arbitrumone_addresses.json)
- [Euler known-vault API](https://docs.euler.finance/build/data-querying/perspectives/)
- [Morpho vault API](https://docs.morpho.org/developers/api/morpho-vaults/)
- [Dolomite wrapper inventory](https://docs.dolomite.io/developer-documentation/dolomite-margin-dtokens)

Core integration limitations remain in `../LENDING_CORE_OBSERVATIONS.md`.
An adapter lifecycle must not be presented as qualification of an enabled frozen
warm sleeve or genuine Nitro fees. Core findings are documented separately.
