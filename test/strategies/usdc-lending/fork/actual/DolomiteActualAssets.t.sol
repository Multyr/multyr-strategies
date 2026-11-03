// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DolomiteUsdcMultiMarketAdapter as Adapter} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol";
import {ProtocolRegistry} from "@multyr-strategies/strategies/usdc-lending/registry/ProtocolRegistry.sol";
interface IActualDToken {function asset() external view returns(address);function convertToAssets(uint256) external view returns(uint256);function maxWithdraw(address) external view returns(uint256);function totalAssets() external view returns(uint256);}
contract DolomiteActualAssetsTest is Test {
    using SafeERC20 for IERC20;
    string constant RPC="https://arbitrum-one.public.blastapi.io";
    uint256 constant PIN=520094008;
    uint256 firstForkPin;
    uint256 finalForkPin;
    address constant HOLDER=0xF977814e90dA44bFA03b6295A0616a897441aceC;
    event ActualDolomite(address token,address market,uint256 rpcBlock,uint8 decimals,uint256 tvl,uint256 wrapperCash,uint256 position,uint256 redeemable,uint16 rate);
    event ActualFunding(address token,address holder,uint256 beforeBalance,uint256 amount,uint256 afterBalance);
    event ActualPpsReference(address market,uint256 firstBlock,uint256 secondBlock,uint256 firstTimestamp,uint256 secondTimestamp,uint256 firstPps,uint256 secondPps,uint256 independentlyCalculatedBps);
    function test_actualDolomiteUsdtLifecycle() public {_run(0xF2d2d55Daf93b0660297eaA10969eBe90ead5CE8,1000e6);}
    function test_actualDolomiteWethLifecycle() public {_run(0xf7b5127B510E568fdC39e6Bb54e2081BFaD489AF,1e18);}
    function test_actualDolomiteEthereumUsdcLifecycle() public {_runOn(1,0x444868B6e8079ac2c55eea115250f92C2b2c4D14,1000e6,0x55FE002aefF02F77364de339a1292923A15844B8);}
    function _observe(Adapter a,address m) internal {
        address token=a.underlying();
        uint256 actual=IActualDToken(m).convertToAssets(IERC20(m).balanceOf(address(a)));
        assertApproxEqAbs(a.investedAssets(),actual,2,"independent actual ERC4626 share conversion");
        assertEq(a.externalMarketTVL(),IActualDToken(m).totalAssets());
        emit ActualDolomite(token,m,finalForkPin,IERC20Metadata(token).decimals(),IActualDToken(m).totalAssets(),IERC20(token).balanceOf(m),a.totalAssets(),IActualDToken(m).maxWithdraw(address(a)),a.currentAPYBps());
    }
    function _run(address m,uint256 amount) internal {
        _runOn(42161,m,amount,HOLDER);
    }
    function _runOn(uint256 chain,address m,uint256 amount,address holder) internal {
        firstForkPin=chain==1?26299000:PIN-100000;finalForkPin=chain==1?26300000:PIN;
        vm.createSelectFork(chain==1?"https://eth-mainnet.public.blastapi.io":RPC,firstForkPin);assertEq(block.chainid,chain);
        address token=IActualDToken(m).asset();
        ProtocolRegistry r=ProtocolRegistry(deployCode("ProtocolRegistry.sol:ProtocolRegistry",abi.encode(address(this))));
        r.addVault(ProtocolRegistry.ProtocolType.DOLOMITE,m,"actual dToken",1000,type(uint128).max);
        Adapter a=Adapter(payable(deployCode("DolomiteUsdcMultiMarket.sol:DolomiteUsdcMultiMarketAdapter")));
        a.initialize(token,address(this),address(this),0,address(r));
        assertLe(address(a).code.length,23552);
        this.primeActualRate(a,m,address(r));
        uint256 beforeHolder=IERC20(token).balanceOf(holder);uint256 supply=IERC20(token).totalSupply();
        uint256 beforeSelf=IERC20(token).balanceOf(address(this));assertGe(beforeHolder,amount);
        vm.prank(holder);IERC20(token).safeTransfer(address(this),amount);
        assertEq(IERC20(token).balanceOf(holder),beforeHolder-amount);
        assertEq(IERC20(token).balanceOf(address(this))-beforeSelf,amount);
        assertEq(IERC20(token).totalSupply(),supply);
        emit ActualFunding(token,holder,beforeHolder,amount,IERC20(token).balanceOf(holder));
        _observe(a,m);IERC20(token).forceApprove(address(a),amount);a.deposit(amount);
        assertApproxEqAbs(a.totalAssets(),amount,2);_observe(a,m);
        a.toggleMarket(0,false);assertApproxEqAbs(a.totalAssets(),amount,2,"disabled market still owns the same real position");a.toggleMarket(0,true);
        vm.expectRevert(bytes4(keccak256("PositionsActive()")));a.refreshFromRegistry();
        uint256 before=IERC20(token).balanceOf(address(this));uint256 paid=a.withdraw(amount/4,address(this));
        assertEq(paid,amount/4,"actual partial withdrawal must succeed");
        assertEq(IERC20(token).balanceOf(address(this))-before,paid);_observe(a,m);
        before=IERC20(token).balanceOf(address(this));uint256 remaining=a.totalAssets();
        a.toggleMarket(0,false);
        a.emergencyPullAllToVault();assertApproxEqAbs(IERC20(token).balanceOf(address(this))-before,remaining,2);
        assertLe(a.totalAssets(),2);assertLe(IERC20(m).balanceOf(address(a)),2);
        // The disabled-market exit is asserted above. Restore catalog eligibility
        // before comparing enabled-market TVL/rates to the independent protocol view.
        a.toggleMarket(0,true);_observe(a,m);
    }
    function primeActualRate(Adapter a,address m,address registry) external {
        require(msg.sender==address(this),"self-only reference");
        uint256 firstPps=IActualDToken(m).convertToAssets(1e24);uint256 firstTime=vm.getBlockTimestamp();
        a.pokeAPYSnapshots();assertEq(a.currentAPYBps(),0,"unprimed observed rate");
        // No position or token balances have been modified yet. Only our local
        // adapter and registry persist; market/index observations remain canonical.
        vm.makePersistent(address(a));vm.makePersistent(registry);vm.rollFork(finalForkPin);
        uint256 secondPps=IActualDToken(m).convertToAssets(1e24);uint256 secondTime=vm.getBlockTimestamp();
        assertGe(secondTime-firstTime,1 hours);assertLe(secondTime-firstTime,2 days);
        assertGt(secondPps,firstPps,"genuine historical per-share interest");
        // Independent integer arithmetic on actual protocol PPS observations.
        uint256 expected=(secondPps-firstPps)*315360000000/firstPps/(secondTime-firstTime);
        if(expected>type(uint16).max)expected=type(uint16).max;
        assertGt(expected,0,"observed yield must be measurable");
        assertEq(a.currentAPYBps(),expected,"actual historical supply-rate reference");
        a.pokeAPYSnapshots();assertEq(a.currentAPYBps(),expected,"maintenance must preserve observed rate");
        emit ActualPpsReference(m,firstForkPin,finalForkPin,firstTime,secondTime,firstPps,secondPps,expected);
    }
}
