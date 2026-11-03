# Real-data validation matrix

Acceptance applies to these named configurations at recorded blocks. It is not
an approval of arbitrary future tokens, markets, oracle configurations or chains.
No transaction is broadcast and the existing shadow deployment is unchanged.
Each frozen ERC4626 Core/strategy instance has one underlying asset. Multi-token
support means configuring separate instances with different supported assets;
mixing currencies inside one instance is not claimed.

| Adapter family | Chains actually exercised | Actual underlying assets | Evidence |
|---|---|---|---|
| Aave V3 | Ethereum, Arbitrum, Base | USDT/PYUSD on Ethereum; USDC/WETH on Arbitrum/Base; WETH in Ethereum multi-adapter integration | Expanded actual gate plus four original unmocked Core/epoch scenarios |
| Comet | Ethereum, Arbitrum | USDT/WETH on Ethereum; WETH on Arbitrum | Three direct lifecycles, actual supply-rate/utilization reference; Ethereum WETH production scoring/rebalance/recall |
| Morpho | Ethereum, Arbitrum | USDT, WETH, PYUSD V1/V2 on Ethereum; USDC Prime on Arbitrum | Five positive direct lifecycles, separate actual capped Core rejection, production multi-adapter integration |
| Euler | Ethereum, Arbitrum | USDC/USDT on Ethereum; USDC on Arbitrum | Three direct lifecycles, actual borrow-SPY/utilization/fee supplier-rate calculation; real PUSH-mode production integration |
| Fluid | Ethereum, Arbitrum | USDT/WETH on Ethereum; USDC on Arbitrum | Three direct lifecycles and actual historical PPS; WETH receives real capital during production rebalance and is recalled |
| Dolomite ERC4626 wrappers | Ethereum, Arbitrum | USDC on Ethereum; USDT/WETH and Core-integrated USDC on Arbitrum | Three direct lifecycles with observed PPS reference; production Core scoring/deployment/recall |
| Venus | Arbitrum, BSC | USDC on Arbitrum; bridged 18-decimal USDC/USDT on BSC | Arbitrum time-based model plus both legacy/current BSC models, five direct lifecycles and Arbitrum Core integration |

The expanded gate passes **32 tests in 10 suites, zero failures and zero skips**:
31 positive lifecycle/integration tests and one negative capped-market rejection.
Four further original unmocked Arbitrum/Base tests pass on the final candidate.
These are distinct from controlled mock/fault unit tests and the older mixed
fixture matrix. Mock tests are never added to the no-mock acceptance count.

Raw observed integer quantities, test/compiler source hashes and log checksum:
[actual-acceptance.json](actual-acceptance.json). Canonical hashes/timestamps:
[canonical-headers.json](canonical-headers.json). The expanded runner scans the
entire actual-test directory for prohibited synthetic-state operations, executes
every test there, rejects missing/extra counts, failures and skips, and rejects
source changes during execution.

Production scoring comparisons independently implement USD whole-amount value,
inverse conversion rounding, USD confidence/relative-cap/seed/portfolio tiers,
liquidity, rate stability EMA, score normalization, selection and clipped targets.
USDT, PYUSD and WETH scenarios execute both economically accepted and protection
plans, ordinary epoch claims and full investment recall using frozen Core code.
Small actual negative-benefit scenarios must fail the gate even when signed BPS
division would truncate the loss to zero. A configured fixed USD6 gas cost and
actual asset/USD quotes are used; no actual future profit is asserted.

Historical integrated simulations preserve affected real pool/token/receipt and
NAV dependency state as a closed counterfactual while USD feeds advance to real
historical rounds. They do not replay all intervening canonical transactions.
Native ArbOS fee-precompile execution is not emulated as no-mock evidence;
dynamic gas models have separate unit/configuration and RPC validation gates.

## Explicit exclusions and configuration facts

- Native ETH is not the frozen Core's ERC20 asset; tested ETH exposure uses WETH.
- Direct DolomiteMargin is incompatible with the advertised PoolLike surface.
  Actually validated Dolomite integrations use the protocol's ERC4626 wrappers.
  Ethereum dUSDC reports the official Margin address
  `0x003Ca23Fd5F0ca87D01F6eC6CD14A8AE60c2b97D` through `DOLOMITE_MARGIN()`;
  see [official deployment addresses](https://docs.dolomite.io/smart-contract-addresses/core-immutable).
- Arbitrum Morpho Core `0x7e97fa6893871A2751B5fE961978DCCb2c201E65`
  rejects deposits with actual `AllCapsReached` at 520094008. It is a tested
  rejection/rollback case. The working USDC row is
  [Gauntlet Prime](https://app.morpho.org/arbitrum/vault/0x7c574174DA4b2be3f705c6244B4BfA0815a8B3Ed/gauntlet-usdc-prime).
- PYUSD V1 Sentora's approximately $3 TVL has zero strategy confidence. Its
  adapter lifecycle pass does not approve strategy allocation. Integrated PYUSD
  uses real V2 main vault `0xb576765fB15505433aF24FEe2c0325895C559FB2`.
- V2 liquidity view counts immediately withdrawable idle cash and exit gates;
  force-deallocation and arbitrary adapter penalties are outside its lower bound.
- Venus annual slots are explicitly configured from the actual market/model:
  Arbitrum 31,536,000 seconds, BSC legacy 10,512,000 blocks, current BSC
  70,080,000 blocks at 131080000. No chain-wide historical default is reused.
  Lender-share book TVL includes the protocol's recognized bad-debt convention;
  it is not a certification of credit recovery.
- Protocol APR conventions are recorded explicitly. Euler's legacy Julian-year
  annualization and integer truncation are disclosed, not silently changed to
  force equality with another protocol's display APY.
