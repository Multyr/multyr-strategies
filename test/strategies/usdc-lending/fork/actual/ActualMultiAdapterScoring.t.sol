// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {LendingEthereumAdditionalUnmockedE2EBase} from "./LendingEthereumAdditionalUnmockedE2E.t.sol";
import {ActualNativeGasGateReferenceBase} from "./ActualNativeGasGateReference.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";
import {AdminModule} from "@multyr-core/core/modules/AdminModule.sol";
import {LiquidityOpsModule} from "@multyr-core/core/modules/LiquidityOpsModule.sol";
import {EpochedQueueModule} from "@multyr-core/core/modules/EpochedQueueModule.sol";
import {AaveV3USDCAdapter} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol";
import {MorphoUsdcMultiMarketAdapter} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol";
import {EulerUsdcMultiMarketAdapter} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol";
import {CometUsdcMultiMarketAdapter} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol";
import {FluidUsdcMultiMarketAdapter} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/FluidUsdcMultiMarket.sol";
import {ISwapRouterV3} from "@multyr-strategies/strategies/usdc-lending/swap/RewardSwapHelper.sol";
import {ProtocolRegistry} from "@multyr-strategies/strategies/usdc-lending/registry/ProtocolRegistry.sol";
import {LendingAssetConfig} from "@multyr-strategies/strategies/usdc-lending/config/LendingAssetConfig.sol";
import {StrategySettingsModule as Settings} from "@multyr-strategies/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {StrategyParamsModule as Params} from "@multyr-strategies/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import {StrategyScoringModule as Scoring} from "@multyr-strategies/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import {StrategyRebalancePlanModule as Plan} from "@multyr-strategies/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol";
import {StrategyRebalanceGateModule as Gate} from "@multyr-strategies/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol";
interface IActualAllocationAdapter {function totalAssets() external view returns(uint256);function withdrawableAssets() external view returns(uint256);function currentAPYBps() external view returns(uint16);function externalMarketTVL() external view returns(uint256);}
interface IActualPortfolioNav {function totalAssets() external view returns(uint256);}
interface IActualFundingFeed {function latestRoundData() external view returns(uint80,int256,uint256,uint256,uint80);function decimals() external view returns(uint8);}
contract ActualMultiAdapterScoringTest is ActualNativeGasGateReferenceBase {
    using SafeERC20 for IERC20Metadata;
    MorphoUsdcMultiMarketAdapter morpho;
    EulerUsdcMultiMarketAdapter euler;
    address morphoMarket;
    address eulerMarket;
    CometUsdcMultiMarketAdapter comet;
    FluidUsdcMultiMarketAdapter fluid;
    address cometMarket;
    address fluidMarket;
    address[] venues;
    mapping(address=>uint256) referenceEma;
    mapping(address=>uint256) referenceApy;
    mapping(address=>uint256) referenceObservationTs;
    struct ObservedPlan {uint16[] apy;address[] adapters;uint256[] targets;uint256 tvl;uint256 moved;uint256[] scores;}
    event ActualScoringReference(address asset,uint256 rpcBlock,address adapter,uint16 apr,uint256 externalAssets,uint256 externalUsd6,uint256 confidence,uint256 liquidityBps,uint256 stability,uint256 independentRawScore,uint256 normalizedScore,uint256 targetAssets);
    event ActualIntegratedExit(address asset,uint256 rpcBlock,uint256 userReceived,uint256 coreReceived,uint256 investedVenues);
    event ActualPreservedNavDependency(address account);
    event ActualRiskRebalance(address asset,uint256 rpcBlock,uint256 moved,uint256 beforeInvested,uint256 afterInvested,uint256 steps);
    event ActualYieldEconomics(address asset,uint256 rpcBlock,uint256 moved,uint256 grossBenefit,uint256 cost,int256 netBenefitBps,bool accepted,uint256 executedSteps);
    event ActualNegativeYieldGate(address asset,uint256 rpcBlock,uint256 grossBenefit,uint256 conservativeCost,uint256 moved,bool accepted);
    event ActualWrapperGas(bytes32 phase,address asset,uint256 forkBlock,address target,bytes4 selector,uint256 calldataBytes,uint256 gasDelta);
    function _observedWrapper(bytes32 phase,bytes memory data) internal {
        bytes4 sel; assembly ("memory-safe") { sel := mload(add(data, 0x20)) }
        uint256 g0=gasleft();
        (bool ok,bytes memory ret)=address(strategy).call(data);
        uint256 gasDelta=g0-gasleft();
        if(!ok){assembly ("memory-safe"){revert(add(ret,0x20),mload(ret))}}
        emit ActualWrapperGas(phase,market.asset,rpcForkBlock,address(strategy),sel,data.length,gasDelta);
    }
    function test_multiAdapterUsdtProductionScoringAndExit() public {_multi(0);}
    function test_multiAdapterPyusdProductionScoringAndExit() public {_multi(1);}
    function test_multiAdapterWethProductionScoringAndExit() public {_multi(2);}
    function _register(address a) internal {
        Settings(address(strategy)).whitelistAdapter(a,true);strategy.addAdapter(a);strategy.toggleAdapter(a,true);venues.push(a);
        referenceEma[a]=7000;
    }
    function _multi(uint8 profile) internal {
        bool pyusd=profile==1;bool weth=profile==2;
        chain=1;user=vm.addr(0xB0B);initialBlock=26150000;setupBlock=26165000;
        vm.createSelectFork(_rpc(),initialBlock);rpcForkBlock=initialBlock;
        market=LendingAssetConfig.Market(1,pyusd?0x6c3ea9036406852006290770BEdFcAbA0e23A0e8:0xdAC17F958D2ee523a2206206994597C13D831ec7,6,0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2,pyusd?0x0C0d01AbF3e6aDfcA0989eBbA9d6e85dD58EaB1E:0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a);
        if(weth){market.asset=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;market.decimals=18;market.aToken=0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;}
        _configureProductionCore();strategy=_candidate();uint256 eta=router.proposeStrategyAllowlist(address(strategy));
        vm.makePersistent(keep);_roll(setupBlock);assertGe(vm.getBlockTimestamp(),eta);buffer.refreshWarmNav();
        router.executeStrategyAllowlist(address(strategy));router.register(address(strategy),0,10000);router.setMaxStrategyBps(address(strategy),10000);router.setLossCapPerStrategy(address(strategy),50);
        adapter=AaveV3USDCAdapter(payable(_new("AaveV3USDCmarket.sol:AaveV3USDCAdapter",bytes(""))));
        adapter.initialize(market.asset,market.aavePool,market.aToken,address(this),address(strategy),10_000_000*10**market.decimals);_register(address(adapter));
        morphoMarket=pyusd?address(bytes20(hex"b576765fb15505433af24fee2c0325895c559fb2")):address(bytes20(hex"beef047a543e45807105e51a8bbefcc5950fcfba"));
        if(weth)morphoMarket=0xBEEf050ecd6a16c4e7bfFbB52Ebba7846C4b8cD4;
        ProtocolRegistry r=ProtocolRegistry(_new("ProtocolRegistry.sol:ProtocolRegistry",abi.encode(address(this))));
        r.addVault(ProtocolRegistry.ProtocolType.MORPHO,morphoMarket,"actual observed vault",1000,type(uint128).max);
        morpho=MorphoUsdcMultiMarketAdapter(payable(_new("MorphoUsdcMultiMarket.sol:MorphoUsdcMultiMarketAdapter",bytes(""))));
        morpho.initialize(market.asset,address(this),address(strategy),10_000_000*10**market.decimals,address(r));
        if(pyusd)morpho.setVaultV2LiquidityView(_new("MorphoVaultV2LiquidityView.sol:MorphoVaultV2LiquidityView",bytes("")));
        _register(address(morpho));morpho.pokeAPYSnapshots();
        // Only local deployments persist: no market balance/position has yet changed.
        vm.makePersistent(keep);_roll(setupBlock+400);buffer.refreshWarmNav();morpho.pokeAPYSnapshots();
        if(!pyusd&&!weth){
            eulerMarket=0x313603FA690301b0CaeEf8069c065862f9162162;
            address[] memory ms=new address[](1);ms[0]=eulerMarket;
            euler=EulerUsdcMultiMarketAdapter(payable(_new("EulerUsdcMultiMarket.sol:EulerUsdcMultiMarketAdapter",bytes(""))));
            euler.initialize(address(strategy),market.asset,ms,address(0),address(this));euler.initializeMarkets();_register(address(euler));
        }
        if(weth)this.configureWethVenues(r);
        this.fundAndDeposit(pyusd);_fresh();LiquidityOpsModule(address(core)).deployToStrategies(type(uint256).max);_observedWrapper("deployIdle.initial",abi.encodeCall(Scoring.deployIdle,()));
        _persistAll();_maintainTo(setupBlock+8000);_observedWrapper("deployIdle.fresh",abi.encodeCall(Scoring.deployIdle,()));_fresh();this.checkActualReference();
        uint256 investedCount;for(uint256 i;i<venues.length;++i)if(IActualAllocationAdapter(venues[i]).totalAssets()>1)++investedCount;
        assertGe(investedCount,2,"actual capital must enter multiple genuine protocols");
        if(this.exerciseActualYieldEconomics())_maintainTo(setupBlock+16000);
        this.exerciseActualRiskRebalance();
        uint256 shares=core.balanceOf(user);vm.prank(user);
        (uint256 epoch,uint256 claim)=EpochedQueueModule(address(core)).requestEpochWithdrawal(shares*950/10000);
        _maintainTo(initialBlock+100000);_fresh();this.checkActualReference();
        EpochedQueueModule queue=EpochedQueueModule(address(core));uint256 owed=queue.epochClaim(epoch,claim).assetsOwed;
        queue.closeCurrentEpoch();queue.fundEpoch(epoch);for(uint256 k;k<4&&queue.epochDeficit(epoch)>0;++k){LiquidityOpsModule(address(core)).realizeForQueue(queue.epochDeficit(epoch));queue.fundEpoch(epoch);}
        assertEq(queue.epochDeficit(epoch),0);uint256 before=IERC20Metadata(market.asset).balanceOf(user);vm.prank(user);queue.claimEpochAssets(epoch,claim);
        assertEq(IERC20Metadata(market.asset).balanceOf(user)-before,owed);
        uint256 beforeCore=IERC20Metadata(market.asset).balanceOf(address(core));uint256 recovered=router.withdrawAllToCore(address(strategy));assertGt(recovered,0);
        assertEq(IERC20Metadata(market.asset).balanceOf(address(core))-beforeCore,recovered);assertLe(strategy.totalAssets(),2);
        for(uint256 i;i<venues.length;++i)assertLe(IActualAllocationAdapter(venues[i]).totalAssets(),2,"every actual venue recalled");
        emit ActualIntegratedExit(market.asset,rpcForkBlock,owed,recovered,investedCount);
    }
    function configureWethVenues(ProtocolRegistry r) external {
        require(msg.sender==address(this));
        cometMarket=0xA17581A9E3356d9A858b789D68B4d866e593aE94;
        r.addVault(ProtocolRegistry.ProtocolType.COMPOUND_V3,cometMarket,"official WETH Comet",1000,type(uint128).max);
        comet=CometUsdcMultiMarketAdapter(payable(_new("CometUsdcMultiMarket.sol:CometUsdcMultiMarketAdapter",bytes(""))));
        comet.initialize(market.asset,address(this),address(strategy),10_000_000e18,address(r));_register(address(comet));
        fluidMarket=0x90551c1795392094FE6D29B758EcCD233cFAa260;
        fluid=FluidUsdcMultiMarketAdapter(payable(_new("FluidUsdcMultiMarket.sol:FluidUsdcMultiMarketAdapter",bytes(""))));
        fluid.initialize(market.asset,address(this),address(strategy),10_000_000e18,fluidMarket);_register(address(fluid));
    }
    /// Governance tightens concentration from the initial deployment policy to
    /// 25%. Actual positions/rates/quotes remain untouched; the production
    /// protection mandate must withdraw excess capital even without APY uplift.
    function exerciseActualRiskRebalance() external {
        require(msg.sender==address(this));
        uint256 beforeInvested;for(uint256 i;i<venues.length;++i)beforeInvested+=IActualAllocationAdapter(venues[i]).totalAssets();
        Settings(address(strategy)).setRebalanceParams(5,1,strategy.rebalanceMinMoveBps(),strategy.minSecondsBetweenRebalances(),strategy.driftToleranceBps(),2500,5000);
        Settings(address(strategy)).setCapDriftTolerance(500);
        (bool allowed,uint256 moved,int256 benefit)=Gate(address(strategy)).canRebalance();
        assertTrue(allowed,"actual over-cap protection must pass gate");assertGt(moved,0);assertEq(benefit,0,"protection mandate is not yield profitability");
        _observedWrapper("prepareRebalance",abi.encodeCall(Plan.prepareRebalance,()));assertEq(strategy.rebalancePlanPhase(),1);assertGt(strategy.rebalancePlanTotalActions(),0);
        uint256 steps;while(strategy.rebalancePlanPhase()!=0&&steps<10){_observedWrapper("executeRebalanceStep",abi.encodeCall(Plan.executeRebalanceStep,()));++steps;}
        assertEq(strategy.rebalancePlanPhase(),0,"actual plan must finish");assertEq(strategy.rebalancePlanConsecutiveFailures(),0);
        _fresh();uint256 afterInvested;uint256 ceiling=strategy.totalAssets()*2500/10000;
        for(uint256 i;i<venues.length;++i){uint256 position=IActualAllocationAdapter(venues[i]).totalAssets();afterInvested+=position;assertLe(position,ceiling+2,"actual post-rebalance hard exposure cap");}
        assertLt(afterInvested,beforeInvested,"real protocol receipts must be redeemed");
        emit ActualRiskRebalance(market.asset,rpcForkBlock,moved,beforeInvested,afterInvested,steps);
    }
    function exerciseActualYieldEconomics() external returns(bool executed) {
        require(msg.sender==address(this));_assertActualNativeGateBranch();ObservedPlan memory p;
        (p.apy,p.adapters,p.targets,p.tvl,p.moved,p.scores)=Scoring(address(strategy)).computeRebalanceInputs();
        assertEq(strategy.rebalanceGasEstimator(),address(0));assertEq(strategy.overCapRiskPremiumBps(),0);assertEq(strategy.capDriftToleranceBps(),0);
        assertEq(strategy.regimeHorizonDays(),0);assertEq(strategy.regimeConfidenceMultBps(),0);assertEq(strategy.recentRebalancePenaltyBps(),0);
        assertEq(strategy.entryDriftBps(),0);assertEq(strategy.minMoveUsd(),0);assertEq(strategy.minBenefitCostRatioBps(),0);
        uint256 currentWeighted;uint256 targetWeighted;uint256 currentSum;uint256 targetSum;
        for(uint256 i;i<p.adapters.length;++i){uint256 current=IActualAllocationAdapter(p.adapters[i]).totalAssets();currentWeighted+=current*p.apy[i];currentSum+=current;targetWeighted+=p.targets[i]*p.apy[i];targetSum+=p.targets[i];}
        if(currentSum>0)currentWeighted/=currentSum;if(targetSum>0)targetWeighted/=targetSum;
        uint256 gross=targetWeighted>currentWeighted?p.moved*(targetWeighted-currentWeighted)*7/(10000*365):0;
        uint256 cost=Math.mulDiv(1e6,(10**market.decimals)*1e12,oracle.getQuoteFresh(market.asset).price,Math.Rounding.Up);
        assertEq(strategy.slippageBpsEstimate(),0);assertEq(strategy.withdrawalSpreadBpsEstimate(),0);
        this.assertRejectsSmallActualNetLoss(gross,p.moved);
        (bool accepted,uint256 moved,int256 bps)=Gate(address(strategy)).canRebalance();assertEq(moved,p.moved);
        int256 net=int256(gross)-int256(cost);int256 referenceBps=p.moved==0?int256(0):net*10000/int256(p.moved);
        // Negative amounts must not become an accepted zero-bps benefit through
        // signed division rounding toward zero. Rates/quotes remain actual.
        assertEq(accepted,p.moved>0&&net>=0&&referenceBps>=int256(uint256(strategy.gateMinNetBenefitBps())),"independent actual economic gate");
        if(accepted){assertEq(bps,referenceBps);_observedWrapper("prepareRebalance",abi.encodeCall(Plan.prepareRebalance,()));uint256 steps;while(strategy.rebalancePlanPhase()!=0&&steps<10){_observedWrapper("executeRebalanceStep",abi.encodeCall(Plan.executeRebalanceStep,()));++steps;}
            assertEq(strategy.rebalancePlanPhase(),0);assertEq(strategy.rebalancePlanConsecutiveFailures(),0);assertGt(steps,0);executed=true;
            emit ActualYieldEconomics(market.asset,rpcForkBlock,moved,gross,cost,bps,true,steps);
        }else emit ActualYieldEconomics(market.asset,rpcForkBlock,moved,gross,cost,bps,false,0);
    }
    function assertRejectsSmallActualNetLoss(uint256 gross,uint256 moved) external {
        require(msg.sender==address(this));uint256 price=oracle.getQuoteFresh(market.asset).price;uint256 denominator=(10**market.decimals)*1e12;
        // Tighten only the cost assumption: positive observed gross yield plus
        // one cent. The actual assets, market rates and USD quote stay intact.
        uint256 costUsd=Math.mulDiv(gross,price,denominator)+10000;
        uint256 cost=Math.mulDiv(costUsd,denominator,price,Math.Rounding.Up);assertGt(cost,gross);assertLt((cost-gross)*10000,moved,"loss below one basis point");
        Settings(address(strategy)).setGateParams(7,0,0,0,costUsd);(bool accepted,,)=Gate(address(strategy)).canRebalance();
        emit ActualNegativeYieldGate(market.asset,rpcForkBlock,gross,cost,moved,accepted);
        assertFalse(accepted,"negative net benefit must not round into accepted zero bps");
        Settings(address(strategy)).setGateParams(7,0,0,0,1e6);
    }
    function fundAndDeposit(bool pyusd) external {
        require(msg.sender==address(this));IERC20Metadata token=IERC20Metadata(market.asset);
        address holder=pyusd?0xAFBb1a7E9ddEf38D9bC4A220E702B18DAcaa2a62:HOLDER;
        if(market.decimals==18)this.fundWethWithRealSwap();
        else {
            uint256 funding=1_000_000e6;uint256 bh=token.balanceOf(holder);uint256 bs=token.balanceOf(address(this));uint256 supply=token.totalSupply();assertGe(bh,funding);
            vm.prank(holder);token.safeTransfer(address(this),funding);assertEq(token.balanceOf(holder),bh-funding);assertEq(token.balanceOf(address(this))-bs,funding);assertEq(token.totalSupply(),supply);
            emit RealFunding(1,market.asset,holder,bh,funding,token.balanceOf(holder));
        }
        uint256 unit=10**market.decimals;uint256 price=oracle.getQuoteFresh(market.asset).price;uint256 seed=Math.mulDiv(1e18,unit,price,Math.Rounding.Up);
        uint256 amount=Math.mulDiv(200_000e18,unit,price,Math.Rounding.Up);
        token.forceApprove(address(core),seed);AdminModule(address(core)).seedDeadDeposit(seed);core.unpauseAll();core.freezeRouting();AdminModule(address(core)).freezeParams();
        token.safeTransfer(user,amount);vm.startPrank(user);token.forceApprove(address(core),amount);assertGt(core.deposit(amount,user),0);vm.stopPrank();
    }
    function fundWethWithRealSwap() external {
        require(msg.sender==address(this));IERC20Metadata input=IERC20Metadata(0xdAC17F958D2ee523a2206206994597C13D831ec7);uint256 funding=300_000e6;
        uint256 beforeHolder=input.balanceOf(HOLDER);uint256 beforeInput=input.balanceOf(address(this));uint256 inputSupply=input.totalSupply();assertGe(beforeHolder,funding);
        vm.prank(HOLDER);input.safeTransfer(address(this),funding);assertEq(input.balanceOf(HOLDER),beforeHolder-funding);assertEq(input.balanceOf(address(this))-beforeInput,funding);assertEq(input.totalSupply(),inputSupply);
        emit RealFunding(1,address(input),HOLDER,beforeHolder,funding,input.balanceOf(HOLDER));
        IActualFundingFeed feed=IActualFundingFeed(0x3E7d1eAB13ad0104d2750B8863b489D65364e32D);
        (uint80 round,int256 answer,,uint256 updated,uint80 answered)=feed.latestRoundData();assertEq(feed.decimals(),8);assertGt(answer,0);assertGe(answered,round);assertLe(vm.getBlockTimestamp()-updated,1 days);
        uint256 expected=Math.mulDiv(funding,uint256(answer)*1e22,oracle.getQuoteFresh(market.asset).price);
        address swap=0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
        IERC20Metadata output=IERC20Metadata(market.asset);uint256 before=output.balanceOf(address(this));uint256 supply=output.totalSupply();input.forceApprove(swap,funding);
        uint256 received=ISwapRouterV3(swap).exactInput(ISwapRouterV3.ExactInputParams(abi.encodePacked(address(input),uint24(500),market.asset),address(this),funding,expected*9900/10000));
        input.forceApprove(swap,0);assertEq(output.balanceOf(address(this))-before,received);assertGe(received,expected*9900/10000);assertEq(output.totalSupply(),supply);
        emit RealFundingConversion(1,address(input),market.asset,funding,expected,received);
    }
    function _persistAll() internal {
        vm.makePersistent(keep);vm.makePersistent(market.asset);vm.makePersistent(market.aavePool);vm.makePersistent(market.aToken);_persistDebtTokens();
        vm.makePersistent(morphoMarket);vm.makePersistent(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);vm.makePersistent(0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC);
        if(morphoMarket==address(bytes20(hex"b576765fb15505433af24fee2c0325895c559fb2")))this.preserveActualV2NavDependencies();
        if(eulerMarket!=address(0)){vm.makePersistent(eulerMarket);vm.makePersistent(0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383);vm.makePersistent(0x000000000022D473030F116dDEE9F6B43aC78BA3);}
        if(cometMarket!=address(0))vm.makePersistent(cometMarket);
        if(fluidMarket!=address(0)){vm.makePersistent(fluidMarket);this.preserveNavDependencies(fluidMarket);}
    }
    function preserveActualV2NavDependencies() external {
        require(msg.sender==address(this));
        this.preserveNavDependencies(morphoMarket);
    }
    function preserveNavDependencies(address valueMarket) external {
        require(msg.sender==address(this));
        // Preserve the actual portfolio holdings used by V2 NAV, not just its
        // shares while letting underlying canonical user flows reset holdings.
        // This records real calls; no code, balance, price or storage is forged.
        vm.startStateDiffRecording();IActualPortfolioNav(valueMarket).totalAssets();
        Vm.AccountAccess[] memory accessed=vm.stopAndReturnStateDiff();require(accessed.length>0&&accessed.length<=512,"bounded actual NAV call graph");
        for(uint256 i;i<accessed.length;++i){address account=accessed[i].account;
            if(account.code.length==0)continue;
            // The production USD feeds advance canonically on every fork roll.
            require(account!=0x8f1dF6D7F2db73eECE86a18b4381F4707b918FB1&&account!=0x3E7d1eAB13ad0104d2750B8863b489D65364e32D,"USD feed must not be frozen");
            vm.makePersistent(account);emit ActualPreservedNavDependency(account);
        }
    }
    function _fresh() internal virtual {
        morpho.pokeAPYSnapshots();if(address(fluid)!=address(0))fluid.pokeAPYSnapshots();Params(address(strategy)).syncPositionAssets();Params(address(strategy)).pokeExternalTVL();
        for(uint256 i;i<venues.length;++i)_observeReferenceStability(venues[i]);
        Params(address(strategy)).pokeLiquidityBatch(0,venues.length);
        for(uint256 i;i<venues.length;++i){assertEq(strategy.stabilityEMA(venues[i]),referenceEma[venues[i]],"independent real-rate stability EMA");assertEq(strategy.lastStabilityUpdateTs(venues[i]),referenceObservationTs[venues[i]]);}
    }
    function _observeReferenceStability(address venue) internal {
        if(IActualAllocationAdapter(venue).totalAssets()<=1)return;
        uint256 last=referenceObservationTs[venue];uint256 nowTs=vm.getBlockTimestamp();if(last!=0&&nowTs<last+6 hours)return;
        uint256 current=IActualAllocationAdapter(venue).currentAPYBps();
        if(last!=0){uint256 previous=referenceApy[venue];uint256 denominator=previous>50?previous:50;uint256 change=(current>previous?current-previous:previous-current)*10000/denominator;if(change>10000)change=10000;
            referenceEma[venue]=(2500*(10000-change)+7500*referenceEma[venue])/10000;}
        referenceApy[venue]=current;referenceObservationTs[venue]=nowTs;
    }
    function _maintainTo(uint256 target) internal {
        while(rpcForkBlock<target){uint256 next=rpcForkBlock+4000;if(next>target)next=target;_roll(next);buffer.refreshWarmNav();_fresh();}
    }
    function _confidence(uint256 usd6) internal pure returns(uint256){return usd6<100_000e6?0:usd6<500_000e6?3000:usd6<2_000_000e6?5000:usd6<10_000_000e6?7000:usd6<50_000_000e6?8500:usd6<250_000_000e6?9500:10000;}
    function _relative(uint256 usd6) internal pure returns(uint256){return usd6<100_000e6?0:usd6<500_000e6?200:usd6<1_000_000e6?500:usd6<2_000_000e6?800:usd6<3_000_000e6?1000:usd6<10_000_000e6?1200:usd6<25_000_000e6?1500:usd6<50_000_000e6?1800:usd6<250_000_000e6?2000:2500;}
    function checkActualReference() external {
        require(msg.sender==address(this));ObservedPlan memory p;
        (p.apy,p.adapters,p.targets,p.tvl,p.moved,p.scores)=Scoring(address(strategy)).computeRebalanceInputs();
        uint256[] memory raw=new uint256[](p.adapters.length);uint256 maxRate;
        for(uint256 i;i<p.adapters.length;++i)if(p.apy[i]>maxRate)maxRate=p.apy[i];
        uint256 sum;for(uint256 i;i<p.adapters.length;++i){raw[i]=this.rawScoreReference(p.adapters[i],p.apy[i],maxRate);sum+=raw[i];}
        uint256[] memory normalized=new uint256[](raw.length);bool[] memory selected=new bool[](raw.length);uint256 selectedSum;
        for(uint256 i;i<raw.length;++i){normalized[i]=raw[i]*10000/sum;assertEq(p.scores[i],normalized[i],"independent composite-score normalization");}
        uint256 usdNav=Math.mulDiv(p.tvl,oracle.getQuoteFresh(market.asset).price,(10**market.decimals)*1e12);
        uint256 seedReference=Math.mulDiv(100e6,(10**market.decimals)*1e12,oracle.getQuoteFresh(market.asset).price,Math.Rounding.Up);
        assertEq(Params(address(strategy)).usd6ToAssetUnits(100e6),seedReference,"independent actual-price inverse conversion rounds up");
        assertEq(Scoring(address(strategy)).effectiveMinNewAdapterSeed(),seedReference,"independent USD seed tier for actual 200k portfolio");
        uint256 n=usdNav<25_000e6?1:usdNav<250_000e6?2:usdNav<1_000_000e6?3:usdNav<5_000_000e6?4:5;
        if(strategy.maxAdaptersPerAllocation()>0&&strategy.maxAdaptersPerAllocation()<n)n=strategy.maxAdaptersPerAllocation();
        assertEq(Scoring(address(strategy)).effectiveMaxAdaptersPerAllocation(),n,"independent USD portfolio tier");
        for(uint256 k;k<n&&k<raw.length;++k){uint256 best=raw.length;for(uint256 i;i<raw.length;++i)if(!selected[i]&&(best==raw.length||normalized[i]>normalized[best]))best=i;selected[best]=true;selectedSum+=normalized[best];}
        for(uint256 i;i<raw.length;++i){uint256 target=selected[i]?normalized[i]*(p.tvl*(10000-strategy.targetIdleBufferBps())/10000)/selectedSum:0;
            uint256 cap=(11000+n-1)/n;if(cap>10000)cap=10000;if(cap<2500)cap=2500;
            if(strategy.adapterMaxExposureBps()>0&&strategy.adapterMaxExposureBps()<cap)cap=strategy.adapterMaxExposureBps();
            assertEq(Scoring(address(strategy)).effectiveAbsCapBps(p.adapters[i]),cap,"independent healthy structural/governance cap");
            uint256 ceiling=cap*p.tvl/10000;if(target>ceiling)target=ceiling*(10000-strategy.targetSafetyMarginBps())/10000;
            uint256 externalAssets=IActualAllocationAdapter(p.adapters[i]).externalMarketTVL();uint256 extUsd=Math.mulDiv(externalAssets,oracle.getQuoteFresh(market.asset).price,(10**market.decimals)*1e12);
            uint256 relative=_relative(extUsd);if(strategy.maxRelativeExposureBps()>0&&strategy.maxRelativeExposureBps()<relative)relative=strategy.maxRelativeExposureBps();
            ceiling=relative*externalAssets/10000;if(target>ceiling)target=ceiling*(10000-strategy.targetSafetyMarginBps())/10000;
            assertEq(p.targets[i],target,"independent actual target allocation and USD-relative cap");
            emit ActualScoringReference(market.asset,rpcForkBlock,p.adapters[i],p.apy[i],externalAssets,extUsd,_confidence(extUsd),strategy.cachedLiquidityBps(p.adapters[i]),strategy.stabilityEMA(p.adapters[i]),raw[i],normalized[i],target);
        }
    }
    function rawScoreReference(address a,uint16 rate,uint256 maxRate) external view returns(uint256) {
        IActualAllocationAdapter v=IActualAllocationAdapter(a);assertEq(rate,v.currentAPYBps());
        uint256 actual=v.totalAssets();uint256 liq=actual<=1?10000:v.withdrawableAssets()*10000/actual;if(liq>10000)liq=10000;if(liq<1)liq=1;
        assertEq(strategy.cachedLiquidityBps(a),liq,"independent actual liquidity ratio");assertEq(strategy.cachedExternalTVL(a),v.externalMarketTVL());
        uint256 externalUsd=Math.mulDiv(v.externalMarketTVL(),oracle.getQuoteFresh(market.asset).price,(10**market.decimals)*1e12);
        assertEq(Params(address(strategy)).assetUnitsToUsd6(v.externalMarketTVL()),externalUsd,"independent real-price USD conversion");
        assertEq(strategy.riskScoreBps(a),0);uint256 risk=7000*_confidence(externalUsd)/10000;
        uint256 stability=referenceEma[a];assertEq(strategy.stabilityEMA(a),stability);
        return 5000*(uint256(rate)*10000/maxRate)+2000*liq+2000*risk+1000*stability;
    }
}
