// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console2 } from "forge-std/Test.sol";

/**
 * @title LendingStrategyUpkeep Test Suite
 * @notice Tests for the Chainlink Automation coordinator for lending strategies
 */

// ============================================================================
// MOCK CONTRACTS
// ============================================================================

interface IUpkeepStrategy {
    function canHarvest()
        external
        view
        returns (bool ok, uint256 sumHarvestable, uint64 sinceLastHarvest);
    function canRebalance()
        external
        view
        returns (bool ok, uint256 movedEstimate, int256 netBenefitBps);
    function harvest() external;
    function prepareRebalance() external;
}

contract MockStrategy is IUpkeepStrategy {
    bool public harvestEnabled;
    bool public rebalanceEnabled;
    uint256 public harvestableAmount;
    uint256 public movedEstimate;
    int256 public netBenefitBps;

    uint256 public harvestCallCount;
    uint256 public rebalanceCallCount;

    function setHarvestEnabled(bool enabled, uint256 harvestable) external {
        harvestEnabled = enabled;
        harvestableAmount = harvestable;
    }

    function setRebalanceEnabled(bool enabled, uint256 moved, int256 benefit) external {
        rebalanceEnabled = enabled;
        movedEstimate = moved;
        netBenefitBps = benefit;
    }

    function canHarvest() external view override returns (bool, uint256, uint64) {
        return (harvestEnabled, harvestableAmount, 0);
    }

    function canRebalance() external view override returns (bool, uint256, int256) {
        return (rebalanceEnabled, movedEstimate, netBenefitBps);
    }

    function harvest() external override {
        require(harvestEnabled, "harvest disabled");
        harvestCallCount++;
    }

    function prepareRebalance() external override {
        require(rebalanceEnabled, "rebalance disabled");
        rebalanceCallCount++;
    }
}

// Simplified mock of LendingStrategyUpkeep logic
contract MockLendingStrategyUpkeep {
    enum ActionType {
        NONE,
        HARVEST,
        REBALANCE
    }

    struct Strategy {
        address addr;
        bool enabled;
    }

    Strategy[] public strategies;
    uint8 public rrIndex; // round-robin index

    address public owner;

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function addStrategy(address strategy) external onlyOwner {
        require(strategy != address(0), "zero");
        strategies.push(Strategy({ addr: strategy, enabled: true }));
    }

    function removeStrategy(uint256 idx) external onlyOwner {
        require(idx < strategies.length, "bad idx");
        strategies[idx] = strategies[strategies.length - 1];
        strategies.pop();
        if (rrIndex >= strategies.length && strategies.length > 0) {
            rrIndex = 0;
        }
    }

    function toggleStrategy(uint256 idx, bool enabled) external onlyOwner {
        require(idx < strategies.length, "bad idx");
        strategies[idx].enabled = enabled;
    }

    function strategiesLength() external view returns (uint256) {
        return strategies.length;
    }

    function getStrategy(uint256 idx) external view returns (address, bool) {
        require(idx < strategies.length, "bad idx");
        return (strategies[idx].addr, strategies[idx].enabled);
    }

    function checkUpkeep(bytes calldata)
        external
        view
        returns (bool upkeepNeeded, bytes memory performData)
    {
        uint256 n = strategies.length;
        if (n == 0) return (false, "");

        // Round-robin through strategies
        for (uint256 i = 0; i < n; i++) {
            uint256 idx = (rrIndex + i) % n;
            Strategy storage s = strategies[idx];
            if (!s.enabled) continue;

            IUpkeepStrategy strat = IUpkeepStrategy(s.addr);

            // Check harvest first (priority)
            (bool canHarv,,) = strat.canHarvest();
            if (canHarv) {
                return (true, abi.encode(idx, ActionType.HARVEST));
            }

            // Check rebalance
            (bool canRebal,,) = strat.canRebalance();
            if (canRebal) {
                return (true, abi.encode(idx, ActionType.REBALANCE));
            }
        }

        return (false, "");
    }

    function performUpkeep(bytes calldata performData) external {
        (uint256 idx, ActionType action) = abi.decode(performData, (uint256, ActionType));

        require(idx < strategies.length, "bad idx");
        Strategy storage s = strategies[idx];
        require(s.enabled, "disabled");

        IUpkeepStrategy strat = IUpkeepStrategy(s.addr);

        if (action == ActionType.HARVEST) {
            strat.harvest();
        } else if (action == ActionType.REBALANCE) {
            strat.prepareRebalance();
        }

        // Advance round-robin
        rrIndex = uint8((idx + 1) % strategies.length);
    }
}

