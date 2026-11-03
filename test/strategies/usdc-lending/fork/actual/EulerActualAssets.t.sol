// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EulerUsdcMultiMarketAdapter as Adapter} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol";
interface IActualEVault {
    function asset() external view returns(address);function convertToAssets(uint256) external view returns(uint256);
    function totalAssets() external view returns(uint256);function totalBorrows() external view returns(uint256);
    function interestFee() external view returns(uint16);function interestRate() external view returns(uint256);
}
contract EulerActualAssetsTest is Test {
    using SafeERC20 for IERC20;
    string constant RPC="https://eth-mainnet.public.blastapi.io";
    uint256 constant PIN=26300000;
    uint256 actualForkPin;
    address constant HOLDER=0xF977814e90dA44bFA03b6295A0616a897441aceC;
    event ActualEuler(address asset,address market,uint256 rpcBlock,uint256 supply,uint256 borrows,uint256 feeBps,uint256 borrowRateRayPerSecond,uint256 independent365DayAprBps,uint256 independentJulianYearAprBps,uint16 adapterRateBps,uint256 position);
    event ActualFunding(address token,address holder,uint256 beforeBalance,uint256 amount,uint256 afterBalance);
    event ActualEarnedEulerInterest(address asset,address market,uint256 rpcBlock,uint256 elapsedSeconds,uint256 principal,uint256 earned,uint256 realized);
    function test_actualEulerUsdcLifecycleAndSupplierRate() public {_run(0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9);}
    function test_actualEulerUsdtLifecycleAndSupplierRate() public {_run(0x313603FA690301b0CaeEf8069c065862f9162162);}
    function test_actualEulerArbitrumUsdcLifecycleAndSupplierRate() public {_runOn(42161,0x0a1eCC5Fe8C9be3C809844fcBe615B46A869b899);}
    function _observe(Adapter a,address m) internal {
        IActualEVault v=IActualEVault(m);uint256 assets=v.totalAssets();uint256 debt=v.totalBorrows();
        uint256 fee=v.interestFee();uint256 rate=v.interestRate();
        assertLe(fee,10000);assertGt(assets,0);
        // One rational calculation, without candidate's early bps/WAD truncation.
        uint256 nominal365=rate*31536000*debt*(10000-fee)/(1e27*assets);
        uint256 julian=rate*31557600*debt*(10000-fee)/(1e27*assets);
        uint256 clamped=julian>type(uint16).max?type(uint16).max:julian;
        assertApproxEqAbs(a.currentAPYBps(),clamped,1,"independent raw supply APR, disclosed Julian year and <=1bps truncation");
        assertApproxEqAbs(a.investedAssets(),v.convertToAssets(IERC20(m).balanceOf(address(a))),2);
        assertEq(a.externalMarketTVL(),assets);
        emit ActualEuler(v.asset(),m,actualForkPin,assets,debt,fee,rate,nominal365,julian,a.currentAPYBps(),a.totalAssets());
    }
    function _run(address m) internal {
        _runOn(1,m);
    }
    function _runOn(uint256 chain,address m) internal {
        actualForkPin=chain==1?PIN:520094008;vm.createSelectFork(chain==1?RPC:"https://arbitrum-one.public.blastapi.io",actualForkPin);assertEq(block.chainid,chain);
        address token=IActualEVault(m).asset();uint256 amount=1000e6;
        address holder=token==0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48?0x55FE002aefF02F77364de339a1292923A15844B8:HOLDER;
        if(chain==42161)holder=0xB38e8c17e38363aF6EbdCb3dAE12e0243582891D;
        address[] memory markets=new address[](1);markets[0]=m;
        Adapter a=Adapter(payable(deployCode("EulerUsdcMultiMarket.sol:EulerUsdcMultiMarketAdapter")));
        a.initialize(address(this),token,markets,address(0),address(this));a.initializeMarkets();
        assertLe(address(a).code.length,23552);
        uint256 beforeHolder=IERC20(token).balanceOf(holder);uint256 supply=IERC20(token).totalSupply();
        uint256 beforeSelf=IERC20(token).balanceOf(address(this));assertGe(beforeHolder,amount);
        vm.prank(holder);IERC20(token).safeTransfer(address(this),amount);
        assertEq(IERC20(token).balanceOf(holder),beforeHolder-amount);assertEq(IERC20(token).balanceOf(address(this))-beforeSelf,amount);
        assertEq(IERC20(token).totalSupply(),supply);emit ActualFunding(token,holder,beforeHolder,amount,IERC20(token).balanceOf(holder));
        _observe(a,m);assertTrue(a.isPushMode());IERC20(token).safeTransfer(address(a),amount);a.deposit(amount);
        assertApproxEqAbs(a.totalAssets(),amount,2);_observe(a,m);
        _harvestActualAccruedInterest(a,m,token,chain,amount);
        uint256 before=IERC20(token).balanceOf(address(this));uint256 paid=a.withdraw(amount/4,address(this));
        assertEq(paid,amount/4);assertEq(IERC20(token).balanceOf(address(this))-before,paid);_observe(a,m);
        before=IERC20(token).balanceOf(address(this));uint256 remaining=a.totalAssets();
        a.emergencyPullAllToVault();assertApproxEqAbs(IERC20(token).balanceOf(address(this))-before,remaining,2);
        assertLe(a.totalAssets(),2);assertLe(IERC20(m).balanceOf(address(a)),2);_observe(a,m);
    }
    function _harvestActualAccruedInterest(Adapter a,address m,address token,uint256 chain,uint256 principal) internal {
        uint256 beforeTime=vm.getBlockTimestamp();assertLe(a.harvestableProfit(),2,"first deposit cannot fabricate earned interest");
        // Preserve only the scenario-modified position/book and underlying while
        // advancing to a real later header. Interest uses the real EVault debt,
        // rate and elapsed seconds; no transfer is used to fabricate profit.
        vm.makePersistent(address(a));vm.makePersistent(m);vm.makePersistent(token);
        actualForkPin+=chain==1?4000:100000;vm.rollFork(actualForkPin);
        uint256 elapsed=vm.getBlockTimestamp()-beforeTime;assertGt(elapsed,0);
        uint256 live=IActualEVault(m).convertToAssets(IERC20(m).balanceOf(address(a)));
        assertGt(live,principal,"real borrower interest must accrue");
        uint256 earned=live-principal;assertEq(a.harvestableProfit(),earned);
        uint256 before=IERC20(token).balanceOf(address(this));uint256 supply=IERC20(token).totalSupply();
        uint256 realized=a.harvest(address(this));assertEq(realized,earned,"actual earned interest delivered");
        assertEq(IERC20(token).balanceOf(address(this))-before,realized);assertEq(IERC20(token).totalSupply(),supply);
        assertApproxEqAbs(a.totalAssets(),principal,2,"harvesting interest must preserve deposited principal");assertLe(a.harvestableProfit(),2);
        emit ActualEarnedEulerInterest(token,m,actualForkPin,elapsed,principal,earned,realized);
    }
}
