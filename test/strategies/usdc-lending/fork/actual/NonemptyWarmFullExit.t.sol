// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {LendingEthereumAdditionalUnmockedE2EBase} from "./LendingEthereumAdditionalUnmockedE2E.t.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AaveV3WarmAdapter_USDC} from "@multyr-core/adapters/warm/AaveV3WarmAdapter_USDC.sol";
import {AdminModule} from "@multyr-core/core/modules/AdminModule.sol";
import {LiquidityOpsModule} from "@multyr-core/core/modules/LiquidityOpsModule.sol";
import {EpochedQueueModule} from "@multyr-core/core/modules/EpochedQueueModule.sol";
import {LendingAssetConfig} from "@multyr-strategies/strategies/usdc-lending/config/LendingAssetConfig.sol";
import {AaveV3USDCAdapter} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol";
import {MorphoUsdcMultiMarketAdapter} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol";
import {ProtocolRegistry} from "@multyr-strategies/strategies/usdc-lending/registry/ProtocolRegistry.sol";
import {StrategySettingsModule as Settings} from "@multyr-strategies/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {StrategyParamsModule as Params} from "@multyr-strategies/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import {StrategyScoringModule as Scoring} from "@multyr-strategies/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import {ISwapRouterV3} from "@multyr-strategies/strategies/usdc-lending/swap/RewardSwapHelper.sol";
interface IWarmV3Factory {function getPool(address,address,uint24) external view returns(address);}
interface IWarmFundingFeed {function latestRoundData() external view returns(uint80,int256,uint256,uint256,uint80);function decimals() external view returns(uint8);}

