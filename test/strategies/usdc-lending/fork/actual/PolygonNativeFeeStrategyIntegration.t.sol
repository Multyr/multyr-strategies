// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {LendingEthereumAdditionalUnmockedE2EBase} from "./LendingEthereumAdditionalUnmockedE2E.t.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LendingAssetConfig} from "@multyr-strategies/strategies/usdc-lending/config/LendingAssetConfig.sol";
import {AaveV3USDCAdapter} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol";
import {StrategySettingsModule as Settings} from "@multyr-strategies/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {StrategyScoringModule as Scoring} from "@multyr-strategies/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import {AdminModule} from "@multyr-core/core/modules/AdminModule.sol";
import {LiquidityOpsModule} from "@multyr-core/core/modules/LiquidityOpsModule.sol";
import {ReadOnlyGasEstimator as E, IFeeInfo, IFeed} from "@multyr-strategies/strategies/usdc-lending/gas/ReadOnlyGasEstimator.sol";

/// Genuine historical Polygon Core/strategy/Aave allocation and recall.
/// Existing holder funds; no fabricated balances or protocol/oracle replacements.
contract PolygonNativeFeeStrategyIntegrationTest is LendingEthereumAdditionalUnmockedE2EBase {
    using SafeERC20 for IERC20Metadata;
    event NativeFeePolygon(uint256 rpcBlock,uint256 nativePriceWad,uint256 executionPriceWei,uint256 quotedGas,uint256 expectedUsd6,uint256 quotedUsd6,uint256 invested,uint256 recalled);
    event ActualPolygonRecall(address asset,uint256 rpcBlock,uint256 invested,uint256 recalled);
    function _assetFeed() internal pure override returns(address) { return 0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7; }
    function test_polygonUsdcNativeFeesRealAllocationAndRecall() public {
        chain=137;user=vm.addr(0xB0B);initialBlock=96500000;setupBlock=96622546;
        vm.createSelectFork(vm.envOr("LENDING_RPC_POLYGON",string("https://polygon.drpc.org")),initialBlock);rpcForkBlock=initialBlock;
        assertEq(block.chainid,137);
        market=LendingAssetConfig.Market(137,0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359,6,0x794a61358D6845594F94dc1DB02A252b5b4814aD,0xA4D94019934D8333Ef880ABFFbF2FDd611C762BD);
        _configureProductionCore();strategy=_candidate();uint256 eta=router.proposeStrategyAllowlist(address(strategy));
        vm.makePersistent(keep);_roll(setupBlock);assertGe(vm.getBlockTimestamp(),eta);buffer.refreshWarmNav();
        router.executeStrategyAllowlist(address(strategy));router.register(address(strategy),0,10000);router.setMaxStrategyBps(address(strategy),10000);router.setLossCapPerStrategy(address(strategy),50);
        adapter=AaveV3USDCAdapter(payable(_new("AaveV3USDCmarket.sol:AaveV3USDCAdapter",bytes(""))));
        adapter.initialize(market.asset,market.aavePool,market.aToken,address(this),address(strategy),10000e6);
        Settings(address(strategy)).whitelistAdapter(address(adapter),true);strategy.addAdapter(address(adapter));strategy.toggleAdapter(address(adapter),true);_poke();
        E estimator=E(_new("ReadOnlyGasEstimator.sol:ReadOnlyGasEstimator",abi.encode(
            IFeeInfo(_new("NativeL1FeeInfo.sol:NativeL1FeeInfo",abi.encode(uint256(4096),uint256(117 gwei)))),
            IFeed(0xAB594600376Ec9fD91F8e885dADF0CE036862dE0),IFeed(address(0)),IFeed(address(0)),
            E.Config(400000,150000,200000,1000000,2000000,23112,132,2500,3600,3600,3600,1e6))));
        Settings(address(strategy)).setRebalanceGasEstimator(address(estimator));
        this.checkActualNativeQuote(estimator);
        IERC20Metadata token=IERC20Metadata(market.asset);uint256 assetPrice=oracle.getQuoteFresh(market.asset).price;
        uint256 seed=Math.mulDiv(1e18,1e6,assetPrice,Math.Rounding.Up);uint256 amount=Math.mulDiv(200e18,1e6,assetPrice,Math.Rounding.Up);
        uint256 funding=seed+amount;uint256 beforeHolder=token.balanceOf(HOLDER);uint256 beforeSelf=token.balanceOf(address(this));uint256 supply=token.totalSupply();assertGe(beforeHolder,funding);
        vm.prank(HOLDER);token.safeTransfer(address(this),funding);assertEq(token.balanceOf(HOLDER),beforeHolder-funding);assertEq(token.balanceOf(address(this))-beforeSelf,funding);assertEq(token.totalSupply(),supply);
        emit RealFunding(137,market.asset,HOLDER,beforeHolder,funding,token.balanceOf(HOLDER));
        token.forceApprove(address(core),seed);AdminModule(address(core)).seedDeadDeposit(seed);core.unpauseAll();core.freezeRouting();AdminModule(address(core)).freezeParams();
        token.safeTransfer(user,amount);vm.startPrank(user);token.forceApprove(address(core),amount);assertGt(core.deposit(amount,user),0);vm.stopPrank();
        LiquidityOpsModule(address(core)).deployToStrategies(type(uint256).max);Scoring(address(strategy)).deployIdle();uint256 invested=adapter.totalAssets();assertGt(invested,0,"real USDC must enter Aave");
        uint256 beforeCore=token.balanceOf(address(core));uint256 recalled=router.withdrawAllToCore(address(strategy));assertGt(recalled,0);assertEq(token.balanceOf(address(core))-beforeCore,recalled);assertLe(adapter.totalAssets(),2);assertLe(strategy.totalAssets(),2);
        emit ActualPolygonRecall(market.asset,rpcForkBlock,invested,recalled);
    }
    function checkActualNativeQuote(E estimator) external returns(uint256 nativePrice) {
        require(msg.sender==address(this));
        IFeed feed=IFeed(0xAB594600376Ec9fD91F8e885dADF0CE036862dE0);
        (uint80 round,int256 answer,,uint256 updated,uint80 answered)=feed.latestRoundData();uint8 d=feed.decimals();assertGt(round,0);assertGe(answered,round);assertGt(answer,0);assertLe(updated,vm.getBlockTimestamp());assertLe(vm.getBlockTimestamp()-updated,3600);assertLe(d,18);
        nativePrice=uint256(answer)*10**(18-d);assertLt(nativePrice,100e18,"actual low native price exercises old ETH floor defect");
        (bool valid,uint256 quotedPrice,)=estimator.validatedPrices();assertTrue(valid);assertEq(quotedPrice,nativePrice);
        E.Action[] memory actions=new E.Action[](1);actions[0]=E.Action(address(adapter),1e6,true);E.Quote memory q=estimator.estimate(address(strategy),actions,2,true);
        uint256 executionPrice=block.basefee+117 gwei;if(tx.gasprice>executionPrice)executionPrice=tx.gasprice;
        uint256 gasAmount=1796224;uint256 executionWei=gasAmount*executionPrice;uint256 usdWei=Math.mulDiv(executionWei,nativePrice,1e18,Math.Rounding.Up);uint256 expected=Math.mulDiv(Math.ceilDiv(usdWei,1e12),12500,10000,Math.Rounding.Up);
        assertTrue(q.reliable);assertTrue(q.usedDefaults);assertEq(q.txCount,2);assertEq(q.l2Gas,gasAmount);assertEq(q.executionWei,executionWei);assertEq(q.posterWei,0);assertEq(q.costUSDC,expected);
        emit NativeFeePolygon(rpcForkBlock,nativePrice,executionPrice,gasAmount,expected,q.costUSDC,0,0);
    }
}
