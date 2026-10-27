// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {AdapterSwapGuard} from "../../../src/strategies/usdc-lending/gas/AdapterSwapGuard.sol";
contract SwapAssetMock { uint256 public totalAssets; constructor(uint256 a){totalAssets=a;} }
contract AdapterSwapGuardTest is Test {
 function testRejectsResidualPosition() public {AdapterSwapGuard g=new AdapterSwapGuard();address[] memory a=new address[](1);a[0]=address(new SwapAssetMock(101));vm.expectRevert("ADAPTER_NOT_DRAINED");g.assertDrained(a,100);}
 function testRejectsMissingContract() public {AdapterSwapGuard g=new AdapterSwapGuard();address[] memory a=new address[](1);a[0]=address(123);vm.expectRevert("MISSING_ADAPTER");g.assertDrained(a,100);}
 function testAcceptsDrainedSet() public {AdapterSwapGuard g=new AdapterSwapGuard();address[] memory a=new address[](2);a[0]=address(new SwapAssetMock(0));a[1]=address(new SwapAssetMock(100));g.assertDrained(a,100);}
}
