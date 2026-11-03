// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {LendingEthereumAdditionalUnmockedE2EBase} from "./LendingEthereumAdditionalUnmockedE2E.t.sol";
import {ActualSafeBatchReference,IActualSafe} from "./ActualSafeBatch.sol";
import {Vm} from "forge-std/Vm.sol";
import {CoreVault} from "@multyr-core/core/CoreVault.sol";
import {StrategyRouter} from "@multyr-core/core/modules/StrategyRouter.sol";
import {LiquidityOpsModule} from "@multyr-core/core/modules/LiquidityOpsModule.sol";
import {BufferManager} from "@multyr-core/core/modules/BufferManager.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {LendingAssetConfig} from "@multyr-strategies/strategies/usdc-lending/config/LendingAssetConfig.sol";
import {UsdcMultiLendingVault as Strategy} from "@multyr-strategies/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
import {StrategySettingsModule as Settings} from "@multyr-strategies/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {StrategyParamsModule as Params} from "@multyr-strategies/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import {AaveV3USDCAdapter} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol";
import {StrategyUpkeep} from "@multyr-strategies/strategies/usdc-lending/automation/LendingStrategyUpkeep.sol";
import {StrategyMigrationGuard} from "@multyr-strategies/strategies/usdc-lending/gas/StrategyMigrationGuard.sol";

