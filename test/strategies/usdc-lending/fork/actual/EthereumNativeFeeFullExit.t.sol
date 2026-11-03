// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FullUserExitE2EBase} from "./FullUserExitE2E.t.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    ReadOnlyGasEstimator as E,
    IMeasurements,
    IFeeInfo,
    IFeed
} from "@multyr-strategies/strategies/usdc-lending/gas/ReadOnlyGasEstimator.sol";
import {StrategySettingsModule as Settings} from
    "@multyr-strategies/strategies/usdc-lending/controller/StrategySettingsModule.sol";

/// Extends FullUserExitE2EBase with an Ethereum native-fee gas estimator.
/// Deploys and wires a real ReadOnlyGasEstimator backed by the Chainlink
/// ETH/USD feed and a NativeL1FeeInfo (no poster cost, tip = 1 gwei).
/// Verifies the cold-start quote independently before running the full
/// two-user/two-epoch lifecycle under the configured model.
/// No vm.mockCall/deal/etch/store/warp or synthetic gas price.
abstract contract EthereumNativeFeeFullExitBase is FullUserExitE2EBase {
    E internal actualE;

    event NativeFeeRawContext(
        uint256 chainId,
        uint256 blockNumber,
        uint256 basefee,
        uint256 sourcePricePerGas,
        uint256 txGasPrice
    );
    event NativeFeeRawFees(uint256 perTx, uint256 perByte, uint256 l2Price);
    event NativeFeeEthPrice(
        uint80 round,
        int256 answer,
        uint256 updatedAt,
        uint8 decimals,
        uint256 priceWad
    );
    event NativeFeeExpected(
        uint256 expectedGas,
        uint256 executionWei,
        uint256 posterWei,
        uint256 usdWei,
        uint256 usd6,
        uint256 costUSDC
    );
    event NativeFeeActualQuote(
        uint256 l2Gas,
        uint256 executionWei,
        uint256 posterWei,
        uint256 txCount,
        uint256 costUSDC,
        bool reliable,
        bool usedDefaults
    );

    function _afterFullExitAdapterConfigured() internal override {
        // Deploy NativeL1FeeInfo: perTx=0, tip=1 gwei → l2Price = block.basefee + 1 gwei
        address feeInfoAddr = _new(
            "NativeL1FeeInfo.sol:NativeL1FeeInfo",
            abi.encode(uint256(4096), uint256(1 gwei))
        );

        // Illustrative benchmark coefficients; not production calibration.
        E.Config memory cfg = E.Config(
            400000, 150000, 200000, 1000000, 2000000, 23112, 132, 2500, 3600, 3600, 3600, 1e6
        );
        // Zero sequencer is valid on Ethereum (chainId=1); zero legacyUSDquoteFeed is valid.
        actualE = E(
            _new(
                "ReadOnlyGasEstimator.sol:ReadOnlyGasEstimator",
                abi.encode(
                    IFeeInfo(feeInfoAddr),
                    IFeed(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419),
                    IFeed(address(0)),
                    IFeed(address(0)),
                    cfg
                )
            )
        );

        assertLe(address(actualE).code.length, 23552, "estimator within lending runtime budget");

        Settings(address(strategy)).setRebalanceGasEstimator(address(actualE));

        _runColdQuoteAssertions(feeInfoAddr);
    }

    function _runColdQuoteAssertions(address feeInfoAddr) internal {
        // Cold start: adapter has no deposit gas observations yet.
        (uint32 coldCount,) = IMeasurements(address(strategy)).depositGasObservation(address(adapter));
        assertEq(coldCount, 0, "cold start: no deposit gas observations");

        E.Action[] memory actions = new E.Action[](1);
        actions[0] = E.Action(address(adapter), 10 ** market.decimals, true);
        E.Quote memory q = actualE.estimate(address(strategy), actions, uint8(2), true);

        _verifyQuote(q, feeInfoAddr);
    }

    function _verifyQuote(E.Quote memory q, address feeInfoAddr) internal {
        // Independent reference: sourceprice = block.basefee + 1 gwei (tip from NativeL1FeeInfo).
        uint256 sourcePrice = block.basefee + 1 gwei;
        uint256 executionPrice = tx.gasprice > sourcePrice ? tx.gasprice : sourcePrice;

        // From config literals:
        // prepareGas(400000) + intrinsicGas*txCount(23112*2) + stepGas(150000)
        // + defaultDepositGas(1000000) + finalizeGas(200000) = 1796224
        uint256 expectedGas = 1796224;
        uint256 expectedExecution = expectedGas * executionPrice;

        _verifyFeedAndCost(q, feeInfoAddr, expectedGas, expectedExecution);
    }

    function _verifyFeedAndCost(
        E.Quote memory q,
        address feeInfoAddr,
        uint256 expectedGas,
        uint256 expectedExecution
    ) internal {
        IFeed ethFeed = IFeed(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        uint8 feedDecimals = ethFeed.decimals();
        (uint80 ethRound, int256 ethAnswer,, uint256 ethUpdated, uint80 ethAnswered) =
            ethFeed.latestRoundData();

        assertGt(ethAnswer, 0, "ETH/USD feed positive answer");
        assertGe(ethAnswered, ethRound, "ETH/USD feed round answered");
        assertLe(block.timestamp - ethUpdated, 3600, "ETH/USD feed fresh at fork block");

        uint256 priceWad = uint256(ethAnswer) * 10 ** (18 - feedDecimals);

        // USD6: three ceil steps with 25 percent margin.
        uint256 usdWei = Math.mulDiv(expectedExecution, priceWad, 1e18, Math.Rounding.Up);
        uint256 usd6 = Math.ceilDiv(usdWei, 1e12);
        uint256 expectedCost = Math.mulDiv(usd6, 12500, 10000, Math.Rounding.Up);

        // Emit raw context for off-chain audit trail.
        (,,,,,uint256 l2PriceFromFeeInfo) = IFeeInfo(feeInfoAddr).getPricesInWei();
        emit NativeFeeRawContext(block.chainid, block.number, block.basefee, block.basefee + 1 gwei, tx.gasprice);
        emit NativeFeeRawFees(0, 0, l2PriceFromFeeInfo);
        emit NativeFeeEthPrice(ethRound, ethAnswer, ethUpdated, feedDecimals, priceWad);
        emit NativeFeeExpected(expectedGas, expectedExecution, 0, usdWei, usd6, expectedCost);
        emit NativeFeeActualQuote(q.l2Gas, q.executionWei, q.posterWei, q.txCount, q.costUSDC, q.reliable, q.usedDefaults);

        // Asset metadata from real strategy and token (separate from Quote fields).
        assertEq(IERC20Metadata(market.asset).decimals(), uint8(market.decimals), "token decimals match market");
        assertEq(strategy.asset(), market.asset, "strategy asset matches market");

        // Quote field assertions (Quote struct has no asset/currency/sampleCount fields).
        assertEq(q.l2Gas, expectedGas, "l2Gas matches literal config sum");
        assertEq(q.txCount, 2, "txCount: 1 prepare + 1 step");
        assertEq(q.posterWei, 0, "posterWei zero on L1 native model");
        assertEq(q.executionWei, expectedExecution, "executionWei from basefee+1gwei");
        assertEq(q.costUSDC, expectedCost, "costUSDC three-ceil USD6 with 25pct margin");
        assertTrue(q.reliable, "quote reliable with valid ETH/USD feed");
        assertTrue(q.usedDefaults, "usedDefaults at cold start");
        assertEq(actualE.quoteCurrency(), bytes32("USD6"), "quoteCurrency is USD6");
    }
}

contract EthereumNativeFeeFullExitTest is EthereumNativeFeeFullExitBase {
    function test_nativeFeeFullExit_usdt() public { _fullExitScenario(false); }
    function test_nativeFeeFullExit_weth() public { _fullExitScenario(true); }
}
