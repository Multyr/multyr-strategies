// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {MockUSDCMorpho,MockMorphoVault} from "./MorphoAdapter.t.sol";
import {MockComet} from "./CometUsdcMultiMarketAdapter.t.sol";
import {ProtocolRegistry} from "../../../../src/strategies/usdc-lending/registry/ProtocolRegistry.sol";
import {MorphoUsdcMultiMarketAdapter as Morpho} from "../../../../src/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol";
import {CometUsdcMultiMarketAdapter as Comet} from "../../../../src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol";
import {DolomiteUsdcMultiMarketAdapter as Dolomite} from "../../../../src/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol";
import {EulerUsdcMultiMarketAdapter as Euler} from "../../../../src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol";

/// @dev Configuration fault tests with controlled receipts, separate from live acceptance.
contract MarketConfigSafetyTest is Test {
    MockUSDCMorpho token;MockMorphoVault one;MockMorphoVault two;MockMorphoVault three;ProtocolRegistry registry;
    function setUp() public {
        token=new MockUSDCMorpho();one=new MockMorphoVault(address(token));two=new MockMorphoVault(address(token));three=new MockMorphoVault(address(token));
        registry=ProtocolRegistry(deployCode("ProtocolRegistry.sol:ProtocolRegistry",abi.encode(address(this))));
    }
    function _register(ProtocolRegistry.ProtocolType protocol,address market) internal {registry.addVault(protocol,market,"config fault fixture",1000,1_000_000e6);}
    function _receipt(address receiver) internal {token.mint(address(this),1000e6);token.approve(address(one),1000e6);one.deposit(1000e6,receiver);}
    function test_morphoRawReceiptsBlockReloadAndReplacementAndDuplicates() public {
        _register(ProtocolRegistry.ProtocolType.MORPHO,address(one));
        Morpho a=Morpho(payable(deployCode("MorphoUsdcMultiMarket.sol:MorphoUsdcMultiMarketAdapter")));a.initialize(address(token),address(this),address(this),0,address(registry));
        vm.expectRevert(Morpho.DuplicateMarket.selector);a.addMarket(address(one));a.addMarket(address(two));
        vm.expectRevert(Morpho.DuplicateMarket.selector);a.updateMarketAddress(0,address(two));
        _receipt(address(a));assertEq(a.principalTotal(),0,"donated receipts bypass principal, not ownership guard");
        vm.expectRevert(Morpho.PositionsActive.selector);a.refreshFromRegistry();
        vm.expectRevert(Morpho.PositionsActive.selector);a.updateMarketAddress(0,address(three));
        a.emergencyPullAllToVault();assertEq(one.balanceOf(address(a)),0);a.refreshFromRegistry();assertEq(a.activeIdx(),0);assertEq(a.principalTotal(),0);assertEq(a.totalAssets(),0);
    }
    function test_cometRawBalanceBlocksReloadAndReplacementAndDuplicates() public {
        MockComet m=new MockComet(address(token));MockComet other=new MockComet(address(token));MockComet replacement=new MockComet(address(token));_register(ProtocolRegistry.ProtocolType.COMPOUND_V3,address(m));
        Comet a=Comet(payable(deployCode("CometUsdcMultiMarket.sol:CometUsdcMultiMarketAdapter")));a.initialize(address(token),address(this),address(this),0,address(registry));
        vm.expectRevert(Comet.DuplicateMarket.selector);a.addMarket(address(m));a.addMarket(address(other));
        vm.expectRevert(Comet.DuplicateMarket.selector);a.updateMarketAddress(0,address(other));
        token.mint(address(a),1000e6);vm.prank(address(a));token.approve(address(m),1000e6);vm.prank(address(a));m.supply(address(token),1000e6);
        assertEq(a.principalTotal(),0);assertEq(m.balanceOf(address(a)),1000e6);
        vm.expectRevert(Comet.PositionsActive.selector);a.refreshFromRegistry();
        vm.expectRevert(Comet.PositionsActive.selector);a.updateMarketAddress(0,address(replacement));
        a.emergencyPullAllToVault();a.refreshFromRegistry();assertEq(a.activeIdx(),0);assertEq(a.totalAssets(),0);
    }
    function test_dolomiteDisabledReceiptsRemainValuedAndBlockReload() public {
        _register(ProtocolRegistry.ProtocolType.DOLOMITE,address(one));
        Dolomite a=Dolomite(payable(deployCode("DolomiteUsdcMultiMarket.sol:DolomiteUsdcMultiMarketAdapter")));a.initialize(address(token),address(this),address(this),0,address(registry));
        vm.expectRevert(Dolomite.DuplicateMarket.selector);a.addMarket(address(one),Dolomite.MarketType.ERC4626);a.addMarket(address(two),Dolomite.MarketType.ERC4626);
        vm.expectRevert(Dolomite.DuplicateMarket.selector);a.updateMarket(0,address(two),Dolomite.MarketType.ERC4626);
        _receipt(address(a));a.toggleMarket(0,false);assertEq(a.totalAssets(),1000e6,"interaction flag cannot erase ownership");
        vm.expectRevert(Dolomite.PositionsActive.selector);a.refreshFromRegistry();
        vm.expectRevert(Dolomite.PositionsActive.selector);a.updateMarket(0,address(three),Dolomite.MarketType.ERC4626);
        a.toggleMarket(0,true);a.emergencyPullAllToVault();a.refreshFromRegistry();assertEq(a.activeIdx(),0);assertEq(a.totalAssets(),0);
    }
    function test_eulerLiveAppendPreservesReceiptsButReplacementAndAliasAreBlocked() public {
        _register(ProtocolRegistry.ProtocolType.EULER_V2,address(one));address[] memory markets=new address[](2);markets[0]=address(one);markets[1]=address(two);
        Euler a=Euler(payable(deployCode("EulerUsdcMultiMarket.sol:EulerUsdcMultiMarketAdapter")));a.initialize(address(this),address(token),markets,address(registry),address(this));
        vm.expectRevert(Euler.DuplicateMarket.selector);a.updateMarketAddress(0,address(two));_receipt(address(a));
        vm.expectRevert(Euler.PositionsActive.selector);a.updateMarketAddress(0,address(three));
        uint256 before=a.totalAssets();a.refreshFromRegistry();assertEq(a.totalAssets(),before,"Euler append/dedup reload is safe with live receipts");assertEq(one.balanceOf(address(a)),1000e6);
    }
}