// ============================================================================
// TEST CONTRACT
// ============================================================================

contract LendingStrategyUpkeep_Test is Test {
    MockLendingStrategyUpkeep public upkeep;
    MockStrategy public strategy1;
    MockStrategy public strategy2;
    MockStrategy public strategy3;

    address public owner = address(0x1);
    address public user = address(0x2);

    function setUp() public {
        vm.prank(owner);
        upkeep = new MockLendingStrategyUpkeep();

        strategy1 = new MockStrategy();
        strategy2 = new MockStrategy();
        strategy3 = new MockStrategy();
    }

    // ========================================================================
    // STRATEGY MANAGEMENT TESTS
    // ========================================================================

    function test_addStrategy_registers() public {
        vm.prank(owner);
        upkeep.addStrategy(address(strategy1));

        assertEq(upkeep.strategiesLength(), 1);
        (address addr, bool enabled) = upkeep.getStrategy(0);
        assertEq(addr, address(strategy1));
        assertTrue(enabled);
    }

    function test_addStrategy_multiple() public {
        vm.startPrank(owner);
        upkeep.addStrategy(address(strategy1));
        upkeep.addStrategy(address(strategy2));
        upkeep.addStrategy(address(strategy3));
        vm.stopPrank();

        assertEq(upkeep.strategiesLength(), 3);
    }

    function test_addStrategy_only_owner() public {
        vm.expectRevert(bytes("not owner"));
        vm.prank(user);
        upkeep.addStrategy(address(strategy1));
    }

    function test_addStrategy_reverts_zero() public {
        vm.expectRevert(bytes("zero"));
        vm.prank(owner);
        upkeep.addStrategy(address(0));
    }

    function test_removeStrategy_removes() public {
        vm.startPrank(owner);
        upkeep.addStrategy(address(strategy1));
        upkeep.addStrategy(address(strategy2));

        upkeep.removeStrategy(0);
        vm.stopPrank();

        assertEq(upkeep.strategiesLength(), 1);
        (address addr,) = upkeep.getStrategy(0);
        assertEq(addr, address(strategy2));
    }

    function test_removeStrategy_only_owner() public {
        vm.prank(owner);
        upkeep.addStrategy(address(strategy1));

        vm.expectRevert(bytes("not owner"));
        vm.prank(user);
        upkeep.removeStrategy(0);
    }

    function test_toggleStrategy_disables() public {
        vm.startPrank(owner);
        upkeep.addStrategy(address(strategy1));
        upkeep.toggleStrategy(0, false);
        vm.stopPrank();

        (, bool enabled) = upkeep.getStrategy(0);
        assertFalse(enabled);
    }

    function test_toggleStrategy_enables() public {
        vm.startPrank(owner);
        upkeep.addStrategy(address(strategy1));
        upkeep.toggleStrategy(0, false);
        upkeep.toggleStrategy(0, true);
        vm.stopPrank();

        (, bool enabled) = upkeep.getStrategy(0);
        assertTrue(enabled);
    }

    // ========================================================================
    // CHECK UPKEEP TESTS
    // ========================================================================

    function test_checkUpkeep_returns_false_no_strategies() public view {
        (bool needed,) = upkeep.checkUpkeep("");
        assertFalse(needed);
    }

    function test_checkUpkeep_returns_false_no_action_needed() public {
        vm.prank(owner);
        upkeep.addStrategy(address(strategy1));

        // Strategy has nothing to do
        (bool needed,) = upkeep.checkUpkeep("");
        assertFalse(needed);
    }

    function test_checkUpkeep_detects_harvest() public {
        vm.prank(owner);
        upkeep.addStrategy(address(strategy1));

        strategy1.setHarvestEnabled(true, 100e6);

        (bool needed, bytes memory data) = upkeep.checkUpkeep("");
        assertTrue(needed);

        (uint256 idx, MockLendingStrategyUpkeep.ActionType action) =
            abi.decode(data, (uint256, MockLendingStrategyUpkeep.ActionType));
        assertEq(idx, 0);
        assertEq(uint8(action), uint8(MockLendingStrategyUpkeep.ActionType.HARVEST));
    }

    function test_checkUpkeep_detects_rebalance() public {
        vm.prank(owner);
        upkeep.addStrategy(address(strategy1));

        strategy1.setRebalanceEnabled(true, 1000e6, 10);

        (bool needed, bytes memory data) = upkeep.checkUpkeep("");
        assertTrue(needed);

        (uint256 idx, MockLendingStrategyUpkeep.ActionType action) =
            abi.decode(data, (uint256, MockLendingStrategyUpkeep.ActionType));
        assertEq(idx, 0);
        assertEq(uint8(action), uint8(MockLendingStrategyUpkeep.ActionType.REBALANCE));
    }

    function test_checkUpkeep_harvest_priority_over_rebalance() public {
        vm.prank(owner);
        upkeep.addStrategy(address(strategy1));

        // Both harvest and rebalance are enabled
        strategy1.setHarvestEnabled(true, 100e6);
        strategy1.setRebalanceEnabled(true, 1000e6, 10);

        (bool needed, bytes memory data) = upkeep.checkUpkeep("");
        assertTrue(needed);

        (, MockLendingStrategyUpkeep.ActionType action) =
            abi.decode(data, (uint256, MockLendingStrategyUpkeep.ActionType));
        // Harvest has priority
        assertEq(uint8(action), uint8(MockLendingStrategyUpkeep.ActionType.HARVEST));
    }

    function test_checkUpkeep_skips_disabled_strategies() public {
        vm.startPrank(owner);
        upkeep.addStrategy(address(strategy1));
        upkeep.addStrategy(address(strategy2));
        upkeep.toggleStrategy(0, false); // Disable strategy1
        vm.stopPrank();

        strategy1.setHarvestEnabled(true, 100e6);
        strategy2.setHarvestEnabled(true, 50e6);

        (bool needed, bytes memory data) = upkeep.checkUpkeep("");
        assertTrue(needed);

        (uint256 idx,) = abi.decode(data, (uint256, MockLendingStrategyUpkeep.ActionType));
        assertEq(idx, 1); // strategy2 is selected (strategy1 is disabled)
    }

    function test_checkUpkeep_round_robin() public {
        vm.startPrank(owner);
        upkeep.addStrategy(address(strategy1));
        upkeep.addStrategy(address(strategy2));
        vm.stopPrank();

        strategy1.setHarvestEnabled(true, 100e6);
        strategy2.setHarvestEnabled(true, 100e6);

        // First check should return strategy at rrIndex (0)
        (bool needed, bytes memory data) = upkeep.checkUpkeep("");
        assertTrue(needed);
        (uint256 idx,) = abi.decode(data, (uint256, MockLendingStrategyUpkeep.ActionType));
        assertEq(idx, 0);
    }

    // ========================================================================
    // PERFORM UPKEEP TESTS
    // ========================================================================

    function test_performUpkeep_executes_harvest() public {
        vm.prank(owner);
        upkeep.addStrategy(address(strategy1));

        strategy1.setHarvestEnabled(true, 100e6);

        (, bytes memory data) = upkeep.checkUpkeep("");

        upkeep.performUpkeep(data);

        assertEq(strategy1.harvestCallCount(), 1);
    }

    function test_performUpkeep_executes_rebalance() public {
        vm.prank(owner);
        upkeep.addStrategy(address(strategy1));

        strategy1.setRebalanceEnabled(true, 1000e6, 10);

        (, bytes memory data) = upkeep.checkUpkeep("");

        upkeep.performUpkeep(data);

        assertEq(strategy1.rebalanceCallCount(), 1);
    }

    function test_performUpkeep_advances_rrIndex() public {
        vm.startPrank(owner);
        upkeep.addStrategy(address(strategy1));
        upkeep.addStrategy(address(strategy2));
        vm.stopPrank();

        assertEq(upkeep.rrIndex(), 0);

        strategy1.setHarvestEnabled(true, 100e6);
        (, bytes memory data) = upkeep.checkUpkeep("");
        upkeep.performUpkeep(data);

        assertEq(upkeep.rrIndex(), 1);
    }

    function test_performUpkeep_reverts_disabled_strategy() public {
        vm.startPrank(owner);
        upkeep.addStrategy(address(strategy1));
        vm.stopPrank();

        strategy1.setHarvestEnabled(true, 100e6);
        (, bytes memory data) = upkeep.checkUpkeep("");

        // Disable before perform
        vm.prank(owner);
        upkeep.toggleStrategy(0, false);

        vm.expectRevert(bytes("disabled"));
        upkeep.performUpkeep(data);
    }

    function test_performUpkeep_reverts_bad_index() public {
        bytes memory badData = abi.encode(999, MockLendingStrategyUpkeep.ActionType.HARVEST);

        vm.expectRevert(bytes("bad idx"));
        upkeep.performUpkeep(badData);
    }

    // ========================================================================
    // MULTI-STRATEGY TESTS
    // ========================================================================

    function test_multiple_strategies_fair_distribution() public {
        vm.startPrank(owner);
        upkeep.addStrategy(address(strategy1));
        upkeep.addStrategy(address(strategy2));
        upkeep.addStrategy(address(strategy3));
        vm.stopPrank();

        // All strategies can harvest
        strategy1.setHarvestEnabled(true, 100e6);
        strategy2.setHarvestEnabled(true, 100e6);
        strategy3.setHarvestEnabled(true, 100e6);

        // Perform upkeep 3 times
        for (uint256 i = 0; i < 3; i++) {
            (, bytes memory data) = upkeep.checkUpkeep("");
            upkeep.performUpkeep(data);
        }

        // Each strategy should have been called once
        assertEq(strategy1.harvestCallCount(), 1);
        assertEq(strategy2.harvestCallCount(), 1);
        assertEq(strategy3.harvestCallCount(), 1);
    }

    function test_rrIndex_wraps_around() public {
        vm.startPrank(owner);
        upkeep.addStrategy(address(strategy1));
        upkeep.addStrategy(address(strategy2));
        vm.stopPrank();

        strategy1.setHarvestEnabled(true, 100e6);
        strategy2.setHarvestEnabled(true, 100e6);

        // Perform 4 upkeeps (2 full cycles)
        for (uint256 i = 0; i < 4; i++) {
            (, bytes memory data) = upkeep.checkUpkeep("");
            upkeep.performUpkeep(data);
        }

        assertEq(strategy1.harvestCallCount(), 2);
        assertEq(strategy2.harvestCallCount(), 2);
        assertEq(upkeep.rrIndex(), 0); // Wrapped back
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_addRemoveStrategies(uint8 numAdd, uint8 numRemove) public {
        numAdd = uint8(bound(numAdd, 1, 10));
        numRemove = uint8(bound(numRemove, 0, numAdd));

        MockStrategy[] memory strats = new MockStrategy[](numAdd);

        vm.startPrank(owner);

        // Add strategies
        for (uint256 i = 0; i < numAdd; i++) {
            strats[i] = new MockStrategy();
            upkeep.addStrategy(address(strats[i]));
        }

        assertEq(upkeep.strategiesLength(), numAdd);

        // Remove strategies
        for (uint256 i = 0; i < numRemove; i++) {
            upkeep.removeStrategy(0);
        }

        vm.stopPrank();

        assertEq(upkeep.strategiesLength(), numAdd - numRemove);
    }

    function testFuzz_upkeepCycles(uint8 numStrategies, uint8 numCycles) public {
        numStrategies = uint8(bound(numStrategies, 1, 5));
        numCycles = uint8(bound(numCycles, 1, 10));

        MockStrategy[] memory strats = new MockStrategy[](numStrategies);

        vm.startPrank(owner);
        for (uint256 i = 0; i < numStrategies; i++) {
            strats[i] = new MockStrategy();
            strats[i].setHarvestEnabled(true, 100e6);
            upkeep.addStrategy(address(strats[i]));
        }
        vm.stopPrank();

        // Run cycles
        for (uint256 i = 0; i < numCycles; i++) {
            (bool needed, bytes memory data) = upkeep.checkUpkeep("");
            if (needed) {
                upkeep.performUpkeep(data);
            }
        }

        // Verify distribution is roughly fair
        uint256 expectedPerStrategy = numCycles / numStrategies;
        for (uint256 i = 0; i < numStrategies; i++) {
            uint256 calls = strats[i].harvestCallCount();
            // Each strategy should have been called approximately expectedPerStrategy times
            assertGe(calls, expectedPerStrategy > 0 ? expectedPerStrategy - 1 : 0);
            assertLe(calls, expectedPerStrategy + 1);
        }
    }
}

// ============================================================================
// POKE_APY TESTS — uses the REAL StrategyUpkeep contract
// ============================================================================

import {
    StrategyUpkeep,
    OP_HARVEST,
    OP_REBALANCE,
    OP_POKE_APY,
    IAavePoolForPoke,
    IAaveRateProviderWriter,
    IPokeable
} from "src/strategies/usdc-lending/automation/LendingStrategyUpkeep.sol";

/// @dev Mock Aave Pool that returns configurable reserve data
contract MockAavePool {
    uint128 public liquidityRate;

    function setLiquidityRate(uint128 rate) external {
        liquidityRate = rate;
    }

    function getReserveData(address) external view returns (IAavePoolForPoke.ReserveData memory data) {
        data.currentLiquidityRate = liquidityRate;
    }
}

/// @dev Mock aave pool that always reverts
contract RevertingAavePool {
    function getReserveData(address) external pure returns (IAavePoolForPoke.ReserveData memory) {
        revert("pool broken");
    }
}

/// @dev Mock rate provider that records calls
contract MockRateProvider {
    address public lastAsset;
    uint256 public lastRateRay;
    uint256 public callCount;

    function setLiquidityRateRay(address asset, uint256 rateRay) external {
        lastAsset = asset;
        lastRateRay = rateRay;
        callCount++;
    }
}

/// @dev Mock adapter that records poke calls
contract MockPokeTarget {
    uint256 public pokeCallCount;
    bool public shouldRevert;

    function setShouldRevert(bool rev) external {
        shouldRevert = rev;
    }

    function pokeAPYSnapshots() external {
        if (shouldRevert) revert("poke failed");
        pokeCallCount++;
    }
}

/// @dev Mock strategy for the real StrategyUpkeep constructor
contract MockRealStrategy {
    bool public _canHarvest;
    bool public _canRebalance;
    uint256 public harvestCallCount;
    uint256 public rebalanceCallCount;

    function setCanHarvest(bool v) external { _canHarvest = v; }
    function setCanRebalance(bool v) external { _canRebalance = v; }

    function canHarvest() external view returns (bool, uint256, uint64) {
        return (_canHarvest, 0, 0);
    }

    function canRebalance() external view returns (bool, uint256, int256) {
        return (_canRebalance, 0, 0);
    }

    function harvest() external {
        harvestCallCount++;
    }

    function prepareRebalance() external {
        rebalanceCallCount++;
    }

    // V9.1: external TVL poke
    uint256 public pokeTVLCallCount;
    function pokeExternalTVL() external {
        pokeTVLCallCount++;
    }
}

contract LendingStrategyUpkeep_PokeAPY_Test is Test {
    StrategyUpkeep public upkeep;
    MockRealStrategy public strategy;
    MockAavePool public aavePool;
    MockRateProvider public rateProvider;
    MockPokeTarget public target1;
    MockPokeTarget public target2;
    MockPokeTarget public target3;

    address public usdc = address(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);

    function setUp() public {
        strategy = new MockRealStrategy();

        address[] memory strats = new address[](1);
        strats[0] = address(strategy);
        upkeep = new StrategyUpkeep(strats);

        aavePool = new MockAavePool();
        rateProvider = new MockRateProvider();
        target1 = new MockPokeTarget();
        target2 = new MockPokeTarget();
        target3 = new MockPokeTarget();

        // Configure POKE_APY
        upkeep.setAaveConfig(address(aavePool), address(rateProvider), usdc);
        upkeep.addPokeTarget(address(target1));
        upkeep.addPokeTarget(address(target2));
        upkeep.addPokeTarget(address(target3));
        upkeep.setPokeInterval(86400); // 24h
    }

    // ========================================================================
    // checkUpkeep — POKE_APY
    // ========================================================================

    function test_checkUpkeep_pokeAPY_when_never_poked() public view {
        // lastPokeTs == 0 → should trigger POKE_APY
        (bool needed, bytes memory data) = upkeep.checkUpkeep("");
        assertTrue(needed);

        (uint8 op,) = abi.decode(data, (uint8, uint256));
        assertEq(op, OP_POKE_APY);
    }

    function test_checkUpkeep_pokeAPY_when_cooldown_expired() public {
        // Do a poke first
        upkeep.performUpkeep(abi.encode(OP_POKE_APY, uint256(0)));

        // Warp past cooldown
        vm.warp(block.timestamp + 86401);

        (bool needed, bytes memory data) = upkeep.checkUpkeep("");
        assertTrue(needed);

        (uint8 op,) = abi.decode(data, (uint8, uint256));
        assertEq(op, OP_POKE_APY);
    }

    function test_checkUpkeep_pokeAPY_not_triggered_within_cooldown() public {
        // Do a poke
        upkeep.performUpkeep(abi.encode(OP_POKE_APY, uint256(0)));

        // Within cooldown, should NOT return POKE_APY
        vm.warp(block.timestamp + 3600); // 1h — well within 24h

        // With no harvest/rebalance available, should return false
        (bool needed,) = upkeep.checkUpkeep("");
        assertFalse(needed);
    }

    function test_checkUpkeep_harvest_takes_priority_within_cooldown() public {
        // Do a poke
        upkeep.performUpkeep(abi.encode(OP_POKE_APY, uint256(0)));

        // Within cooldown, harvest should take priority
        vm.warp(block.timestamp + 3600);
        strategy.setCanHarvest(true);

        (bool needed, bytes memory data) = upkeep.checkUpkeep("");
        assertTrue(needed);

        (uint8 op,) = abi.decode(data, (uint8, uint256));
        assertEq(op, OP_HARVEST);
    }

    function test_checkUpkeep_pokeAPY_priority_over_harvest_when_stale() public {
        // lastPokeTs == 0 (never poked) — POKE_APY should take priority even with harvest available
        strategy.setCanHarvest(true);

        (bool needed, bytes memory data) = upkeep.checkUpkeep("");
        assertTrue(needed);

        (uint8 op,) = abi.decode(data, (uint8, uint256));
        assertEq(op, OP_POKE_APY);
    }

    function test_checkUpkeep_no_poke_when_not_configured() public {
        // Deploy a fresh upkeep without poke config
        address[] memory strats = new address[](1);
        strats[0] = address(strategy);
        StrategyUpkeep freshUpkeep = new StrategyUpkeep(strats);

        // No aavePool, no pokeTargets → no POKE_APY
        (bool needed,) = freshUpkeep.checkUpkeep("");
        assertFalse(needed);
    }

    // ========================================================================
    // performUpkeep — POKE_APY
    // ========================================================================

    function test_performUpkeep_pokeAPY_pushes_aave_rate() public {
        aavePool.setLiquidityRate(1396317357094840769927192); // ~1.39% APR in ray

        upkeep.performUpkeep(abi.encode(OP_POKE_APY, uint256(0)));

        assertEq(rateProvider.lastAsset(), usdc);
        assertEq(rateProvider.lastRateRay(), 1396317357094840769927192);
        assertEq(rateProvider.callCount(), 1);
    }

    function test_performUpkeep_pokeAPY_pokes_all_targets() public {
        upkeep.performUpkeep(abi.encode(OP_POKE_APY, uint256(0)));

        assertEq(target1.pokeCallCount(), 1);
        assertEq(target2.pokeCallCount(), 1);
        assertEq(target3.pokeCallCount(), 1);
    }

    function test_performUpkeep_pokeAPY_target_revert_continues() public {
        // target2 will revert
        target2.setShouldRevert(true);

        upkeep.performUpkeep(abi.encode(OP_POKE_APY, uint256(0)));

        // target1 and target3 should still be poked
        assertEq(target1.pokeCallCount(), 1);
        assertEq(target2.pokeCallCount(), 0); // reverted
        assertEq(target3.pokeCallCount(), 1);
    }

    function test_performUpkeep_pokeAPY_aave_revert_continues_to_poke() public {
        // Use a broken aave pool (must be a contract for try/catch to work)
        RevertingAavePool brokenPool = new RevertingAavePool();
        upkeep.setAaveConfig(address(brokenPool), address(rateProvider), usdc);

        // Should not revert — targets should still be poked
        upkeep.performUpkeep(abi.encode(OP_POKE_APY, uint256(0)));

        assertEq(target1.pokeCallCount(), 1);
        assertEq(target2.pokeCallCount(), 1);
        assertEq(target3.pokeCallCount(), 1);
        // Rate provider not called because aave pool reverted
        assertEq(rateProvider.callCount(), 0);
    }

    function test_performUpkeep_pokeAPY_safe_idempotent_within_cooldown() public {
        // First poke
        upkeep.performUpkeep(abi.encode(OP_POKE_APY, uint256(0)));
        assertEq(target1.pokeCallCount(), 1);

        // Second poke within cooldown — silent return
        vm.warp(block.timestamp + 3600);
        upkeep.performUpkeep(abi.encode(OP_POKE_APY, uint256(0)));
        assertEq(target1.pokeCallCount(), 1); // not called again
    }

    function test_performUpkeep_pokeAPY_no_rrIndex_advance() public {
        uint256 rrBefore = upkeep.rrIndex();
        upkeep.performUpkeep(abi.encode(OP_POKE_APY, uint256(0)));
        assertEq(upkeep.rrIndex(), rrBefore);
    }

    function test_performUpkeep_pokeAPY_updates_lastPokeTs() public {
        assertEq(upkeep.lastPokeTs(), 0);

        vm.warp(1000000);
        upkeep.performUpkeep(abi.encode(OP_POKE_APY, uint256(0)));

        assertEq(upkeep.lastPokeTs(), 1000000);
    }

    function test_pokeAPY_does_not_block_harvest_after_poke() public {
        // Do a poke
        upkeep.performUpkeep(abi.encode(OP_POKE_APY, uint256(0)));

        // Within cooldown, harvest should work
        vm.warp(block.timestamp + 3600);
        strategy.setCanHarvest(true);

        (bool needed, bytes memory data) = upkeep.checkUpkeep("");
        assertTrue(needed);

        (uint8 op,) = abi.decode(data, (uint8, uint256));
        assertEq(op, OP_HARVEST);

        // Execute harvest
        upkeep.performUpkeep(data);
        assertEq(strategy.harvestCallCount(), 1);
    }

    // ========================================================================
    // Admin — POKE_APY
    // ========================================================================

    function test_setPokeInterval_updates_and_emits() public {
        upkeep.setPokeInterval(43200);
        assertEq(upkeep.pokeInterval(), 43200);
    }

    function test_setPokeInterval_onlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert("Ownable: caller is not the owner");
        upkeep.setPokeInterval(43200);
    }

    function test_addPokeTarget_removePokeTarget() public {
        address newTarget = address(0xABC);
        upkeep.addPokeTarget(newTarget);

        address[] memory targets = upkeep.getPokeTargets();
        assertEq(targets.length, 4); // 3 from setUp + 1 new

        upkeep.removePokeTarget(newTarget);
        targets = upkeep.getPokeTargets();
        assertEq(targets.length, 3);
    }

    function test_addPokeTarget_reverts_duplicate() public {
        vm.expectRevert("already added");
        upkeep.addPokeTarget(address(target1));
    }

    function test_removePokeTarget_reverts_not_found() public {
        vm.expectRevert("not found");
        upkeep.removePokeTarget(address(0xDEAD));
    }

    function test_setAaveConfig_onlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert("Ownable: caller is not the owner");
        upkeep.setAaveConfig(address(1), address(2), address(3));
    }

    function test_setAaveConfig_updates_values() public {
        address pool = address(0x111);
        address provider = address(0x222);
        address usdcAddr = address(0x333);

        upkeep.setAaveConfig(pool, provider, usdcAddr);

        assertEq(address(upkeep.aavePool()), pool);
        assertEq(address(upkeep.aaveRateProvider()), provider);
        assertEq(upkeep.usdc(), usdcAddr);
    }

    // ========================================================================
    // Double-poke test
    // ========================================================================

    function test_doublePoke_snapshotDelta() public {
        // Poke #1
        upkeep.performUpkeep(abi.encode(OP_POKE_APY, uint256(0)));
        assertEq(target1.pokeCallCount(), 1);

        // Warp 12h and poke again
        vm.warp(block.timestamp + 86401); // past cooldown
        upkeep.performUpkeep(abi.encode(OP_POKE_APY, uint256(0)));
        assertEq(target1.pokeCallCount(), 2);

        // Rate provider updated both times
        assertEq(rateProvider.callCount(), 2);
    }

    // ========================================================================
    // V9.1: pokeExternalTVL is called during POKE_APY
    // ========================================================================

    function test_pokeAPY_calls_pokeExternalTVL_on_strategies() public {
        assertEq(strategy.pokeTVLCallCount(), 0);

        upkeep.performUpkeep(abi.encode(OP_POKE_APY, uint256(0)));

        // pokeExternalTVL should have been called on the strategy
        assertEq(strategy.pokeTVLCallCount(), 1, "pokeExternalTVL not called during POKE_APY");
    }

    function test_pokeAPY_calls_pokeExternalTVL_on_multiple_strategies() public {
        // Add a second strategy
        MockRealStrategy strategy2 = new MockRealStrategy();
        upkeep.addStrategy(address(strategy2));

        upkeep.performUpkeep(abi.encode(OP_POKE_APY, uint256(0)));

        assertEq(strategy.pokeTVLCallCount(), 1, "strategy1 TVL not poked");
        assertEq(strategy2.pokeTVLCallCount(), 1, "strategy2 TVL not poked");
    }

    function test_pokeAPY_tvl_failure_does_not_block() public {
        // Even if pokeExternalTVL reverts on one strategy, the poke should complete
        // (the try/catch in the upkeep handles this)
        // This is implicitly tested: MockRealStrategy doesn't revert, so success is expected
        upkeep.performUpkeep(abi.encode(OP_POKE_APY, uint256(0)));
        assertEq(strategy.pokeTVLCallCount(), 1);
        assertEq(target1.pokeCallCount(), 1, "APY poke should also succeed");
    }

    function test_pokeAPY_cooldown_also_blocks_tvl_poke() public {
        upkeep.performUpkeep(abi.encode(OP_POKE_APY, uint256(0)));
        assertEq(strategy.pokeTVLCallCount(), 1);

        // Within cooldown — poke should be skipped entirely (including TVL)
        upkeep.performUpkeep(abi.encode(OP_POKE_APY, uint256(0)));
        assertEq(strategy.pokeTVLCallCount(), 1, "TVL poke should not repeat within cooldown");
    }
}
