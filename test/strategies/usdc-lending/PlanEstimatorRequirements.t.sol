// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {StrategyAllocCalcModule} from "../../../src/strategies/usdc-lending/controller/StrategyAllocCalcModule.sol";
import {AdapterScore} from "../../../src/strategies/usdc-lending/controller/StrategyStorageLayout.sol";
import {CandidateActions} from "../../../src/strategies/usdc-lending/gas/CandidateActions.sol";
import {ReadOnlyGasEstimator as E} from "../../../src/strategies/usdc-lending/gas/ReadOnlyGasEstimator.sol";

contract AllocationEvidenceHarness is StrategyAllocCalcModule {
    constructor() StrategyAllocCalcModule(address(1), address(2)) {}
    function limit(uint256 tvl, uint16 configured) external returns(uint16) {
        maxAdaptersPerAllocation = configured;
        return _effectiveMaxAdapters(tvl);
    }
    function targets(AdapterScore[] memory scores, uint256 tvl) external returns(uint256[] memory) {
        for (uint256 i; i < scores.length; ++i) enabled[scores[i].adapter] = true;
        return _targetAllocations(scores, tvl);
    }
    function buffer(uint16 bps) external { targetIdleBufferBps = bps; }
    function observe(address a, uint256 gasUsed, bool deposit) external { _recordExecutionGas(a, gasUsed, deposit); }
}
contract PlanEstimatorRequirementsTest is Test {
    AllocationEvidenceHarness h;
    function setUp() public { vm.warp(1800000000); h = new AllocationEvidenceHarness(); }
    function test_tierBoundariesAndStaticCeiling() public {
        uint256[9] memory tvls = [uint256(24999e6),25000e6,249999e6,250000e6,999999e6,1000000e6,4999999e6,5000000e6,10000000e6];
        uint16[9] memory expected = [uint16(1),2,2,3,3,4,4,5,5];
        for(uint256 i; i < tvls.length; ++i) {
            assertEq(h.limit(tvls[i],0),expected[i]);
            assertEq(h.limit(tvls[i],10),expected[i]);
            assertEq(h.limit(tvls[i],1),1);
        }
    }
    function test_targetsSelectCompositeScoreAcrossAllTiers() public {
        AdapterScore[] memory scores = new AdapterScore[](7);
        for(uint256 i; i<7; ++i) scores[i] = AdapterScore(address(uint160(i+10)), (i+1)*100, 500,0,10000,10000,10000);
        h.buffer(1000);
        uint256[5] memory tvls = [uint256(10000e6),100000e6,500000e6,2000000e6,6000000e6];
        for(uint256 k; k<5; ++k) {
            h.limit(tvls[k],0);
            uint256[] memory t = h.targets(scores,tvls[k]);
            uint256 count; uint256 sum;
            for(uint256 j; j<7; ++j) {
                if(t[j]>0) { ++count; assertGe(j,6-k); }
                sum += t[j];
            }
            assertEq(count,k+1); assertLe(sum,tvls[k]*9000/10000);
        }
    }
    function test_500kExampleHasFiveActionsThreeDestinations() public pure {
        address[] memory adapters = new address[](5);
        uint256[] memory current = new uint256[](5);
        uint256[] memory targets = new uint256[](5);
        uint256[] memory scores = new uint256[](5);
        for(uint256 i; i<5; ++i) { adapters[i]=address(uint160(i+1)); scores[i]=100; }
        current[0]=300000e6; current[1]=200000e6;
        targets[2]=200000e6; targets[3]=175000e6; targets[4]=125000e6;
        E.Action[] memory actions = CandidateActions.funded(CandidateActions.build(adapters,current,targets,scores,1),0,1);
        assertEq(actions.length,5);
        for(uint256 i; i<5; ++i) {
            assertEq(actions[i].adapter,adapters[i]);
            assertEq(actions[i].deposit,i>=2);
            assertEq(actions[i].amount,i<2?current[i]:targets[i]);
        }
    }
    function test_evidenceResetsOnRegimeChangeAndAge() public {
        address a=address(99);
        h.observe(a,300000,true); h.observe(a,305000,true); h.observe(a,310000,true);
        (uint32 count,) = h.depositGasObservation(a); assertEq(count,3);
        (count,) = h.withdrawGasObservation(a); assertEq(count,0);
        h.observe(a,1000000,true);
        (count,) = h.depositGasObservation(a); assertEq(count,1);
        assertEq(h.emaDepositGas(a),1000000);
        vm.warp(block.timestamp+7 days+1);
        h.observe(a,1000000,true);
        (count,) = h.depositGasObservation(a); assertEq(count,1);
    }
}
