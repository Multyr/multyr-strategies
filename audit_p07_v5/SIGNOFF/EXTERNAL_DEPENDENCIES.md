# External Dependencies -- V10.0

**Reference**: V10 adapters interact with the following external protocols.
See MULTI_CHAIN_PLAYBOOK.md for chain-specific addresses.

## Protocol dependencies (Arbitrum One canonical)

| Protocol | Contract | Multyr interaction |
|---|---|---|
| Aave V3 | Pool, aUsdc | AaveV3USDCAdapter deposits/withdraws |
| Compound V3 (Comet) | Comet USDC | CometUsdcMultiMarketAdapter |
| Dolomite | DepositWithdrawalProxy, IsolationModeVault | DolomiteUsdcMultiMarketAdapter |
| Euler V2 | EVault, EulerRouter | EulerUsdcMultiMarketAdapter |
| Fluid | fUSDC (fToken) | FluidUsdcMultiMarketAdapter |
| Morpho Blue | Morpho, MarketId | MorphoUsdcMultiMarketAdapter |
| Venus | vUSDC (vToken), Comptroller | VenusUsdcMultiMarketAdapter |
| Uniswap V3 | SwapRouter | RewardSwapHelper |
| Camelot V3 | AlgebraRouter | RewardSwapHelper |
| Uniswap PERMIT2 | 0x000000000022D473030F116dDEE9F6B43aC78BA3 | EulerUsdcMultiMarketAdapter (constant) |
| Chainlink Automation | Registry | LendingStrategyUpkeep |
| OpenZeppelin | AccessControl, ReentrancyGuard, Initializable (4.x) | All contracts |

## Deployment infrastructure

| Component | Version |
|---|---|
| Solidity | 0.8.28 |
| Foundry | forge 0.2.0+ |
| OpenZeppelin Contracts | 4.x (see lib/) |
| Multyr Core | v1.0.0 (submodule @multyr-core) |
| Multyr Periphery | v1.0.0 (submodule @multyr-periphery) |

## No external price oracles in adapters

Adapters do not directly read price oracles. Oracle reads happen in the controller
layer (StrategyRebalanceGateModule, StrategyScoringModule) and are out of V10 scope.