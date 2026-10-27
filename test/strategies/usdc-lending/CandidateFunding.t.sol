// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {CandidateActions} from "../../../src/strategies/usdc-lending/gas/CandidateActions.sol";
import {ReadOnlyGasEstimator as E} from "../../../src/strategies/usdc-lending/gas/ReadOnlyGasEstimator.sol";
contract CandidateFundingTest is Test {
    function testPreservedTrancheCannotOvercommitDeposits() public pure {
        E.Action[] memory a = new E.Action[](3);
        a[0] = E.Action(address(1), 30e6, false);
        a[1] = E.Action(address(2), 40e6, true);
        a[2] = E.Action(address(3), 35e6, true);
        a = CandidateActions.funded(a, 35e6, 1e4);
        assertEq(a.length,3);
        assertEq(a[1].amount,40e6);
        assertEq(a[2].amount,25e6);
    }
    function testDustRemainderDoesNotCreateAnotherAction() public pure {
        E.Action[] memory a = new E.Action[](2);
        a[0] = E.Action(address(1), 10e6, true);
        a[1] = E.Action(address(2), 1e6, true);
        a = CandidateActions.funded(a,10e6+99,100);
        assertEq(a.length,1);
    }
    function testFuzzDepositsNeverExceedFunding(uint96 idle,uint96 withdrawal,uint96 first,uint96 second) public pure {
        E.Action[] memory a = new E.Action[](3);
        a[0] = E.Action(address(1),withdrawal,false);
        a[1] = E.Action(address(2),first,true);
        a[2] = E.Action(address(3),second,true);
        a = CandidateActions.funded(a,idle,1);
        uint256 deposited;
        for(uint256 i;i<a.length;++i) if(a[i].deposit) deposited+=a[i].amount;
        assertLe(deposited,uint256(idle)+withdrawal);
    }
}
