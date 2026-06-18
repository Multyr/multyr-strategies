// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AaveV3USDCAdapter} from
    "../../src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol";
import {CometUsdcMultiMarketAdapter} from
    "../../src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol";
import {DolomiteUsdcMultiMarketAdapter} from
    "../../src/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol";
import {EulerUsdcMultiMarketAdapter} from
    "../../src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol";
import {FluidUsdcMultiMarketAdapter} from
    "../../src/strategies/usdc-lending/adapters/lending/FluidUsdcMultiMarket.sol";
import {MorphoUsdcMultiMarketAdapter} from
    "../../src/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol";
import {VenusUsdcMultiMarketAdapter} from
    "../../src/strategies/usdc-lending/adapters/lending/VenusUsdcMultiMarket.sol";
import {RewardSwapHelper} from
    "../../src/strategies/usdc-lending/swap/RewardSwapHelper.sol";
import {StrategyBootstrapper} from
    "../../src/strategies/usdc-lending/StrategyBootstrapper.sol";

/// @notice Test helper for V10 adapter deploy+initialize pattern.
/// @dev Provides one-liner deploy+init for each adapter type, reducing boilerplate
///      in the 49 instantiations across test files. Each function deploys a fresh
///      contract and calls initialize() atomically — mirrors AdapterFactory behaviour
///      but without CREATE2 or DEPLOYER_ROLE complexity for unit test setup.
abstract contract V10AdapterTestHelper {
    function deployAaveAdapter(
        address asset_,
        address pool_,
        address aToken_,
        address admin_,
        address vault_,
        uint256 maxCap_
    ) internal returns (AaveV3USDCAdapter adapter) {
        adapter = new AaveV3USDCAdapter();
        adapter.initialize(asset_, pool_, aToken_, admin_, vault_, maxCap_);
    }

    function deployCometAdapter(
        address usdc_,
        address admin_,
        address vault_,
        uint256 capacity_,
        address registry_
    ) internal returns (CometUsdcMultiMarketAdapter adapter) {
        adapter = new CometUsdcMultiMarketAdapter();
        adapter.initialize(usdc_, admin_, vault_, capacity_, registry_);
    }

    function deployDolomiteAdapter(
        address usdc_,
        address admin_,
        address vault_,
        uint256 capacity_,
        address registry_
    ) internal returns (DolomiteUsdcMultiMarketAdapter adapter) {
        adapter = new DolomiteUsdcMultiMarketAdapter();
        adapter.initialize(usdc_, admin_, vault_, capacity_, registry_);
    }

    function deployEulerAdapter(
        address vault_,
        address usdc_,
        address[] memory markets_,
        address registry_,
        address admin_
    ) internal returns (EulerUsdcMultiMarketAdapter adapter) {
        adapter = new EulerUsdcMultiMarketAdapter();
        adapter.initialize(vault_, usdc_, markets_, registry_, admin_);
    }

    function deployFluidAdapter(
        address usdc_,
        address admin_,
        address vault_,
        uint256 capacity_,
        address fToken_
    ) internal returns (FluidUsdcMultiMarketAdapter adapter) {
        adapter = new FluidUsdcMultiMarketAdapter();
        adapter.initialize(usdc_, admin_, vault_, capacity_, fToken_);
    }

    function deployMorphoAdapter(
        address usdc_,
        address admin_,
        address vault_,
        uint256 capacity_,
        address registry_
    ) internal returns (MorphoUsdcMultiMarketAdapter adapter) {
        adapter = new MorphoUsdcMultiMarketAdapter();
        adapter.initialize(usdc_, admin_, vault_, capacity_, registry_);
    }

    function deployVenusAdapter(
        address usdc_,
        address admin_,
        address vault_,
        uint256 capacity_,
        address vToken_,
        uint256 blocksPerYear_
    ) internal returns (VenusUsdcMultiMarketAdapter adapter) {
        adapter = new VenusUsdcMultiMarketAdapter();
        adapter.initialize(usdc_, admin_, vault_, capacity_, vToken_, blocksPerYear_);
    }

    function deployRewardSwapHelper(
        address usdc_,
        address admin_,
        address uniswapV3Router_,
        address camelotV3Router_
    ) internal returns (RewardSwapHelper helper) {
        helper = new RewardSwapHelper();
        helper.initialize(usdc_, admin_, uniswapV3Router_, camelotV3Router_);
    }

    function deployStrategyBootstrapper(
        address payable strategy_,
        address deployer_
    ) internal returns (StrategyBootstrapper bootstrapper) {
        bootstrapper = new StrategyBootstrapper();
        bootstrapper.initialize(strategy_, deployer_);
    }
}
