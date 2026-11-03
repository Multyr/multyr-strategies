// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolRegistry} from "@multyr-strategies/strategies/usdc-lending/registry/ProtocolRegistry.sol";
import {AaveV3USDCAdapter as Aave} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol";
import {CometUsdcMultiMarketAdapter as Comet} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol";
import {MorphoUsdcMultiMarketAdapter as Morpho} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol";
import {EulerUsdcMultiMarketAdapter as Euler} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol";
import {FluidUsdcMultiMarketAdapter as Fluid} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/FluidUsdcMultiMarket.sol";
import {DolomiteUsdcMultiMarketAdapter as Dolomite} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol";
import {VenusUsdcMultiMarketAdapter as Venus} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/VenusUsdcMultiMarket.sol";

interface IMatrixDirectAdapter {
    function deposit(uint256) external;
    function withdraw(uint256,address) external returns (uint256);
    function emergencyPullAllToVault() external;
    function totalAssets() external view returns (uint256);
    function investedAssets() external view returns (uint256);
    function externalMarketTVL() external view returns (uint256);
    function currentAPYBps() external view returns (uint16);
}
interface IMatrixDirectVault {
    function convertToAssets(uint256) external view returns (uint256);
    function totalAssets() external view returns (uint256);
}
interface IMatrixDirectFeed {
    function latestRoundData() external view returns (uint80,int256,uint256,uint256,uint80);
    function decimals() external view returns (uint8);
}

