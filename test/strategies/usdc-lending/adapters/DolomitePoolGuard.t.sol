// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {MockDoloERC4626} from "./DolomiteUsdcMultiMarketAdapter.t.sol";
import {MockUSDCEulX} from "./EulerUsdcMultiMarketAdapter.t.sol";
import {FollowupCapacityMarket} from "./AdapterReviewFollowup.t.sol";
import {ProtocolRegistry} from "../../../../src/strategies/usdc-lending/registry/ProtocolRegistry.sol";
import {DolomiteUsdcMultiMarketAdapter as D} from "../../../../src/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol";

/// Controlled account-based ownership model. ERC20 balance is deliberately
/// independent of Margin account Wei, as the production accounting permits.
contract PoolAccountOwnership {
    struct AccountInfo { address owner; uint256 number; }
    struct Wei { bool sign; uint256 value; }
    MockUSDCEulX public immutable token;
    mapping(address=>uint256) public owned;
    address public reportedToken;
    bool public failWithdraw;
    bool public failBalance;
    bool public failAccount;
    constructor(MockUSDCEulX t){token=t;reportedToken=address(t);}
    function baseToken() external view returns(address){return address(token);}
    function balanceOf(address) external view returns(uint256){require(!failBalance,"NO_ERC20");return 0;}
    function getMarketTokenAddress(uint256) external view returns(address){return reportedToken;}
    function getAccountWei(AccountInfo calldata account,uint256) external view returns(Wei memory){
        require(!failAccount,"ACCOUNT_UNAVAILABLE");return Wei(true,account.number==0?owned[account.owner]:0);
    }
    function availableLiquidity(address) external view returns(uint256){return token.balanceOf(address(this));}
    function supply(address underlying,uint256 amount) external {
        require(underlying==address(token));token.transferFrom(msg.sender,address(this),amount);owned[msg.sender]+=amount;
    }
    function withdraw(address underlying,uint256 amount) external {
        require(!failWithdraw,"WITHDRAW_FAILED");require(underlying==address(token));owned[msg.sender]-=amount;token.transfer(msg.sender,amount);
    }
    function fail(bool withdrawal,bool erc20,bool account) external {failWithdraw=withdrawal;failBalance=erc20;failAccount=account;}
    function setReportedToken(address a) external {reportedToken=a;}
    function donateFor(address owner,uint256 amount) external {
        token.transferFrom(msg.sender,address(this),amount);owned[owner]+=amount;
    }
}
contract PoolGuardRateProvider {
    function getSupplyRatePerSecond(address) external pure returns(uint256){return 1e12;}
}
contract R25RateProvider {
    address immutable high;
    constructor(address h){high=h;}
    function getSupplyRatePerSecond(address m) external view returns(uint256){return m==high?1e12:1e8;}
}

