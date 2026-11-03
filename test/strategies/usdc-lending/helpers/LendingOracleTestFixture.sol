// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IParamsProvider} from "@multyr-core/interfaces/IParamsProvider.sol";
import {IPriceOracleMiddleware} from "@multyr-core/interfaces/IPriceOracleMiddleware.sol";

contract LendingTestPriceOracle {
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

contract LendingTestParamsProvider {
    address public immutable oracle;
    uint256 public immutable maxStaleness;

    constructor(address oracle_, uint256 maxStaleness_) {
        oracle = oracle_;
        maxStaleness = maxStaleness_;
    }

    function oracleConfigFor(address, address) external view returns (address, uint256) {
        return (oracle, maxStaleness);
    }
}

contract LendingTestCoreOracleSource {
    IParamsProvider public immutable params;
    constructor(address params_) { params = IParamsProvider(params_); }
}

/// @dev Unit-test-only Core/GlobalConfig oracle wiring. Production paths remain fail-closed.
abstract contract LendingOracleTestFixture is Test {
    function _newOracleCore(uint256 priceWad) internal returns (address core) {
        LendingTestPriceOracle oracle = new LendingTestPriceOracle();
        oracle.set(priceWad, uint48(block.timestamp), true);
        // Unit-test fixture remains valid across suites that warp block.timestamp.
        // Oracle staleness behavior is covered separately with an explicitly bounded config.
        LendingTestParamsProvider provider = new LendingTestParamsProvider(address(oracle), type(uint256).max);
        core = address(new LendingTestCoreOracleSource(address(provider)));
    }
}