/// @notice Reference cutover/rollback against actual frozen Core and its real book.
/// This exercises router/accounting compatibility, not an approved deployment
/// manifest or native ArbOS calibration. New candidate uses the disclosed base
/// fixture policy; no actual Core policy, runtime or role map is changed.
contract ActualFrozenCoreCutoverTest is LendingEthereumAdditionalUnmockedE2EBase, ActualSafeBatchReference {
    address constant CORE=0x5e0cdb76487BD96Ff069Ef7F78eaDF5b5909C8cb;
    address constant ROUTER=0x37847D2e12892e3298DEE695e7E971fba0Ca3e24;
    address constant OLD=0x2AD722B6241605481829E4B251AE8A4Ba8Be86cE;
    address constant OLD_UPKEEP=0xAB30b7D1ADe850b6b122bcfF29F389CF1D051D44;
    event ActualFrozenCutover(uint256 rpcBlock,address oldStrategy,address candidate,uint256 oldNav,uint256 recalled,uint256 candidateInvested,uint256 candidateRecalled,uint256 finalCoreCash);

    function test_actualFrozenCoreCutoverAndRollbackWithRealCapital() public {
        chain=42161;rpcForkBlock=520384312;
        vm.createSelectFork("https://arbitrum-one.public.blastapi.io",rpcForkBlock);
        market=LendingAssetConfig.Market(42161,0xaf88d065e77c8cC2239327C5EDb3A432268e5831,6,0x794a61358D6845594F94dc1DB02A252b5b4814aD,0x724dc807b04555b71ed48a6896b6F41593b8C637);
        core=CoreVault(payable(CORE));router=StrategyRouter(ROUTER);
        bytes32 coreHash=CORE.codehash;bytes32 routerHash=ROUTER.codehash;bytes32 tokenHash=market.asset.codehash;
        address gov=router.owner();assertEq(gov,0x70ef444799D6FBbE0865bA598Bee6795e064a326);
        assertTrue(router.isStrategyEnabled(OLD));assertEq(StrategyUpkeep(OLD_UPKEEP).owner(),gov);assertTrue(StrategyUpkeep(OLD_UPKEEP).enabled(OLD));
        strategy=_candidate();
        assertGt(Params(address(strategy)).assetUnitsToUsd6(1e6),0,"actual frozen Core oracle path");
        adapter=AaveV3USDCAdapter(payable(_new("AaveV3USDCmarket.sol:AaveV3USDCAdapter",bytes(""))));
        adapter.initialize(market.asset,market.aavePool,market.aToken,address(this),address(strategy),10000000e6);
        Settings(address(strategy)).whitelistAdapter(address(adapter),true);strategy.addAdapter(address(adapter));strategy.toggleAdapter(address(adapter),true);
        Params(address(strategy)).pokeExternalTVL();Params(address(strategy)).pokeLiquidityBatch(0,1);
        address[] memory managed=new address[](1);managed[0]=address(strategy);
        StrategyUpkeep upkeep=StrategyUpkeep(_new("LendingStrategyUpkeep.sol:StrategyUpkeep",abi.encode(managed)));
        strategy.grantRole(keccak256("KEEPER_ROLE"),address(upkeep));upkeep.transferOwnership(gov);
        strategy.grantRole(bytes32(0),gov);strategy.grantRole(keccak256("PARAM_ROLE"),gov);strategy.grantRole(keccak256("KEEPER_ROLE"),gov);
        strategy.renounceRole(keccak256("KEEPER_ROLE"),address(this));strategy.renounceRole(keccak256("PARAM_ROLE"),address(this));strategy.renounceRole(bytes32(0),address(this));
        adapter.grantRole(bytes32(0),gov);adapter.grantRole(keccak256("PARAM_ROLE"),gov);
        adapter.renounceRole(keccak256("PARAM_ROLE"),address(this));adapter.renounceRole(bytes32(0),address(this));
        StrategyMigrationGuard guard=StrategyMigrationGuard(_new("StrategyMigrationGuard.sol:StrategyMigrationGuard",bytes("")));
        address[] memory proposalTargets=new address[](1);proposalTargets[0]=ROUTER;
        bytes[] memory proposalCalls=new bytes[](1);proposalCalls[0]=abi.encodeWithSignature("proposeStrategyAllowlist(address)",address(strategy));
        _executeActualSafeBatch(gov,proposalTargets,proposalCalls);
        uint256 eta=vm.getBlockTimestamp()+router.strategyAllowlistDelay();
        assertEq(router.strategyAllowlistDelay(),300,"preserve actual shadow delay");
        vm.makePersistent(keep);vm.makePersistent(ROUTER);vm.makePersistent(gov);
        _roll(520388312);assertGe(vm.getBlockTimestamp(),eta);
        Strategy old=Strategy(payable(OLD));IERC20Metadata token=IERC20Metadata(market.asset);
        uint256 oldNav=old.totalAssets();assertGt(oldNav,0);uint256 coreCash=token.balanceOf(CORE);
        guard.assertNoPlan(OLD);
        address[] memory pair=new address[](2);pair[0]=OLD;pair[1]=address(strategy);
        uint16[] memory weights=new uint16[](2);weights[1]=10000;
        uint256 n=old.adapterCount();address[] memory targets=new address[](n+13);bytes[] memory calls=new bytes[](n+13);uint256 k;
        targets[k]=OLD_UPKEEP;calls[k++]=abi.encodeWithSignature("toggleStrategy(address,bool)",OLD,false);
        targets[k]=address(guard);calls[k++]=abi.encodeWithSignature("assertNoPlan(address)",OLD);
        targets[k]=OLD;calls[k++]=abi.encodeWithSignature("setDepositsDisabled(bool)",true);
        for(uint256 i;i<n;++i){targets[k]=OLD;calls[k++]=abi.encodeWithSignature("callAdapterEmergencyPull(address)",old.adapters(i));}
        targets[k]=ROUTER;calls[k++]=abi.encodeWithSignature("withdrawAllToCore(address)",OLD);
        targets[k]=address(guard);calls[k++]=abi.encodeWithSignature("assertDrained(address,uint256)",OLD,100);
        targets[k]=ROUTER;calls[k++]=abi.encodeWithSignature("executeStrategyAllowlist(address)",address(strategy));
        targets[k]=ROUTER;calls[k++]=abi.encodeWithSignature("register(address,uint16,uint16)",address(strategy),uint16(100),uint16(10000));
        targets[k]=ROUTER;calls[k++]=abi.encodeWithSignature("setMaxStrategyBps(address,uint16)",address(strategy),uint16(10000));
        targets[k]=ROUTER;calls[k++]=abi.encodeWithSignature("setWeights(address[],uint16[])",pair,weights);
        targets[k]=ROUTER;calls[k++]=abi.encodeWithSignature("toggle(address,bool)",OLD,false);
        targets[k]=address(core.bufferManager());calls[k++]=abi.encodeWithSignature("refreshWarmNav()");
        targets[k]=CORE;calls[k++]=abi.encodeWithSignature("deployToStrategies(uint256)",type(uint256).max);
        // Actual Core routes cash; the actual keeper wrapper deploys it to Aave.
        targets[k]=address(upkeep);calls[k++]=abi.encodeWithSignature("performUpkeep(bytes)",abi.encode(uint8(4),uint256(0)));assertEq(k,n+13);
        // A failing final production guard must revert the entire actual Safe batch,
        // including old recalls, routing changes and every underlying transfer.
        address[] memory badTargets=new address[](k+1);bytes[] memory badCalls=new bytes[](k+1);
        for(uint256 i;i<k;++i){badTargets[i]=targets[i];badCalls[i]=calls[i];}
        badTargets[k]=address(guard);badCalls[k]=abi.encodeWithSignature("assertDrained(address,uint256)",address(strategy),100);
        uint256 nonceBeforeFailure=IActualSafe(gov).nonce();vm.expectRevert("GS013");this.executeReferenceSafeBatch(gov,badTargets,badCalls);
        assertEq(IActualSafe(gov).nonce(),nonceBeforeFailure);assertEq(token.balanceOf(CORE),coreCash);assertEq(old.totalAssets(),oldNav);
        assertEq(strategy.totalAssets(),0);assertTrue(router.isStrategyEnabled(OLD));assertFalse(router.isStrategyEnabled(address(strategy)));
        assertTrue(StrategyUpkeep(OLD_UPKEEP).enabled(OLD));assertFalse(old.depositsDisabled());
        vm.recordLogs();_executeActualSafeBatch(gov,targets,calls);Vm.Log[] memory cutoverLogs=vm.getRecordedLogs();
        uint256 recalled=_transferred(cutoverLogs,OLD,CORE);uint256 deployed=_transferred(cutoverLogs,CORE,address(strategy));
        assertGe(recalled+100,oldNav);guard.assertDrained(OLD,100);assertEq(token.balanceOf(CORE),coreCash+recalled-deployed);
        uint256 invested=adapter.totalAssets();assertGt(invested,0,"actual Core must fund real Aave position");
        assertLe(strategy.idleCash(),deployed*500/10000+2,"named real profile must invest at least95percent");
        uint256 candidateNav=strategy.totalAssets();uint256 beforeRecall=token.balanceOf(CORE);
        address[] memory rollbackTargets=new address[](9);bytes[] memory rollbackCalls=new bytes[](9);k=0;
        rollbackTargets[k]=address(upkeep);rollbackCalls[k++]=abi.encodeWithSignature("toggleStrategy(address,bool)",address(strategy),false);
        rollbackTargets[k]=address(strategy);rollbackCalls[k++]=abi.encodeWithSignature("setDepositsDisabled(bool)",true);
        rollbackTargets[k]=ROUTER;rollbackCalls[k++]=abi.encodeWithSignature("withdrawAllToCore(address)",address(strategy));
        rollbackTargets[k]=address(guard);rollbackCalls[k++]=abi.encodeWithSignature("assertDrained(address,uint256)",address(strategy),100);
        rollbackTargets[k]=ROUTER;rollbackCalls[k++]=abi.encodeWithSignature("toggle(address,bool)",OLD,true);
        weights[0]=10000;weights[1]=0;rollbackTargets[k]=ROUTER;rollbackCalls[k++]=abi.encodeWithSignature("setWeights(address[],uint16[])",pair,weights);
        rollbackTargets[k]=ROUTER;rollbackCalls[k++]=abi.encodeWithSignature("toggle(address,bool)",address(strategy),false);
        rollbackTargets[k]=OLD;rollbackCalls[k++]=abi.encodeWithSignature("setDepositsDisabled(bool)",false);
        rollbackTargets[k]=OLD_UPKEEP;rollbackCalls[k++]=abi.encodeWithSignature("toggleStrategy(address,bool)",OLD,true);assertEq(k,9);
        vm.recordLogs();_executeActualSafeBatch(gov,rollbackTargets,rollbackCalls);
        uint256 candidateRecalled=_transferred(vm.getRecordedLogs(),address(strategy),CORE);guard.assertDrained(address(strategy),100);
        assertGe(candidateRecalled+2,candidateNav);assertEq(token.balanceOf(CORE),beforeRecall+candidateRecalled);
        // Rollback restores routing/keeper state with recalled capital safely in Core.
        assertTrue(router.isStrategyEnabled(OLD));assertFalse(router.isStrategyEnabled(address(strategy)));
        assertFalse(upkeep.enabled(address(strategy)));assertTrue(StrategyUpkeep(OLD_UPKEEP).enabled(OLD));
        assertEq(CORE.codehash,coreHash);assertEq(ROUTER.codehash,routerHash);assertEq(market.asset.codehash,tokenHash);
        emit ActualFrozenCutover(rpcForkBlock,OLD,address(strategy),oldNav,recalled,invested,candidateRecalled,token.balanceOf(CORE));
    }
    function executeReferenceSafeBatch(address gov,address[] memory targets,bytes[] memory calls) external {
        require(msg.sender==address(this),"self-only reference batch");_executeActualSafeBatch(gov,targets,calls);
    }
    function _transferred(Vm.Log[] memory logs,address from,address to) internal view returns(uint256 total) {
        for(uint256 i;i<logs.length;++i){Vm.Log memory l=logs[i];if(l.emitter==market.asset&&l.topics.length==3&&l.topics[0]==keccak256("Transfer(address,address,uint256)")&&l.topics[1]==bytes32(uint256(uint160(from)))&&l.topics[2]==bytes32(uint256(uint160(to))))total+=abi.decode(l.data,(uint256));}
    }
}
