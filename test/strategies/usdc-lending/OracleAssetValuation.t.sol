// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IParamsProvider} from "@multyr-core/interfaces/IParamsProvider.sol";
import {IPriceOracleMiddleware} from "@multyr-core/interfaces/IPriceOracleMiddleware.sol";
import {OracleValuationLib} from "@multyr-core/core/libraries/OracleValuationLib.sol";
import {StrategyParamsModule} from "../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";

contract OracleAssetMetadataMock {
    uint8 public immutable decimals;
    constructor(uint8 decimals_) { decimals = decimals_; }
}

contract OracleQuoteMock {
    uint256 public priceWad;
    uint48 public updatedAt;
    bool public fresh = true;

    function set(uint256 priceWad_, uint48 updatedAt_, bool fresh_) external {
        priceWad = priceWad_;
        updatedAt = updatedAt_;
        fresh = fresh_;
    }

    function getQuote(address) external view returns (IPriceOracleMiddleware.Quote memory quote) {
        quote = IPriceOracleMiddleware.Quote(priceWad, 8, updatedAt, fresh);
    }
}

contract OracleParamsMock {
    address public oracle;
    uint256 public maxStaleness = 1 hours;

    function setOracle(address oracle_) external { oracle = oracle_; }

    function oracleConfigFor(address, address) external view returns (address, uint256) {
        return (oracle, maxStaleness);
    }
}

contract OracleCoreMock {
    IParamsProvider public immutable params;
    constructor(address params_) { params = IParamsProvider(params_); }
}

contract OneRawUnitTvlMock {
    function externalMarketTVL() external pure returns (uint256) { return 1; }
}

contract TvlValuationHarness is StrategyParamsModule {
    constructor(address asset_, address core_, address adapter_) StrategyParamsModule(asset_, core_) {
        _grantRole(KEEPER_ROLE, msg.sender);
        adapters.push(adapter_);
        enabled[adapter_] = true;
    }
}

contract OracleAssetValuationTest is Test {
    uint256 constant USD_WAD = 1e18;

    OracleQuoteMock internal quote;
    OracleParamsMock internal params;
    OracleCoreMock internal core;

    function setUp() public {
        quote = new OracleQuoteMock();
        params = new OracleParamsMock();
        params.setOracle(address(quote));
        core = new OracleCoreMock(address(params));
        quote.set(USD_WAD, uint48(block.timestamp), true);
    }

    function _module(uint8 decimals_) internal returns (StrategyParamsModule) {
        OracleAssetMetadataMock asset = new OracleAssetMetadataMock(decimals_);
        return new StrategyParamsModule(address(asset), address(core));
    }

    function test_usdcOneDollarUnitPreservesSixDecimalScale() public {
        assertEq(_module(6).usdUnitInAsset(), 1e6);
        assertEq(_module(6).usd6ToAssetUnits(25_000e6), 25_000e6);
    }

    function test_wethDollarScaleTracksPriceAndRoundsUp() public {
        StrategyParamsModule module = _module(18);
        quote.set(3_000e18, uint48(block.timestamp), true);
        assertEq(module.usd6ToAssetUnits(1), 333_333_334);
        assertEq(module.usd6ToAssetUnits(25_000e6), 8_333_333_333_333_333_334);

        quote.set(1_500e18, uint48(block.timestamp), true);
        assertEq(module.usd6ToAssetUnits(25_000e6), 16_666_666_666_666_666_667);
    }

    function test_staleOracleFailsClosed() public {
        StrategyParamsModule module = _module(18);
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(abi.encodeWithSelector(
            OracleValuationLib.OracleDataStale.selector,
            address(quote),
            2 hours,
            1 hours
        ));
        module.usdUnitInAsset();
    }

    function test_lowDecimalHighPriceTiersUseWholeAmountValue() public {
        _assertLowDecimalTiers();
    }

    function test_tvlMaximumDoesNotRoundAnUpperBoundUpToOneAssetUnit() public {
        OracleAssetMetadataMock asset = new OracleAssetMetadataMock(2);
        OneRawUnitTvlMock adapter = new OneRawUnitTvlMock();
        TvlValuationHarness module = new TvlValuationHarness(address(asset), address(core), address(adapter));
        quote.set(10_000_000_000_000e18, uint48(block.timestamp), true);
        assertEq(module.assetUnitsToUsd6(1), 100_000_000_000e6);
        module.pokeExternalTVL();
        assertEq(module.cachedExternalTVL(address(adapter)), 0);
        assertEq(module.cachedExternalTVLTs(address(adapter)), 0);
    }

    function _assertLowDecimalTiers() internal {
        StrategyParamsModule module = _module(2);
        quote.set(3_000e18, uint48(block.timestamp), true);
        assertEq(module.assetUnitsToUsd6(3_333), 99_990e6);
        assertEq(module.tierRelativeCap(3_333), 0);
        assertEq(module.tierRelativeCap(3_334), 200);
        assertEq(module.tierMaxAdapters(833, 5), 1);
        assertEq(module.tierMaxAdapters(834, 5), 2);
        assertEq(module.tierSeed(834, 0), 4); // $100 rounds once to 0.04 tokens.
        quote.set(USD_WAD, uint48(block.timestamp), true);
    }

    function test_missingOracleFailsClosed() public {
        StrategyParamsModule module = _module(18);
        params.setOracle(address(0));
        vm.expectRevert(abi.encodeWithSelector(
            OracleValuationLib.OracleNotConfigured.selector,
            address(module.ASSET())
        ));
        module.usdUnitInAsset();
    }

    function test_zeroOraclePriceFailsClosed() public {
        StrategyParamsModule module = _module(18);
        quote.set(0, uint48(block.timestamp), true);
        vm.expectRevert(abi.encodeWithSelector(
            OracleValuationLib.OracleDataStale.selector,
            address(quote),
            0,
            1 hours
        ));
        module.usdUnitInAsset();
    }
}
