// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VenusUsdcMultiMarketAdapter as Adapter} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/VenusUsdcMultiMarket.sol";
interface IActualVenus {function underlying() external view returns(address);function exchangeRateStored() external view returns(uint256);function supplyRatePerBlock() external view returns(uint256);function getCash() external view returns(uint256);function totalBorrows() external view returns(uint256);function totalReserves() external view returns(uint256);function interestRateModel() external view returns(address);}
contract VenusActualAssetsTest is Test {
    using SafeERC20 for IERC20;
    uint256 pin;uint256 chain;uint256 slots;
    event ActualVenus(address token,address market,uint256 chainId,uint256 rpcBlock,uint8 decimals,uint256 annualSlots,uint256 ratePerSlot,uint256 independentAprBps,uint256 position);
    event ActualVenusBalanceSheet(address market,uint256 cash,uint256 borrows,uint256 reserves,uint256 badDebt,uint256 netSuppliedAssets);
    event ActualFunding(address token,address holder,uint256 beforeBalance,uint256 amount,uint256 afterBalance);
    function test_actualVenusArbitrumUsdcLifecycleAndTimeBasedRate() public {_run("https://arbitrum-one.public.blastapi.io",520094008,42161,0x7D8609f8da70fF9027E9bc5229Af4F6727662707,0xB38e8c17e38363aF6EbdCb3dAE12e0243582891D,1000e6);}
    function test_actualVenusBscUsdcLifecycleAndLegacyRate() public {_run("https://bsc-mainnet.public.blastapi.io",45000000,56,0xecA88125a5ADbe82614ffC12D0DB554E2e2867C8,0xF977814e90dA44bFA03b6295A0616a897441aceC,1000e18);}
    function test_actualVenusBscUsdtLifecycleAndLegacyRate() public {_run("https://bsc-mainnet.public.blastapi.io",45000000,56,0xfD5840Cd36d94D7229439859C0112a4185BC0255,0xF977814e90dA44bFA03b6295A0616a897441aceC,100e18);}
    function test_actualVenusBscCurrentUsdcLifecycleAndRate() public {_run("https://bsc-mainnet.public.blastapi.io",131080000,56,0xecA88125a5ADbe82614ffC12D0DB554E2e2867C8,0xF977814e90dA44bFA03b6295A0616a897441aceC,1000e18);}
    function test_actualVenusBscCurrentUsdtLifecycleAndRate() public {_run("https://bsc-mainnet.public.blastapi.io",131080000,56,0xfD5840Cd36d94D7229439859C0112a4185BC0255,0xF977814e90dA44bFA03b6295A0616a897441aceC,100e18);}
    function _actualSlots(address m) internal view returns(uint256) {
        (bool ok,bytes memory raw)=m.staticcall(abi.encodeWithSignature("blocksOrSecondsPerYear()"));
        if(!ok||raw.length<32){(ok,raw)=IActualVenus(m).interestRateModel().staticcall(abi.encodeWithSignature("blocksPerYear()"));}
        if(!ok||raw.length<32){(ok,raw)=IActualVenus(m).interestRateModel().staticcall(abi.encodeWithSignature("BLOCKS_PER_YEAR()"));}
        require(ok&&raw.length>=32,"actual rate-model annual normalization required");uint256 n=abi.decode(raw,(uint256));require(n>0&&n<=200_000_000);return n;
    }
    function _observe(Adapter a,address m) internal {
        IActualVenus v=IActualVenus(m);address token=v.underlying();uint256 rate=v.supplyRatePerBlock();uint256 expected=rate*slots/1e14;if(expected>type(uint16).max)expected=type(uint16).max;
        assertEq(a.currentAPYBps(),expected,"independent real per-slot supply APR");
        uint256 exchange=v.exchangeRateStored();uint256 badDebt;
        (bool ok,bytes memory raw)=m.staticcall(abi.encodeWithSignature("badDebt()"));if(ok&&raw.length>=32)badDebt=abi.decode(raw,(uint256));
        // Isolated Venus retains recognized bad debt in its book exchange rate;
        // legacy core markets have no badDebt getter. Record this credit exposure.
        uint256 net=v.getCash()+v.totalBorrows()+badDebt-v.totalReserves();
        assertApproxEqAbs(IERC20(m).totalSupply()*exchange/1e18,net,1,"independent lender-share liability vs protocol net assets");
        assertApproxEqAbs(a.externalMarketTVL(),net,1,"external supplied TVL excludes protocol-owned reserves");
        assertEq(a.investedAssets(),IERC20(m).balanceOf(address(a))*exchange/1e18,"actual vToken exchange-rate NAV");
        emit ActualVenus(token,m,chain,pin,IERC20Metadata(token).decimals(),slots,rate,expected,a.totalAssets());
        emit ActualVenusBalanceSheet(m,v.getCash(),v.totalBorrows(),v.totalReserves(),badDebt,net);
    }
    function _run(string memory rpc,uint256 blockPin,uint256 chainId,address m,address holder,uint256 amount) internal {
        pin=blockPin;chain=chainId;vm.createSelectFork(rpc,pin);assertEq(block.chainid,chain);address token=IActualVenus(m).underlying();slots=_actualSlots(m);
        Adapter a=Adapter(payable(deployCode("VenusUsdcMultiMarket.sol:VenusUsdcMultiMarketAdapter")));a.initialize(token,address(this),address(this),0,m,slots);assertLe(address(a).code.length,23552);assertEq(a.blocksPerYear(),slots);
        assertEq(a.accrueVenusInterest(),0,"actual interest maintenance must succeed");
        uint256 beforeHolder=IERC20(token).balanceOf(holder);uint256 supply=IERC20(token).totalSupply();uint256 beforeSelf=IERC20(token).balanceOf(address(this));assertGe(beforeHolder,amount);
        vm.prank(holder);IERC20(token).safeTransfer(address(this),amount);assertEq(IERC20(token).balanceOf(holder),beforeHolder-amount);assertEq(IERC20(token).balanceOf(address(this))-beforeSelf,amount);assertEq(IERC20(token).totalSupply(),supply);
        emit ActualFunding(token,holder,beforeHolder,amount,IERC20(token).balanceOf(holder));
        _observe(a,m);IERC20(token).forceApprove(address(a),amount);a.deposit(amount);
        // vTokens have eight share decimals even when the asset has eighteen.
        // Bound the actual mint rounding by one raw share at its observed rate.
        uint256 quantum=IActualVenus(m).exchangeRateStored()/1e18+1;
        assertLe(a.totalAssets(),amount);assertLe(amount-a.totalAssets(),quantum);assertGt(a.totalAssets(),0);_observe(a,m);
        uint256 before=IERC20(token).balanceOf(address(this));uint256 paid=a.withdraw(amount/4,address(this));assertEq(paid,amount/4);assertEq(IERC20(token).balanceOf(address(this))-before,paid);_observe(a,m);
        before=IERC20(token).balanceOf(address(this));uint256 remaining=a.totalAssets();a.emergencyPullAllToVault();
        assertApproxEqAbs(IERC20(token).balanceOf(address(this))-before,remaining,2);assertLe(a.totalAssets(),2);assertLe(IERC20(m).balanceOf(address(a)),2);_observe(a,m);
    }
}
