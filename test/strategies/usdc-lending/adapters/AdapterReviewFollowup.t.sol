// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {MockUSDCEulX, MockPermit2X} from "./EulerUsdcMultiMarketAdapter.t.sol";
import {ReviewEulerRateMarket} from "./AdapterFullReviewRegression.t.sol";
import {ProtocolRegistry} from "../../../../src/strategies/usdc-lending/registry/ProtocolRegistry.sol";
import {EulerUsdcMultiMarketAdapter as Euler} from "../../../../src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol";
import {DolomiteUsdcMultiMarketAdapter as Dolomite} from "../../../../src/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol";

/// Controlled activation/cap failure evidence, never part of the unmocked gate.
contract FollowupCapacityMarket {
    MockUSDCEulX public immutable token;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply = 1500e6;
    uint256 internal nav = 1500e6;
    uint256 public additionalCap = type(uint256).max;
    uint256 public supplied;
    bool public active;
    uint256 public immutable interestRate;
    constructor(MockUSDCEulX t, bool ready, uint256 rate) {
        token=t; active=ready; interestRate=rate;
        balanceOf[address(0xdead)]=1500e6;t.mint(address(this),1000e6);
    }
    function asset() external view returns(address){return address(token);}
    function totalAssets() external view returns(uint256){return nav;}
    function totalBorrows() external pure returns(uint256){return 500e6;}
    function interestFee() external pure returns(uint256){return 0;}
    function setCap(uint256 cap) external {additionalCap=cap;}
    function maxDeposit(address) public view returns(uint256){return additionalCap>supplied?additionalCap-supplied:0;}
    function convertToAssets(uint256 shares) external pure returns(uint256){return shares;}
    function maxWithdraw(address owner) external view returns(uint256){return balanceOf[owner];}
    function deposit(uint256 assets,address receiver) external returns(uint256 shares){
        require(active||assets==100,"NEEDS_POKE");require(assets<=maxDeposit(receiver),"CAP");
        active=true;token.transferFrom(msg.sender,address(this),assets);
        supplied+=assets;balanceOf[receiver]+=assets;totalSupply+=assets;nav+=assets;return assets;
    }
    function withdraw(uint256 assets,address receiver,address owner) external returns(uint256){
        require(msg.sender==owner,"OWNER");balanceOf[owner]-=assets;totalSupply-=assets;nav-=assets;
        token.transfer(receiver,assets);return assets;
    }
}
contract FollowupAmbiguousMarket is FollowupCapacityMarket {
    constructor(MockUSDCEulX t) FollowupCapacityMarket(t,true,0){}
    function baseToken() external view returns(address){return address(token);}
}
contract FollowupZeroShareMarket {
    MockUSDCEulX public immutable token;
    constructor(MockUSDCEulX t){token=t;}
    function asset() external view returns(address){return address(token);}
    function totalAssets() external pure returns(uint256){return 0;}
    function balanceOf(address) external pure returns(uint256){return 0;}
    function convertToAssets(uint256 shares) external pure returns(uint256){return shares;}
    function maxDeposit(address) external pure returns(uint256){return type(uint256).max;}
    function deposit(uint256 assets,address) external returns(uint256){
        token.transferFrom(msg.sender,address(this),assets);return 0;
    }
}
contract AdapterReviewFollowupTest is Test {
    function _token() internal returns(MockUSDCEulX token){
        vm.warp(1800000000);
        MockPermit2X permit=new MockPermit2X();vm.etch(0x000000000022D473030F116dDEE9F6B43aC78BA3,address(permit).code);
        token=new MockUSDCEulX();
    }
    function _euler(MockUSDCEulX token,address[] memory markets) internal returns(Euler a){
        a=Euler(payable(deployCode("EulerUsdcMultiMarket.sol:EulerUsdcMultiMarketAdapter")));
        a.initialize(address(this),address(token),markets,address(0),address(this));
    }
    function test_eulerBadMaxDepositDoesNotHideHealthyApy() public {
        MockUSDCEulX token=_token();ReviewEulerRateMarket good=new ReviewEulerRateMarket(address(token),1e18);
        ReviewEulerRateMarket bad=new ReviewEulerRateMarket(address(token),2e18);
        address[] memory markets=new address[](2);markets[0]=address(good);markets[1]=address(bad);
        Euler a=_euler(token,markets);
        vm.mockCallRevert(address(bad),abi.encodeWithSignature("maxDeposit(address)",address(a)),"BROKEN_CAP");
        assertGt(a.currentAPYBps(),0,"healthy market rate must remain readable");
    }
    function test_eulerActivationRetryDeploysBudgetAndRecordsAllPrincipal() public {
        MockUSDCEulX token=_token();FollowupCapacityMarket market=new FollowupCapacityMarket(token,false,2e18);
        address[] memory markets=new address[](1);markets[0]=address(market);Euler a=_euler(token,markets);
        token.mint(address(a),1000e6);a.deposit(1000e6);
        assertEq(token.balanceOf(address(a)),0);assertEq(market.balanceOf(address(a)),1000e6);
        assertEq(a.harvestableProfit(),0,"poke capital must not appear as yield");
        assertEq(token.allowance(address(a),address(market)),0);
    }
    function test_eulerTinyRequestCannotSpendExistingIdleOnPoke() public {
        MockUSDCEulX token=_token();FollowupCapacityMarket market=new FollowupCapacityMarket(token,false,2e18);
        address[] memory markets=new address[](1);markets[0]=address(market);Euler a=_euler(token,markets);
        token.mint(address(a),101);
        vm.expectRevert(bytes("Deposit failed - no market with sufficient capacity"));a.deposit(1);
        assertEq(token.balanceOf(address(a)),101);assertEq(market.balanceOf(address(a)),0);
    }
    function test_eulerOptimizeActivationRetryPreservesCapitalAndRevokesApproval() public {
        MockUSDCEulX token=_token();ReviewEulerRateMarket low=new ReviewEulerRateMarket(address(token),1e18);
        FollowupCapacityMarket high=new FollowupCapacityMarket(token,false,1e20);
        address[] memory markets=new address[](2);markets[0]=address(low);markets[1]=address(high);
        Euler a=_euler(token,markets);a.toggleMarket(1,false,false);token.mint(address(a),1000e6);a.deposit(1000e6);
        a.toggleMarket(1,true,false);a.optimize();
        assertEq(low.balanceOf(address(a)),0);assertEq(high.balanceOf(address(a)),1000e6);
        assertEq(a.totalAssets(),1000e6);assertEq(a.harvestableProfit(),0);
        assertEq(token.allowance(address(a),address(low)),0);assertEq(token.allowance(address(a),address(high)),0);
    }
    function test_eulerOptimizeInsufficientRetryCapRollsBackSourceAndPoke() public {
        MockUSDCEulX token=_token();ReviewEulerRateMarket low=new ReviewEulerRateMarket(address(token),1e18);
        FollowupCapacityMarket high=new FollowupCapacityMarket(token,false,1e20);high.setCap(400e6);
        address[] memory markets=new address[](2);markets[0]=address(low);markets[1]=address(high);
        Euler a=_euler(token,markets);a.toggleMarket(1,false,false);token.mint(address(a),1000e6);a.deposit(1000e6);
        a.toggleMarket(1,true,false);vm.expectRevert(bytes("no capacity after poke"));a.optimize();
        assertEq(low.balanceOf(address(a)),1000e6);assertEq(high.balanceOf(address(a)),0);
        assertEq(token.balanceOf(address(a)),0);assertEq(a.harvestableProfit(),0);assertFalse(high.active());
    }
    function _dolo(MockUSDCEulX token,uint256 firstCap) internal returns(Dolomite a,FollowupCapacityMarket first,FollowupCapacityMarket second){
        first=new FollowupCapacityMarket(token,true,0);second=new FollowupCapacityMarket(token,true,0);first.setCap(firstCap);
        ProtocolRegistry registry=ProtocolRegistry(deployCode("ProtocolRegistry.sol:ProtocolRegistry",abi.encode(address(this))));
        registry.addVault(ProtocolRegistry.ProtocolType.DOLOMITE,address(first),"first",1000,1_000_000e6);
        registry.addVault(ProtocolRegistry.ProtocolType.DOLOMITE,address(second),"second",1000,1_000_000e6);
        a=Dolomite(payable(deployCode("DolomiteUsdcMultiMarket.sol:DolomiteUsdcMultiMarketAdapter")));
        a.initialize(address(token),address(this),address(this),1_000_000e6,address(registry));
        token.mint(address(this),1000e6);token.approve(address(a),1000e6);
    }
    function test_dolomiteFullActiveMarketFallsBackToHealthyMarket() public {
        MockUSDCEulX token=_token();(Dolomite a,FollowupCapacityMarket first,FollowupCapacityMarket second)=_dolo(token,0);
        a.deposit(1000e6);assertEq(first.balanceOf(address(a)),0);assertEq(second.balanceOf(address(a)),1000e6);
        assertEq(a.principalTotalValue(),1000e6);assertEq(token.allowance(address(a),address(first)),0);
        assertEq(token.allowance(address(a),address(second)),0);
    }
    function test_dolomitePartialActiveCapFillsOtherMarket() public {
        MockUSDCEulX token=_token();(Dolomite a,FollowupCapacityMarket first,FollowupCapacityMarket second)=_dolo(token,400e6);
        a.deposit(1000e6);assertEq(first.balanceOf(address(a)),400e6);assertEq(second.balanceOf(address(a)),600e6);
        assertEq(a.principalTotalValue(),1000e6);assertEq(a.totalAssets(),1000e6);
        assertEq(token.allowance(address(a),address(first)),0);assertEq(token.allowance(address(a),address(second)),0);
    }
    function test_dolomiteRegistrySkipsAmbiguousMarketButKeepsValidEntry() public {
        MockUSDCEulX token=_token();FollowupAmbiguousMarket bad=new FollowupAmbiguousMarket(token);
        FollowupCapacityMarket good=new FollowupCapacityMarket(token,true,0);
        ProtocolRegistry registry=ProtocolRegistry(deployCode("ProtocolRegistry.sol:ProtocolRegistry",abi.encode(address(this))));
        registry.addVault(ProtocolRegistry.ProtocolType.DOLOMITE,address(bad),"ambiguous",1000,1_000_000e6);
        registry.addVault(ProtocolRegistry.ProtocolType.DOLOMITE,address(good),"valid",1000,1_000_000e6);
        Dolomite a=Dolomite(payable(deployCode("DolomiteUsdcMultiMarket.sol:DolomiteUsdcMultiMarketAdapter")));
        a.initialize(address(token),address(this),address(this),1_000_000e6,address(registry));
        address[] memory actual=a.markets();assertEq(actual.length,1);assertEq(actual[0],address(good));
    }
    function test_dolomiteZeroShareSuccessRollsBackTransferredFunds() public {
        MockUSDCEulX token=_token();FollowupZeroShareMarket market=new FollowupZeroShareMarket(token);
        ProtocolRegistry registry=ProtocolRegistry(deployCode("ProtocolRegistry.sol:ProtocolRegistry",abi.encode(address(this))));
        registry.addVault(ProtocolRegistry.ProtocolType.DOLOMITE,address(market),"zero-shares",1000,1_000_000e6);
        Dolomite a=Dolomite(payable(deployCode("DolomiteUsdcMultiMarket.sol:DolomiteUsdcMultiMarketAdapter")));
        a.initialize(address(token),address(this),address(this),1_000_000e6,address(registry));
        token.mint(address(this),1000e6);token.approve(address(a),1000e6);
        vm.expectRevert(bytes("Dolomite: deposit returned 0 shares"));a.deposit(1000e6);
        assertEq(token.balanceOf(address(this)),1000e6);assertEq(token.balanceOf(address(a)),0);
        assertEq(token.balanceOf(address(market)),0);assertEq(a.principalTotalValue(),0);
    }
}
