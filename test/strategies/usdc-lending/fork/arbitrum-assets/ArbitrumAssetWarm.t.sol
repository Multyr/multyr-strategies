// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LendingEthereumAdditionalUnmockedE2EBase} from "../actual/LendingEthereumAdditionalUnmockedE2E.t.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AaveV3WarmAdapter_USDC} from "@multyr-core/adapters/warm/AaveV3WarmAdapter_USDC.sol";
import {AdminModule} from "@multyr-core/core/modules/AdminModule.sol";
import {LiquidityOpsModule} from "@multyr-core/core/modules/LiquidityOpsModule.sol";
import {EpochedQueueModule} from "@multyr-core/core/modules/EpochedQueueModule.sol";
import {LendingAssetConfig} from "@multyr-strategies/strategies/usdc-lending/config/LendingAssetConfig.sol";
import {AaveV3USDCAdapter} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol";
import {StrategySettingsModule as Settings} from "@multyr-strategies/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {StrategyParamsModule as Params} from "@multyr-strategies/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import {StrategyScoringModule as Scoring} from "@multyr-strategies/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import {ISwapRouterV3} from "@multyr-strategies/strategies/usdc-lending/swap/RewardSwapHelper.sol";
import {RealArbitrumFunding} from "./RealArbitrumFunding.sol";

interface IMatrixWarmFeed {function latestRoundData() external view returns(uint80,int256,uint256,uint256,uint80);function decimals() external view returns(uint8);}
interface IMatrixWarmFactory {function getPool(address,address,uint24) external view returns(address);}

