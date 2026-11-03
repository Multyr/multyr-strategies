// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {PriceOracleMiddleware} from "@multyr-core/core/modules/PriceOracleMiddleware.sol";
import {WstEthUsdPriceFeed} from "@multyr-strategies/strategies/usdc-lending/oracles/WstEthUsdPriceFeed.sol";
interface IActualStEthUsd {
    function decimals() external view returns(uint8);
    function latestRoundData() external view returns(uint80,int256,uint256,uint256,uint80);
}
interface IActualNativeWstEth {
    function stEthPerToken() external view returns(uint256);
}
/// Real native conversion and Chainlink rounds, with the unchanged Core oracle.
contract WstEthOracleActualTest is Test {
    address constant WSTETH=0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant STETH_USD=0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    address constant LEGACY_WSTETH_USD=0x8B6851156023f4f5A66F68BEA80851c3D905Ac93;
    event ActualWstEthPrice(uint256 rpcBlock,uint80 round,int256 stEthUsdAnswer,uint256 conversion,
        int256 wrapperAnswer,uint256 updatedAt,uint256 corePriceWad);
    function setUp() public {
        vm.createSelectFork("https://eth-mainnet.public.blastapi.io",26300000);
        assertEq(block.chainid,1);
    }
    function _oracle() internal returns(PriceOracleMiddleware){
        return PriceOracleMiddleware(deployCode("PriceOracleMiddleware.sol:PriceOracleMiddleware",abi.encode(address(this))));
    }
    function test_actualNativeConversionAndFrozenCoreOracleAgree() public {
        WstEthUsdPriceFeed wrapped=new WstEthUsdPriceFeed(WSTETH,STETH_USD);
        assertLe(address(wrapped).code.length,23552);
        (uint80 round,int256 answer,uint256 started,uint256 updated,uint80 answered)=IActualStEthUsd(STETH_USD).latestRoundData();
        assertGt(answer,0);assertGt(updated,0);assertLe(updated,block.timestamp);assertLe(block.timestamp-updated,1 days);assertGe(answered,round);
        uint256 rate=IActualNativeWstEth(WSTETH).stEthPerToken();assertGt(rate,0);
        assertLe(uint256(answer),type(uint256).max/rate);
        uint256 expected=uint256(answer)*rate/1e18;
        (uint80 r,int256 price,uint256 st,uint256 up,uint80 ar)=wrapped.latestRoundData();
        assertEq(r,round);assertEq(st,started);assertEq(up,updated);assertEq(ar,answered);
        assertEq(uint256(price),expected);assertEq(wrapped.decimals(),8);
        PriceOracleMiddleware oracle=_oracle();oracle.setOracleFeed(WSTETH,address(wrapped),1 days);
        uint256 corePrice=oracle.getQuoteFresh(WSTETH).price;
        assertEq(corePrice,expected*1e10,"frozen Core must normalize actual USD price to18 decimals");
        emit ActualWstEthPrice(block.number,round,answer,rate,price,updated,corePrice);
    }
    function test_actualLegacyLatestAnswerOnlyFeedCannotMasqueradeAsRoundFeed() public {
        (bool legacyRoundOk,)=LEGACY_WSTETH_USD.staticcall(abi.encodeWithSignature("latestRoundData()"));
        assertFalse(legacyRoundOk,"official legacy adapter lacks round metadata");
        PriceOracleMiddleware oracle=_oracle();
        vm.expectRevert(bytes4(keccak256("InvalidPrice()")));
        oracle.setOracleFeed(WSTETH,LEGACY_WSTETH_USD,1 days);
    }
}