/// Separate technical compatibility from the strategy's unchanged allocation policy.
contract ArbitrumAssetDirectTest is Test {
    using SafeERC20 for IERC20Metadata;
    uint256 family;
    address underlying;
    address venue;
    address receipt;
    address[] keep;
    event ActualMatrixDirect(uint256 family,address asset,address market,uint256 pin,uint256 supplied,uint256 externalAssets,uint16 aprBps,uint256 position);
    event ActualMatrixDirectFunding(address asset,address holder,uint256 beforeBalance,uint256 amount,uint256 afterBalance);
    event ActualMatrixDirectRecall(uint256 family,address asset,uint256 partialPaid,uint256 finalRecall,uint256 residual);
    event ActualMatrixDirectRate(uint256 family,address asset,uint256 independentAprBps,uint16 observedAprBps);
    event ActualMatrixReceiptQuantum(address asset,address market,uint256 assetUnitsPerReceiptQuantum);

    function _new(string memory artifact,bytes memory args) internal returns(address a) {
        bytes memory creation=abi.encodePacked(vm.getCode(artifact),args);
        bytes32 salt=keccak256(abi.encode("ARBITRUM_ASSET_DIRECT_20261103",family,underlying,keep.length,artifact));
        assembly ("memory-safe"){a:=create2(0,add(creation,32),mload(creation),salt)}
        assertGt(a.code.length,0);assertLe(a.code.length,24576);assertEq(IERC20Metadata(underlying).balanceOf(a),0,"new fixture must not inherit a canonical token donation");keep.push(a);
    }
    function test_arbitrumRealAssetDirectLifecycle() public {
        family=vm.envUint("MATRIX_FAMILY");underlying=vm.envAddress("MATRIX_ASSET");venue=vm.envAddress("MATRIX_MARKET");
        receipt=vm.envOr("MATRIX_RECEIPT",address(0));uint256 pin=vm.envOr("MATRIX_PIN_BLOCK",uint256(514200000));
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"),pin-100000);assertEq(block.chainid,42161);
        IMatrixDirectAdapter a=IMatrixDirectAdapter(_adapter());
        uint256 pps;uint256 ts;
        if(family==2||family==4||family==5){pps=IMatrixDirectVault(venue).convertToAssets(1e24);ts=vm.getBlockTimestamp();_poke(address(a));}
        vm.makePersistent(keep);vm.rollFork(pin);
        if(pps>0){
            uint256 next=IMatrixDirectVault(venue).convertToAssets(1e24);
            uint256 expected=next>pps?Math.mulDiv(next-pps,315360000000,pps)/(vm.getBlockTimestamp()-ts):0;
            if(expected>type(uint16).max)expected=type(uint16).max;
            assertEq(a.currentAPYBps(),expected,"independent historical PPS APR");_poke(address(a));
        }
        if(family==6)assertEq(Venus(payable(address(a))).accrueVenusInterest(),0);
        IERC20Metadata token=IERC20Metadata(underlying);
        IMatrixDirectFeed feed=IMatrixDirectFeed(vm.envAddress("MATRIX_FEED"));
        (,int256 answer,,uint256 updated,)=feed.latestRoundData();assertGt(answer,0);assertLe(updated,vm.getBlockTimestamp());assertLt(vm.getBlockTimestamp()-updated,1 days);
        uint256 amount=Math.mulDiv(1000*10**token.decimals(),10**feed.decimals(),uint256(answer),Math.Rounding.Up);
        address holder=vm.envAddress("MATRIX_HOLDER");uint256 hb=token.balanceOf(holder);uint256 before=token.balanceOf(address(this));uint256 supply=token.totalSupply();
        assertGe(hb,amount);vm.prank(holder);token.safeTransfer(address(this),amount);
        assertEq(token.balanceOf(holder),hb-amount);assertEq(token.balanceOf(address(this))-before,amount);assertEq(token.totalSupply(),supply);
        emit ActualMatrixDirectFunding(underlying,holder,hb,amount,token.balanceOf(holder));
        _observe(a,pin,amount);
        if(family==3)token.safeTransfer(address(a),amount);else token.forceApprove(address(a),amount);
        a.deposit(amount);
        uint256 depositRounding=2;
        if(family==6){
            // A vToken has 8 decimals even when WETH has 18. One raw receipt
            // quantum can therefore exceed two wei; derive its bound on-chain.
            uint256 quantum=Math.ceilDiv(_read(venue,abi.encodeWithSignature("exchangeRateStored()")),1e18);
            if(quantum>depositRounding)depositRounding=quantum;
            emit ActualMatrixReceiptQuantum(underlying,venue,quantum);
        }
        assertApproxEqAbs(a.totalAssets(),amount,depositRounding,"NAV bounded by actual receipt rounding");_observe(a,pin,amount);
        assertGt(a.investedAssets(),0,"real capital must enter the protocol, not remain adapter idle");
        assertApproxEqAbs(a.investedAssets(),amount,depositRounding,"actual receipt position must back the funded amount");
        before=token.balanceOf(address(this));uint256 paid=a.withdraw(amount/4,address(this));
        assertEq(paid,amount/4,"real partial withdrawal");assertEq(token.balanceOf(address(this))-before,paid);
        uint256 left=a.totalAssets();before=token.balanceOf(address(this));a.emergencyPullAllToVault();uint256 recalled=token.balanceOf(address(this))-before;
        assertApproxEqAbs(recalled,left,2,"real full recall");assertLe(a.totalAssets(),2);
        emit ActualMatrixDirectRecall(family,underlying,paid,recalled,a.totalAssets());
    }
    function _adapter() internal returns(address a) {
        if(family==0){a=_new("AaveV3USDCmarket.sol:AaveV3USDCAdapter",bytes(""));Aave(payable(a)).initialize(underlying,venue,receipt,address(this),address(this),0);return a;}
        if(family==3){address[] memory ms=new address[](1);ms[0]=venue;a=_new("EulerUsdcMultiMarket.sol:EulerUsdcMultiMarketAdapter",bytes(""));Euler(payable(a)).initialize(address(this),underlying,ms,address(0),address(this));Euler(payable(a)).initializeMarkets();return a;}
        if(family==4){a=_new("FluidUsdcMultiMarket.sol:FluidUsdcMultiMarketAdapter",bytes(""));Fluid(payable(a)).initialize(underlying,address(this),address(this),0,venue);return a;}
        if(family==6){a=_new("VenusUsdcMultiMarket.sol:VenusUsdcMultiMarketAdapter",bytes(""));Venus(payable(a)).initialize(underlying,address(this),address(this),0,venue,31536000);return a;}
        ProtocolRegistry r=ProtocolRegistry(_new("ProtocolRegistry.sol:ProtocolRegistry",abi.encode(address(this))));
        ProtocolRegistry.ProtocolType t=family==1?ProtocolRegistry.ProtocolType.COMPOUND_V3:family==2?ProtocolRegistry.ProtocolType.MORPHO:ProtocolRegistry.ProtocolType.DOLOMITE;
        r.addVault(t,venue,"actual Arbitrum asset",1000,type(uint128).max);
        if(family==1){a=_new("CometUsdcMultiMarket.sol:CometUsdcMultiMarketAdapter",bytes(""));Comet(payable(a)).initialize(underlying,address(this),address(this),0,address(r));}
        else if(family==2){a=_new("MorphoUsdcMultiMarket.sol:MorphoUsdcMultiMarketAdapter",bytes(""));Morpho(payable(a)).initialize(underlying,address(this),address(this),0,address(r));if(vm.envOr("MATRIX_V2",false))Morpho(payable(a)).setVaultV2LiquidityView(_new("MorphoVaultV2LiquidityView.sol:MorphoVaultV2LiquidityView",bytes("")));}
        else {require(family==5,"unknown family");a=_new("DolomiteUsdcMultiMarket.sol:DolomiteUsdcMultiMarketAdapter",bytes(""));Dolomite(payable(a)).initialize(underlying,address(this),address(this),0,address(r));}
    }
    function _poke(address a) internal {
        if(family==2)Morpho(payable(a)).pokeAPYSnapshots();
        else if(family==4)Fluid(payable(a)).pokeAPYSnapshots();
        else if(family==5)Dolomite(payable(a)).pokeAPYSnapshots();
    }
    function _observe(IMatrixDirectAdapter a,uint256 pin,uint256 supplied) internal {
        if(family==2||family==3||family==4||family==5){
            assertEq(a.externalMarketTVL(),IMatrixDirectVault(venue).totalAssets());
            assertApproxEqAbs(a.investedAssets(),IMatrixDirectVault(venue).convertToAssets(IERC20Metadata(venue).balanceOf(address(a))),2,"independent receipt NAV");
        }
        uint256 expected;
        if(family==0){
            (bool ok,bytes memory raw)=venue.staticcall(abi.encodeWithSignature("getReserveData(address)",underlying));require(ok&&raw.length>=96,"real Aave reserve data");
            uint256 rate;assembly ("memory-safe"){rate:=mload(add(raw,96))}expected=rate/1e23;
            assertEq(a.externalMarketTVL(),IERC20Metadata(receipt).totalSupply());assertEq(a.investedAssets(),IERC20Metadata(receipt).balanceOf(address(a)));
        }else if(family==1){
            uint256 utilization=_read(venue,abi.encodeWithSignature("getUtilization()"));
            expected=_read(venue,abi.encodeWithSignature("getSupplyRate(uint256)",utilization))*31536000/1e14;
            assertEq(a.externalMarketTVL(),IERC20Metadata(venue).totalSupply());assertEq(a.investedAssets(),IERC20Metadata(venue).balanceOf(address(a)));
        }else if(family==3){
            uint256 assets=IMatrixDirectVault(venue).totalAssets();uint256 debt=_read(venue,abi.encodeWithSignature("totalBorrows()"));uint256 fee=_read(venue,abi.encodeWithSignature("interestFee()"));assertLe(fee,10000);
            expected=_read(venue,abi.encodeWithSignature("interestRate()"))*31557600*debt*(10000-fee)/(1e27*assets);
        }else if(family==6){
            uint256 slots=_read(venue,abi.encodeWithSignature("blocksOrSecondsPerYear()"));assertEq(slots,31536000);
            expected=_read(venue,abi.encodeWithSignature("supplyRatePerBlock()"))*slots/1e14;
            uint256 exchange=_read(venue,abi.encodeWithSignature("exchangeRateStored()"));
            uint256 net=_read(venue,abi.encodeWithSignature("getCash()"))+_read(venue,abi.encodeWithSignature("totalBorrows()"))+_read(venue,abi.encodeWithSignature("badDebt()"))-_read(venue,abi.encodeWithSignature("totalReserves()"));
            assertApproxEqAbs(a.externalMarketTVL(),net,1,"Venus lender TVL net of reserves");
            assertEq(a.investedAssets(),Math.mulDiv(IERC20Metadata(venue).balanceOf(address(a)),exchange,1e18));
        }
        if(family==0||family==1||family==3||family==6){
            if(expected>type(uint16).max)expected=type(uint16).max;
            assertApproxEqAbs(a.currentAPYBps(),expected,family==3?1:0,"independent protocol supply APR");
            emit ActualMatrixDirectRate(family,underlying,expected,a.currentAPYBps());
        }
        emit ActualMatrixDirect(family,underlying,venue,pin,supplied,a.externalMarketTVL(),a.currentAPYBps(),a.totalAssets());
    }
    function _read(address target,bytes memory data) internal view returns(uint256){
        (bool ok,bytes memory raw)=target.staticcall(data);require(ok&&raw.length>=32,"real protocol getter required");return abi.decode(raw,(uint256));
    }
}
