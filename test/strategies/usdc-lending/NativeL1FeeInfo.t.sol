// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {NativeL1FeeInfo} from "../../../src/strategies/usdc-lending/gas/NativeL1FeeInfo.sol";
import {
    ReadOnlyGasEstimator as E,
    IFeeInfo,
    IFeed
} from "../../../src/strategies/usdc-lending/gas/ReadOnlyGasEstimator.sol";
// Import helper contracts from existing fixture; do NOT inherit the test class.
import {Feed, Samples} from "./ReadOnlyGasEstimator.t.sol";

contract NativeL1FeeInfoTest is Test {
    // Illustrative benchmark config — NOT approved production calibration.
    // 12 fields: prepareGas, stepGas, finalizeGas, defaultDepositGas, defaultWithdrawGas,
    //            intrinsicGas, calldataBytes, marginBps, maxPriceAge, usdcMaxPriceAge,
    //            sequencerGrace, fallbackUSDC
    E.Config internal cfg = E.Config(
        400000, 150000, 200000, 1000000, 2000000, 23112, 132, 2500, 3600, 3600, 3600, 1e6
    );

    // ── NativeL1FeeInfo constructor validation ────────────────────────────────

    function test_nativeL1SourceRejectsUnsupportedChain() public {
        vm.chainId(31337);
        vm.expectRevert("unsupported chain");
        new NativeL1FeeInfo(512, 1 gwei);

        vm.chainId(42161);
        vm.expectRevert("unsupported chain");
        new NativeL1FeeInfo(512, 1 gwei);

        vm.chainId(8453);
        vm.expectRevert("unsupported chain");
        new NativeL1FeeInfo(512, 1 gwei);

        vm.chainId(10);
        vm.expectRevert("unsupported chain");
        new NativeL1FeeInfo(512, 1 gwei);
    }

    function test_nativeL1SourceRejectsBadSize() public {
        vm.chainId(1);
        vm.expectRevert("invalid size");
        new NativeL1FeeInfo(511, 1 gwei);

        vm.expectRevert("invalid size");
        new NativeL1FeeInfo(65536, 1 gwei);

        // Boundary values must succeed.
        new NativeL1FeeInfo(512, 1 gwei);
        new NativeL1FeeInfo(65535, 1 gwei);
    }

    function test_nativeL1SourceRejectsInvalidPriority() public {
        vm.chainId(1);
        vm.expectRevert("invalid priority");
        new NativeL1FeeInfo(512, 0);

        vm.expectRevert("invalid priority");
        new NativeL1FeeInfo(512, 100 gwei + 1);

        // Boundary values must succeed.
        new NativeL1FeeInfo(512, 1);
        new NativeL1FeeInfo(512, 100 gwei);
    }

    function test_nativeL1SourceImmutablesStoredCorrectly() public {
        vm.chainId(1);
        NativeL1FeeInfo src = new NativeL1FeeInfo(1024, 3 gwei);
        assertEq(src.chainId(), 1);
        assertEq(src.maxCalldataBytes(), 1024);
        assertEq(src.priorityFeeWei(), 3 gwei);
    }

    function test_nativeL1SourceGetPricesRejectsWrongChain() public {
        vm.chainId(1);
        NativeL1FeeInfo src = new NativeL1FeeInfo(512, 2 gwei);

        vm.chainId(42161);
        vm.expectRevert("chain mismatch");
        src.getPricesInWei();
    }

    function test_nativeL1SourceReturnsPrices() public {
        vm.chainId(1);
        NativeL1FeeInfo src = new NativeL1FeeInfo(512, 2 gwei);
        vm.fee(10 gwei);
        (uint256 perTx, uint256 perByte, uint256 a, uint256 b, uint256 c2, uint256 l2Price) =
            src.getPricesInWei();
        assertEq(perTx, 0);
        assertEq(perByte, 0);
        assertEq(a, 0);
        assertEq(b, 0);
        assertEq(c2, 0);
        assertEq(l2Price, 12 gwei); // basefee(10) + priority(2)
    }

    // ── feeInfo code guard: precompile exception ─────────────────────────────

    function test_feeInfoNoCodeRejectedOnL1() public {
        vm.warp(1800000000);
        vm.chainId(1);
        Feed eth = new Feed(3000e8);
        // 0xBEEF: nonzero, no EVM code, not the Arbitrum precompile — must revert on chain 1.
        vm.expectRevert("dependency");
        new E(IFeeInfo(address(0xBEEF)), eth, IFeed(address(0)), IFeed(address(0)), cfg);
    }

    function test_feeInfoNoCodeRejectedOnBSC() public {
        vm.warp(1800000000);
        vm.chainId(56);
        Feed bnb = new Feed(700e8);
        // 0xBEEF: nonzero, no EVM code, not the Arbitrum precompile — must revert on chain 56.
        vm.expectRevert("dependency");
        new E(IFeeInfo(address(0xBEEF)), bnb, IFeed(address(0)), IFeed(address(0)), cfg);
    }

    function test_feeInfoNoCodeRejectedOnArbitrumWhenNotPrecompile() public {
        vm.warp(1800000000);
        vm.chainId(42161);
        Feed eth = new Feed(3000e8);
        Feed seqFeed = new Feed(0); // valid seq: has code, satisfies address(s).code.length > 0
        // 0xBEEF: nonzero, no EVM code, not 0x6c — must revert on chain 42161 even with valid seq.
        vm.expectRevert("dependency");
        new E(IFeeInfo(address(0xBEEF)), eth, IFeed(address(0)), IFeed(address(seqFeed)), cfg);
    }

    function test_feeInfoPrecompile0x6cRejectedOutsideArbitrum() public {
        vm.warp(1800000000);
        Feed eth = new Feed(3000e8);
        Feed seqFeed = new Feed(0);
        assertEq(address(0x6c).code.length, 0);
        uint256[3] memory chains = [uint256(1), uint256(56), uint256(8453)];
        for (uint256 i; i < chains.length; ++i) {
            vm.chainId(chains[i]);
            IFeed seq = chains[i] == 8453 ? IFeed(address(seqFeed)) : IFeed(address(0));
            vm.expectRevert("dependency");
            new E(IFeeInfo(address(0x6c)), eth, IFeed(address(0)), seq, cfg);
        }
    }

    function test_feeInfoPrecompile0x6cAcceptedOnArbitrum() public {
        vm.warp(1800000000);
        vm.chainId(42161);
        Feed eth = new Feed(3000e8);
        Feed seqFeed = new Feed(0); // valid seq feed
        // 0x6c is ArbGasInfo: a native Arbitrum precompile with no EVM code.
        // Construction must succeed on chain 42161 with a valid seq feed; no call made.
        E est = new E(IFeeInfo(address(0x6c)), eth, IFeed(address(0)), IFeed(address(seqFeed)), cfg);
        assertEq(address(est.feeInfo()), address(0x6c));
    }

    // ── ReadOnlyGasEstimator constructor on L1 ────────────────────────────────

    function _deployE(uint256 chainIdVal, address seq, IFeeInfo fi, IFeed nativeFeed)
        internal
        returns (E)
    {
        vm.chainId(chainIdVal);
        return new E(fi, nativeFeed, IFeed(address(0)), IFeed(seq), cfg);
    }

    function test_zeroSeqConstructsOnEthereum() public {
        vm.warp(1800000000);
        vm.chainId(1);
        NativeL1FeeInfo src = new NativeL1FeeInfo(512, 2 gwei);
        Feed eth = new Feed(3000e8);
        // address(0) sequencer is valid on chain 1.
        E est = new E(IFeeInfo(address(src)), eth, IFeed(address(0)), IFeed(address(0)), cfg);
        assertEq(address(est.sequencer()), address(0));
    }

    function test_zeroSeqConstructsOnBSC() public {
        vm.warp(1800000000);
        vm.chainId(56);
        NativeL1FeeInfo src = new NativeL1FeeInfo(512, 2 gwei);
        Feed bnb = new Feed(700e8);
        E est = new E(IFeeInfo(address(src)), bnb, IFeed(address(0)), IFeed(address(0)), cfg);
        assertEq(address(est.sequencer()), address(0));
    }

    function test_zeroSeqRejectsOnL2() public {
        vm.warp(1800000000);
        // Arbitrum One
        vm.chainId(42161);
        Feed eth = new Feed(3000e8);
        // Need a fee source with code; deploy on this chain ID.
        // Use a Feed as a stand-in for feeInfo code presence check (feeInfo only requires != address(0)).
        // Actually feeInfo only requires address(f) != address(0), not code check.
        // So we can pass any non-zero address for feeInfo. But ethUSD needs code.length > 0.
        vm.expectRevert("dependency");
        new E(IFeeInfo(address(1)), eth, IFeed(address(0)), IFeed(address(0)), cfg);

        // Base
        vm.chainId(8453);
        vm.expectRevert("dependency");
        new E(IFeeInfo(address(1)), eth, IFeed(address(0)), IFeed(address(0)), cfg);

        // Optimism
        vm.chainId(10);
        vm.expectRevert("dependency");
        new E(IFeeInfo(address(1)), eth, IFeed(address(0)), IFeed(address(0)), cfg);
    }

    function test_nonzeroCodeEmptySeqRejectsOnL1() public {
        vm.warp(1800000000);
        vm.chainId(1);
        NativeL1FeeInfo src = new NativeL1FeeInfo(512, 2 gwei);
        Feed eth = new Feed(3000e8);
        // address(7) has no code → invalid even on L1.
        vm.expectRevert("dependency");
        new E(IFeeInfo(address(src)), eth, IFeed(address(0)), IFeed(address(7)), cfg);
    }

    // ── Quoting on Ethereum with NativeL1FeeInfo ──────────────────────────────

    function test_ethereumQuoteReliablePositiveExecutionZeroPosting() public {
        vm.warp(1800000000);
        vm.chainId(1);
        NativeL1FeeInfo src = new NativeL1FeeInfo(512, 2 gwei);
        Feed eth = new Feed(3000e8);
        E est = new E(IFeeInfo(address(src)), eth, IFeed(address(0)), IFeed(address(0)), cfg);
        Samples samples = new Samples();

        vm.fee(10 gwei); // basefee = 10 gwei; l2Price = 12 gwei

        E.Action[] memory actions = new E.Action[](2);
        actions[0] = E.Action(address(1), 100e6, false);
        actions[1] = E.Action(address(2), 100e6, true);
        E.Quote memory q = est.estimate(address(samples), actions, 2, true);

        assertTrue(q.reliable, "ETH quote must be reliable");
        assertEq(q.posterWei, 0, "L1 has no posting fee");
        assertGt(q.executionWei, 0, "execution cost must be positive");
        assertEq(q.executionWei, q.l2Gas * 12 gwei, "executionWei = l2Gas * effectiveGasPrice");

        // Verify independent USD6 math: ETH at 3000 USD, marginBps=2500.
        uint256 usdWei = Math.mulDiv(q.executionWei, 3000e18, 1e18, Math.Rounding.Up);
        uint256 usd6 = Math.ceilDiv(usdWei, 1e12);
        uint256 expectedCost = Math.mulDiv(usd6, 12500, 10000, Math.Rounding.Up);
        assertEq(q.costUSDC, expectedCost, "USD6 math must be independent of underlying USDC");
        assertGt(q.costUSDC, cfg.fallbackUSDC, "dynamic quote must exceed fallback");
    }

    function test_bscQuoteReliablePositiveExecutionZeroPosting() public {
        vm.warp(1800000000);
        vm.chainId(56);
        NativeL1FeeInfo src = new NativeL1FeeInfo(512, 2 gwei);
        Feed bnb = new Feed(700e8); // BNB at 700 USD, same 8-decimal feed
        E est = new E(IFeeInfo(address(src)), bnb, IFeed(address(0)), IFeed(address(0)), cfg);
        Samples samples = new Samples();

        vm.fee(10 gwei);

        E.Action[] memory actions = new E.Action[](2);
        actions[0] = E.Action(address(1), 100e6, false);
        actions[1] = E.Action(address(2), 100e6, true);
        E.Quote memory q = est.estimate(address(samples), actions, 2, true);

        assertTrue(q.reliable, "BSC quote must be reliable");
        assertEq(q.posterWei, 0, "L1 has no posting fee");
        assertGt(q.executionWei, 0);
        assertEq(q.executionWei, q.l2Gas * 12 gwei);

        // BNB USD6 math is independent of any USDC peg.
        uint256 usdWei = Math.mulDiv(q.executionWei, 700e18, 1e18, Math.Rounding.Up);
        uint256 usd6 = Math.ceilDiv(usdWei, 1e12);
        uint256 expectedCost = Math.mulDiv(usd6, 12500, 10000, Math.Rounding.Up);
        assertEq(q.costUSDC, expectedCost, "BNB USD6 math independent of underlying USDC");

        // ETH quote at same gas is proportionally higher than BNB quote (3000/700 ratio).
        vm.chainId(1);
        NativeL1FeeInfo ethSrc = new NativeL1FeeInfo(512, 2 gwei);
        Feed ethFeed = new Feed(3000e8);
        E ethEst = new E(IFeeInfo(address(ethSrc)), ethFeed, IFeed(address(0)), IFeed(address(0)), cfg);
        E.Quote memory qEth = ethEst.estimate(address(samples), actions, 2, true);
        assertGt(qEth.costUSDC, q.costUSDC, "ETH quote must be higher than BNB quote at same gas");
        assertEq(qEth.l2Gas, q.l2Gas, "gas estimates are chain-independent");
    }

    // ── Fake chain replay protection ─────────────────────────────────────────

    function test_fakeChainReplayFailsClosed() public {
        vm.warp(1800000000);
        vm.chainId(1);
        NativeL1FeeInfo src = new NativeL1FeeInfo(512, 2 gwei);
        Feed eth = new Feed(3000e8);
        E est = new E(IFeeInfo(address(src)), eth, IFeed(address(0)), IFeed(address(0)), cfg);
        Samples samples = new Samples();

        // Confirm quote is reliable on the correct chain.
        vm.fee(5 gwei);
        E.Action[] memory actions = new E.Action[](2);
        actions[0] = E.Action(address(1), 100e6, false);
        actions[1] = E.Action(address(2), 100e6, true);
        assertTrue(est.estimate(address(samples), actions, 2, true).reliable, "reliable on chain 1");

        // Simulate cross-chain replay: chain ID becomes an L2.
        vm.chainId(42161);
        E.Quote memory q = est.estimate(address(samples), actions, 2, true);
        assertFalse(q.reliable, "cross-chain replay must fail closed");
        assertEq(q.costUSDC, cfg.fallbackUSDC, "fallback cost on replay");
    }

    function test_fakeChainReplayFailsClosedFromBSC() public {
        vm.warp(1800000000);
        vm.chainId(56);
        NativeL1FeeInfo src = new NativeL1FeeInfo(512, 2 gwei);
        Feed bnb = new Feed(700e8);
        E est = new E(IFeeInfo(address(src)), bnb, IFeed(address(0)), IFeed(address(0)), cfg);
        Samples samples = new Samples();

        vm.fee(3 gwei);
        E.Action[] memory actions = new E.Action[](1);
        actions[0] = E.Action(address(1), 100e6, true);
        assertTrue(est.estimate(address(samples), actions, 1, true).reliable, "reliable on chain 56");

        vm.chainId(10);
        assertFalse(est.estimate(address(samples), actions, 1, true).reliable, "BSC to L2 replay closed");
    }

    // ── Existing Config API price checks unaltered ────────────────────────────

    function test_configValidationUnalteredOnL1() public {
        vm.warp(1800000000);
        vm.chainId(1);
        NativeL1FeeInfo src = new NativeL1FeeInfo(512, 2 gwei);
        Feed eth = new Feed(3000e8);
        E est = new E(IFeeInfo(address(src)), eth, IFeed(address(0)), IFeed(address(0)), cfg);

        // Bad marginBps must revert via _validate.
        E.Config memory bad = cfg;
        bad.marginBps = 0;
        vm.expectRevert(E.InvalidConfig.selector);
        est.setConfig(bad);

        bad = cfg;
        bad.maxPriceAge = 0;
        vm.expectRevert(E.InvalidConfig.selector);
        est.setConfig(bad);

        bad = cfg;
        bad.intrinsicGas = 20999;
        vm.expectRevert(E.InvalidConfig.selector);
        est.setConfig(bad);

        // Valid update still works.
        E.Config memory good = cfg;
        good.marginBps = 3000;
        est.setConfig(good);
        (bool ok, bytes memory configData) = address(est).staticcall(abi.encodeWithSignature("config()"));
        assertTrue(ok);
        E.Config memory actualConfig = abi.decode(configData, (E.Config));
        assertEq(actualConfig.marginBps, 3000);
    }

    function test_nativePriceBoundsUnaltered() public {
        vm.warp(1800000000);
        vm.chainId(1);
        NativeL1FeeInfo src = new NativeL1FeeInfo(512, 2 gwei);
        Samples samples = new Samples();

        // Below 100e18 lower bound — unreliable.
        Feed lowFeed = new Feed(int256(99e18 / 1e10)); // 99 USD in 8-decimal form
        E est = new E(IFeeInfo(address(src)), lowFeed, IFeed(address(0)), IFeed(address(0)), cfg);
        vm.fee(5 gwei);
        E.Action[] memory actions = new E.Action[](1);
        actions[0] = E.Action(address(1), 100e6, true);
        assertFalse(est.estimate(address(samples), actions, 1, true).reliable, "below lower bound unreliable");

        // Above 100000e18 upper bound — unreliable.
        Feed highFeed = new Feed(int256(100001e18 / 1e10)); // 100001 USD in 8-decimal
        E est2 = new E(IFeeInfo(address(src)), highFeed, IFeed(address(0)), IFeed(address(0)), cfg);
        assertFalse(est2.estimate(address(samples), actions, 1, true).reliable, "above upper bound unreliable");

        // Within bounds — reliable.
        Feed okFeed = new Feed(700e8); // BNB-like, well within 100..100000
        E est3 = new E(IFeeInfo(address(src)), okFeed, IFeed(address(0)), IFeed(address(0)), cfg);
        assertTrue(est3.estimate(address(samples), actions, 1, true).reliable, "in-bounds reliable");
    }
}
