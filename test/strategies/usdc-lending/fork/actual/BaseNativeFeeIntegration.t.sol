// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {LendingUnmockedE2EBase} from "../LendingUnmockedE2E.fork.t.sol";
import {StrategySettingsModule as Settings} from "@multyr-strategies/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {IOPGasPriceOracle} from "@multyr-strategies/strategies/usdc-lending/gas/OPStackFeeInfo.sol";
import {ReadOnlyGasEstimator as E, IFeed, IMeasurements} from "@multyr-strategies/strategies/usdc-lending/gas/ReadOnlyGasEstimator.sol";

/// @dev Base-only fork integration: real GPO precompile, real ETH/USD Chainlink feed,
///      actual OPStackFeeInfo + ReadOnlyGasEstimator deployed into the live fork.
///      No mock/etch/deal/warp. Config coefficients illustrative, not production calibration.
///      Derives LendingUnmockedE2EBase so the full real-asset epoch lifecycle runs after
///      each gas estimation assertion.
contract BaseNativeFeeIntegrationTest is LendingUnmockedE2EBase {
    IOPGasPriceOracle constant GPO =
        IOPGasPriceOracle(0x420000000000000000000000000000000000000F);
    IFeed constant ETH_FEED  = IFeed(0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70);
    IFeed constant SEQUENCER_FEED = IFeed(0xBCF85224fc0756B9Fa45aA7892530B47e10b6433);

    event BaseFeeContext(uint256 chainId, uint256 rpcBlock, uint256 evmBlock,
        uint256 timestamp, uint256 priceUpdatedAt, uint256 sequencerStartedAt);

    event BaseFeeRawData(
        uint256 blockBasefee,
        uint256 l1Upper,
        uint256 opConst,
        uint256 opSample,
        uint256 l2Price,
        uint256 ethAnswer,
        uint8   ethDecimals,
        uint256 ethPriceWAD
    );
    event BaseFeeExpected(
        uint256 expectedL2Gas,
        uint256 expectedPosterWei,
        uint256 expectedExecWei,
        uint256 rawWei,
        uint256 expectedUSD6
    );
    event BaseFeeActual(
        uint256 costUSD6,
        uint256 l2Gas,
        uint256 posterWei,
        uint256 execWei,
        uint256 sampleCount,
        bool    reliable,
        bool    usedDefaults
    );

    address internal gasEstimator;

    function test_baseNativeFeesUsdc() public { _scenario(8453, false); }
    function test_baseNativeFeesWeth()  public { _scenario(8453, true);  }

    function _afterAdapterConfigured() internal override {
        // Deploy OPStackFeeInfo against the real Base GPO precompile.
        address helper = _new(
            "OPStackFeeInfo.sol:OPStackFeeInfo",
            abi.encode(GPO, uint256(4096), uint256(1 gwei))
        );

        // Deploy ReadOnlyGasEstimator with illustrative config coefficients.
        E.Config memory cfg = E.Config(400000,150000,200000,1000000,2000000,23112,132,2500,3600,3600,3600,1e6);
        gasEstimator = _new(
            "ReadOnlyGasEstimator.sol:ReadOnlyGasEstimator",
            abi.encode(helper, address(ETH_FEED), address(0), address(SEQUENCER_FEED), cfg)
        );
        assertLe(helper.code.length, 23552);
        assertLe(gasEstimator.code.length, 23552);

        // Wire into strategy settings.
        Settings(address(strategy)).setRebalanceGasEstimator(gasEstimator);

        // Run raw-reference verification before lifecycle proceeds.
        _verifyBaseFeeEstimate();
    }

    function _verifyBaseFeeEstimate() internal {
        // ── Raw GPO reads ────────────────────────────────────────────────────
        // maxCalldataBytes(4096) + RLP overhead(256) = 4352 bytes per OPStackFeeInfo.getPricesInWei
        uint256 l1Upper  = GPO.getL1FeeUpperBound(4352);
        uint256 opConst  = GPO.getOperatorFee(0);
        uint256 opSample = GPO.getOperatorFee(1_000_000);
        assertGe(opSample, opConst, "operator fee must be monotone non-decreasing");

        // ── ETH/USD feed freshness ───────────────────────────────────────────
        uint8 feedDecimals = ETH_FEED.decimals();
        (, int256 ethAnswer,, uint256 ethUpdatedAt,) = ETH_FEED.latestRoundData();
        assertGt(ethAnswer, 0,                          "ETH feed answer must be positive");
        assertLe(ethUpdatedAt, block.timestamp,         "ETH feed updatedAt must not be future");
        assertGe(ethUpdatedAt + 3_600, block.timestamp, "ETH feed must be fresh within staleness bound");
        (, int256 sequencerStatus, uint256 sequencerStartedAt,,) = SEQUENCER_FEED.latestRoundData();
        assertEq(sequencerStatus, 0);
        assertGt(sequencerStartedAt, 0);
        assertLt(sequencerStartedAt, block.timestamp);
        assertGt(block.timestamp - sequencerStartedAt, 3600);
        emit BaseFeeContext(block.chainid,rpcForkBlock,block.number,block.timestamp,ethUpdatedAt,sequencerStartedAt);

        // ── Independent arithmetic: do NOT derive expected from quote ────────
        //
        // l2Price = basefee + priorityFee(1 gwei) + ceil((opSample - opConst) / 1e6)
        uint256 opPerGas       = Math.ceilDiv(opSample - opConst, 1_000_000);
        uint256 l2Price        = block.basefee + 1 gwei + opPerGas;
        // perTx = getL1FeeUpperBound(4352) + getOperatorFee(0)
        uint256 perTx          = l1Upper + opConst;
        // perByte = 1 (second slot from getPricesInWei)
        // expectedL2Gas: base + 2*txOverhead + deposit + withdrawal + allocCalc
        uint256 expectedL2Gas  = 400_000 + 2 * 23_112 + 200_000 + 150_000 + 1_000_000; // = 1_796_224
        // poster: txCount(2) * (perTx + calldataBytes(132) * perByte(1))
        uint256 expectedPoster = 2 * (perTx + 132);
        uint256 effectiveGasPrice = tx.gasprice > l2Price ? tx.gasprice : l2Price;
        uint256 expectedExec   = expectedL2Gas * effectiveGasPrice;
        // ETH price in WAD from feed (feed is 8 decimals → multiply by 1e10)
        uint256 ethPriceWAD    = uint256(ethAnswer) * (10 ** (18 - uint256(feedDecimals)));
        uint256 rawWei         = expectedExec + expectedPoster;
        // Convert wei cost to USD with 18-decimal intermediate, then to USD6
        uint256 usdWad         = Math.mulDiv(rawWei, ethPriceWAD, 1e18, Math.Rounding.Up);
        uint256 usd6Base       = Math.ceilDiv(usdWad, 1e12);
        // Apply 25% margin (2500 bps = marginBps from config)
        uint256 expectedUSD6   = Math.mulDiv(usd6Base, 12_500, 10_000, Math.Rounding.Up);

        emit BaseFeeRawData(
            block.basefee, l1Upper, opConst, opSample,
            l2Price, uint256(ethAnswer), feedDecimals, ethPriceWAD
        );
        emit BaseFeeExpected(expectedL2Gas, expectedPoster, expectedExec, rawWei, expectedUSD6);

        // ── Actual estimator call ────────────────────────────────────────────
        uint256 unit = 10 ** market.decimals;
        E.Action[] memory actions = new E.Action[](1);
        actions[0] = E.Action(address(adapter), unit, true);
        (uint32 sampleCount,) = IMeasurements(address(strategy)).depositGasObservation(address(adapter));
        E.Quote memory q = E(gasEstimator).estimate(address(strategy), actions, 2, true);

        emit BaseFeeActual(
            q.costUSDC, q.l2Gas, q.posterWei, q.executionWei,
            sampleCount, q.reliable, q.usedDefaults
        );

        // ── Cold-start EMA assertions ────────────────────────────────────────
        assertEq(sampleCount, 0,   "cold-start EMA must report zero samples");
        assertTrue(q.usedDefaults,   "cold-start must use configured defaults");

        // ── Gas component assertions ─────────────────────────────────────────
        assertEq(q.l2Gas,        expectedL2Gas,   "L2 gas must match config derivation");
        assertEq(q.posterWei,    expectedPoster,  "poster fee must match GPO reads");
        assertEq(q.executionWei, expectedExec,    "execution wei must match l2Gas * effectivePrice");
        assertEq(q.costUSDC,     expectedUSD6,    "USD6 cost must match independent arithmetic");
        assertEq(q.txCount, 2);

        // ── Reliability and asset metadata ───────────────────────────────────
        assertTrue(q.reliable,                          "estimate must be reliable with fresh feeds");
        assertEq(E(gasEstimator).quoteCurrency(), bytes32("USD6"));
        assertEq(strategy.asset(), market.asset);
        assertEq(IERC20Metadata(market.asset).decimals(), market.decimals);
    }
}
