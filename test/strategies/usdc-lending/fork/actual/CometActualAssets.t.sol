// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CometUsdcMultiMarketAdapter as Adapter} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol";
import {ProtocolRegistry} from "@multyr-strategies/strategies/usdc-lending/registry/ProtocolRegistry.sol";
interface IActualComet {function baseToken() external view returns(address);function balanceOf(address) external view returns(uint256);function totalSupply() external view returns(uint256);function getUtilization() external view returns(uint256);function getSupplyRate(uint256) external view returns(uint64);}
contract CometActualAssetsTest is Test {
    using SafeERC20 for IERC20;
    address constant HOLDER=0xF977814e90dA44bFA03b6295A0616a897441aceC;
    event ActualComet(address token,address market,uint256 chainId,uint256 rpcBlock,uint8 decimals,uint256 supply,uint256 cash,uint256 utilization,uint256 ratePerSecond,uint256 independentlyCalculatedBps,uint256 position);
    event ActualFunding(address token,address holder,uint256 beforeBalance,uint256 amount,uint256 afterBalance);
    function test_actualCometEthereumUsdtLifecycleAndRate() public {_run("https://eth-mainnet.public.blastapi.io",26300000,1,0x3Afdc9BCA9213A35503b077a6072F3D0d5AB0840,1000e6);}
    function test_actualCometEthereumWethLifecycleAndRate() public {_run("https://eth-mainnet.public.blastapi.io",26300000,1,0xA17581A9E3356d9A858b789D68B4d866e593aE94,1e18);}
    function test_actualCometArbitrumWethLifecycleAndRate() public {_run("https://arbitrum-one.public.blastapi.io",520094008,42161,0x6f7D514bbD4aFf3BcD1140B7344b32f063dEe486,1e18);}
    function _observe(Adapter a,address m,uint256 chain,uint256 pin) internal {
        IActualComet c=IActualComet(m);address token=c.baseToken();uint256 util=c.getUtilization();uint256 rate=c.getSupplyRate(util);
        uint256 expected=rate*31536000/1e14;if(expected>type(uint16).max)expected=type(uint16).max;
        assertEq(a.currentAPYBps(),expected,"independent real Comet per-second supply APR");
        assertEq(a.investedAssets(),c.balanceOf(address(a)),"actual indexed base balance");assertEq(a.externalMarketTVL(),c.totalSupply());
        emit ActualComet(token,m,chain,pin,IERC20Metadata(token).decimals(),c.totalSupply(),IERC20(token).balanceOf(m),util,rate,expected,a.totalAssets());
    }
    function _run(string memory rpc,uint256 pin,uint256 chain,address m,uint256 amount) internal {
        vm.createSelectFork(rpc,pin);assertEq(block.chainid,chain);address token=IActualComet(m).baseToken();
        ProtocolRegistry r=ProtocolRegistry(deployCode("ProtocolRegistry.sol:ProtocolRegistry",abi.encode(address(this))));
        r.addVault(ProtocolRegistry.ProtocolType.COMPOUND_V3,m,"official Compound deployment",1000,type(uint128).max);
        Adapter a=Adapter(payable(deployCode("CometUsdcMultiMarket.sol:CometUsdcMultiMarketAdapter")));
        a.initialize(token,address(this),address(this),0,address(r));assertLe(address(a).code.length,23552);
        uint256 beforeHolder=IERC20(token).balanceOf(HOLDER);uint256 supply=IERC20(token).totalSupply();uint256 beforeSelf=IERC20(token).balanceOf(address(this));assertGe(beforeHolder,amount);
        vm.prank(HOLDER);IERC20(token).safeTransfer(address(this),amount);
        assertEq(IERC20(token).balanceOf(HOLDER),beforeHolder-amount);assertEq(IERC20(token).balanceOf(address(this))-beforeSelf,amount);assertEq(IERC20(token).totalSupply(),supply);
        emit ActualFunding(token,HOLDER,beforeHolder,amount,IERC20(token).balanceOf(HOLDER));
        _observe(a,m,chain,pin);IERC20(token).forceApprove(address(a),amount);a.deposit(amount);assertApproxEqAbs(a.totalAssets(),amount,2);_observe(a,m,chain,pin);
        vm.expectRevert(bytes4(keccak256("PositionsActive()")));a.refreshFromRegistry();
        uint256 before=IERC20(token).balanceOf(address(this));uint256 paid=a.withdraw(amount/4,address(this));assertEq(paid,amount/4);assertEq(IERC20(token).balanceOf(address(this))-before,paid);_observe(a,m,chain,pin);
        before=IERC20(token).balanceOf(address(this));uint256 remaining=a.totalAssets();a.emergencyPullAllToVault();
        assertApproxEqAbs(IERC20(token).balanceOf(address(this))-before,remaining,2);assertLe(a.totalAssets(),2);assertLe(IActualComet(m).balanceOf(address(a)),2);_observe(a,m,chain,pin);
    }
}
