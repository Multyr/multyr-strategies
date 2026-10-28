// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {
    StrategyAdapterOpsModule
} from "../../../src/strategies/usdc-lending/controller/StrategyAdapterOpsModule.sol";
import {UsdcMultiLendingVaultTestBase, MockLendingAdapter} from "./UsdcMultiLendingVault.t.sol";
import {Feed, Fees} from "./ReadOnlyGasEstimator.t.sol";
import {
    ReadOnlyGasEstimator as E
} from "../../../src/strategies/usdc-lending/gas/ReadOnlyGasEstimator.sol";
import {
    StrategySettingsModule
} from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {
    StrategyScoringModule
} from "../../../src/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import {
    StrategyRebalanceGateModule
} from "../../../src/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol";
import {
    StrategyRebalancePlanModule
} from "../../../src/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol";

contract ReadOnlyGasIntegrationTest is UsdcMultiLendingVaultTestBase {
    E estimator;
    Fees fees;
    Feed eth;
    Feed usdcFeed;
    Feed sequencer;

    function setUp() public override {
        vm.warp(1800000000);
        super.setUp();
        _addAndEnableAdapter(adapter1);
        _addAndEnableAdapter(adapter2);
        _addAndEnableAdapter(adapter3);
        vm.startPrank(admin);
        StrategySettingsModule(address(vault)).exitBootstrapMode();
        StrategySettingsModule(address(vault)).setMaxIdleAfterDepositBps(10000);
        StrategySettingsModule(address(vault)).setGateParams(30, 0, 0, 0, 1e6);
        StrategySettingsModule(address(vault)).setCapDriftTolerance(0);
        vm.stopPrank();
        _prepareCache();
        _mintAndTransferToVault(core, 300_000e6);
        vm.prank(core);
        vault.deposit(300_000e6);
        vm.warp(block.timestamp + 301);
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();
        fees = new Fees();
        eth = new Feed(3000e8);
        usdcFeed = new Feed(1e8);
        sequencer = new Feed(0);
        E.Config memory c = E.Config(
            800000, 600000, 200000, 1000000, 2000000, 23112, 132, 5000, 7 days, 7 days, 3600, 1e6
        );
        estimator = new E(fees, eth, usdcFeed, sequencer, c);
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setRebalanceGasEstimator(address(estimator));
    }

    function prepare() internal {
        adapter1.setAPY(100);
        adapter3.setAPY(2000);
        _prepareCache();
        vm.warp(block.timestamp + 21601);
        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).prepareRebalance();
    }

    function step() internal {
        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).executeRebalanceStep();
    }

    function _prepareSafety() internal returns (address destination) {
        // Concentrated book with a small high-yield destination: the mandate
        // must create both a protective withdrawal and a subsequent deposit.
        adapter1.setDeposited(199_999e6);
        adapter2.setDeposited(100_000e6);
        adapter3.setDeposited(1e6);
        deal(address(usdc), address(adapter1), 199_999e6);
        deal(address(usdc), address(adapter2), 100_000e6);
        deal(address(usdc), address(adapter3), 1e6);
        deal(address(usdc), address(vault), 0);
        vm.startPrank(admin);
        StrategySettingsModule(address(vault)).setCapDriftTolerance(1);
        StrategySettingsModule(address(vault)).setRebalanceParams(3, 1, 0, 3600, 1000, 3000, 5000);
        vm.stopPrank();
        prepare();
        for (uint256 i; i < vault.rebalancePlanTotalActions(); ++i) {
            if (vault.rebalancePlanAmounts(i) >> 255 == 1) destination = vault.rebalancePlanAdapters(i);
        }
        assertTrue(destination != address(0), "fixture must include a safety deposit");
    }

    function test_safetyRecallContinuesButDisabledDepositsAreSkipped() public {
        address destination = _prepareSafety();
        uint256 before = vault.positionAssets(destination);
        uint256 idleBefore = usdc.balanceOf(address(vault));
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setDepositsDisabled(true);
        eth.set(0, block.timestamp);
        while (vault.rebalancePlanPhase() != 0) step();
        assertEq(vault.positionAssets(destination), before);
        assertGt(usdc.balanceOf(address(vault)), idleBefore, "protective recalls must proceed");
    }

    function test_safetyDepositRechecksCapacity() public {
        address destination = _prepareSafety();
        uint256 before = vault.positionAssets(destination);
        adapter1.setMaxCap(0);
        adapter2.setMaxCap(0);
        adapter3.setMaxCap(0);
        while (vault.rebalancePlanPhase() != 0) step();
        assertEq(vault.positionAssets(destination), before);
    }

    function test_safetyDepositRechecksFlag() public {
        address destination = _prepareSafety();
        uint256 before = vault.positionAssets(destination);
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setFlaggedAdapter(destination, true);
        while (vault.rebalancePlanPhase() != 0) step();
        assertEq(vault.positionAssets(destination), before);
    }

    function test_safetyPlanDoesNotRequireValidGasOracle() public {
        address destination = _prepareSafety();
        uint256 before = vault.positionAssets(destination);
        eth.set(0, block.timestamp);
        while (vault.rebalancePlanPhase() != 0) step();
        assertGt(vault.positionAssets(destination), before);
    }

    function test_scoresEventMatchesPreparedInputsAndQuote() public {
        vm.recordLogs();
        prepare();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (E.Action[] memory actions, E.Quote memory q) = StrategyRebalanceGateModule(address(vault)).previewRebalanceGas();
        bytes32 expectedData;
        {
            (uint16[] memory apys, address[] memory list, uint256[] memory targets, uint256 tvl,, uint256[] memory scores) =
                StrategyScoringModule(address(vault)).computeRebalanceInputs();
            expectedData = keccak256(abi.encode(list, scores, apys, targets, tvl));
        }
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(vault) || logs[i].topics[0] !=
                keccak256("RebalanceScores(bytes32,address[],uint256[],uint16[],uint256[],uint256)")) continue;
            found = true;
            assertEq(logs[i].topics[1], q.actionsHash);
            assertEq(keccak256(logs[i].data), expectedData);
        }
        assertTrue(found);
        assertGt(actions.length, 0);
    }

    function test_dynamicCompletePlanRecordsWithdrawals() public {
        prepare();
        uint256 count = vault.rebalancePlanTotalActions();
        assertGt(count, 0);
        for (uint256 i; i < 10 && vault.rebalancePlanPhase() != 0; ++i) {
            step();
        }
        assertEq(vault.rebalancePlanPhase(), 0);
        assertEq(
            vault.rebalancePlanConsecutiveFailures(), 0, "successful plan must finalize, not cancel"
        );
        assertEq(vault.lastSnapshotTs(), block.timestamp);
        assertGt(
            vault.emaWithdrawGas(address(adapter1)) + vault.emaWithdrawGas(address(adapter2)), 0
        );
    }

    function test_unreliableOracleCancelsBeforeSpending() public {
        prepare();
        uint256 position = vault.positionAssets(address(adapter1));
        eth.set(0, block.timestamp);
        step();
        assertEq(vault.rebalancePlanPhase(), 0);
        assertEq(vault.positionAssets(address(adapter1)), position);
        assertEq(vault.lastRebalanceTs(), block.timestamp);
        (bool can,,) = StrategyRebalanceGateModule(address(vault)).canRebalance();
        assertFalse(can);
    }

    function test_gasSpikeCancelsBeforeSpending() public {
        prepare();
        uint256 position = vault.positionAssets(address(adapter1));
        fees.set(1000 gwei, 1e15);
        step();
        assertEq(vault.rebalancePlanPhase(), 0);
        assertEq(vault.positionAssets(address(adapter1)), position);
    }

    function test_previewStaticcallAndOracleFailure() public {
        adapter1.setAPY(100);
        adapter3.setAPY(2000);
        _prepareCache();
        vm.warp(block.timestamp + 21601);
        (bool success, bytes memory data) =
            address(vault).staticcall(abi.encodeWithSignature("canRebalance()"));
        assertTrue(success);
        (bool can,,) = abi.decode(data, (bool, uint256, int256));
        assertTrue(can);
        eth.set(0, block.timestamp);
        (success, data) = address(vault).staticcall(abi.encodeWithSignature("canRebalance()"));
        assertTrue(success);
        (can,,) = abi.decode(data, (bool, uint256, int256));
        assertFalse(can);
    }

    function test_changedSelectedSetCancelsBeforeSpending() public {
        // Limit the 300K book to one target, then change which venue wins.
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setRebalanceParams(1, 1, 0, 3600, 1000, 0, 5000);
        prepare();
        uint256 before = vault.positionAssets(address(adapter1));
        adapter1.setAPY(6000);
        adapter2.setAPY(1);
        adapter3.setAPY(1);
        _prepareCache();
        step();
        assertEq(vault.rebalancePlanPhase(), 0);
        assertEq(vault.positionAssets(address(adapter1)), before);
        assertGt(vault.rebalancePlanConsecutiveFailures(), 0);
    }

    function _smallEulerBook(uint256 idle, bool excludeFluid) internal {
        // Low-fee fixture makes this tiny illustrative move economically viable.
        fees.set(1_000_000,1_000_000);
        vm.prank(core); vault.withdrawAll(core);
        adapter1.setDeposited(20_550_000); adapter2.setDeposited(0); adapter3.setDeposited(0);
        deal(address(usdc),address(adapter1),20_550_000);
        deal(address(usdc),address(adapter2),0); deal(address(usdc),address(adapter3),0);
        deal(address(usdc),address(vault),idle);
        adapter1.setAPY(100); adapter2.setAPY(1674); adapter3.setAPY(500);
        vm.startPrank(admin);
        StrategySettingsModule(address(vault)).setRiskWeights(10000,0,0,0,0);
        StrategySettingsModule(address(vault)).setRebalanceParams(7,1,0,3600,1000,0,5000);
        StrategySettingsModule(address(vault)).setTargetIdleBufferBps(1000);
        StrategySettingsModule(address(vault)).setDustTolerance(1);
        if (excludeFluid) StrategySettingsModule(address(vault)).setQuarantined(address(adapter1),true);
        vm.stopPrank();
        vm.warp(block.timestamp+21601); _prepareCache();
        vm.prank(keeper); StrategyAdapterOpsModule(address(vault)).syncPositionAssets(true);
    }

    function test_smallEulerPlanRetainsReserveAndRecallsExcludedFluid() public {
        _smallEulerBook(4_450_000,true); // 25 USDC total; target 22.5, reserve 2.5.
        (E.Action[] memory actions,E.Quote memory q)=StrategyRebalanceGateModule(address(vault)).previewRebalanceGas();
        assertEq(actions.length,2); assertEq(q.txCount,2);
        assertEq(actions[0].adapter,address(adapter1)); assertFalse(actions[0].deposit);
        assertEq(actions[0].amount,20_550_000);
        assertEq(actions[1].adapter,address(adapter2)); assertTrue(actions[1].deposit);
        assertEq(actions[1].amount,22_500_000);
        vm.prank(keeper); StrategyRebalancePlanModule(address(vault)).prepareRebalance();
        assertEq(vault.rebalancePlanAmounts(0),actions[0].amount);
        assertEq(vault.rebalancePlanAmounts(1)&((1<<255)-1),actions[1].amount);
        step();
        assertEq(vault.rebalancePlanPhase(),0);
        assertEq(vault.positionAssets(address(adapter1)),0);
        assertEq(vault.positionAssets(address(adapter2)),22_500_000);
        assertEq(usdc.balanceOf(address(vault)),2_500_000);
    }

    function test_disabledFluidRemainsRecallable() public {
        _smallEulerBook(4_450_000,false);
        vm.prank(admin); vault.toggleAdapter(address(adapter1),false);
        (E.Action[] memory actions,)=StrategyRebalanceGateModule(address(vault)).previewRebalanceGas();
        assertEq(actions.length,2); assertEq(actions[0].adapter,address(adapter1));
        vm.prank(keeper); StrategyRebalancePlanModule(address(vault)).prepareRebalance();
        step();
        assertEq(vault.positionAssets(address(adapter1)),0);
        assertEq(vault.positionAssets(address(adapter2)),22_500_000);
    }

    function test_newIdleFundsRespectEulerTargetAndReserve() public {
        _smallEulerBook(4_450_000,false);
        vm.prank(keeper); StrategyRebalancePlanModule(address(vault)).prepareRebalance(); step();
        deal(address(usdc),address(vault),12_500_000); // 10 additional USDC; TVL 35.
        vm.warp(block.timestamp+301);
        vm.prank(keeper); StrategyScoringModule(address(vault)).deployIdle();
        assertEq(vault.positionAssets(address(adapter2)),31_500_000);
        assertEq(vault.positionAssets(address(adapter1)),0);
        assertEq(vault.positionAssets(address(adapter3)),0);
        assertEq(usdc.balanceOf(address(vault)),3_500_000);
    }

    function test_idleBufferConfigurationBoundsAndAuthorization() public {
        vm.expectRevert(); StrategySettingsModule(address(vault)).setTargetIdleBufferBps(1000);
        vm.startPrank(admin);
        vm.expectRevert(); StrategySettingsModule(address(vault)).setTargetIdleBufferBps(10001);
        StrategySettingsModule(address(vault)).setTargetIdleBufferBps(10000);
        assertEq(vault.targetIdleBufferBps(),10000);
        StrategySettingsModule(address(vault)).setTargetIdleBufferBps(0);
        assertEq(vault.targetIdleBufferBps(),0);
        vm.stopPrank();
    }

    function test_smallEulerPlanStillRejectsUneconomicGas() public {
        _smallEulerBook(4_450_000,false);
        fees.set(1_000_000_000,1_000_000_000);
        vm.prank(keeper); vm.expectRevert();
        StrategyRebalancePlanModule(address(vault)).prepareRebalance();
        assertEq(vault.positionAssets(address(adapter1)),20_550_000);
    }

    function test_smallEulerPlanUsesReserveWhenNoExistingIdle() public {
        _smallEulerBook(0,false);
        (E.Action[] memory actions,)=StrategyRebalanceGateModule(address(vault)).previewRebalanceGas();
        assertEq(actions.length,2); assertEq(actions[0].amount,20_550_000);
        assertEq(actions[1].amount,18_495_000);
    }

    function test_bufferIncreaseInvalidatesPreparedDeposit() public {
        _smallEulerBook(4_450_000,false);
        vm.prank(keeper); StrategyRebalancePlanModule(address(vault)).prepareRebalance();
        vm.prank(admin); StrategySettingsModule(address(vault)).setTargetIdleBufferBps(5000);
        step();
        assertEq(vault.rebalancePlanPhase(),0);
        assertEq(vault.positionAssets(address(adapter1)),20_550_000);
        assertEq(vault.positionAssets(address(adapter2)),0);
    }

    function test_500kFiveOperationPlanExecutesExactlyQuotedActions() public {
        // Clear the setup book through the real withdrawal path so recorded NAV
        // and adapter balances agree before constructing the illustrative book.
        vm.prank(core); vault.withdrawAll(core);
        MockLendingAdapter euler = new MockLendingAdapter(address(usdc));
        MockLendingAdapter fluid = new MockLendingAdapter(address(usdc));
        euler.setVault(address(vault)); fluid.setVault(address(vault));
        euler.setExtMarketTVL(1_000_000_000e6); fluid.setExtMarketTVL(1_000_000_000e6);
        _addAndEnableAdapter(euler); _addAndEnableAdapter(fluid);
        adapter1.setDeposited(300000e6); adapter2.setDeposited(200000e6); adapter3.setDeposited(0);
        deal(address(usdc),address(adapter1),300000e6); deal(address(usdc),address(adapter2),200000e6);
        deal(address(usdc),address(adapter3),0); deal(address(usdc),address(vault),0);
        adapter1.setAPY(10); adapter2.setAPY(10); adapter3.setAPY(800); euler.setAPY(700); fluid.setAPY(500);
        vm.startPrank(admin);
        StrategySettingsModule(address(vault)).setRiskWeights(10000,0,0,0,0);
        StrategySettingsModule(address(vault)).setRebalanceParams(7,1,0,3600,1000,5000,5000);
        // Illustrative 40% target needs an explicit cap override; the normal tier ceiling is ~36.7%.
        StrategySettingsModule(address(vault)).setAdapterAbsCapOverride(address(adapter3),4000);
        StrategySettingsModule(address(vault)).setAdapterAbsCapOverride(address(euler),4000);
        StrategySettingsModule(address(vault)).setAdapterAbsCapOverride(address(fluid),4000);
        vm.stopPrank();
        _prepareCache(); vm.warp(block.timestamp+21601);
        vm.prank(keeper); StrategyAdapterOpsModule(address(vault)).syncPositionAssets(true);
        (E.Action[] memory actions,E.Quote memory q)=StrategyRebalanceGateModule(address(vault)).previewRebalanceGas();
        assertEq(actions.length,5); assertEq(q.txCount,4);
        assertFalse(actions[0].deposit); assertFalse(actions[1].deposit);
        assertEq(actions[0].amount,300000e6); assertEq(actions[1].amount,200000e6);
        vm.prank(keeper); StrategyRebalancePlanModule(address(vault)).prepareRebalance();
        for(uint256 i; i<5; ++i) {
            assertEq(vault.rebalancePlanAdapters(i),actions[i].adapter);
            assertEq(vault.rebalancePlanAmounts(i)&((1<<255)-1),actions[i].amount);
            assertEq(vault.rebalancePlanAmounts(i)>>255==1,actions[i].deposit);
        }
        uint256 steps;
        while(vault.rebalancePlanPhase()!=0 && steps<5) { step(); ++steps; }
        assertEq(steps,3); assertEq(vault.rebalancePlanConsecutiveFailures(),0);
        assertEq(vault.positionAssets(address(adapter1)),0); assertEq(vault.positionAssets(address(adapter2)),0);
        for(uint256 i=2; i<5; ++i) assertEq(vault.positionAssets(actions[i].adapter),actions[i].amount);
    }

    function test_withdrawalRoundingPricesOnlyAvailableProceeds() public {
        prepare();
        vm.prank(keeper); StrategyRebalancePlanModule(address(vault)).cancelRebalancePlan();
        (E.Action[] memory original,) = StrategyRebalanceGateModule(address(vault)).previewRebalanceGas();
        address source = original[0].adapter;
        assertFalse(original[0].deposit);
        uint256 available = original[0].amount - 1;
        vm.mockCall(source, abi.encodeWithSignature("withdrawableAssets()"), abi.encode(available));
        (E.Action[] memory rounded,E.Quote memory q) = StrategyRebalanceGateModule(address(vault)).previewRebalanceGas();
        assertEq(rounded[0].amount,available);
        assertTrue(q.reliable);
        vm.prank(keeper); StrategyRebalancePlanModule(address(vault)).prepareRebalance();
        for(uint256 i; i<rounded.length; ++i) {
            assertEq(vault.rebalancePlanAdapters(i),rounded[i].adapter);
            assertEq(vault.rebalancePlanAmounts(i)&((1<<255)-1),rounded[i].amount);
        }
    }

    function test_estimatorCannotBeReplaced() public {
        vm.prank(admin);
        vm.expectRevert();
        StrategySettingsModule(address(vault)).setRebalanceGasEstimator(address(estimator));
    }

    function test_failedWithdrawalDoesNotRecordSampleOrContinue() public {
        prepare();
        address first = vault.rebalancePlanAdapters(0);
        if (first == address(adapter1)) adapter1.setWithdrawReverts(true);
        else if (first == address(adapter2)) adapter2.setWithdrawReverts(true);
        else adapter3.setWithdrawReverts(true);
        step();
        assertEq(vault.emaWithdrawGas(first), 0);
        assertEq(vault.rebalancePlanPhase(), 0);
    }

    function test_strictDepositAndEmergencyRecallRecordGas() public {
        assertGt(vault.emaDepositGas(address(adapter1)) + vault.emaDepositGas(address(adapter2)), 0);
        eth.set(0, block.timestamp); // safety exits must not depend on estimator availability
        vm.prank(admin);
        vault.emergencyRecallAll();
        assertGt(
            vault.emaWithdrawGas(address(adapter1)) + vault.emaWithdrawGas(address(adapter2)), 0
        );
    }

    function test_partialDepositStopsDynamicPlan() public {
        prepare();
        adapter1.setPartialDepositBps(5000);
        adapter2.setPartialDepositBps(5000);
        adapter3.setPartialDepositBps(5000);
        for (uint256 i; i < 10 && vault.rebalancePlanPhase() != 0; ++i) {
            step();
        }
        assertEq(vault.rebalancePlanPhase(), 0);
        assertGt(vault.rebalancePlanConsecutiveFailures(), 0);
    }

    function test_readOnlyPreviewMatchesPreparedActionAmounts() public {
        prepare();
        (E.Action[] memory actions, E.Quote memory quote_) =
            StrategyRebalanceGateModule(address(vault)).previewRebalanceGas();
        assertTrue(quote_.reliable);
        assertEq(actions.length, vault.rebalancePlanTotalActions());
        for (uint256 i; i < actions.length; ++i) {
            assertEq(actions[i].adapter, vault.rebalancePlanAdapters(i));
            assertEq(
                actions[i].amount | (actions[i].deposit ? 1 << 255 : 0),
                vault.rebalancePlanAmounts(i)
            );
        }
    }

    function test_capacityReductionCancelsBeforeSpending() public {
        prepare();
        adapter1.setMaxCap(0);
        adapter2.setMaxCap(0);
        adapter3.setMaxCap(0);
        uint256 before = vault.positionAssets(address(adapter1));
        step();
        assertEq(vault.rebalancePlanPhase(), 0);
        assertEq(vault.positionAssets(address(adapter1)), before);
    }

    function test_benchmarkFullPlanCallsAndDifferentVaultSizes() public {
        uint256[5] memory sizes = [uint256(10_000e6), 100_000e6, 500_000e6, 2_000_000e6, 6_000_000e6];
        for (uint256 k; k < sizes.length; ++k) {
            uint256 snapshot = vm.snapshotState();
            uint256 total = vault.totalAssets();
            uint256 p1 = adapter1.deposited() * sizes[k] / total;
            uint256 p2 = adapter2.deposited() * sizes[k] / total;
            uint256 p3 = adapter3.deposited() * sizes[k] / total;
            adapter1.setDeposited(p1);
            adapter2.setDeposited(p2);
            adapter3.setDeposited(p3);
            deal(address(usdc), address(adapter1), p1);
            deal(address(usdc), address(adapter2), p2);
            deal(address(usdc), address(adapter3), p3);
            deal(address(usdc), address(vault), sizes[k] - p1 - p2 - p3);
            adapter1.setAPY(100);
            adapter3.setAPY(2000);
            _prepareCache();
            vm.warp(block.timestamp + 21601);
            vm.prank(keeper);
            StrategyAdapterOpsModule(address(vault)).syncPositionAssets(true);
            (, E.Quote memory q) = StrategyRebalanceGateModule(address(vault)).previewRebalanceGas();
            (bool accepted,, int256 net) =
                StrategyRebalanceGateModule(address(vault)).canRebalance();
            console2.log("book USDC6", sizes[k]);
            console2.log("modeled USDC6", q.costUSDC);
            console2.log("accepted", accepted);
            console2.log("net benefit bps", net);
            if (accepted) {
                vm.prank(keeper);
                uint256 begin = gasleft();
                StrategyRebalancePlanModule(address(vault)).prepareRebalance();
                uint256 measured = begin - gasleft();
                console2.log("prepare call gas (not cold transaction)", measured);
                uint256 steps;
                while (vault.rebalancePlanPhase() != 0 && steps < 10) {
                    vm.prank(keeper);
                    begin = gasleft();
                    StrategyRebalancePlanModule(address(vault)).executeRebalanceStep();
                    uint256 used = begin - gasleft();
                    measured += used;
                    ++steps;
                    console2.log("step call gas (not cold transaction)", used);
                }
                assertEq(vault.rebalancePlanPhase(), 0);
                console2.log("total measured call gas", measured);
                console2.log("modeled L2 gas", q.l2Gas);
                console2.log("planned transaction count", q.txCount);
                console2.log("observed execution steps", steps);
                console2.log("modeled USDC before margin", (q.costUSDC * 10000) / 15000);
                uint256 measuredWei = (measured + q.txCount * 23112) * 20000000 + q.posterWei;
                uint256 measuredUsdc = (measuredWei * 3000 + 1e12 - 1) / 1e12;
                console2.log("measured call gas priced USDC before margin", measuredUsdc);
                console2.log("measured call gas priced USDC with 50 percent margin", (measuredUsdc * 15000 + 9999) / 10000);
            }
            assertTrue(vm.revertToState(snapshot));
        }
    }
}
