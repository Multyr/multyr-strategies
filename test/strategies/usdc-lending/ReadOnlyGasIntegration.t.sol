// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {
    StrategyAdapterOpsModule
} from "../../../src/strategies/usdc-lending/controller/StrategyAdapterOpsModule.sol";
import {UsdcMultiLendingVaultTestBase} from "./UsdcMultiLendingVault.t.sol";
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
            800000, 600000, 200000, 1000000, 2000000, 23112, 132, 2500, 7 days, 7 days, 3600, 1e6
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
        StrategySettingsModule(address(vault)).setRebalanceParams(3, 2, 0, 3600, 1000, 3000, 5000);
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
        uint256[4] memory sizes = [uint256(21e6), 100e6, 10_000e6, 300_000e6];
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
            }
            assertTrue(vm.revertToState(snapshot));
        }
    }
}
