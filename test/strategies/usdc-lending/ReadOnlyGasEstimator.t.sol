// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {GasEstimatorPreflight} from "../../../script/GasEstimatorPreflight.sol";
import {
    ReadOnlyGasEstimator as E,
    IMeasurements,
    IFeeInfo,
    IFeed
} from "../../../src/strategies/usdc-lending/gas/ReadOnlyGasEstimator.sol";
import {CandidateActions} from "../../../src/strategies/usdc-lending/gas/CandidateActions.sol";

contract Feed is IFeed {
    uint8 public decimals = 8;
    int256 public answer;
    uint256 public updated;
    uint256 public started;
    uint80 public round = 1;
    uint80 public answered = 1;

    constructor(int256 a) {
        answer = a;
        updated = block.timestamp;
        started = block.timestamp - 7200;
    }

    function set(int256 a, uint256 t) external {
        answer = a;
        updated = t;
    }

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    function setRound(uint80 r) external {
        answered = r;
    }

    function setStarted(uint256 s) external {
        started = s;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (round, answer, started, updated, answered);
    }
}

contract Fees is IFeeInfo {
    uint256 public price = 20_000_000;
    uint256 public perByte = 1_000_000_000;
    bool public fail;

    function set(uint256 p, uint256 b) external {
        price = p;
        perByte = b;
    }

    function setFail() external {
        fail = true;
    }

    function getPricesInWei()
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        require(!fail);
        return (140 * perByte, perByte, 0, 0, 0, price);
    }
}

contract Samples is IMeasurements {
    struct Observation { uint32 count; uint64 updated; }
    mapping(address => Observation) public depositGasObservation;
    mapping(address => Observation) public withdrawGasObservation;
    function evidence(address a, bool deposit, uint32 count, uint64 updated) external {
        if (deposit) depositGasObservation[a] = Observation(count, updated);
        else withdrawGasObservation[a] = Observation(count, updated);
    }
    mapping(address => uint64) public emaDepositGas;
    mapping(address => uint64) public emaWithdrawGas;

    function set(address a, uint64 d, uint64 w) external {
        emaDepositGas[a] = d;
        emaWithdrawGas[a] = w;
    }
}

contract QuoteBaseline {
    uint256 public cost;
    uint256 public validUntil;

    function update(uint256 c, uint256 expiry) external {
        cost = c;
        validUntil = expiry;
    }

    function read() external view returns (uint256) {
        return block.timestamp <= validUntil ? cost : 1e6;
    }
}