/// Frozen production Core warm sleeve plus two actual lending venues; real funding and queued user exit.
contract NonemptyWarmFullExitTest is LendingEthereumAdditionalUnmockedE2EBase {
    using SafeERC20 for IERC20Metadata;
    address fundingPool;
    address constant FUNDING_USDT=0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    AaveV3WarmAdapter_USDC warm;
    MorphoUsdcMultiMarketAdapter morpho;
    address constant PRIME=0x7c574174DA4b2be3f705c6244B4BfA0815a8B3Ed;
    event ActualNonemptyWarm(uint256 rpcBlock,uint256 warmBefore,uint256 strategyBefore,uint256 owed,uint256 claimed,uint256 warmAfter,uint256 strategyAfter);
    function _assetFeed() internal pure override returns(address){return 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;}
    function test_realWarmAndTwoLendingVenuesFundFullUserClaim() public {
        chain=42161;user=vm.addr(0xB0B);initialBlock=515094008;setupBlock=516094008;
        vm.createSelectFork("https://arbitrum-one.public.blastapi.io",initialBlock);rpcForkBlock=initialBlock;
        market=LendingAssetConfig.Market(42161,0xaf88d065e77c8cC2239327C5EDb3A432268e5831,6,0x794a61358D6845594F94dc1DB02A252b5b4814aD,0x724dc807b04555b71ed48a6896b6F41593b8C637);
        _configureProductionCore();strategy=_candidate();uint256 eta=router.proposeStrategyAllowlist(address(strategy));
        // Capital is deposited while the original two-day allowlist is pending. Its real deposit lock ages concurrently.
        uint256 depositTime=_depositEarly();vm.makePersistent(keep);vm.makePersistent(market.asset);vm.makePersistent(FUNDING_USDT);vm.makePersistent(fundingPool);
        _roll(setupBlock);assertGe(vm.getBlockTimestamp(),eta);
        buffer.refreshWarmNav();router.executeStrategyAllowlist(address(strategy));router.register(address(strategy),0,10000);router.setMaxStrategyBps(address(strategy),10000);router.setLossCapPerStrategy(address(strategy),50);
        adapter=AaveV3USDCAdapter(payable(_new("AaveV3USDCmarket.sol:AaveV3USDCAdapter",bytes(""))));adapter.initialize(market.asset,market.aavePool,market.aToken,address(this),address(strategy),10000000e6);_register(address(adapter));
        ProtocolRegistry reg=ProtocolRegistry(_new("ProtocolRegistry.sol:ProtocolRegistry",abi.encode(address(this))));reg.addVault(ProtocolRegistry.ProtocolType.MORPHO,PRIME,"actual USDC Prime",1000,type(uint128).max);
        morpho=MorphoUsdcMultiMarketAdapter(payable(_new("MorphoUsdcMultiMarket.sol:MorphoUsdcMultiMarketAdapter",bytes(""))));morpho.initialize(market.asset,address(this),address(strategy),10000000e6,address(reg));_register(address(morpho));morpho.pokeAPYSnapshots();
        // Learn actual PPS across canonical historical observations before taking any position.
        vm.makePersistent(keep);_roll(setupBlock+4000);morpho.pokeAPYSnapshots();buffer.refreshWarmNav();
        warm=AaveV3WarmAdapter_USDC(_new("AaveV3WarmAdapter_USDC.sol:AaveV3WarmAdapter_USDC",abi.encode(address(buffer),address(core),market.asset,market.aavePool,0x243Aa95cAC2a25651eda86e80bEe66114413c43b)));
        assertEq(warm.asset(),market.asset);assertEq(warm.coreVault(),address(core));assertEq(warm.controller(),address(buffer));assertEq(address(warm.aToken()),market.aToken);
        buffer.addWarmAdapter(address(warm));address[] memory ws=new address[](1);ws[0]=address(warm);core.approveWarmAdapters(ws,type(uint256).max);buffer.setKeeper(address(this));assertEq(buffer.minRebalanceAmount(),5000e6);
        IERC20Metadata token=IERC20Metadata(market.asset);
        assertEq(warm.totalAssets(),0,"new warm adapter must not be pre-funded");uint256 hotBeforeWarm=token.balanceOf(address(core));
        buffer.rebalance();buffer.refreshWarmNav();assertGt(warm.totalAssets(),0,"warm must hold actual Aave receipts");assertApproxEqAbs(hotBeforeWarm-token.balanceOf(address(core)),warm.totalAssets(),2,"actual Core cash funds fresh warm position");assertEq(token.balanceOf(address(buffer)),0);_freshTwo();LiquidityOpsModule(address(core)).deployToStrategies(type(uint256).max);Scoring(address(strategy)).deployIdle();_freshTwo();assertGt(adapter.totalAssets(),0);assertGt(morpho.totalAssets(),0);assertGt(strategy.totalAssets(),0);_checkNav();
        vm.makePersistent(keep);vm.makePersistent(market.asset);vm.makePersistent(market.aavePool);vm.makePersistent(market.aToken);_persistDebtTokens();vm.makePersistent(PRIME);vm.makePersistent(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
        _roll(setupBlock+8000);assertGe(vm.getBlockTimestamp(),depositTime+1 days);buffer.refreshWarmNav();morpho.pokeAPYSnapshots();_freshTwo();_checkNav();
        EpochedQueueModule queue=EpochedQueueModule(address(core));uint256 shares=core.balanceOf(user);assertGt(shares,0);vm.prank(user);(uint256 epoch,uint256 claim)=queue.requestEpochWithdrawal(shares);assertEq(core.balanceOf(user),0);uint256 owed=queue.epochClaim(epoch,claim).assetsOwed;uint256 warmBefore=warm.totalAssets();uint256 strategyBefore=strategy.totalAssets();uint256 hot=token.balanceOf(address(core));assertGt(owed,hot+warmBefore);assertGt(owed,hot+strategyBefore);uint256 requestTime=vm.getBlockTimestamp();
        uint256 epochDuration=config.getQueueParams(address(core)).epochDuration;assertEq(epochDuration,7 days);
        _roll(setupBlock+4000000);assertGe(vm.getBlockTimestamp(),requestTime+epochDuration);buffer.refreshWarmNav();morpho.pokeAPYSnapshots();_freshTwo();queue.closeCurrentEpoch();assertEq(queue.epochClaim(epoch,claim).assetsOwed,owed,"request fixes owed assets before close");
        // Actual queue policy pulls warm first, then the strategy for the residual.
        queue.fundEpoch(epoch);for(uint256 i;i<6&&queue.epochDeficit(epoch)>0;++i){uint256 deficit=queue.epochDeficit(epoch);LiquidityOpsModule(address(core)).realizeForQueue(deficit);queue.fundEpoch(epoch);assertLt(queue.epochDeficit(epoch),deficit);}
        assertEq(queue.epochDeficit(epoch),0);uint256 beforeUser=token.balanceOf(user);vm.prank(user);queue.claimEpochAssets(epoch,claim);uint256 paid=token.balanceOf(user)-beforeUser;assertEq(paid,owed);assertTrue(queue.epochClaim(epoch,claim).claimed);assertEq(core.balanceOf(user),0);assertLt(warm.totalAssets(),warmBefore);assertLt(strategy.totalAssets(),strategyBefore);assertEq(token.balanceOf(address(buffer)),0);buffer.refreshWarmNav();_freshTwo();_checkNav();emit ActualNonemptyWarm(rpcForkBlock,warmBefore,strategyBefore,owed,paid,warm.totalAssets(),strategy.totalAssets());
    }
    function _register(address a) internal {Settings(address(strategy)).whitelistAdapter(a,true);strategy.addAdapter(a);strategy.toggleAdapter(a,true);}
    function _freshTwo() internal {Params(address(strategy)).syncPositionAssets();Params(address(strategy)).pokeExternalTVL();Params(address(strategy)).pokeLiquidityBatch(0,2);}
    function _checkNav() internal view {uint256 gross=IERC20Metadata(market.asset).balanceOf(address(core))+warm.totalAssets()+strategy.totalAssets();assertApproxEqAbs(core.grossAssets(),gross,2);uint256 owed=core.totalOwed();assertApproxEqAbs(core.totalAssets(),gross>owed?gross-owed:0,2);}
    function _depositEarly() internal returns(uint256 timestamp) {
        IERC20Metadata usdt=IERC20Metadata(FUNDING_USDT);IERC20Metadata token=IERC20Metadata(market.asset);assertEq(usdt.decimals(),6);
        uint256 beforeHolder=usdt.balanceOf(HOLDER);uint256 beforeSelf=usdt.balanceOf(address(this));uint256 supply=usdt.totalSupply();assertGe(beforeHolder,90000e6);vm.prank(HOLDER);usdt.safeTransfer(address(this),90000e6);assertEq(usdt.balanceOf(HOLDER),beforeHolder-90000e6);assertEq(usdt.balanceOf(address(this))-beforeSelf,90000e6);assertEq(usdt.totalSupply(),supply);emit RealFunding(chain,FUNDING_USDT,HOLDER,beforeHolder,90000e6,usdt.balanceOf(HOLDER));
        IWarmFundingFeed feed=IWarmFundingFeed(address(bytes20(hex"3f3f5df88dc9f13eac63df89ec16ef6e7e25dde7")));(uint80 round,int256 answer,,uint256 updated,uint80 answered)=feed.latestRoundData();assertEq(feed.decimals(),8);assertGt(round,0);assertGe(answered,round);assertGt(answer,0);assertLe(updated,vm.getBlockTimestamp());assertLe(vm.getBlockTimestamp()-updated,1 days);
        uint256 price=oracle.getQuoteFresh(market.asset).price;uint256 expected=Math.mulDiv(88000e6,uint256(answer)*1e10,price);uint256 old=token.balanceOf(address(this));uint256 tokenSupply=token.totalSupply();address uni=0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
        fundingPool=IWarmV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984).getPool(FUNDING_USDT,market.asset,100);assertGt(fundingPool.code.length,0);usdt.forceApprove(uni,88000e6);uint256 got=ISwapRouterV3(uni).exactInput(ISwapRouterV3.ExactInputParams(abi.encodePacked(FUNDING_USDT,uint24(100),market.asset),address(this),88000e6,expected*9900/10000));usdt.forceApprove(uni,0);assertGe(got,expected*9900/10000);assertEq(token.balanceOf(address(this))-old,got);assertEq(token.totalSupply(),tokenSupply);assertEq(usdt.totalSupply(),supply);emit RealFundingConversion(chain,FUNDING_USDT,market.asset,88000e6,expected,got);
        uint256 seed=Math.mulDiv(1e18,1e6,price,Math.Rounding.Up);uint256 amount=Math.mulDiv(85000e18,1e6,price,Math.Rounding.Up);assertGe(token.balanceOf(address(this)),seed+amount);token.forceApprove(address(core),seed);AdminModule(address(core)).seedDeadDeposit(seed);core.unpauseAll();core.freezeRouting();AdminModule(address(core)).freezeParams();token.safeTransfer(user,amount);vm.startPrank(user);token.forceApprove(address(core),amount);assertGt(core.deposit(amount,user),0);vm.stopPrank();timestamp=vm.getBlockTimestamp();
    }
}
