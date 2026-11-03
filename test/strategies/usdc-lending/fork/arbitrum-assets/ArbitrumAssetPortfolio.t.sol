// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {ActualMultiAdapterScoringTest} from "../actual/ActualMultiAdapterScoring.t.sol";
import {RealArbitrumFunding,IMatrixFundingFeed} from "./RealArbitrumFunding.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AdminModule} from "@multyr-core/core/modules/AdminModule.sol";
import {LiquidityOpsModule} from "@multyr-core/core/modules/LiquidityOpsModule.sol";
import {EpochedQueueModule} from "@multyr-core/core/modules/EpochedQueueModule.sol";
import {LendingAssetConfig} from "@multyr-strategies/strategies/usdc-lending/config/LendingAssetConfig.sol";
import {ProtocolRegistry} from "@multyr-strategies/strategies/usdc-lending/registry/ProtocolRegistry.sol";
import {AaveV3USDCAdapter as Aave} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol";
import {CometUsdcMultiMarketAdapter as Comet} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol";
import {MorphoUsdcMultiMarketAdapter as Morpho} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol";
import {EulerUsdcMultiMarketAdapter as Euler} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol";
import {FluidUsdcMultiMarketAdapter as Fluid} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/FluidUsdcMultiMarket.sol";
import {DolomiteUsdcMultiMarketAdapter as Dolomite} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol";
import {VenusUsdcMultiMarketAdapter as Venus} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/VenusUsdcMultiMarket.sol";
import {StrategySettingsModule as Settings} from "@multyr-strategies/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {StrategyParamsModule as Params} from "@multyr-strategies/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import {StrategyScoringModule as Scoring} from "@multyr-strategies/strategies/usdc-lending/controller/StrategyScoringModule.sol";
interface IMatrixPortfolioAdapter {function totalAssets() external view returns(uint256);function externalMarketTVL() external view returns(uint256);}