contract DolomitePoolGuardCounterexamplesTest is Test {
    MockUSDCEulX token;PoolAccountOwnership pool;ProtocolRegistry registry;D adapter;
    function setUp() public {
        token=new MockUSDCEulX();pool=new PoolAccountOwnership(token);
        registry=ProtocolRegistry(deployCode("ProtocolRegistry.sol:ProtocolRegistry",abi.encode(address(this))));
        registry.addVault(ProtocolRegistry.ProtocolType.DOLOMITE,address(pool),"account",1000,1_000_000e6);
        adapter=D(payable(deployCode("DolomiteUsdcMultiMarket.sol:DolomiteUsdcMultiMarketAdapter")));
        adapter.initialize(address(token),address(this),address(this),1_000_000e6,address(registry));
    }
    function _fund() internal {
        adapter.validateDolomiteConfig();token.mint(address(this),1000e6);token.approve(address(adapter),1000e6);adapter.deposit(1000e6);
        assertEq(adapter.totalAssets(),1000e6);
    }
    function _replaceRegistry() internal returns(FollowupCapacityMarket replacement) {
        replacement=new FollowupCapacityMarket(token,true,0);
        registry.setVaultEnabled(ProtocolRegistry.ProtocolType.DOLOMITE,address(pool),false);
        registry.addVault(ProtocolRegistry.ProtocolType.DOLOMITE,address(replacement),"replacement",1000,1_000_000e6);
    }
    function test_failedEmergencyCannotEraseMarginOwnershipOnRegistryRefresh() public {
        _fund();pool.fail(true,false,false);adapter.emergencyPullAllToVault();
        assertEq(pool.owned(address(adapter)),1000e6);
        _replaceRegistry();vm.expectRevert(D.PositionsActive.selector);adapter.refreshFromRegistry();
        address[] memory markets=adapter.markets();assertEq(markets.length,1);assertEq(markets[0],address(pool));
    }
    function test_emptyMarginAccountCanRefreshWithoutErc20BalanceOf() public {
        adapter.validateDolomiteConfig();pool.fail(false,true,false);FollowupCapacityMarket replacement=_replaceRegistry();
        adapter.refreshFromRegistry();address[] memory markets=adapter.markets();assertEq(markets.length,1);assertEq(markets[0],address(replacement));
    }
    function test_foreignMarketTokenCannotValidateAssetDenominatedAccount() public {
        pool.setReportedToken(address(new MockUSDCEulX()));vm.expectRevert();adapter.validateDolomiteConfig();
        assertFalse(adapter.dolomiteConfigValid());
    }
    function test_fundedMarginAccountCannotChangeAccountNumber() public {
        _fund();vm.expectRevert(D.PositionsActive.selector);adapter.setAccountNumber(1);
        assertEq(adapter.accountNumber(),0);assertEq(adapter.totalAssets(),1000e6);
    }
    function test_unvalidatedPoolDepositCannotHideFundedNav() public {
        token.mint(address(this),1000e6);token.approve(address(adapter),1000e6);
        vm.expectRevert();adapter.deposit(1000e6);
        assertEq(token.balanceOf(address(this)),1000e6);assertEq(pool.owned(address(adapter)),0);
    }
    function test_failedEmergencyCannotChangeMarketIdAndStrandOwnership() public {
        _fund();pool.fail(true,false,false);adapter.emergencyPullAllToVault();
        uint256 marketId=adapter.usdcMarketId();vm.expectRevert(D.PositionsActive.selector);adapter.setUsdcMarketId(marketId+1);
        assertEq(adapter.usdcMarketId(),marketId);assertEq(pool.owned(address(adapter)),1000e6);
    }
    function test_unreadableMarginAccountCannotBeErasedAfterEmergencyFailure() public {
        _fund();pool.fail(true,false,false);adapter.emergencyPullAllToVault();pool.fail(true,false,true);
        _replaceRegistry();vm.expectRevert();adapter.refreshFromRegistry();
        address[] memory markets=adapter.markets();assertEq(markets[0],address(pool));
    }
    function _fundThenCreditUnbookedOwnership() internal {
        _fund();adapter.withdraw(1000e6,address(this));assertEq(adapter.principalTotalValue(),0);
        token.approve(address(pool),1000e6);pool.donateFor(address(adapter),1000e6);
        assertEq(pool.owned(address(adapter)),1000e6);
    }
    function test_disabledUnbookedAccountCannotChangeTuple() public {
        _fundThenCreditUnbookedOwnership();adapter.toggleMarket(0,false);
        vm.expectRevert(D.PositionsActive.selector);adapter.setAccountNumber(1);
    }
    function test_invalidationCannotBypassPreviouslyConfiguredAccountOwnership() public {
        _fundThenCreditUnbookedOwnership();FollowupCapacityMarket market=new FollowupCapacityMarket(token,true,0);
        adapter.addMarket(address(market),D.MarketType.ERC4626);assertFalse(adapter.dolomiteConfigValid());
        vm.expectRevert(D.PositionsActive.selector);adapter.setAccountNumber(1);
    }
    function test_validatedWrongAccountCannotSilentlyReceiveNoDepositCredit() public {
        adapter.setAccountNumber(1);adapter.validateDolomiteConfig();
        token.mint(address(this),1000e6);token.approve(address(adapter),1000e6);
        vm.expectRevert();adapter.deposit(1000e6);
        assertEq(token.balanceOf(address(this)),1000e6);assertEq(pool.owned(address(adapter)),0);
    }
    function test_optimizeCannotBypassUnvalidatedPoolFundingGuard() public {
        vm.warp(1800000000);adapter.toggleMarket(0,false);
        FollowupCapacityMarket market=new FollowupCapacityMarket(token,true,0);
        adapter.addMarket(address(market),D.MarketType.ERC4626);
        token.mint(address(this),1000e6);token.approve(address(adapter),1000e6);adapter.deposit(1000e6);
        adapter.toggleMarket(0,true);adapter.setRateProvider(address(new PoolGuardRateProvider()));
        uint256 receipts=market.balanceOf(address(adapter));assertEq(receipts,1000e6);
        vm.expectRevert();adapter.optimize();
        assertEq(market.balanceOf(address(adapter)),receipts);assertEq(pool.owned(address(adapter)),0);
    }
    function test_failedEmergencyPreservesRecordedPrincipal() public {
        _fund();pool.fail(true,false,false);adapter.emergencyPullAllToVault();
        assertEq(pool.owned(address(adapter)),1000e6);assertEq(adapter.principalTotalValue(),1000e6);
    }

    function test_disabledErc4626EmergencyStillRecallsOwnedPosition() public {
        adapter.toggleMarket(0,false);FollowupCapacityMarket market=new FollowupCapacityMarket(token,true,0);
        adapter.addMarket(address(market),D.MarketType.ERC4626);
        token.mint(address(this),1000e6);token.approve(address(adapter),1000e6);adapter.deposit(1000e6);
        adapter.toggleMarket(1,false);adapter.emergencyPullAllToVault();
        assertEq(token.balanceOf(address(this)),1000e6);assertEq(market.balanceOf(address(adapter)),0);
        assertEq(adapter.principalTotalValue(),0);
    }

    function test_counterexample_firstUnvalidatedReadableDonationBlocksTupleChange() public {
        token.mint(address(this),1000e6);token.approve(address(pool),1000e6);pool.donateFor(address(adapter),1000e6);
        vm.expectRevert(D.PositionsActive.selector);adapter.setAccountNumber(1);
    }
    function test_counterexample_ercFirstThenPoolDonationBlocksTupleChange() public {
        FollowupCapacityMarket erc=new FollowupCapacityMarket(token,true,0);
        adapter.updateMarket(0,address(erc),D.MarketType.ERC4626);adapter.validateDolomiteConfig();
        adapter.addMarket(address(pool),D.MarketType.PoolLike);
        token.mint(address(this),1000e6);token.approve(address(pool),1000e6);pool.donateFor(address(adapter),1000e6);
        vm.expectRevert(D.PositionsActive.selector);adapter.setAccountNumber(1);
    }
    function test_counterexample_optimizeKeepsAggregatePrincipalEqualToPerMarketSum() public {
        vm.warp(1800000000);
        MockDoloERC4626 low=new MockDoloERC4626(address(token));
        address high=address(pool);
        adapter.updateMarket(0,address(low),D.MarketType.ERC4626);
        adapter.addMarket(high,D.MarketType.PoolLike);adapter.validateDolomiteConfig();
        token.mint(address(this),1000e6);token.approve(address(adapter),1000e6);adapter.deposit(1000e6);
        low.simulateInterest(1000e6);token.mint(address(low),1000e6);
        adapter.setRateProvider(address(new R25RateProvider(high)));
        adapter.setWeights(10000,0,0,0,0);adapter.setOptimizeParams(0,5000,2,80);
        (uint256 moved,,)=adapter.optimize();assertEq(moved,1000e6);
        assertEq(adapter.principalAt(0),500e6);assertEq(adapter.principalAt(1),1000e6);
        assertEq(adapter.principalTotalValue(),1500e6,"aggregate basis must match real per-market basis after capitalizing yield");
        assertEq(adapter.principalTotalValue(),adapter.principalAt(0)+adapter.principalAt(1));
        uint256 before=token.balanceOf(address(this));adapter.emergencyPullAllToVault();
        assertEq(token.balanceOf(address(this))-before,2000e6);assertEq(adapter.principalTotalValue(),0);
    }
}
