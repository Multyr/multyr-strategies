// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Vm} from "forge-std/Vm.sol";
import {TVL_Confidence} from "./TVL_Confidence.t.sol";
import {StrategyParamsModule} from "../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import {ILendingAdapter} from "../../../src/strategies/usdc-lending/interfaces/ILendingAdapter.sol";

contract AdapterFailureTelemetryTest is TVL_Confidence {
    bytes32 constant FAILURE = keccak256("AdapterCallFailed(address,bytes4,uint256,bytes)");
    function _refresh() internal {
        if (StrategyParamsModule(address(vault)).adapterCount() == 0) {
            _addAndEnable(adapterBig); _addAndEnable(adapterMed);
        }
        vm.prank(keeper); StrategyParamsModule(address(vault)).pokeExternalTVL();
    }
    function _find(Vm.Log[] memory logs,address adapter,bytes4 selector,bytes memory reason) internal view returns(bool) {
        for(uint i;i<logs.length;i++) {
            Vm.Log memory l=logs[i];
            if(l.emitter!=address(vault)||l.topics.length!=3||l.topics[0]!=FAILURE) continue;
            if(address(uint160(uint256(l.topics[1])))!=adapter||bytes4(l.topics[2])!=selector) continue;
            (uint256 timestamp,bytes memory data)=abi.decode(l.data,(uint256,bytes));
            if(timestamp==block.timestamp&&keccak256(data)==keccak256(reason))return true;
        }
        return false;
    }
    function test_capacityRevertEmitsExactDataAndRetainsCache() public {
        _refresh();
        uint oldCap=vault.cachedAdapterCapacity(address(adapterBig));
        bytes memory reason=abi.encodeWithSignature("AdapterUnavailable(uint256)",42);
        vm.mockCallRevert(address(adapterBig),abi.encodeWithSelector(ILendingAdapter.maxCapacity.selector),reason);
        vm.recordLogs();_refresh();
        assertTrue(_find(vm.getRecordedLogs(),address(adapterBig),ILendingAdapter.maxCapacity.selector,reason));
        assertEq(vault.cachedAdapterCapacity(address(adapterBig)),oldCap);
        assertGt(vault.cachedExternalTVL(address(adapterMed)),0,"other adapters still refresh");
    }
    function test_tvlAndCapacityBothFailEmitDistinctSelectorsAndKeepTimestamps() public {
        _refresh();
        uint oldTVL=vault.cachedExternalTVL(address(adapterBig));
        uint oldTs=vault.cachedExternalTVLTs(address(adapterBig));
        vm.warp(block.timestamp+60);
        bytes memory reason=abi.encodeWithSignature("Error(string)","offline");
        vm.mockCallRevert(address(adapterBig),abi.encodeWithSelector(ILendingAdapter.externalMarketTVL.selector),reason);
        vm.mockCallRevert(address(adapterBig),abi.encodeWithSelector(ILendingAdapter.maxCapacity.selector),hex"");
        vm.recordLogs();_refresh();Vm.Log[] memory logs=vm.getRecordedLogs();
        assertTrue(_find(logs,address(adapterBig),ILendingAdapter.externalMarketTVL.selector,reason));
        assertTrue(_find(logs,address(adapterBig),ILendingAdapter.maxCapacity.selector,hex""));
        assertEq(vault.cachedExternalTVL(address(adapterBig)),oldTVL);
        assertEq(vault.cachedExternalTVLTs(address(adapterBig)),oldTs);
    }
    function test_malformedCapacityReturnIsObservedWithoutBreakingRefresh() public {
        _refresh();uint oldCap=vault.cachedAdapterCapacity(address(adapterBig));
        vm.mockCall(address(adapterBig),abi.encodeWithSelector(ILendingAdapter.maxCapacity.selector),hex"1234");
        vm.recordLogs();_refresh();
        assertTrue(_find(vm.getRecordedLogs(),address(adapterBig),ILendingAdapter.maxCapacity.selector,hex"1234"));
        assertEq(vault.cachedAdapterCapacity(address(adapterBig)),oldCap);
    }
    function test_liquidityPokeObservesTotalWithdrawableAndAPYFailures() public {
        _refresh();
        bytes memory reason=abi.encodeWithSignature("Error(string)","unavailable");
        vm.mockCall(address(adapterBig),abi.encodeWithSelector(ILendingAdapter.totalAssets.selector),abi.encode(uint256(1e6)));
        vm.mockCallRevert(address(adapterBig),abi.encodeWithSelector(ILendingAdapter.withdrawableAssets.selector),reason);
        vm.mockCallRevert(address(adapterBig),abi.encodeWithSelector(ILendingAdapter.currentAPYBps.selector),reason);
        vm.recordLogs();vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeLiquidityBatch(0,1);
        Vm.Log[] memory logs=vm.getRecordedLogs();
        assertTrue(_find(logs,address(adapterBig),ILendingAdapter.withdrawableAssets.selector,reason));
        assertTrue(_find(logs,address(adapterBig),ILendingAdapter.currentAPYBps.selector,reason));
        vm.mockCallRevert(address(adapterBig),abi.encodeWithSelector(ILendingAdapter.totalAssets.selector),reason);
        vm.recordLogs();vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeLiquidityBatch(0,1);
        assertTrue(_find(vm.getRecordedLogs(),address(adapterBig),ILendingAdapter.totalAssets.selector,reason));
    }

    function test_healthyRefreshDoesNotEmitFailure() public {
        vm.recordLogs();_refresh();Vm.Log[] memory logs=vm.getRecordedLogs();
        for(uint i;i<logs.length;i++)if(logs[i].topics.length>0)assertTrue(logs[i].topics[0]!=FAILURE);
    }
}