/// Reuses the independently implemented score/selection/target and protection
/// references, now with actual Arbitrum 6/8/18-decimal asset portfolios.
contract ArbitrumAssetPortfolioTest is ActualMultiAdapterScoringTest,RealArbitrumFunding {
    using SafeERC20 for IERC20Metadata;
    mapping(address=>uint256) private families;
    address private assetFeed;
    address private exitUser;
    event ActualMatrixPortfolio(address asset,uint256 eligibleVenues,uint256 investedVenues,uint256 userClaim,uint256 finalRecall);
    event ActualMatrixPortfolioExcluded(uint256 family,address asset,address market,uint256 externalUsd6);
    function _rpc() internal view override returns(string memory){return vm.envString("ARBITRUM_RPC_URL");}
    function _assetFeed() internal view override returns(address){return assetFeed;}
    function _new(string memory artifact,bytes memory args) internal override returns(address a){a=_deployArbitrumFixture(artifact,args,market.asset,keep.length);keep.push(a);}

    function test_arbitrumRealAssetPortfolioScoringRebalanceAndExit() public {
        chain=42161;user=vm.addr(0xB0B);exitUser=vm.addr(0xB0C2);assetFeed=vm.envAddress("MATRIX_FEED");
        vm.createSelectFork(_rpc(),513000000);rpcForkBlock=513000000;
        market=LendingAssetConfig.Market(chain,vm.envAddress("MATRIX_ASSET"),0,vm.envAddress("MATRIX_MARKET"),vm.envAddress("MATRIX_RECEIPT"));market.decimals=IERC20Metadata(market.asset).decimals();
        _configureProductionCore();strategy=_candidate();uint256 eta=router.proposeStrategyAllowlist(address(strategy));vm.makePersistent(keep);_roll(513800000);assertGe(vm.getBlockTimestamp(),eta);
        buffer.refreshWarmNav();router.executeStrategyAllowlist(address(strategy));router.register(address(strategy),0,10000);router.setMaxStrategyBps(address(strategy),10000);router.setLossCapPerStrategy(address(strategy),50);
        address[] memory markets=vm.envAddress("MATRIX_MARKETS",",");assertEq(markets.length,7);
        ProtocolRegistry r=ProtocolRegistry(_new("ProtocolRegistry.sol:ProtocolRegistry",abi.encode(address(this))));
        for(uint256 i;i<7;++i){if(markets[i]==address(0))continue;address a=_venue(i,markets[i],r);
            uint256 usd=Math.mulDiv(IMatrixPortfolioAdapter(a).externalMarketTVL(),oracle.getQuoteFresh(market.asset).price,(10**market.decimals)*1e12);
            if(usd<100_000e6){emit ActualMatrixPortfolioExcluded(i,market.asset,markets[i],usd);continue;}
            _register(a);families[a]=i;_snapshot(a,i);
        }
        assertGe(venues.length,2,"actual portfolio needs multiple eligible protocols");vm.makePersistent(keep);_roll(514200000);buffer.refreshWarmNav();_fresh();
        vm.startStateDiffRecording();_fundArbitrumAsset(market.asset,assetFeed,100000);this.depositPortfolioUsers();
        Vm.AccountAccess[] memory changes=vm.stopAndReturnStateDiff();
        for(uint256 i;i<changes.length;++i)for(uint256 j;j<changes[i].storageAccesses.length;++j)if(changes[i].storageAccesses[j].isWrite){address account=changes[i].storageAccesses[j].account;require(account!=assetFeed,"price feed cannot be written");vm.makePersistent(account);}
        _persistArbitrumFunding();vm.makePersistent(keep);vm.makePersistent(market.asset);vm.makePersistent(market.aavePool);vm.makePersistent(market.aToken);_persistDebtTokens();
        for(uint256 i;i<venues.length;++i)this.preservePortfolioNav(venues[i]);
        _advancePortfolio(515000000);Scoring(address(strategy)).deployIdle();_fresh();this.checkActualReference();
        uint256 invested;for(uint256 i;i<venues.length;++i)if(IMatrixPortfolioAdapter(venues[i]).totalAssets()>2)++invested;assertGe(invested,2,"real capital must enter multiple protocols");
        this.exerciseActualRiskRebalance();
        EpochedQueueModule q=EpochedQueueModule(address(core));uint256 shares=core.balanceOf(exitUser);assertGt(shares,0);assertLt(shares*10000/core.totalSupply(),1000);
        vm.prank(exitUser);(uint256 epoch,uint256 claim)=q.requestEpochWithdrawal(shares);uint256 owed=q.epochClaim(epoch,claim).assetsOwed;uint256 requested=vm.getBlockTimestamp();
        _advancePortfolio(520094008);assertGe(vm.getBlockTimestamp(),requested+7 days);q.closeCurrentEpoch();q.fundEpoch(epoch);
        for(uint256 i;i<8&&q.epochDeficit(epoch)>0;++i){LiquidityOpsModule(address(core)).realizeForQueue(q.epochDeficit(epoch));q.fundEpoch(epoch);}assertEq(q.epochDeficit(epoch),0);
        uint256 old=IERC20Metadata(market.asset).balanceOf(exitUser);vm.prank(exitUser);q.claimEpochAssets(epoch,claim);assertEq(IERC20Metadata(market.asset).balanceOf(exitUser)-old,owed);assertEq(core.balanceOf(exitUser),0);
        old=IERC20Metadata(market.asset).balanceOf(address(core));uint256 recalled=router.withdrawAllToCore(address(strategy));assertGt(recalled,0);assertEq(IERC20Metadata(market.asset).balanceOf(address(core))-old,recalled);assertLe(strategy.totalAssets(),2);
        for(uint256 i;i<venues.length;++i)assertLe(IMatrixPortfolioAdapter(venues[i]).totalAssets(),2,"all actual portfolio positions recalled");
        emit ActualMatrixPortfolio(market.asset,venues.length,invested,owed,recalled);
    }
    function depositPortfolioUsers() external {
        require(msg.sender==address(this));IERC20Metadata token=IERC20Metadata(market.asset);uint256 unit=10**market.decimals;uint256 price=oracle.getQuoteFresh(market.asset).price;
        uint256 seed=Math.mulDiv(1e18,unit,price,Math.Rounding.Up);uint256 big=Math.mulDiv(85000e18,unit,price,Math.Rounding.Up);uint256 small=Math.mulDiv(6500e18,unit,price,Math.Rounding.Up);assertGe(token.balanceOf(address(this)),seed+big+small);
        token.forceApprove(address(core),seed);AdminModule(address(core)).seedDeadDeposit(seed);core.unpauseAll();core.freezeRouting();AdminModule(address(core)).freezeParams();
        token.safeTransfer(user,big);vm.startPrank(user);token.forceApprove(address(core),big);assertGt(core.deposit(big,user),0);vm.stopPrank();
        token.safeTransfer(exitUser,small);vm.startPrank(exitUser);token.forceApprove(address(core),small);assertGt(core.deposit(small,exitUser),0);vm.stopPrank();
        _fresh();LiquidityOpsModule(address(core)).deployToStrategies(type(uint256).max);Scoring(address(strategy)).deployIdle();_fresh();
    }
    function _venue(uint256 f,address m,ProtocolRegistry r) internal returns(address a){
        if(f==0){a=_new("AaveV3USDCmarket.sol:AaveV3USDCAdapter",bytes(""));Aave(payable(a)).initialize(market.asset,m,market.aToken,address(this),address(strategy),0);adapter=Aave(payable(a));}
        else if(f==3){address[] memory ms=new address[](1);ms[0]=m;a=_new("EulerUsdcMultiMarket.sol:EulerUsdcMultiMarketAdapter",bytes(""));Euler(payable(a)).initialize(address(strategy),market.asset,ms,address(0),address(this));Euler(payable(a)).initializeMarkets();}
        else if(f==4){a=_new("FluidUsdcMultiMarket.sol:FluidUsdcMultiMarketAdapter",bytes(""));Fluid(payable(a)).initialize(market.asset,address(this),address(strategy),0,m);}
        else if(f==6){a=_new("VenusUsdcMultiMarket.sol:VenusUsdcMultiMarketAdapter",bytes(""));Venus(payable(a)).initialize(market.asset,address(this),address(strategy),0,m,31536000);}
        else {ProtocolRegistry.ProtocolType t=f==1?ProtocolRegistry.ProtocolType.COMPOUND_V3:f==2?ProtocolRegistry.ProtocolType.MORPHO:ProtocolRegistry.ProtocolType.DOLOMITE;r.addVault(t,m,"actual portfolio",1000,type(uint128).max);
            if(f==1){a=_new("CometUsdcMultiMarket.sol:CometUsdcMultiMarketAdapter",bytes(""));Comet(payable(a)).initialize(market.asset,address(this),address(strategy),0,address(r));}
            else if(f==2){a=_new("MorphoUsdcMultiMarket.sol:MorphoUsdcMultiMarketAdapter",bytes(""));Morpho(payable(a)).initialize(market.asset,address(this),address(strategy),0,address(r));if(market.asset==0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9)Morpho(payable(a)).setVaultV2LiquidityView(_new("MorphoVaultV2LiquidityView.sol:MorphoVaultV2LiquidityView",bytes("")));}
            else {a=_new("DolomiteUsdcMultiMarket.sol:DolomiteUsdcMultiMarketAdapter",bytes(""));Dolomite(payable(a)).initialize(market.asset,address(this),address(strategy),0,address(r));}}
    }
    function _snapshot(address a,uint256 f) internal {if(f==2)Morpho(payable(a)).pokeAPYSnapshots();else if(f==4)Fluid(payable(a)).pokeAPYSnapshots();else if(f==5)Dolomite(payable(a)).pokeAPYSnapshots();}
    function _fresh() internal override {
        IMatrixFundingFeed feed=IMatrixFundingFeed(assetFeed);(,int256 answer,,uint256 updated,)=feed.latestRoundData();assertGt(answer,0);assertEq(feed.decimals(),8);assertLe(updated,vm.getBlockTimestamp());assertLe(vm.getBlockTimestamp()-updated,1 days);assertEq(oracle.getQuoteFresh(market.asset).price,uint256(answer)*1e10,"independent actual USD price for portfolio scoring");
        for(uint256 i;i<venues.length;++i)_snapshot(venues[i],families[venues[i]]);
        Params(address(strategy)).syncPositionAssets();Params(address(strategy)).pokeExternalTVL();Params(address(strategy)).pokeLiquidityBatch(0,venues.length);
        for(uint256 i;i<venues.length;++i)_observeReferenceStability(venues[i]);
    }
    function _advancePortfolio(uint256 target) internal {
        // Observe real PPS within its two-day production window. Refresh Core
        // and strategy caches before financial actions, not on empty timer ticks.
        while(rpcForkBlock<target){uint256 next=rpcForkBlock+400000;if(next>target)next=target;uint256 previous=vm.getBlockTimestamp();_roll(next);assertLe(vm.getBlockTimestamp()-previous,2 days,"canonical PPS observation window");for(uint256 i;i<venues.length;++i)_snapshot(venues[i],families[venues[i]]);}
        buffer.refreshWarmNav();_fresh();
    }
    function preservePortfolioNav(address a) external {
        require(msg.sender==address(this));vm.startStateDiffRecording();IMatrixPortfolioAdapter(a).totalAssets();Vm.AccountAccess[] memory accesses=vm.stopAndReturnStateDiff();require(accesses.length>0&&accesses.length<=512);
        for(uint256 i;i<accesses.length;++i){address account=accesses[i].account;if(account.code.length==0)continue;require(account!=assetFeed,"price feed must advance canonically");vm.makePersistent(account);}
    }
}
