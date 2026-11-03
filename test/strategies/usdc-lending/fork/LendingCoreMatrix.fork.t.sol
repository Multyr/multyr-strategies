// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LendingStrategyMatrixFixture} from "./LendingStrategyMatrix.fork.t.sol";
import {LendingAssetConfig} from "../../../../src/strategies/usdc-lending/config/LendingAssetConfig.sol";
import {AaveV3USDCAdapter} from "../../../../src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol";
import {UsdcMultiLendingVault} from "../../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
import {StrategySettingsModule} from "../../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {StrategyParamsModule} from "../../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import {StrategyScoringModule} from "../../../../src/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import {LendingTestPriceOracle} from "../helpers/LendingOracleTestFixture.sol";
import {CoreHarness} from "../../../helpers/CoreHarness.sol";
import {MockParamsProvider} from "../../../helpers/MockParamsProvider.sol";
import {MockBufferManagerForTests} from "../../../helpers/MockBufferManagerForTests.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IParamsProvider} from "@multyr-core/interfaces/IParamsProvider.sol";
import {StrategyRouter} from "@multyr-core/core/modules/StrategyRouter.sol";
import {LiquidityOpsModule} from "@multyr-core/core/modules/LiquidityOpsModule.sol";
import {EpochedQueueModule} from "@multyr-core/core/modules/EpochedQueueModule.sol";

