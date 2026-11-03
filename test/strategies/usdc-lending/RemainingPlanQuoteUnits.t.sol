// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {StrategyStorageLayout} from "../../../src/strategies/usdc-lending/controller/StrategyStorageLayout.sol";
import {StrategyRebalanceGateModule as Gate} from "../../../src/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol";
import {StrategyParamsModule as Params} from "../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import {ReadOnlyGasEstimator as Estimator} from "../../../src/strategies/usdc-lending/gas/ReadOnlyGasEstimator.sol";
import {OracleQuoteMock, OracleParamsMock, OracleCoreMock} from "./OracleAssetValuation.t.sol";

contract RemainingAsset {
    uint8 public immutable decimals;
    constructor(uint8 precision) { decimals = precision; }
    function balanceOf(address) external view returns (uint256) { return 1_000_000 * 10**decimals; }
}

contract RemainingQuote {
    uint256 public cost;
    function setCost(uint256 value) external { cost = value; }
    function estimate(address, Estimator.Action[] calldata, uint8, bool) external view returns (Estimator.Quote memory q) {
        q.costUSDC = cost;
        q.reliable = true;
    }
}

contract RemainingAllocation {
    function validateRebalanceDeposit(address, uint256, uint256) external pure returns (bool) { return true; }
}

contract RemainingInputs {
    address immutable adapter;
    uint256 immutable amount;
    constructor(address venue, uint256 capital) { adapter = venue; amount = capital; }
    function computeRebalanceInputs() external view returns (
        uint16[] memory apys, address[] memory list, uint256[] memory targets,
        uint256 tvl, uint256 moved, uint256[] memory scores
    ) {
        apys = new uint16[](1); apys[0] = 1000; // 10% APR, independently valued below.
        list = new address[](1); list[0] = adapter;
        targets = new uint256[](1); targets[0] = amount;
        scores = new uint256[](1); scores[0] = 10000;
        return (apys, list, targets, amount, amount, scores);
    }
}

contract RemainingProxy is StrategyStorageLayout {
    address immutable gate;
    constructor(address asset, address core_, address params, address scoring, address logic,
        address allocation, address estimator, address adapter, uint256 amount)
        StrategyStorageLayout(asset, core_, params, scoring, address(0))
    {
        gate = logic;
        _grantRole(KEEPER_ROLE, msg.sender);
        enabled[adapter] = true;
        allocCalcModule_addr = allocation;
        rebalanceGasEstimator = estimator;
        gateHorizonDays = 7;
        rebalancePlanPhase = 1;
        rebalancePlanTotalActions = 1;
        rebalancePlanAdapters[0] = adapter;
        rebalancePlanAmounts[0] = amount | (1 << 255);
    }
    fallback() external {
        address target = msg.sig == Params.usd6ToAssetUnits.selector ? paramsModule : gate;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}

contract RemainingPlanQuoteUnitsTest is Test {
    function _check(uint8 precision, uint256 price18, uint256 costUsd6, bool expected) internal {
        RemainingAsset asset = new RemainingAsset(precision);
        OracleQuoteMock oracle = new OracleQuoteMock();
        oracle.set(price18, uint48(block.timestamp), true);
        OracleParamsMock config = new OracleParamsMock(); config.setOracle(address(oracle));
        OracleCoreMock core = new OracleCoreMock(address(config));
        address venue = address(0xA11CE);
        // $100,000 at 10% APR over seven days earns about $191.78.
        // Therefore a $5 quote must pass, and a $500 quote must fail, for every asset.
        uint256 amount = 100_000 * 1e18 * 10**precision / price18;
        RemainingInputs scoring = new RemainingInputs(venue, amount);
        RemainingQuote estimator = new RemainingQuote(); estimator.setCost(costUsd6);
        address params = deployCode("StrategyParamsModule.sol:StrategyParamsModule", abi.encode(address(asset), address(core)));
        address gate = deployCode("StrategyRebalanceGateModule.sol:StrategyRebalanceGateModule",
            abi.encode(address(asset), address(core), params, address(scoring), address(0)));
        RemainingProxy proxy = new RemainingProxy(address(asset), address(core), params, address(scoring), gate,
            address(new RemainingAllocation()), address(estimator), venue, amount);
        vm.recordLogs();
        assertEq(Gate(address(proxy)).checkRemainingPlan(), expected, "economic decision must preserve dollar value");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        uint256 denominator = price18 * 1e6;
        uint256 expectedCost = (costUsd6 * 10**precision * 1e18 + denominator - 1) / denominator;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != keccak256("RebalanceEconomicsEvaluated(uint256,uint256,uint256,int256,bool)")) continue;
            (uint256 moved,,uint256 cost,,bool accepted) = abi.decode(logs[i].data,(uint256,uint256,uint256,int256,bool));
            assertEq(moved, amount); assertEq(cost, expectedCost, "economics event uses asset units");
            assertEq(accepted, expected); found = true;
        }
        assertTrue(found, "economic decision event preserved");
    }

    function test_sixDecimalPegAndDepegUseSameDollarEconomics() public {
        _check(6, 1e18, 5e6, true); _check(6, 0.8e18, 5e6, true);
    }
    function test_eightDecimalBitcoinPlanDoesNotOverpriceGas() public { _check(8, 100_000e18, 5e6, true); }
    function test_eighteenDecimalEtherPlanRejectsUnprofitableSuffix() public { _check(18, 2_000e18, 500e6, false); }
}