/// Existing frozen Aave warm code, real underlying and an ordinary full-user claim.
/// Kept separate from Lending-only qualification; no Core source changes.
contract ArbitrumAssetWarmTest is LendingEthereumAdditionalUnmockedE2EBase,RealArbitrumFunding {
    using SafeERC20 for IERC20Metadata;
    address constant FUNDING=0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address constant UNISWAP=0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant WETH=0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address[] pools;
    AaveV3WarmAdapter_USDC warm;
    address smallUser;
    event ActualMatrixWarmConfig(address asset,uint256 defaultRawMin,uint256 configuredMin,uint256 referenceUsd6);
    event ActualMatrixWarmExit(address asset,uint256 pin,uint256 warmBefore,uint256 warmAfter,uint256 invested,uint256 owed,uint256 received,uint256 residualShares);
    function _rpc() internal view override returns(string memory){return vm.envString("ARBITRUM_RPC_URL");}
    function _new(string memory artifact,bytes memory args) internal override returns(address a){a=_deployArbitrumFixture(artifact,args,market.asset,keep.length);keep.push(a);}
    function _assetFeed() internal view override returns(address){return vm.envAddress("MATRIX_FEED");}
    function _usd(uint256 dollars) internal view returns(uint256){IMatrixWarmFeed feed=IMatrixWarmFeed(_assetFeed());(,int256 answer,,uint256 updated,)=feed.latestRoundData();assertGt(answer,0);assertEq(feed.decimals(),8);assertLe(updated,vm.getBlockTimestamp());assertLe(vm.getBlockTimestamp()-updated,1 days);uint256 price=oracle.getQuoteFresh(market.asset).price;assertEq(price,uint256(answer)*1e10,"independent raw USD price for frozen warm Core");return Math.mulDiv(dollars*1e18,10**market.decimals,price,Math.Rounding.Up);}
    function test_arbitrumFrozenWarmCoreStrategyLifecycle() public {
        chain=42161;user=vm.addr(0xB0B);smallUser=vm.addr(0xB0C2);initialBlock=513000000;setupBlock=513800000;
        vm.createSelectFork(_rpc(),initialBlock);rpcForkBlock=initialBlock;
        market=LendingAssetConfig.Market(chain,vm.envAddress("MATRIX_ASSET"),0,vm.envAddress("MATRIX_MARKET"),vm.envAddress("MATRIX_RECEIPT"));
        market.decimals=IERC20Metadata(market.asset).decimals();
        _configureProductionCore();strategy=_candidate();uint256 eta=router.proposeStrategyAllowlist(address(strategy));
        vm.makePersistent(keep);_roll(setupBlock);assertGe(vm.getBlockTimestamp(),eta);buffer.refreshWarmNav();
        router.executeStrategyAllowlist(address(strategy));router.register(address(strategy),0,10000);router.setMaxStrategyBps(address(strategy),10000);router.setLossCapPerStrategy(address(strategy),50);
        adapter=AaveV3USDCAdapter(payable(_new("AaveV3USDCmarket.sol:AaveV3USDCAdapter",bytes(""))));
        adapter.initialize(market.asset,market.aavePool,market.aToken,address(this),address(strategy),0);
        Settings(address(strategy)).whitelistAdapter(address(adapter),true);strategy.addAdapter(address(adapter));strategy.toggleAdapter(address(adapter),true);
        warm=AaveV3WarmAdapter_USDC(_new("AaveV3WarmAdapter_USDC.sol:AaveV3WarmAdapter_USDC",abi.encode(address(buffer),address(core),market.asset,market.aavePool,0x243Aa95cAC2a25651eda86e80bEe66114413c43b)));
        assertEq(warm.asset(),market.asset);assertEq(address(warm.aToken()),market.aToken);assertEq(warm.coreVault(),address(core));assertEq(warm.controller(),address(buffer));
        buffer.addWarmAdapter(address(warm));address[] memory ws=new address[](1);ws[0]=address(warm);core.approveWarmAdapters(ws,type(uint256).max);buffer.setKeeper(address(this));
        uint256 defaultMin=buffer.minRebalanceAmount();
        // Preserve the $5000 economic threshold via the existing config API.
        // Reusing 5000e6 raw units would mean a different amount for 8/18 decimals.
        buffer.setRebalanceParams(buffer.rebalanceCooldown(),_usd(5000),buffer.navRefreshInterval());
        emit ActualMatrixWarmConfig(market.asset,defaultMin,buffer.minRebalanceAmount(),5000e6);
        this.fundAndDepositWarmUsers();buffer.rebalance();buffer.refreshWarmNav();assertGt(warm.totalAssets(),0,"real nonempty warm sleeve");
        _poke();LiquidityOpsModule(address(core)).deployToStrategies(type(uint256).max);Scoring(address(strategy)).deployIdle();assertGt(adapter.totalAssets(),0);
        vm.makePersistent(keep);vm.makePersistent(market.asset);vm.makePersistent(market.aavePool);vm.makePersistent(market.aToken);_persistDebtTokens();
        vm.makePersistent(FUNDING);vm.makePersistent(WETH);for(uint256 i;i<pools.length;++i)vm.makePersistent(pools[i]);
        _roll(514200000);buffer.refreshWarmNav();_poke();Scoring(address(strategy)).deployIdle();
        // This ~$91k portfolio belongs to the two-adapter tier. With one
        // Lending venue, concentration limits legitimately retain idle cash.
        // Preserve that policy and reconcile it instead of forcing investment.
        Params(address(strategy)).syncPositionAssets();
        assertEq(Scoring(address(strategy)).effectiveMaxAdaptersPerAllocation(),2);
        assertApproxEqAbs(strategy.totalAssets(),strategy.idleCash()+adapter.totalAssets(),2,"warm scenario Lending NAV conservation");
        uint256 invested=adapter.totalAssets();uint256 warmBefore=warm.totalAssets();assertGt(invested,0);
        EpochedQueueModule q=EpochedQueueModule(address(core));uint256 shares=core.balanceOf(smallUser);assertGt(shares,0);assertLt(shares*10000/core.totalSupply(),1000);
        vm.prank(smallUser);(uint256 epoch,uint256 claim)=q.requestEpochWithdrawal(shares);uint256 owed=q.epochClaim(epoch,claim).assetsOwed;
        assertGt(owed,IERC20Metadata(market.asset).balanceOf(address(core)),"claim must use invested capital");uint256 requested=vm.getBlockTimestamp();
        _roll(517000000);assertGe(vm.getBlockTimestamp(),requested+7 days);buffer.refreshWarmNav();_poke();strategy.harvest();q.closeCurrentEpoch();q.fundEpoch(epoch);
        for(uint256 i;i<6&&q.epochDeficit(epoch)>0;++i){LiquidityOpsModule(address(core)).realizeForQueue(q.epochDeficit(epoch));q.fundEpoch(epoch);}
        assertEq(q.epochDeficit(epoch),0);uint256 before=IERC20Metadata(market.asset).balanceOf(smallUser);vm.prank(smallUser);q.claimEpochAssets(epoch,claim);
        uint256 received=IERC20Metadata(market.asset).balanceOf(smallUser)-before;assertEq(received,owed);assertEq(core.balanceOf(smallUser),0);assertLt(warm.totalAssets(),warmBefore,"actual warm capital recalled");
        uint256 coreBefore=IERC20Metadata(market.asset).balanceOf(address(core));uint256 recalled=router.withdrawAllToCore(address(strategy));
        assertEq(IERC20Metadata(market.asset).balanceOf(address(core))-coreBefore,recalled);assertLe(adapter.totalAssets(),2);assertLe(strategy.totalAssets(),2);
        emit ActualMatrixWarmExit(market.asset,rpcForkBlock,warmBefore,warm.totalAssets(),invested,owed,received,core.balanceOf(smallUser));
    }
    function fundAndDepositWarmUsers() external {
        require(msg.sender==address(this));IERC20Metadata input=IERC20Metadata(FUNDING);IERC20Metadata token=IERC20Metadata(market.asset);
        uint256 amountIn=95000e6;uint256 hb=input.balanceOf(HOLDER);uint256 before=input.balanceOf(address(this));uint256 supply=input.totalSupply();assertGe(hb,amountIn);
        vm.prank(HOLDER);input.safeTransfer(address(this),amountIn);assertEq(input.balanceOf(HOLDER),hb-amountIn);assertEq(input.balanceOf(address(this))-before,amountIn);assertEq(input.totalSupply(),supply);
        emit RealFunding(chain,FUNDING,HOLDER,hb,amountIn,input.balanceOf(HOLDER));
        if(market.asset!=FUNDING){
            bytes memory path;
            if(market.asset==0xaf88d065e77c8cC2239327C5EDb3A432268e5831){_pool(FUNDING,market.asset,100);path=abi.encodePacked(FUNDING,uint24(100),market.asset);}
            else if(market.asset==WETH){_pool(FUNDING,WETH,500);path=abi.encodePacked(FUNDING,uint24(500),WETH);}
            else {_pool(FUNDING,WETH,500);_pool(WETH,market.asset,500);path=abi.encodePacked(FUNDING,uint24(500),WETH,uint24(500),market.asset);}
            (,int256 answer,,uint256 updated,)=IMatrixWarmFeed(0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7).latestRoundData();assertGt(answer,0);assertLe(updated,vm.getBlockTimestamp());assertLe(vm.getBlockTimestamp()-updated,1 days);
            uint256 expected=Math.mulDiv(amountIn*uint256(answer)*1e4,10**market.decimals,oracle.getQuoteFresh(market.asset).price);
            uint256 old=token.balanceOf(address(this));uint256 targetSupply=token.totalSupply();input.forceApprove(UNISWAP,amountIn);
            uint256 got=ISwapRouterV3(UNISWAP).exactInput(ISwapRouterV3.ExactInputParams(path,address(this),amountIn,expected*9900/10000));input.forceApprove(UNISWAP,0);
            assertEq(token.balanceOf(address(this))-old,got);assertGe(got,expected*9900/10000);assertEq(token.totalSupply(),targetSupply);assertEq(input.totalSupply(),supply);
            emit RealFundingConversion(chain,FUNDING,market.asset,amountIn,expected,got);
        }
        uint256 seed=_usd(1);uint256 big=_usd(85000);uint256 small=_usd(6500);assertGe(token.balanceOf(address(this)),seed+big+small);
        token.forceApprove(address(core),seed);AdminModule(address(core)).seedDeadDeposit(seed);core.unpauseAll();core.freezeRouting();AdminModule(address(core)).freezeParams();
        token.safeTransfer(user,big);vm.startPrank(user);token.forceApprove(address(core),big);assertGt(core.deposit(big,user),0);vm.stopPrank();
        token.safeTransfer(smallUser,small);vm.startPrank(smallUser);token.forceApprove(address(core),small);assertGt(core.deposit(small,smallUser),0);vm.stopPrank();
    }
    function _pool(address a,address b,uint24 fee) internal {
        address pool=IMatrixWarmFactory(0x1F98431c8aD98523631AE4a59f267346ea31F984).getPool(a,b,fee);assertGt(pool.code.length,0,"real funding pool required");pools.push(pool);
    }
}
