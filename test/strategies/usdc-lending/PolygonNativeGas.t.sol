// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {
    ReadOnlyGasEstimator as E,
    IMeasurements,
    IFeeInfo,
    IFeed
} from "../../../src/strategies/usdc-lending/gas/ReadOnlyGasEstimator.sol";

import {Feed, Samples} from "./ReadOnlyGasEstimator.t.sol";
import {NativeL1FeeInfo} from "../../../src/strategies/usdc-lending/gas/NativeL1FeeInfo.sol";

contract PolygonNativeFeeSourceTest is Test {
    function test_polygonMeasured117GweiPrioritySupported() public {
        vm.chainId(137);vm.fee(242977417725);
        // Public20-block feeHistory ending96622546 has max90th-percentile117gwei.
        NativeL1FeeInfo source=new NativeL1FeeInfo(4096,117 gwei);
        (uint256 fixedFee,uint256 perByte,,,,uint256 price)=source.getPricesInWei();
        assertEq(fixedFee,0);assertEq(perByte,0);assertEq(price,359977417725);
    }
    function test_nativeSource137ConstructorAndReplay() public {
        vm.chainId(137);
        NativeL1FeeInfo source = new NativeL1FeeInfo(4096, 1 gwei);
        assertEq(source.chainId(),137);
        vm.chainId(1);
        vm.expectRevert("chain mismatch");
        source.getPricesInWei();
    }

    // ── Polygon 137 priority-cap boundary tests ───────────────────────────────

    function test_polygon137_zeroPriorityRejected() public {
        vm.chainId(137);
        vm.expectRevert("invalid priority");
        new NativeL1FeeInfo(4096, 0);
    }

    function test_polygon137_1000GweiPlus1Rejected() public {
        vm.chainId(137);
        vm.expectRevert("invalid priority");
        new NativeL1FeeInfo(4096, 1000 gwei + 1);
    }

    function test_polygon137_exact1000GweiAccepted() public {
        vm.chainId(137);
        NativeL1FeeInfo source = new NativeL1FeeInfo(4096, 1000 gwei);
        assertEq(source.priorityFeeWei(), 1000 gwei);
    }

    function test_ethereum1_exact100GweiAccepted() public {
        vm.chainId(1);
        NativeL1FeeInfo source = new NativeL1FeeInfo(4096, 100 gwei);
        assertEq(source.priorityFeeWei(), 100 gwei);
    }

    function test_ethereum1_100GweiPlus1Rejected() public {
        vm.chainId(1);
        vm.expectRevert("invalid priority");
        new NativeL1FeeInfo(4096, 100 gwei + 1);
    }

    function test_bsc56_exact100GweiAccepted() public {
        vm.chainId(56);
        NativeL1FeeInfo source = new NativeL1FeeInfo(4096, 100 gwei);
        assertEq(source.priorityFeeWei(), 100 gwei);
    }

    function test_bsc56_100GweiPlus1Rejected() public {
        vm.chainId(56);
        vm.expectRevert("invalid priority");
        new NativeL1FeeInfo(4096, 100 gwei + 1);
    }
}