contract ReadOnlyGasEstimatorTest is Test {
    E e;
    Feed eth;
    Feed usdc;
    Feed seq;
    Fees fees;
    Samples samples;

    function validateDeployment(address candidate, bytes32 hash) external view {
        GasEstimatorPreflight.validate(candidate, address(this), address(eth), address(usdc), address(seq), hash);
    }

    function test_deploymentChecksFeeSourceConfigAndPrices() public {
        (, bytes memory data) = address(e).staticcall(abi.encodeWithSignature("config()"));
        bytes32 hash = keccak256(data);
        vm.expectRevert("GAS_FEE_SOURCE");
        this.validateDeployment(address(e), hash);
        vm.etch(address(0x6c), address(fees).code);
        Fees(address(0x6c)).set(20_000_000, 1_000_000_000);
        E candidate = new E(IFeeInfo(address(0x6c)), eth, usdc, seq, abi.decode(data, (E.Config)));
        this.validateDeployment(address(candidate), hash);
        vm.expectRevert("GAS_CONFIG");
        this.validateDeployment(address(candidate), bytes32(uint256(1)));
        Fees(address(0x6c)).set(0, 1);
        vm.expectRevert("GAS_FEES_INVALID");
        this.validateDeployment(address(candidate), hash);
    }

    function setUp() public {
        vm.warp(1800000000);
        eth = new Feed(3000e8);
        usdc = new Feed(1e8);
        seq = new Feed(0);
        fees = new Fees();
        samples = new Samples();
        // Illustrative benchmark coefficients, NOT approved production calibration.
        E.Config memory c = E.Config(
            400000, 150000, 200000, 1000000, 2000000, 23112, 132, 2500, 3600, 3600, 3600, 1e6
        );
        e = new E(fees, eth, usdc, seq, c);
    }

    function quote(E.Action[] memory actions) internal view returns (E.Quote memory) {
        return e.estimate(address(samples), actions, 2, true);
    }

    function test_remainingPlanExcludesPreparation() public view {
        E.Quote memory full = quote(plan(4));
        E.Quote memory remaining = e.estimate(address(samples), plan(4), 2, false);
        assertEq(full.txCount, remaining.txCount + 1);
        assertEq(full.l2Gas - remaining.l2Gas, 400000 + 23112);
        assertGt(full.costUSDC, remaining.costUSDC);
    }

    function test_batchSizeBoundToStrategy() public view {
        E.Quote memory one = e.estimate(address(samples), plan(4), 1, true);
        E.Quote memory two = quote(plan(4));
        assertGt(one.costUSDC, two.costUSDC);
        assertNotEq(one.actionsHash, two.actionsHash);
    }

    function test_governanceTransfer() public {
        e.proposeCalibrator(address(77));
        vm.prank(address(78));
        vm.expectRevert();
        e.acceptCalibrator();
        vm.prank(address(77));
        e.acceptCalibrator();
        vm.expectRevert();
        e.setAdapterFloors(address(1), 1e6, 2e6);
    }

    function plan(uint256 n) internal pure returns (E.Action[] memory a) {
        a = new E.Action[](n);
        for (uint256 i; i < n; i++) {
            a[i] = E.Action(address(uint160(i + 1)), 100e6, i % 2 == 1);
        }
    }

    function test_componentsNoDoubleCounting() public view {
        E.Quote memory q = quote(plan(2));
        assertTrue(q.reliable);
        assertTrue(q.usedDefaults);
        assertEq(q.txCount, 2);
        assertEq(q.l2Gas, 400000 + 150000 + 200000 + 2 * 23112 + 1000000 + 2000000);
        assertEq(q.executionWei, q.l2Gas * 20_000_000);
        assertEq(q.posterWei, 2 * (140 + 132) * 1_000_000_000);
        assertGt(q.costUSDC, 0);
    }

    function test_pricesDynamic() public {
        uint256 before = quote(plan(4)).costUSDC;
        fees.set(200_000_000, 10_000_000_000);
        assertGe(quote(plan(4)).costUSDC, before * 9);
    }

    function test_missingOrLowSamplesUseFloors() public {
        uint256 before = quote(plan(2)).costUSDC;
        samples.set(address(1), 1, 1);
        assertEq(quote(plan(2)).costUSDC, before);
        samples.set(address(1), 1, 3000000);
        samples.evidence(address(1), false, 3, uint64(block.timestamp));
        assertGt(quote(plan(2)).costUSDC, before);
    }

    function test_reliableEmaBelowDefaultAndStaleFallback() public {
        E.Action[] memory a = new E.Action[](1);
        a[0] = E.Action(address(1), 100e6, true);
        e.setAdapterFloors(address(1), 750000, 350000);
        uint256 cold = quote(a).l2Gas;
        samples.set(address(1), 305025, 0);
        samples.evidence(address(1), true, 2, uint64(block.timestamp));
        assertEq(quote(a).l2Gas, cold);
        samples.evidence(address(1), true, 3, uint64(block.timestamp));
        assertEq(quote(a).l2Gas, cold - 750000 + 305025);
        assertFalse(quote(a).usedDefaults);
        samples.evidence(address(1), true, 3, uint64(block.timestamp - 7 days - 1));
        assertEq(quote(a).l2Gas, cold);
    }

    function test_fiveOperationsThreeTargetsFourTransactions() public {
        E.Action[] memory a = new E.Action[](5);
        a[0] = E.Action(address(1), 300000e6, false);
        a[1] = E.Action(address(2), 200000e6, false);
        a[2] = E.Action(address(3), 200000e6, true);
        a[3] = E.Action(address(4), 175000e6, true);
        a[4] = E.Action(address(5), 125000e6, true);
        e.setPathOverhead(E.PathOverhead(500000, 200000, 300000, 400000, 250000));
        E.Quote memory q = quote(a);
        assertEq(q.txCount, 4);
        assertEq(q.l2Gas, 500000 + 200000 + 300000 * 2 + 250000 + 4 * 23112 + 2 * 2000000 + 3 * 1000000);
        a[1].deposit = true;
        assertEq(quote(a).l2Gas, q.l2Gas - 2000000 + 1000000 + 200000);
        E.Quote memory remainder = e.estimate(address(samples), a, 2, false);
        assertEq(remainder.txCount, 3);
        assertEq(remainder.l2Gas, quote(a).l2Gas - 500000 - 23112);
    }

    function test_badOracleFailsClosed() public {
        eth.set(3000e8, block.timestamp - 3601);
        E.Quote memory q = quote(plan(2));
        assertFalse(q.reliable);
        assertEq(q.costUSDC, 1e6);
        eth.set(-1, block.timestamp);
        assertFalse(quote(plan(2)).reliable);
        eth.set(3000e8, block.timestamp + 1);
        assertFalse(quote(plan(2)).reliable);
        eth.set(3000e8, block.timestamp);
        eth.setRound(0);
        assertFalse(quote(plan(2)).reliable);
    }

    function test_decimalsAndUsdcDepeg() public {
        eth.setDecimals(18);
        eth.set(3000e18, block.timestamp);
        assertTrue(quote(plan(2)).reliable);
        eth.setDecimals(19);
        assertFalse(quote(plan(2)).reliable);
        eth.setDecimals(8);
        eth.set(3000e8, block.timestamp);
        usdc.set(50_000_000, block.timestamp);
        assertFalse(quote(plan(2)).reliable);
    }

    function test_sequencerGraceAndFeesFailure() public {
        seq.set(1, block.timestamp);
        assertFalse(quote(plan(2)).reliable);
        seq.set(0, block.timestamp);
        seq.setStarted(block.timestamp);
        assertFalse(quote(plan(2)).reliable);
        seq.setStarted(block.timestamp - 7200);
        fees.setFail();
        assertFalse(quote(plan(2)).reliable);
    }

    function test_planIdentityChanges() public view {
        E.Action[] memory a = plan(2);
        bytes32 h = quote(a).actionsHash;
        a[0].amount++;
        assertNotEq(quote(a).actionsHash, h);
    }

    function testFuzz_costMonotonicInExecutionPrice(uint64 p) public {
        uint256 price = bound(p, 20_000_000, 1000 gwei);
        uint256 before = quote(plan(10)).costUSDC;
        fees.set(price, 1_000_000_000);
        assertGe(quote(plan(10)).costUSDC, before);
    }

    function test_actionOrderingDustAndAmounts() public pure {
        address[] memory a = new address[](3);
        a[0] = address(1);
        a[1] = address(2);
        a[2] = address(3);
        uint256[] memory c = new uint256[](3);
        c[0] = 100e6;
        uint256[] memory t = new uint256[](3);
        t[0] = 20e6;
        t[1] = 30e6;
        t[2] = 50e6;
        uint256[] memory s = new uint256[](3);
        s[1] = 9000;
        s[2] = 1000;
        E.Action[] memory x = CandidateActions.build(a, c, t, s, 1e6);
        assertEq(x.length, 3);
        assertFalse(x[0].deposit);
        assertEq(x[0].amount, 80e6);
        assertEq(x[1].adapter, address(2));
        assertEq(x[2].adapter, address(3));
        assertEq(CandidateActions.build(a, c, t, s, 60e6).length, 1);
    }

    function test_profitabilityScenarios() public {
        uint256[3] memory tvls = [uint256(21e6), 100e6, 10000e6];
        for (uint256 i; i < 3; i++) {
            E.Quote memory q = quote(plan(4));
            uint256 moved = tvls[i] / 2;
            uint256 gain = moved * 200 * 30 / (10000 * 365); // illustrative +2% annual uplift
            uint256 spreads = moved * 4 / 10000;
            bool pass = q.reliable && gain > q.costUSDC + spreads + moved * 10 / 10000;
            emit log_named_uint("TVL USDC6", tvls[i]);
            emit log_named_uint("cost USDC6", q.costUSDC);
            emit log_named_uint("gate accepted", pass ? 1 : 0);
        }
    }

    function test_adapterSpecificCalibrationAndAccess() public {
        uint256 before = quote(plan(2)).costUSDC;
        e.setAdapterFloors(address(1), 1100000, 3000000); // Conservative adapter override
        assertGt(quote(plan(2)).costUSDC, before);
        vm.prank(address(99));
        vm.expectRevert("unauthorized");
        e.setAdapterFloors(address(1), 21000, 21000);
    }

    function test_storedQuoteBaseline() public {
        QuoteBaseline q = new QuoteBaseline();
        uint256 before = gasleft();
        q.update(10000, block.timestamp + 300);
        emit log_named_uint("initial quote update call gas excluding intrinsic", before - gasleft());
        vm.cool(address(q));
        before = gasleft();
        q.update(12000, block.timestamp + 600);
        emit log_named_uint(
            "repeat quote update same-tx call gas excluding intrinsic", before - gasleft()
        );
        before = gasleft();
        q.read();
        emit log_named_uint("quote read call gas", before - gasleft());
    }

    function test_emptyPlanRejected() public {
        vm.expectRevert(E.InvalidPlan.selector);
        quote(new E.Action[](0));
    }

    function test_oracleRevertAndExcessivePriceFallback() public {
        vm.mockCallRevert(
            address(eth), abi.encodeWithSelector(IFeed.latestRoundData.selector), hex"dead"
        );
        assertFalse(quote(plan(2)).reliable);
        vm.clearMockedCalls();
        fees.set(1001 gwei, 1);
        assertFalse(quote(plan(2)).reliable);
    }

    function test_benchmarkColdAndWarm() public {
        for (uint256 n = 2; n <= 10; n += 2) {
            E.Action[] memory a = plan(n);
            vm.cool(address(e));
            vm.cool(address(eth));
            vm.cool(address(usdc));
            vm.cool(address(seq));
            vm.cool(address(fees));
            vm.cool(address(samples));
            uint256 before = gasleft();
            E.Quote memory q = quote(a);
            uint256 cold = before - gasleft();
            before = gasleft();
            quote(a);
            uint256 warm = before - gasleft();
            emit log_named_uint("actions", n);
            emit log_named_uint("cold gas", cold);
            emit log_named_uint("warm gas", warm);
            assertTrue(q.reliable);
            assertLt(cold, 200000);
        }
    }

    function test_transactionPriceCannotUnderstateExecutionCost() public {
        vm.txGasPrice(100_000_000);
        E.Quote memory q = quote(plan(2));
        assertEq(q.executionWei, q.l2Gas * 100_000_000);
    }

    function test_thirtyPercentMarginAppliedOnceToWholePlan() public {
        (, bytes memory data) = address(e).staticcall(abi.encodeWithSignature("config()"));
        E.Config memory c = abi.decode(data, (E.Config));
        c.marginBps = 3000;
        e.setConfig(c);
        for (uint256 n = 1; n <= 7; ++n) {
            E.Quote memory q = quote(plan(n));
            uint256 base = ((q.executionWei + q.posterWei) * 3000 + 1e12 - 1) / 1e12;
            assertEq(q.costUSDC, (base * 13000 + 9999) / 10000);
        }
    }

    function test_configGovernanceAndBounds() public {
        E.Config memory c = E.Config(
            400000, 350000, 200000, 1000000, 2000000, 23112, 132, 5000, 3600, 3600, 3600, 1e6
        );
        uint256 before = quote(plan(2)).costUSDC;
        vm.prank(address(99));
        vm.expectRevert();
        e.setConfig(c);
        e.setConfig(c);
        assertGt(quote(plan(2)).costUSDC, before);
        c.marginBps = 0;
        vm.expectRevert();
        e.setConfig(c);
    }
}
