// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AaveV3USDCAdapter} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol";
import {WstEthUsdPriceFeed} from "@multyr-strategies/strategies/usdc-lending/oracles/WstEthUsdPriceFeed.sol";

interface IRealFeedV3 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80,int256,uint256,uint256,uint80);
}

contract AaveAdditionalRealAssetsTest is Test {
    using SafeERC20 for IERC20;
    address constant POOL=0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    uint256 constant START=26300000;
    uint256 constant END=26310000;
    string constant RPC="https://eth-mainnet.public.blastapi.io";
    event ActualMarketObservation(address asset,uint256 rpcBlock,uint256 timestamp,uint8 decimals,
        uint256 protocolSupply,uint256 protocolCash,uint256 liquidityRateRay,uint16 adapterAprBps,
        int256 priceAnswer,uint8 feedDecimals,uint256 priceUpdatedAt,uint256 position,uint256 positionUsd6);
    event ActualHolderTransfer(address asset,address holder,uint256 holderBefore,uint256 transferred,uint256 holderAfter);
    event ActualIndexReference(address asset,uint256 scaledReceiptBalance,uint256 normalizedIncome,uint256 independentlyCalculatedAssets);

    function test_actualEthereumUsdtLifecycleAndRate() public {
        _lifecycle(0xdAC17F958D2ee523a2206206994597C13D831ec7,
            0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a,
            0x3E7d1eAB13ad0104d2750B8863b489D65364e32D,
            0xF977814e90dA44bFA03b6295A0616a897441aceC);
    }

    function test_actualEthereumPyusdLifecycleAndRate() public {
        _lifecycle(0x6c3ea9036406852006290770BEdFcAbA0e23A0e8,
            0x0C0d01AbF3e6aDfcA0989eBbA9d6e85dD58EaB1E,
            0x8f1dF6D7F2db73eECE86a18b4381F4707b918FB1,
            0xAFBb1a7E9ddEf38D9bC4A220E702B18DAcaa2a62);
    }

    function test_actualEthereumWstEthLifecycleAndRate() public {
        vm.createSelectFork(RPC,START);
        WstEthUsdPriceFeed feed=new WstEthUsdPriceFeed(
            0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0,
            0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8);
        vm.makePersistent(address(feed));
        _lifecycle(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0,
            0x0B925eD163218f6662a35e0f0371Ac234f9E9371,address(feed),
            0x634F07A674F75A0973B5D7F6Bc3809CDE8367cB8,2e18,1e18);
    }

    function test_actualEthereumRlusdLifecycleAndRate() public {
        _lifecycle(0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD,
            0xFa82580c16A31D0c1bC632A36F82e83EfEF3Eec0,
            0x26C46B7aD0012cA71F2298ada567dC9Af14E7f2A,
            0xF977814e90dA44bFA03b6295A0616a897441aceC);
    }

    function _reserve(address asset) internal view returns(bytes memory data) {
        (bool ok,bytes memory raw)=POOL.staticcall(abi.encodeWithSignature("getReserveData(address)",asset));
        require(ok && raw.length==480,"published legacy reserve ABI");
        return raw;
    }
    function _word(bytes memory data,uint256 index) internal pure returns(uint256 value) {
        assembly("memory-safe") { value := mload(add(add(data,32),mul(index,32))) }
    }

    function _observe(address asset,address receipt,address feed,AaveV3USDCAdapter adapter,uint256 rpcBlock) internal {
        bytes memory data=_reserve(asset);
        assertEq(address(uint160(_word(data,8))),receipt,"official receipt and live pool disagree");
        uint256 rate=_word(data,2);
        uint256 expected=rate/1e23; // Aave reports an annual liquidity rate in RAY, not a per-second borrow rate.
        if(expected>type(uint16).max) expected=type(uint16).max;
        assertEq(adapter.currentAPYBps(),expected,"independent actual Aave supply APR reference");
        uint256 supply=IERC20(receipt).totalSupply();
        assertEq(adapter.externalMarketTVL(),supply,"actual external supply units");
        uint256 position=adapter.totalAssets();
        assertApproxEqAbs(adapter.investedAssets(),IERC20(receipt).balanceOf(address(adapter)),1);
        this.assertIndexedReference(asset,receipt,adapter);
        (uint80 round,int256 answer,,uint256 updated,uint80 answered)=IRealFeedV3(feed).latestRoundData();
        assertGt(answer,0); assertGe(answered,round); assertLe(updated,block.timestamp);
        assertLe(block.timestamp-updated,1 days,"actual price must satisfy production freshness");
        uint8 d=IERC20Metadata(asset).decimals(); uint8 fd=IRealFeedV3(feed).decimals();
        uint256 usd6=Math.mulDiv(position,uint256(answer)*1e6,(10**uint256(d))*(10**uint256(fd)));
        emit ActualMarketObservation(asset,rpcBlock,block.timestamp,d,supply,IERC20(asset).balanceOf(receipt),
            rate,adapter.currentAPYBps(),answer,fd,updated,position,usd6);
    }

    function assertIndexedReference(address asset,address receipt,AaveV3USDCAdapter adapter) external {
        require(msg.sender==address(this), "self-only reference");
        (bool scaledOk,bytes memory scaledData)=receipt.staticcall(abi.encodeWithSignature("scaledBalanceOf(address)",address(adapter)));
        (bool indexOk,bytes memory indexData)=POOL.staticcall(abi.encodeWithSignature("getReserveNormalizedIncome(address)",asset));
        require(scaledOk && indexOk,"actual scaled balance/index API");
        uint256 scaled=abi.decode(scaledData,(uint256)); uint256 income=abi.decode(indexData,(uint256));
        // Independent Aave RAY multiplication with half-up rounding, using two
        // actual protocol observations rather than the adapter's valuation code.
        uint256 referenceAssets=Math.mulDiv(scaled,income,1e27);
        if(mulmod(scaled,income,1e27)>=5e26) ++referenceAssets;
        assertApproxEqAbs(adapter.investedAssets(),referenceAssets,1,"independent scaled-receipt NAV reference");
        emit ActualIndexReference(asset,scaled,income,referenceAssets);
    }

    function _lifecycle(address asset,address receipt,address feed,address holder) internal {
        vm.createSelectFork(RPC,START);
        uint256 unit=10**uint256(IERC20Metadata(asset).decimals());
        _lifecycle(asset,receipt,feed,holder,1000*unit,500*unit);
    }

    function _lifecycle(address asset,address receipt,address feed,address holder,uint256 funding,uint256 amount) internal {
        vm.createSelectFork(RPC,START);
        assertEq(block.chainid,1); assertEq(holder.code.length,0,"funding must use an actual EOA");
        uint256 unit=10**uint256(IERC20Metadata(asset).decimals());
        uint256 holderBefore=IERC20(asset).balanceOf(holder); uint256 supplyBefore=IERC20(asset).totalSupply();
        assertGe(holderBefore,funding);
        vm.prank(holder); IERC20(asset).safeTransfer(address(this),funding);
        assertEq(IERC20(asset).balanceOf(holder),holderBefore-funding);
        assertEq(IERC20(asset).totalSupply(),supplyBefore,"no synthetic funding");
        emit ActualHolderTransfer(asset,holder,holderBefore,funding,IERC20(asset).balanceOf(holder));
        AaveV3USDCAdapter adapter=AaveV3USDCAdapter(payable(deployCode("AaveV3USDCmarket.sol:AaveV3USDCAdapter")));
        assertLe(address(adapter).code.length,23552);
        adapter.initialize(asset,POOL,receipt,address(this),address(this),10_000_000*unit);
        _observe(asset,receipt,feed,adapter,START);
        IERC20(asset).forceApprove(address(adapter),amount);
        adapter.deposit(amount);
        uint256 invested=adapter.totalAssets(); assertApproxEqAbs(invested,amount,2);
        assertGt(invested,0);

        // Coherent closed counterfactual market: preserve pool, asset, receipt and
        // its debt tokens, while real historical Chainlink rounds advance. This
        // is not a replay of intervening canonical transactions or historical ROI.
        bytes memory reserve=_reserve(asset);
        address[] memory keep=new address[](4);
        keep[0]=asset;keep[1]=POOL;keep[2]=receipt;keep[3]=address(adapter);
        vm.makePersistent(keep);
        for(uint256 i=9;i<=10;++i){address debt=address(uint160(_word(reserve,i)));if(debt.code.length>0)vm.makePersistent(debt);}
        vm.rollFork(END);
        uint256 accrued=adapter.totalAssets();
        assertGe(accrued,invested,"actual indexed position must remain accounted");
        uint256 before=IERC20(asset).balanceOf(address(this));
        uint256 paid=adapter.withdraw(amount/5,address(this));
        assertEq(paid,amount/5);assertEq(IERC20(asset).balanceOf(address(this))-before,paid);
        _observe(asset,receipt,feed,adapter,END);
        before=IERC20(asset).balanceOf(address(this));
        uint256 remainder=adapter.totalAssets();assertGt(remainder,0);
        adapter.emergencyPullAllToVault();
        assertApproxEqAbs(IERC20(asset).balanceOf(address(this))-before,remainder,2);
        assertLe(adapter.totalAssets(),2);assertLe(IERC20(receipt).balanceOf(address(adapter)),2);
        _observe(asset,receipt,feed,adapter,END);
    }
}