contract PolygonNativeGasTest is Test {
    E e;
    Feed pol;
    NativeL1FeeInfo fees;
    Samples samples;

    // Benchmark config identical to ReadOnlyGasEstimator.t.sol setUp — NOT production calibration.
    E.Config internal BASE_CONFIG = E.Config(
        400000, 150000, 200000, 1000000, 2000000, 23112, 132, 2500, 3600, 3600, 3600, 1e6
    );

    function setUp() public {
        vm.chainId(137);
        vm.warp(1800000000);
        pol  = new Feed(10_000_000); // 0.1 USD at 8 decimals
        fees = new NativeL1FeeInfo(4096, 1 gwei);
        samples = new Samples();
        e = new E(fees, pol, IFeed(address(0)), IFeed(address(0)), BASE_CONFIG);
    }

    // ── constructor ───────────────────────────────────────────────────────────

    function test_estimatorCtor137UsesRealNativeSource() public view {
        assertEq(address(e.sequencer()), address(0));
        assertEq(address(e.feeInfo()), address(fees));
    }

    function test_polygonTotalFeeAboveExistingEstimatorCeilingRemainsUnreliable() public {
        vm.fee(1 gwei);
        NativeL1FeeInfo upper=new NativeL1FeeInfo(4096,1000 gwei);
        E bounded=new E(upper,pol,IFeed(address(0)),IFeed(address(0)),BASE_CONFIG);
        (bool valid,,)=bounded.validatedPrices();assertTrue(valid,"native oracle remains valid");
        E.Quote memory q=bounded.estimate(address(samples),plan(1),2,true);
        assertFalse(q.reliable,"basefee plus priority above1000gwei must retain existing fee guard");
    }

    function test_ctor137_zeroSeq_validatedPricesReturnsTrue() public view {
        (bool valid, uint256 p,) = e.validatedPrices();
        assertTrue(valid);
        // 0.1 USD at 8 dec normalised to 18 dec
        assertEq(p, uint256(10_000_000) * 1e10);
    }

    // ── price range for POL ───────────────────────────────────────────────────

    function test_realFormat_0point1USD_POL_quote_independentCeilMath() public {
        E.Quote memory q = e.estimate(address(samples), plan(1), 2, true);
        assertTrue(q.reliable);
        uint256 expectedGas=1796224;
        uint256 executionPrice=block.basefee+1 gwei;
        if(tx.gasprice>executionPrice)executionPrice=tx.gasprice;
        uint256 executionWei=expectedGas*executionPrice;
        assertEq(q.l2Gas,expectedGas);
        assertEq(q.executionWei,executionWei);
        assertEq(q.posterWei,0);
        assertEq(q.txCount,2);
        // Independent ceiling-math replication (same pattern as existing zero-poster test).
        uint256 eth = uint256(10_000_000) * 1e10;
        uint256 usdWei = executionWei * eth;
        // mulDiv UP
        uint256 usdWeiUp = (usdWei + 1e18 - 1) / 1e18;
        uint256 usd6 = (usdWeiUp + 1e12 - 1) / 1e12;
        uint256 expected = (usd6 * 12500 + 9999) / 10000; // 2500 bps margin, rounded up
        assertEq(q.costUSDC, expected);
    }

    function test_staleFeedRejects() public {
        pol.set(10_000_000, block.timestamp - 3601);
        (bool valid,,) = e.validatedPrices();
        assertFalse(valid);
        assertFalse(e.estimate(address(samples), plan(2), 2, true).reliable);
    }

    function test_negativeFeedRejects() public {
        pol.set(-1, block.timestamp);
        (bool valid,,) = e.validatedPrices();
        assertFalse(valid);
    }

    function test_tooLowFeedRejects_below0point0001USD() public {
        // 0.00009 USD → 9000 at 8 dec → normalised 9e13 < 1e14 (floor)
        pol.set(9000, block.timestamp);
        (bool valid,,) = e.validatedPrices();
        assertFalse(valid);
        assertFalse(e.estimate(address(samples), plan(2), 2, true).reliable);
    }

    function test_tooHighFeedRejects_above1000USD() public {
        // 1001 USD → 100_100_000_000 at 8 dec → normalised > 1000e18 (ceiling)
        pol.set(100_100_000_000, block.timestamp);
        (bool valid,,) = e.validatedPrices();
        assertFalse(valid);
    }

    function test_boundaryLow_0point0001USD_accepted() public {
        // exactly 0.0001 USD → 10000 at 8 dec → normalised 1e14 == low → accepted
        pol.set(10000, block.timestamp);
        (bool valid,uint256 p,) = e.validatedPrices();
        assertTrue(valid);
        assertEq(p, 1e14);
    }

    function test_boundaryHigh_1000USD_accepted() public {
        // exactly 1000 USD → 100_000_000_000 at 8 dec → normalised 1000e18 == high → accepted
        pol.set(100_000_000_000, block.timestamp);
        (bool valid, uint256 p,) = e.validatedPrices();
        assertTrue(valid);
        assertEq(p, 1000e18);
    }

    // ── replay protection ─────────────────────────────────────────────────────

    function test_chainReplayRejects() public {
        (bool valid,,) = e.validatedPrices();
        assertTrue(valid);
        // Simulate contract called on a different chain than deployed — must fail closed.
        vm.chainId(1);
        (valid,,) = e.validatedPrices();
        assertFalse(valid);
        assertFalse(e.estimate(address(samples), plan(2), 2, true).reliable);
    }

    // ── Ethereum chain 1 preserves $100 lower bound ───────────────────────────

    function test_ETH1_stillRejects_0point1USD_nativePrice() public {
        vm.chainId(1);
        Feed ethFeed = new Feed(10_000_000); // 0.1 USD — below the $100 ETH floor
        NativeL1FeeInfo ethFees = new NativeL1FeeInfo(4096, 1 gwei);
        E eth1 = new E(ethFees, ethFeed, IFeed(address(0)), IFeed(address(0)), BASE_CONFIG);
        (bool valid,,) = eth1.validatedPrices();
        assertFalse(valid);
        assertFalse(eth1.estimate(address(samples), plan(2), 2, true).reliable);
    }

    function test_ETH1_accepts_3000USD_nativePrice() public {
        vm.chainId(1);
        Feed ethFeed = new Feed(3000e8);
        NativeL1FeeInfo ethFees = new NativeL1FeeInfo(4096, 1 gwei);
        E eth1 = new E(ethFees, ethFeed, IFeed(address(0)), IFeed(address(0)), BASE_CONFIG);
        (bool valid,,) = eth1.validatedPrices();
        assertTrue(valid);
    }

    // ── L2 chains still reject zero sequencer ────────────────────────────────

    function test_L2Chains_10_8453_42161_rejectZeroSeq() public {
        Feed f    = new Feed(2000e8);
        NativeL1FeeInfo fee = new NativeL1FeeInfo(4096, 1 gwei);
        uint256[3] memory chains = [uint256(10), 8453, 42161];
        for (uint256 i; i < 3; ++i) {
            vm.chainId(chains[i]);
            vm.expectRevert("dependency");
            new E(fee, f, IFeed(address(0)), IFeed(address(0)), BASE_CONFIG);
        }
    }

    // ── codeless EOA rejected everywhere ─────────────────────────────────────

    function test_codelessEoa_feeInfo_rejected() public {
        // chain is 137 (setUp); EOA has no code → feeInfo check fails
        address eoa = address(0xdead);
        vm.expectRevert("dependency");
        new E(IFeeInfo(eoa), pol, IFeed(address(0)), IFeed(address(0)), BASE_CONFIG);
    }

    function test_codelessEoa_ethUSD_rejected() public {
        address eoa = address(0xdead);
        vm.expectRevert("dependency");
        new E(fees, IFeed(eoa), IFeed(address(0)), IFeed(address(0)), BASE_CONFIG);
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function plan(uint256 n) internal pure returns (E.Action[] memory a) {
        a = new E.Action[](n);
        for (uint256 i; i < n; i++) {
            a[i] = E.Action(address(uint160(i + 1)), 100e6, i % 2 == 0);
        }
    }
}
