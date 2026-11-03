// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {LendingEthereumAdditionalUnmockedE2EBase} from "./LendingEthereumAdditionalUnmockedE2E.t.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AdminModule} from "@multyr-core/core/modules/AdminModule.sol";
import {LiquidityOpsModule} from "@multyr-core/core/modules/LiquidityOpsModule.sol";
import {LendingAssetConfig} from "@multyr-strategies/strategies/usdc-lending/config/LendingAssetConfig.sol";
import {ProtocolRegistry} from "@multyr-strategies/strategies/usdc-lending/registry/ProtocolRegistry.sol";
import {DolomiteUsdcMultiMarketAdapter as Dolomite} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol";
import {VenusUsdcMultiMarketAdapter as Venus} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/VenusUsdcMultiMarket.sol";
import {StrategySettingsModule as Settings} from "@multyr-strategies/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {StrategyParamsModule as Params} from "@multyr-strategies/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import {StrategyScoringModule as Scoring} from "@multyr-strategies/strategies/usdc-lending/controller/StrategyScoringModule.sol";
interface IRemainingActualAdapter {function totalAssets() external view returns(uint256);function externalMarketTVL() external view returns(uint256);function withdrawableAssets() external view returns(uint256);}
interface IRemainingActualPps {function convertToAssets(uint256) external view returns(uint256);}
contract ArbitrumRemainingCoreTest is LendingEthereumAdditionalUnmockedE2EBase {
    using SafeERC20 for IERC20Metadata;
    event ActualRemainingCore(address adapter,address actualMarket,address asset,uint256 rpcBlock,uint256 invested,uint256 recalled,uint256 independentExternalUsd6);
    function test_actualDolomiteProductionCoreScoringAndRecall() public {_run(false);}
    function test_actualVenusProductionCoreScoringAndRecall() public {_run(true);}
    function _assetFeed() internal pure override returns(address){return 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;}
    function _run(bool venus) internal {
        chain=42161;user=vm.addr(0xB0B);vm.createSelectFork("https://arbitrum-one.public.blastapi.io",519094008);rpcForkBlock=519094008;
        market=LendingAssetConfig.Market(42161,0xaf88d065e77c8cC2239327C5EDb3A432268e5831,6,address(0),address(0));
        _configureProductionCore();strategy=_candidate();uint256 eta=router.proposeStrategyAllowlist(address(strategy));vm.makePersistent(keep);_roll(519994008);
        assertGe(vm.getBlockTimestamp(),eta);buffer.refreshWarmNav();router.executeStrategyAllowlist(address(strategy));router.register(address(strategy),0,10000);router.setMaxStrategyBps(address(strategy),10000);router.setLossCapPerStrategy(address(strategy),50);
        address actualMarket=venus?0x7D8609f8da70fF9027E9bc5229Af4F6727662707:0x444868B6e8079ac2c55eea115250f92C2b2c4D14;
        address venue;uint256 firstPps;uint256 firstTime;
        if(venus){Venus a=Venus(payable(_new("VenusUsdcMultiMarket.sol:VenusUsdcMultiMarketAdapter",bytes(""))));a.initialize(market.asset,address(this),address(strategy),0,actualMarket,31536000);venue=address(a);}
        else {ProtocolRegistry r=ProtocolRegistry(_new("ProtocolRegistry.sol:ProtocolRegistry",abi.encode(address(this))));r.addVault(ProtocolRegistry.ProtocolType.DOLOMITE,actualMarket,"actual dUSDC",1000,type(uint128).max);
            Dolomite a=Dolomite(payable(_new("DolomiteUsdcMultiMarket.sol:DolomiteUsdcMultiMarketAdapter",bytes(""))));a.initialize(market.asset,address(this),address(strategy),0,address(r));venue=address(a);a.pokeAPYSnapshots();firstPps=IRemainingActualPps(actualMarket).convertToAssets(1e24);firstTime=vm.getBlockTimestamp();}
        Settings(address(strategy)).whitelistAdapter(venue,true);strategy.addAdapter(venue);strategy.toggleAdapter(venue,true);
        // Only local deployments persist before funding; all protocol state and
        // price rounds at the final pin are canonical, with no synthetic balances.
        vm.makePersistent(keep);_roll(520094008);buffer.refreshWarmNav();
        if(!venus){uint256 secondPps=IRemainingActualPps(actualMarket).convertToAssets(1e24);uint256 rate=(secondPps-firstPps)*315360000000/firstPps/(vm.getBlockTimestamp()-firstTime);Dolomite(payable(venue)).pokeAPYSnapshots();assertEq(Dolomite(payable(venue)).currentAPYBps(),rate);}
        else assertEq(Venus(payable(venue)).accrueVenusInterest(),0);
        this.fundOrdinaryUserAndDeploy(venue);
        uint256 invested=IRemainingActualAdapter(venue).totalAssets();assertGt(invested,0,"production Core capital must enter real protocol");
        uint256 extUsd=Math.mulDiv(IRemainingActualAdapter(venue).externalMarketTVL(),oracle.getQuoteFresh(market.asset).price,1e18);
        assertEq(Params(address(strategy)).assetUnitsToUsd6(IRemainingActualAdapter(venue).externalMarketTVL()),extUsd);assertEq(Scoring(address(strategy)).effectiveMaxAdaptersPerAllocation(),1,"actual small portfolio tier");
        uint256 before=IERC20Metadata(market.asset).balanceOf(address(core));uint256 recalled=router.withdrawAllToCore(address(strategy));assertGt(recalled,0);assertEq(IERC20Metadata(market.asset).balanceOf(address(core))-before,recalled);
        assertLe(strategy.totalAssets(),2);assertLe(IRemainingActualAdapter(venue).totalAssets(),2);
        emit ActualRemainingCore(venue,actualMarket,market.asset,rpcForkBlock,invested,recalled,extUsd);
    }
    function fundOrdinaryUserAndDeploy(address venue) external {
        require(msg.sender==address(this));IERC20Metadata token=IERC20Metadata(market.asset);address holder=0xB38e8c17e38363aF6EbdCb3dAE12e0243582891D;
        uint256 amount=Math.mulDiv(1000e18,1e6,oracle.getQuoteFresh(market.asset).price,Math.Rounding.Up);uint256 seed=Math.mulDiv(1e18,1e6,oracle.getQuoteFresh(market.asset).price,Math.Rounding.Up);uint256 funding=amount+seed;
        uint256 before=token.balanceOf(holder);uint256 selfBefore=token.balanceOf(address(this));uint256 supply=token.totalSupply();assertGe(before,funding);vm.prank(holder);token.safeTransfer(address(this),funding);
        assertEq(token.balanceOf(holder),before-funding);assertEq(token.balanceOf(address(this))-selfBefore,funding);assertEq(token.totalSupply(),supply);emit RealFunding(chain,market.asset,holder,before,funding,token.balanceOf(holder));
        token.forceApprove(address(core),seed);AdminModule(address(core)).seedDeadDeposit(seed);core.unpauseAll();core.freezeRouting();AdminModule(address(core)).freezeParams();
        token.safeTransfer(user,amount);vm.startPrank(user);token.forceApprove(address(core),amount);assertGt(core.deposit(amount,user),0);vm.stopPrank();
        Params(address(strategy)).pokeExternalTVL();Params(address(strategy)).pokeLiquidityBatch(0,1);LiquidityOpsModule(address(core)).deployToStrategies(type(uint256).max);Scoring(address(strategy)).deployIdle();
        Params(address(strategy)).syncPositionAssets();Params(address(strategy)).pokeLiquidityBatch(0,1);assertGt(IRemainingActualAdapter(venue).withdrawableAssets(),0);
    }
}
