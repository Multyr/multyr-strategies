// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RateTestAsset} from "./AdapterRateRemediation.t.sol";
import {MorphoUsdcMultiMarketAdapter} from "../../../src/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol";

contract OversizedMorphoRegistry {
    address public immutable asset;
    constructor(address a) { asset = a; }
    function getEnabledVaults(uint8) external view returns (address[] memory markets) {
        markets = new address[](256);
        for (uint256 i; i < markets.length; ++i) markets[i] = address(this);
    }
}

contract MorphoRegistryBoundTest is Test {
    function test_registryCannotBypassManualMarketCountBound() public {
        RateTestAsset asset = new RateTestAsset(18);
        MorphoUsdcMultiMarketAdapter adapter = MorphoUsdcMultiMarketAdapter(payable(deployCode(
            "MorphoUsdcMultiMarket.sol:MorphoUsdcMultiMarketAdapter")));
        OversizedMorphoRegistry registry = new OversizedMorphoRegistry(address(asset));
        vm.expectRevert(bytes("too many markets"));
        adapter.initialize(address(asset), address(this), address(this), type(uint256).max, address(registry));
    }
}
