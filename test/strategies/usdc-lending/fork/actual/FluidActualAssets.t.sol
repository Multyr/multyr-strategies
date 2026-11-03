// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FluidUsdcMultiMarketAdapter as Adapter} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/FluidUsdcMultiMarket.sol";
interface IActualFluid {function asset() external view returns(address);function convertToAssets(uint256) external view returns(uint256);function maxWithdraw(address) external view returns(uint256);function totalAssets() external view returns(uint256);}
contract FluidActualAssetsTest is Test {
    using SafeERC20 for IERC20;
    uint256 pin;uint256 chain;
    event ActualFluid(address token,address market,uint256 chainId,uint256 rpcBlock,uint8 decimals,uint256 supply,uint256 wrapperCash,uint256 redeemable,uint16 rate,uint256 position);
    event ActualPpsReference(address market,uint256 firstBlock,uint256 secondBlock,uint256 firstTimestamp,uint256 secondTimestamp,uint256 firstPps,uint256 secondPps,uint256 independentlyCalculatedBps);
    event ActualFunding(address token,address holder,uint256 beforeBalance,uint256 amount,uint256 afterBalance);
    function test_actualFluidEthereumUsdtLifecycleAndHistoricalRate() public {_run("https://eth-mainnet.public.blastapi.io",26300000,1000,1,address(bytes20(hex"5c20b550819128074fd538edf79791733ccedd18")),0xF977814e90dA44bFA03b6295A0616a897441aceC,1000e6);}
    function test_actualFluidEthereumWethLifecycleAndHistoricalRate() public {_run("https://eth-mainnet.public.blastapi.io",26300000,1000,1,0x90551c1795392094FE6D29B758EcCD233cFAa260,0xF977814e90dA44bFA03b6295A0616a897441aceC,1e18);}
    function test_actualFluidArbitrumUsdcLifecycleAndHistoricalRate() public {_run("https://arbitrum-one.public.blastapi.io",520094008,100000,42161,0x1A996cb54bb95462040408C06122D45D6Cdb6096,0xB38e8c17e38363aF6EbdCb3dAE12e0243582891D,1000e6);}
    function _observe(Adapter a,address m) internal {
        address token=a.underlying();uint256 actual=IActualFluid(m).convertToAssets(IERC20(m).balanceOf(address(a)));
        assertApproxEqAbs(a.investedAssets(),actual,2);assertEq(a.externalMarketTVL(),IActualFluid(m).totalAssets());
        emit ActualFluid(token,m,chain,pin,IERC20Metadata(token).decimals(),IActualFluid(m).totalAssets(),IERC20(token).balanceOf(m),IActualFluid(m).maxWithdraw(address(a)),a.currentAPYBps(),a.totalAssets());
    }
    function _run(string memory rpc,uint256 last,uint256 delta,uint256 id,address m,address holder,uint256 amount) internal {
        pin=last;chain=id;vm.createSelectFork(rpc,last-delta);assertEq(block.chainid,id);address token=IActualFluid(m).asset();
        Adapter a=Adapter(payable(deployCode("FluidUsdcMultiMarket.sol:FluidUsdcMultiMarketAdapter")));
        a.initialize(token,address(this),address(this),0,m);assertLe(address(a).code.length,23552);
        this.primeActualRate(a,m,last-delta,last);
        uint256 beforeHolder=IERC20(token).balanceOf(holder);uint256 supply=IERC20(token).totalSupply();uint256 beforeSelf=IERC20(token).balanceOf(address(this));assertGe(beforeHolder,amount);
        vm.prank(holder);IERC20(token).safeTransfer(address(this),amount);assertEq(IERC20(token).balanceOf(holder),beforeHolder-amount);assertEq(IERC20(token).balanceOf(address(this))-beforeSelf,amount);assertEq(IERC20(token).totalSupply(),supply);
        emit ActualFunding(token,holder,beforeHolder,amount,IERC20(token).balanceOf(holder));
        _observe(a,m);IERC20(token).forceApprove(address(a),amount);a.deposit(amount);assertApproxEqAbs(a.totalAssets(),amount,2);_observe(a,m);
        uint256 before=IERC20(token).balanceOf(address(this));uint256 paid=a.withdraw(amount/4,address(this));assertEq(paid,amount/4);assertEq(IERC20(token).balanceOf(address(this))-before,paid);_observe(a,m);
        before=IERC20(token).balanceOf(address(this));uint256 remaining=a.totalAssets();a.emergencyPullAllToVault();
        assertApproxEqAbs(IERC20(token).balanceOf(address(this))-before,remaining,2);assertLe(a.totalAssets(),2);assertLe(IERC20(m).balanceOf(address(a)),2);_observe(a,m);
    }
    function primeActualRate(Adapter a,address m,uint256 firstBlock,uint256 lastBlock) external {
        require(msg.sender==address(this));uint256 firstPps=IActualFluid(m).convertToAssets(1e24);uint256 firstTime=vm.getBlockTimestamp();
        assertEq(a.currentAPYBps(),0);vm.makePersistent(address(a));vm.rollFork(lastBlock);
        uint256 secondPps=IActualFluid(m).convertToAssets(1e24);uint256 secondTime=vm.getBlockTimestamp();
        assertGe(secondTime-firstTime,1 hours);assertLe(secondTime-firstTime,2 days);assertGt(secondPps,firstPps);
        uint256 expected=(secondPps-firstPps)*315360000000/firstPps/(secondTime-firstTime);if(expected>type(uint16).max)expected=type(uint16).max;
        assertGt(expected,0);assertEq(a.currentAPYBps(),expected);a.pokeAPYSnapshots();assertEq(a.currentAPYBps(),expected);
        emit ActualPpsReference(m,firstBlock,lastBlock,firstTime,secondTime,firstPps,secondPps,expected);
    }
}
