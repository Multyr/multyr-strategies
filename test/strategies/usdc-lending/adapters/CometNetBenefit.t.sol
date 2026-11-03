// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {MockUSDCComet,MockComet} from "./CometUsdcMultiMarketAdapter.t.sol";
import {SimpleProtocolRegistry} from "../../../helpers/SimpleProtocolRegistry.sol";
import {CometUsdcMultiMarketAdapter as Adapter} from "../../../../src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol";
/// Controlled economic boundary regression, not real-market acceptance.
contract CometNetBenefitTest is Test {
    function test_optimizeThresholdUsesBenefitAfterCosts() public {
        MockUSDCComet token=new MockUSDCComet();MockComet one=new MockComet(address(token));MockComet two=new MockComet(address(token));
        SimpleProtocolRegistry r=new SimpleProtocolRegistry();r.addVault(SimpleProtocolRegistry.ProtocolType.COMPOUND_V3,address(one),"cost boundary",10000,1_000_000e6);
        Adapter a=Adapter(payable(deployCode("CometUsdcMultiMarket.sol:CometUsdcMultiMarketAdapter")));a.initialize(address(token),address(this),address(this),0,address(r));
        token.mint(address(this),1000e6);token.approve(address(a),1000e6);one.setSupplyRate(1585489599);a.deposit(500e6);
        a.addMarket(address(two));two.setSupplyRate(3170979198);a.deposit(500e6);
        one.setSupplyRate(3170979198);two.setSupplyRate(1585489599);a.setOptimizeParams(0,0,2);a.setCostsEstimates(8,0,0);
        assertEq(a.activeIdx(),1);uint256 gross=uint256(500e6)*500*7/(10000*365);assertGt(gross*10000/1000e6,2);assertLt((gross-500e6*8/10000)*10000/1000e6,2);
        (uint256 rejected,,)=a.optimize();assertEq(rejected,0,"gross passes but net must reject");assertEq(two.balanceOf(address(a)),500e6);
        a.setCostsEstimates(4,0,0);(uint256 moved,,)=a.optimize();assertEq(moved,500e6,"net above threshold must execute");assertEq(one.balanceOf(address(a)),1000e6);assertEq(two.balanceOf(address(a)),0);
    }
}