/// @dev Real frozen CoreVault modules/Router and real candidate strategy/Aave.
///      CoreHarness only wires configuration; Params, oracle and warm NAV are fixtures.
contract LendingCoreMatrixForkTest is LendingStrategyMatrixFixture {
    function test_coreArbitrumUsdcEpochExit() public { _coreLifecycle(42161, false); }
    function test_coreArbitrumWethEpochExit() public { _coreLifecycle(42161, true); }
    function test_coreBaseUsdcEpochExit() public { _coreLifecycle(8453, false); }
    function test_coreBaseWethEpochExit() public { _coreLifecycle(8453, true); }

    function _coreLifecycle(uint256 chainId, bool weth) internal {
        if (chainId == 42161) vm.createSelectFork(vm.envOr("LENDING_ARBITRUM_RPC", string("https://arbitrum-one.public.blastapi.io")), 520094008);
        else vm.createSelectFork("https://mainnet.base.org", 53345555);
        LendingAssetConfig.Market memory m = LendingAssetConfig.get(chainId, weth);
        uint256 price = weth ? 3000e18 : 1e18;
        MockParamsProvider params = new MockParamsProvider();
        params.setLockPeriod(0);
        LendingTestPriceOracle oracle = new LendingTestPriceOracle();
        oracle.set(price, uint48(block.timestamp), true);
        CoreHarness core = CoreHarness(payable(deployCode("test/helpers/CoreHarness.sol:CoreHarness",
            abi.encode(IERC20Metadata(m.asset), "Matrix core", "mCORE", address(this), address(this), address(params)))));
        vm.mockCall(address(params), abi.encodeCall(IParamsProvider.oracleConfigFor, (m.asset, address(core))),
            abi.encode(address(oracle), uint256(1 days)));
        vm.mockCall(address(params), abi.encodeCall(IParamsProvider.oracleFor, (m.asset)), abi.encode(address(oracle)));
        MockBufferManagerForTests buffer = new MockBufferManagerForTests(address(core));
        core.setBufferManagerUnsafe(address(buffer));
        core.setOpsUnsafe(0, 0);
        core.setFeeParamsUnsafe(0, 0, address(this));
        address routerAddress = deployCode("StrategyRouter.sol:StrategyRouter",
            abi.encode(address(core), address(core), address(params)));
        core.setStrategyRouterUnsafe(routerAddress);
        UsdcMultiLendingVault strategy = _deployForRouter(m.asset, address(core), routerAddress);
        assertGt(routerAddress.code.length, 0);
        // The frozen production router remains subject to the actual EIP-170 limit.
        assertLe(routerAddress.code.length, 24576);
        vm.prank(address(core));
        StrategyRouter(routerAddress).proposeStrategyAllowlist(address(strategy));
        vm.warp(block.timestamp + StrategyRouter(routerAddress).strategyAllowlistDelay());
        // Real timelock setup must refresh its bounded oracle instead of widening staleness.
        oracle.set(price, uint48(block.timestamp), true);
        buffer.refreshWarmNav();
        vm.startPrank(address(core));
        StrategyRouter(routerAddress).executeStrategyAllowlist(address(strategy));
        StrategyRouter(routerAddress).register(address(strategy), 0, 10000);
        StrategyRouter(routerAddress).setMaxStrategyBps(address(strategy), 10000);
        StrategyRouter(routerAddress).setLossCapPerStrategy(address(strategy), 50);
        vm.stopPrank();
        core.setIntakeUnsafe(address(strategy));

        AaveV3USDCAdapter adapter = new AaveV3USDCAdapter();
        uint256 unit = 10 ** m.decimals;
        adapter.initialize(m.asset, m.aavePool, m.aToken, address(this), address(strategy), 1000 * unit);
        StrategySettingsModule(address(strategy)).whitelistAdapter(address(adapter), true);
        strategy.addAdapter(address(adapter));
        strategy.toggleAdapter(address(adapter), true);
        StrategySettingsModule(address(strategy)).setAdapterDepositMode(address(adapter), false);
        StrategyParamsModule(address(strategy)).pokeExternalTVL();
        StrategyParamsModule(address(strategy)).pokeLiquidityBatch(0, 1);

        uint256 amount = (weth ? 1 : 100) * unit;
        deal(m.asset, address(this), amount);
        IERC20Metadata(m.asset).approve(address(core), amount);
        uint256 shares = core.deposit(amount, address(this));
        assertGt(shares, 0);
        LiquidityOpsModule liquidity = LiquidityOpsModule(address(core));
        liquidity.deployToStrategies(type(uint256).max);
        assertGt(strategy.totalAssets(), 0, "core must actually route capital");
        StrategyScoringModule(address(strategy)).deployIdle();
        assertGt(adapter.totalAssets(), 0, "capital must reach the real Aave market");
        vm.warp(block.timestamp + 301);
        buffer.refreshWarmNav();
        StrategyScoringModule(address(strategy)).deployIdle();
        assertLe(strategy.idleCash(), 2, "staged ramp must leave no material idle funding shortcut");

        EpochedQueueModule queue = EpochedQueueModule(address(core));
        (uint256 epoch, uint256 claim) = queue.requestEpochWithdrawal(shares / 4);
        uint256 owed = queue.epochClaim(epoch, claim).assetsOwed;
        assertGt(owed, 0);
        vm.warp(block.timestamp + 8 days);
        oracle.set(price, uint48(block.timestamp), true);
        buffer.refreshWarmNav();
        strategy.harvest();
        uint256 investedBeforeExit = adapter.totalAssets();
        queue.closeCurrentEpoch();
        for (uint256 i; i < 4 && queue.epochDeficit(epoch) > 0; ++i) {
            uint256 beforeDeficit = queue.epochDeficit(epoch);
            liquidity.realizeForQueue(beforeDeficit);
            queue.fundEpoch(epoch);
            assertLt(queue.epochDeficit(epoch), beforeDeficit, "funding must make real progress");
        }
        assertEq(queue.epochDeficit(epoch), 0);
        uint256 beforeClaim = IERC20Metadata(m.asset).balanceOf(address(this));
        queue.claimEpochAssets(epoch, claim);
        assertEq(IERC20Metadata(m.asset).balanceOf(address(this)) - beforeClaim, owed);
        assertTrue(queue.epochClaim(epoch, claim).claimed);
        assertGt(core.balanceOf(address(this)), 0);
        assertLt(adapter.totalAssets(), investedBeforeExit, "epoch exit must withdraw real invested assets");
    }
}
