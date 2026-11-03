// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {MockUSDCMorpho,MockMorphoVault} from "./MorphoAdapter.t.sol";
import {SimpleProtocolRegistry} from "../../../helpers/SimpleProtocolRegistry.sol";
import {MorphoUsdcMultiMarketAdapter as Adapter} from "../../../../src/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol";
import {MorphoVaultV2LiquidityView} from "../../../../src/strategies/usdc-lending/adapters/lending/MorphoVaultV2LiquidityView.sol";

/// @dev Controlled fault fixture, never used as real-market acceptance evidence.
contract MockZeroMaxMorphoV2 is MockMorphoVault {
    address public liquidityAdapter;
    bool public sharesAllowed=true;
    bool public assetsAllowed=true;
    bool public revertGate;
    constructor(address token) MockMorphoVault(token) {}
    function maxWithdraw(address) external pure override returns(uint256){return 0;}
    function gates(bool shares,bool assets,bool fail) external {sharesAllowed=shares;assetsAllowed=assets;revertGate=fail;}
    function canSendShares(address) external view returns(bool){require(!revertGate,"gate-failed");return sharesAllowed;}
    function canReceiveAssets(address) external view returns(bool){require(!revertGate,"gate-failed");return assetsAllowed;}
}
contract MorphoV2LiquidityViewTest is Test {
    MockUSDCMorpho token;
    MockZeroMaxMorphoV2 market;
    Adapter adapter;
    MorphoVaultV2LiquidityView helper;
    function setUp() public {
        token=new MockUSDCMorpho();market=new MockZeroMaxMorphoV2(address(token));helper=new MorphoVaultV2LiquidityView();
        SimpleProtocolRegistry r=new SimpleProtocolRegistry();r.addVault(SimpleProtocolRegistry.ProtocolType.MORPHO,address(market),"V2 fault fixture",10000,1_000_000e6);
        adapter=new Adapter();adapter.initialize(address(token),address(this),address(this),0,address(r));
        token.mint(address(this),1000e6);token.approve(address(adapter),1000e6);
    }
    function test_missingViewRejectsV2DepositAtomically() public {
        vm.expectRevert(abi.encodeWithSelector(Adapter.AllMarketsFailed.selector,1000e6));adapter.deposit(1000e6);
        assertEq(token.balanceOf(address(this)),1000e6);assertEq(adapter.totalAssets(),0);assertEq(market.balanceOf(address(adapter)),0);
    }
    function test_idleBoundAndNormalPartialWithdrawal() public {
        adapter.setVaultV2LiquidityView(address(helper));adapter.deposit(1000e6);
        vm.prank(address(market));token.transfer(address(0xBEEF),700e6);
        assertEq(market.maxWithdraw(address(adapter)),0);assertEq(adapter.withdrawableAssets(),300e6);
        uint256 received=adapter.withdraw(300e6,address(this));assertEq(received,300e6);assertEq(token.balanceOf(address(this)),300e6);
        assertEq(adapter.totalAssets(),700e6);assertEq(adapter.withdrawableAssets(),0,"allocated assets are not idle liquidity");
    }
    function test_exitGatesFailClosedWithoutLosingPosition() public {
        adapter.setVaultV2LiquidityView(address(helper));adapter.deposit(1000e6);
        market.gates(false,true,false);assertEq(adapter.withdrawableAssets(),0);
        market.gates(true,false,false);assertEq(adapter.withdrawableAssets(),0);
        market.gates(true,true,true);assertEq(adapter.withdrawableAssets(),0);
        assertEq(adapter.totalAssets(),1000e6);assertEq(market.balanceOf(address(adapter)),1000e6);
        market.gates(true,true,false);assertEq(adapter.withdrawableAssets(),1000e6);
        assertEq(adapter.withdraw(1000e6,address(this)),1000e6);assertEq(adapter.totalAssets(),0);
    }
    function test_wrongAssetAndV1BindingZeroRemainUnavailable() public {
        adapter.setVaultV2LiquidityView(address(helper));adapter.deposit(1000e6);
        assertEq(helper.withdrawableIdle(address(0xBAD),address(market),address(adapter),address(this)),0);
        MockMorphoVault v1=new MockMorphoVault(address(token));
        assertEq(helper.withdrawableIdle(address(token),address(v1),address(adapter),address(this)),0);
    }
    function test_onlyParamCanConfigureDeployedView() public {
        vm.prank(address(0xBEEF));vm.expectRevert();adapter.setVaultV2LiquidityView(address(helper));
        vm.expectRevert(bytes("liquidity view code"));adapter.setVaultV2LiquidityView(address(0xBEEF));
        adapter.setVaultV2LiquidityView(address(helper));assertEq(adapter.vaultV2LiquidityView(),address(helper));
    }
}
