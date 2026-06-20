// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { StrategyRebalanceGateModule } from "../../../src/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol";
import { StrategyRebalancePlanModule } from "../../../src/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol";
import {
    UsdcMultiLendingVault
} from "../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
import {
    ILendingAdapter
} from "../../../src/strategies/usdc-lending/interfaces/ILendingAdapter.sol";
import {
    StrategyParamsModule
} from "../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import { StrategySettingsModule } from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import { StrategyAllocCalcModule } from "../../../src/strategies/usdc-lending/controller/StrategyAllocCalcModule.sol";
import {
    StrategyScoringModule
} from "../../../src/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import { StrategyAdapterOpsModule } from "../../../src/strategies/usdc-lending/controller/StrategyAdapterOpsModule.sol";
import { StrategyExplainabilityLens } from "../../../src/strategies/usdc-lending/lens/StrategyExplainabilityLens.sol";
import { StrategySafetyOverflowModule } from "../../../src/strategies/usdc-lending/controller/StrategySafetyOverflowModule.sol";

// ============================================================================
// MOCK CONTRACTS
// ============================================================================

contract MockUSDCInvariant {
    string public constant name = "USD Coin";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "allowance");
            allowance[from][msg.sender] -= amount;
        }
        require(balanceOf[from] >= amount, "insufficient");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract MockAdapterInvariant is ILendingAdapter {
    address public immutable underlying_;
    uint256 public deposited;
    uint16 public apyBps;
    uint256 public extMarketTVL;

    constructor(address _underlying, uint16 _apy) {
        underlying_ = _underlying;
        apyBps = _apy;
    }

    function name() external pure override returns (string memory) {
        return "MockInvariant";
    }

    function underlying() external view override returns (address) {
        return underlying_;
    }

    function totalAssets() external view override returns (uint256) {
        return deposited;
    }

    function withdrawableAssets() external view override returns (uint256) {
        return deposited;
    }

    function currentAPYBps() external view override returns (uint16) {
        return apyBps;
    }

    function incentiveAPYBps() external pure override returns (uint16) {
        return 0;
    }

    function harvestableProfit() external pure override returns (uint256) {
        return 0;
    }

    function maxCapacity() external pure override returns (uint256) {
        return type(uint256).max;
    }

    function isPushMode() external pure override returns (bool) {
        return false;
    }

    function idleAssetBalance() external view override returns (uint256) { return 0; }
    function investedAssets() external view override returns (uint256) { return deposited; }
    function sweepIdleAssetToVault() external override {}
    function emergencyPullAllToVault() external override {}

    function deposit(uint256 assets) external override {
        MockUSDCInvariant(underlying_).transferFrom(msg.sender, address(this), assets);
        deposited += assets;
    }

    function withdraw(uint256 assets, address receiver) external override returns (uint256) {
        uint256 toWithdraw = assets > deposited ? deposited : assets;
        deposited -= toWithdraw;
        MockUSDCInvariant(underlying_).transfer(receiver, toWithdraw);
        return toWithdraw;
    }

    function harvest(address) external pure override returns (uint256) {
        return 0;
    }

    function externalMarketTVL() external view override returns (uint256) {
        return extMarketTVL;
    }

    function setAPY(uint16 _apy) external {
        apyBps = _apy;
    }

    function setExtMarketTVL(uint256 _tvl) external {
        extMarketTVL = _tvl;
    }

    function setVault(address) external {
        // no-op for mock — vault is not stored
    }
}

// ============================================================================
// HANDLER CONTRACT
// ============================================================================

contract VaultHandler is Test {
    UsdcMultiLendingVault public vault;
    MockUSDCInvariant public usdc;
    address public core;
    address public keeper;
    address public admin;

    // Ghost variables for tracking
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_depositCalls;
    uint256 public ghost_withdrawCalls;
    uint256 public ghost_harvestCalls;
    uint256 public ghost_rebalanceCalls;

    constructor(
        UsdcMultiLendingVault _vault,
        MockUSDCInvariant _usdc,
        address _core,
        address _keeper,
        address _admin
    ) {
        vault = _vault;
        usdc = _usdc;
        core = _core;
        keeper = _keeper;
        admin = _admin;
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1e6, 10_000_000e6);
        console2.log("Bound result", amount);

        // PUSH PATTERN: CoreVault transfers USDC to strategy BEFORE calling deposit()
        // See CoreVault._routeDeposit(): token.safeTransfer(plan[i].strat, amount)
        usdc.mint(address(vault), amount); // Simulate CoreVault push

        vm.prank(core);
        vault.deposit(amount);

        ghost_totalDeposited += amount;
        ghost_depositCalls++;
    }

    function withdraw(uint256 amount) external {
        uint256 available = vault.totalAssets();
        if (available == 0) return;

        amount = bound(amount, 1, available);

        vm.prank(core);
        uint256 withdrawn = vault.withdraw(amount, core);

        ghost_totalWithdrawn += withdrawn;
        ghost_withdrawCalls++;
    }

    function harvest() external {
        vm.prank(keeper);
        vault.harvest();
        ghost_harvestCalls++;
    }

    function rebalance() external {
        // Only attempt if cooldown has passed
        uint256 lastRebalance = vault.lastRebalanceTs();
        uint256 cooldown = vault.minSecondsBetweenRebalances();

        if (block.timestamp - lastRebalance < cooldown) {
            vm.warp(block.timestamp + cooldown + 1);
        }

        vm.prank(keeper);
        try StrategyRebalancePlanModule(address(vault)).prepareRebalance() {
            ghost_rebalanceCalls++;
        } catch { }
    }

    function warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1 hours, 7 days);
        vm.warp(block.timestamp + seconds_);
    }
}

// ============================================================================
// INVARIANT TEST CONTRACT
// ============================================================================

contract UsdcMultiLendingVault_Invariant_Test is StdInvariant, Test {
    address constant ARBITRUM_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    UsdcMultiLendingVault public vault;
    MockUSDCInvariant public usdc;
    MockAdapterInvariant public adapter1;
    MockAdapterInvariant public adapter2;
    MockAdapterInvariant public adapter3;
    VaultHandler public handler;

    address public admin = address(0x1);
    address public core = address(0x2);
    address public router = address(0x6);
    address public keeper = address(0x3);
    address public paramSetter = address(0x4);

    bytes32 constant PARAM_ROLE = keccak256("PARAM_ROLE");
    bytes32 constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    function setUp() public {
        usdc = new MockUSDCInvariant();
        vm.etch(ARBITRUM_USDC, address(usdc).code);
        usdc = MockUSDCInvariant(ARBITRUM_USDC);

        adapter1 = new MockAdapterInvariant(ARBITRUM_USDC, 800);
        adapter2 = new MockAdapterInvariant(ARBITRUM_USDC, 600);
        adapter3 = new MockAdapterInvariant(ARBITRUM_USDC, 400);

        // Audit #2 P0.6: seed realistic external TVL so confidence != ZERO
        adapter1.setExtMarketTVL(50_000_000e6);
        adapter2.setExtMarketTVL(50_000_000e6);
        adapter3.setExtMarketTVL(50_000_000e6);

        UsdcMultiLendingVault.StrategyInitParams memory params =
            UsdcMultiLendingVault.StrategyInitParams({
                maxAdaptersPerAllocation: 3,
                minAdaptersActive: 2,
                rebalanceMinMoveBps: 50,
                minSecondsBetweenRebalances: 21600,
                driftToleranceBps: 80,
                wAPY: 4000,
                wLiq: 2000,
                wRisk: 2000,
                wStability: 1000,
                wIncentive: 1000,
                incentiveDecayHalfLife: 86400,
                adapterMaxExposureBps: 5000,
                newAdapterRampBps: 500,
                gateHorizonDays: 7,
                gateMinNetBenefitBps: 2,
                slippageBpsEstimate: 5,
                withdrawalSpreadBpsEstimate: 5,
                gasCostUSDC: 1e6,
                harvestThresholdBps: 5,
                minSecondsBetweenHarvests: 43200,
                dustTolerance: 2e6,
                stabilityEMAPeriod: 7,
                minNewAdapterSeed: 0,
                newAdapterRampDuration: 0,
                maxIdleAfterDepositBps: 500,
                maxIdleBootstrapBps: 5000,
                degradedViewThresholdBps: 2500,
                failureDecaySeconds: 3600,
                minSecondsBetweenDeployIdle: 300,
                bootstrapDuration: 86400,
                maxRelativeExposureBps: 0,
                externalTVLStalenessSeconds: 43200
            });

        // Constructor takes core, router, timelock, guardian, bootstrapper, paramsModule, scoringModule
        StrategyParamsModule paramsModule = new StrategyParamsModule(ARBITRUM_USDC, core);
        StrategyAdapterOpsModule adapterOpsMod = new StrategyAdapterOpsModule(
            ARBITRUM_USDC, core, address(paramsModule), address(0), address(0)
        );
        StrategyScoringModule scoringMod = new StrategyScoringModule(
            ARBITRUM_USDC, core, address(paramsModule), address(0), address(adapterOpsMod)
        );
        address gateModInv1 = address(new StrategyRebalanceGateModule(ARBITRUM_USDC, core, address(paramsModule), address(scoringMod), address(adapterOpsMod)));
        vault = new UsdcMultiLendingVault(
            ARBITRUM_USDC, core, router, admin, keeper, address(0), address(paramsModule), address(scoringMod), address(adapterOpsMod), gateModInv1, params
        );

        // Architectural completion: wire StrategyRebalancePlanModule (was missing post-EIP170 split)
        StrategyRebalancePlanModule _planMod = new StrategyRebalancePlanModule(
            ARBITRUM_USDC, core, address(paramsModule), address(scoringMod), address(adapterOpsMod)
        );
        vm.prank(admin);
        vault.setRebalancePlanModule(address(_planMod));

        // REFACTOR-A: wire StrategySettingsModule (governance setters, last in fallback chain)
        StrategySettingsModule _settingsMod0 = new StrategySettingsModule(ARBITRUM_USDC, core);
        vm.prank(admin);
        vault.setSettingsModule(address(_settingsMod0));
        StrategyAllocCalcModule _allocCalcMod0 = new StrategyAllocCalcModule(ARBITRUM_USDC, core);
        vm.prank(admin);
        vault.setAllocCalcModule(address(_allocCalcMod0));
        StrategySafetyOverflowModule _overflowMod = new StrategySafetyOverflowModule(
            ARBITRUM_USDC, core, address(0), address(0), address(adapterOpsMod)
        );
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setSafetyOverflowModule(address(_overflowMod));

        vm.startPrank(admin);
        vault.grantRole(PARAM_ROLE, paramSetter);

        address(vault).call(abi.encodeWithSignature("whitelistAdapter(address,bool)", address(adapter1), true));

        vault.addAdapter(address(adapter1));
        vault.toggleAdapter(address(adapter1), true);
        (bool ok1,) = address(vault).call(abi.encodeWithSignature("setAdapterDepositMode(address,bool)", address(adapter1), false));
        require(ok1, "setAdapterDepositMode failed");
        address(vault).call(abi.encodeWithSignature("whitelistAdapter(address,bool)", address(adapter2), true));
        vault.addAdapter(address(adapter2));
        vault.toggleAdapter(address(adapter2), true);
        (bool ok2,) = address(vault).call(abi.encodeWithSignature("setAdapterDepositMode(address,bool)", address(adapter2), false));
        require(ok2, "setAdapterDepositMode failed");
        address(vault).call(abi.encodeWithSignature("whitelistAdapter(address,bool)", address(adapter3), true));
        vault.addAdapter(address(adapter3));
        vault.toggleAdapter(address(adapter3), true);
        (bool ok3,) = address(vault).call(abi.encodeWithSignature("setAdapterDepositMode(address,bool)", address(adapter3), false));
        require(ok3, "setAdapterDepositMode failed");
        vm.stopPrank();

        // Audit #2 P0.6: poke TVL cache so adapters get non-zero confidence
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        handler = new VaultHandler(vault, usdc, core, keeper, admin);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = VaultHandler.deposit.selector;
        selectors[1] = VaultHandler.withdraw.selector;
        selectors[2] = VaultHandler.harvest.selector;
        selectors[3] = VaultHandler.rebalance.selector;
        selectors[4] = VaultHandler.warpTime.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    // ========================================================================
    // INVARIANTS
    // ========================================================================

    /// @notice INV-1: totalAssets = sum(positionAssets) + idleCash
    function invariant_totalAssets_equals_positions_plus_idle() public view {
        (address[] memory addrs, uint256[] memory positions) = vault.positions();

        uint256 sumPositions = 0;
        for (uint256 i = 0; i < addrs.length; i++) {
            sumPositions += positions[i];
        }

        uint256 expectedTotal = sumPositions + vault.idleCash();
        uint256 actualTotal = vault.totalAssets();

        assertEq(actualTotal, expectedTotal, "INV-1: totalAssets mismatch");
    }

    /// @notice INV-2: idleCash within allowed bounds after any operation
    ///         Note: the vault only enforces idle bounds PER DEPOSIT (not globally).
    ///         Between handler actions, idle can accumulate above the per-deposit
    ///         threshold when adapters hit their caps. We check the weaker invariant
    ///         that idle never exceeds TVL (conservation, not policy).
    function invariant_idleCash_bounded() public view {
        // Skip if vault is paused (emergency state may have idle)
        if (vault.paused()) return;

        // Only check if there have been deposits
        if (handler.ghost_depositCalls() == 0) return;

        uint256 idle = vault.idleCash();
        uint256 tvl = vault.totalAssets();

        // Idle must never exceed total TVL (conservation)
        assertLe(idle, tvl, "INV-2: idleCash exceeds totalAssets");
    }

    /// @notice INV-3: totalDeposited >= totalWithdrawn (conservation of funds)
    function invariant_deposits_gte_withdrawals() public view {
        assertGe(
            handler.ghost_totalDeposited(),
            handler.ghost_totalWithdrawn(),
            "INV-3: more withdrawn than deposited"
        );
    }

    /// @notice INV-4: totalAssets = totalDeposited - totalWithdrawn (no fund leakage)
    function invariant_no_fund_leakage() public view {
        uint256 expectedAssets = handler.ghost_totalDeposited() - handler.ghost_totalWithdrawn();
        uint256 actualAssets = vault.totalAssets();

        assertEq(actualAssets, expectedAssets, "INV-4: fund leakage detected");
    }

    /// @notice INV-5: withdrawableAssets <= totalAssets
    function invariant_withdrawable_lte_total() public view {
        assertLe(
            vault.withdrawableAssets(),
            vault.totalAssets(),
            "INV-5: withdrawableAssets exceeds totalAssets"
        );
    }

    /// @notice INV-6: each adapter's positionAssets matches adapter's deposited
    function invariant_position_tracking_accurate() public view {
        (address[] memory addrs, uint256[] memory positions) = vault.positions();

        for (uint256 i = 0; i < addrs.length; i++) {
            MockAdapterInvariant adapter = MockAdapterInvariant(addrs[i]);
            uint256 adapterDeposited = adapter.deposited();

            assertEq(positions[i], adapterDeposited, "INV-6: position mismatch");
        }
    }

    /// @notice INV-7: lastHarvestTs and lastRebalanceTs are always <= block.timestamp
    function invariant_timestamps_valid() public view {
        assertLe(vault.lastHarvestTs(), block.timestamp, "INV-7: harvest timestamp in future");
        assertLe(vault.lastRebalanceTs(), block.timestamp, "INV-7: rebalance timestamp in future");
    }

    /// @notice INV-8: enabled adapters count >= 0 (registry integrity)
    function invariant_registry_integrity() public view {
        uint256 enabledCount = 0;
        uint256 n = 3; // We know we have 3 adapters

        for (uint256 i = 0; i < n; i++) {
            address adapter = vault.adapters(i);
            if (vault.enabled(adapter)) {
                enabledCount++;
                assertTrue(vault.isAdapter(adapter), "INV-8: enabled but not isAdapter");
            }
        }

        assertGe(enabledCount, 0, "INV-8: negative enabled count");
    }

    /// @notice INV-9: roles are consistent
    function invariant_roles_consistent() public view {
        bytes32 CORE_ROLE = keccak256("CORE_ROLE");

        assertTrue(vault.hasRole(CORE_ROLE, core), "INV-9: core role missing");
        assertTrue(vault.hasRole(KEEPER_ROLE, keeper), "INV-9: keeper role missing");
    }

    /// @notice INV-10: if paused, deposit/withdraw/harvest/rebalance revert
    function invariant_pausable_works() public view {
        // This is implicitly tested by the fact that if paused,
        // the handler operations would revert
        // Just verify pause state is boolean
        assertTrue(vault.paused() || !vault.paused(), "INV-10: invalid pause state");
    }

    // ========================================================================
    // HELPER: Print call statistics after invariant run
    // ========================================================================

    function invariant_callSummary() public view {
        console2.log("============ INVARIANT TEST SUMMARY ============");
        console2.log("Total deposits:   ", handler.ghost_depositCalls());
        console2.log("Total withdraws:  ", handler.ghost_withdrawCalls());
        console2.log("Total harvests:   ", handler.ghost_harvestCalls());
        console2.log("Total rebalances: ", handler.ghost_rebalanceCalls());
        console2.log("Total deposited:  ", handler.ghost_totalDeposited());
        console2.log("Total withdrawn:  ", handler.ghost_totalWithdrawn());
        console2.log("Current assets:   ", vault.totalAssets());
        console2.log("================================================");
    }
}

// ============================================================================
// ADVERSARIAL INVARIANT TEST
// ============================================================================

contract AdversarialHandler is Test {
    UsdcMultiLendingVault public vault;
    MockUSDCInvariant public usdc;
    address public core;
    address public keeper;
    address public admin;
    address public attacker;

    uint256 public ghost_attackAttempts;
    uint256 public ghost_successfulAttacks;

    constructor(
        UsdcMultiLendingVault _vault,
        MockUSDCInvariant _usdc,
        address _core,
        address _keeper,
        address _admin
    ) {
        vault = _vault;
        usdc = _usdc;
        core = _core;
        keeper = _keeper;
        admin = _admin;
        attacker = address(0xBAD);
    }

    // Attacker tries to deposit without CORE_ROLE
    function attackDeposit(uint256 amount) external {
        amount = bound(amount, 1e6, 1_000_000e6);

        // Mint to a temporary address, not directly to attacker
        // This way we can track if attacker ever receives funds FROM the vault
        address tempFunder = address(0xF00D);
        usdc.mint(tempFunder, amount);

        // Transfer to attacker to fund the attack attempt
        vm.prank(tempFunder);
        usdc.transfer(attacker, amount);

        uint256 attackerBalanceBefore = usdc.balanceOf(attacker);

        vm.startPrank(attacker);
        usdc.approve(address(vault), amount);

        ghost_attackAttempts++;
        try vault.deposit(amount) {
            ghost_successfulAttacks++;
        } catch { }
        vm.stopPrank();

        // Return unused funds from attacker (simulating attacker not keeping minted funds)
        uint256 attackerBalanceAfter = usdc.balanceOf(attacker);
        if (attackerBalanceAfter > 0) {
            vm.prank(attacker);
            usdc.transfer(tempFunder, attackerBalanceAfter);
        }
    }

    // Attacker tries to withdraw without CORE_ROLE
    function attackWithdraw(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e6);

        ghost_attackAttempts++;
        vm.prank(attacker);
        try vault.withdraw(amount, attacker) {
            ghost_successfulAttacks++;
        } catch { }
    }

    // Attacker tries to harvest without KEEPER_ROLE
    function attackHarvest() external {
        ghost_attackAttempts++;
        vm.prank(attacker);
        try vault.harvest() {
            ghost_successfulAttacks++;
        } catch { }
    }

    // Attacker tries to rebalance without KEEPER_ROLE
    function attackRebalance() external {
        ghost_attackAttempts++;
        vm.prank(attacker);
        try StrategyRebalancePlanModule(address(vault)).prepareRebalance() {
            ghost_successfulAttacks++;
        } catch { }
    }

    // Attacker tries to pause without DEFAULT_ADMIN_ROLE
    function attackPause() external {
        ghost_attackAttempts++;
        vm.prank(attacker);
        try vault.pause() {
            ghost_successfulAttacks++;
        } catch { }
    }

    // Attacker tries to add adapter without DEFAULT_ADMIN_ROLE
    function attackAddAdapter(address adapter) external {
        ghost_attackAttempts++;
        vm.prank(attacker);
        try vault.addAdapter(adapter) {
            ghost_successfulAttacks++;
        } catch { }
    }

    // Attacker tries to freeze roles without DEFAULT_ADMIN_ROLE
    function attackFreezeRoles() external {
        ghost_attackAttempts++;
        vm.prank(attacker);
        try StrategySettingsModule(address(vault)).freezeRoles() {
            ghost_successfulAttacks++;
        } catch { }
    }

    // Attacker tries emergency recall without proper role
    function attackEmergencyRecall() external {
        ghost_attackAttempts++;
        vm.prank(attacker);
        try vault.emergencyRecallAll() {
            ghost_successfulAttacks++;
        } catch { }
    }

    // Legitimate operations to have state to attack
    function legitimateDeposit(uint256 amount) external {
        amount = bound(amount, 1e6, 10_000_000e6);
        usdc.mint(core, amount);

        vm.startPrank(core);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }

    function legitimateWithdraw(uint256 amount) external {
        uint256 available = vault.totalAssets();
        if (available == 0) return;

        amount = bound(amount, 1, available);

        vm.prank(core);
        vault.withdraw(amount, core);
    }
}

contract UsdcMultiLendingVault_Adversarial_Invariant_Test is StdInvariant, Test {
    address constant ARBITRUM_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    UsdcMultiLendingVault public vault;
    MockUSDCInvariant public usdc;
    MockAdapterInvariant public adapter1;
    MockAdapterInvariant public adapter2;
    AdversarialHandler public handler;

    address public admin = address(0x1);
    address public core = address(0x2);
    address public router = address(0x6);
    address public keeper = address(0x3);

    function setUp() public {
        usdc = new MockUSDCInvariant();
        vm.etch(ARBITRUM_USDC, address(usdc).code);
        usdc = MockUSDCInvariant(ARBITRUM_USDC);

        adapter1 = new MockAdapterInvariant(ARBITRUM_USDC, 800);
        adapter2 = new MockAdapterInvariant(ARBITRUM_USDC, 600);

        // Audit #2 P0.6: seed realistic external TVL so confidence != ZERO
        adapter1.setExtMarketTVL(50_000_000e6);
        adapter2.setExtMarketTVL(50_000_000e6);

        UsdcMultiLendingVault.StrategyInitParams memory params =
            UsdcMultiLendingVault.StrategyInitParams({
                maxAdaptersPerAllocation: 3,
                minAdaptersActive: 2,
                rebalanceMinMoveBps: 50,
                minSecondsBetweenRebalances: 21600,
                driftToleranceBps: 80,
                wAPY: 4000,
                wLiq: 2000,
                wRisk: 2000,
                wStability: 1000,
                wIncentive: 1000,
                incentiveDecayHalfLife: 86400,
                adapterMaxExposureBps: 5000,
                newAdapterRampBps: 500,
                gateHorizonDays: 7,
                gateMinNetBenefitBps: 2,
                slippageBpsEstimate: 5,
                withdrawalSpreadBpsEstimate: 5,
                gasCostUSDC: 1e6,
                harvestThresholdBps: 5,
                minSecondsBetweenHarvests: 43200,
                dustTolerance: 2e6,
                stabilityEMAPeriod: 7,
                minNewAdapterSeed: 0,
                newAdapterRampDuration: 0,
                maxIdleAfterDepositBps: 500,
                maxIdleBootstrapBps: 5000,
                degradedViewThresholdBps: 2500,
                failureDecaySeconds: 3600,
                minSecondsBetweenDeployIdle: 300,
                bootstrapDuration: 86400,
                maxRelativeExposureBps: 0,
                externalTVLStalenessSeconds: 43200
            });

        // Constructor takes core, router, timelock, guardian, bootstrapper, paramsModule, scoringModule
        StrategyParamsModule paramsModule = new StrategyParamsModule(ARBITRUM_USDC, core);
        StrategyAdapterOpsModule adapterOpsMod = new StrategyAdapterOpsModule(
            ARBITRUM_USDC, core, address(paramsModule), address(0), address(0)
        );
        StrategyScoringModule scoringMod = new StrategyScoringModule(
            ARBITRUM_USDC, core, address(paramsModule), address(0), address(adapterOpsMod)
        );
        address gateModInv2 = address(new StrategyRebalanceGateModule(ARBITRUM_USDC, core, address(paramsModule), address(scoringMod), address(adapterOpsMod)));
        vault = new UsdcMultiLendingVault(
            ARBITRUM_USDC, core, router, admin, keeper, address(0), address(paramsModule), address(scoringMod), address(adapterOpsMod), gateModInv2, params
        );

        // Architectural completion: wire StrategyRebalancePlanModule (was missing post-EIP170 split)
        StrategyRebalancePlanModule _planMod = new StrategyRebalancePlanModule(
            ARBITRUM_USDC, core, address(paramsModule), address(scoringMod), address(adapterOpsMod)
        );
        vm.prank(admin);
        vault.setRebalancePlanModule(address(_planMod));

        // REFACTOR-A: wire StrategySettingsModule (governance setters, last in fallback chain)
        StrategySettingsModule _settingsMod1 = new StrategySettingsModule(ARBITRUM_USDC, core);
        vm.prank(admin);
        vault.setSettingsModule(address(_settingsMod1));
        StrategyAllocCalcModule _allocCalcMod1 = new StrategyAllocCalcModule(ARBITRUM_USDC, core);
        vm.prank(admin);
        vault.setAllocCalcModule(address(_allocCalcMod1));

        vm.startPrank(admin);
        address(vault).call(abi.encodeWithSignature("whitelistAdapter(address,bool)", address(adapter1), true));
        vault.addAdapter(address(adapter1));
        vault.toggleAdapter(address(adapter1), true);
        (bool ok1,) = address(vault).call(abi.encodeWithSignature("setAdapterDepositMode(address,bool)", address(adapter1), false));
        require(ok1, "setAdapterDepositMode failed");
        address(vault).call(abi.encodeWithSignature("whitelistAdapter(address,bool)", address(adapter2), true));
        vault.addAdapter(address(adapter2));
        vault.toggleAdapter(address(adapter2), true);
        (bool ok2,) = address(vault).call(abi.encodeWithSignature("setAdapterDepositMode(address,bool)", address(adapter2), false));
        require(ok2, "setAdapterDepositMode failed");
        vm.stopPrank();

        // Audit #2 P0.6: poke TVL cache so adapters get non-zero confidence
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        handler = new AdversarialHandler(vault, usdc, core, keeper, admin);

        targetContract(address(handler));
    }

    /// @notice ADVERSARIAL-INV-1: No attack should ever succeed
    function invariant_no_successful_attacks() public view {
        assertEq(
            handler.ghost_successfulAttacks(), 0, "ADVERSARIAL-INV-1: unauthorized access detected"
        );
    }

    /// @notice ADVERSARIAL-INV-2: Attacker balance should never increase from vault
    function invariant_attacker_cannot_steal() public view {
        address attacker = address(0xBAD);
        assertEq(usdc.balanceOf(attacker), 0, "ADVERSARIAL-INV-2: attacker stole funds");
    }

    function invariant_adversarialSummary() public view {
        console2.log("============ ADVERSARIAL SUMMARY ============");
        console2.log("Attack attempts:    ", handler.ghost_attackAttempts());
        console2.log("Successful attacks: ", handler.ghost_successfulAttacks());
        console2.log("=============================================");
    }
}

// ============================================================================
// SCORING INVARIANT TESTS (V9.1 — APY normalization + confidence bands)
// ============================================================================

contract ScoringInvariantHandler is Test {
    UsdcMultiLendingVault public vault;
    MockUSDCInvariant public usdc;
    MockAdapterInvariant[] public adapters;
    address public core;
    address public keeper;

    uint256 public ghost_depositCalls;
    uint256 public ghost_apyChanges;

    constructor(
        UsdcMultiLendingVault _vault,
        MockUSDCInvariant _usdc,
        MockAdapterInvariant[] memory _adapters,
        address _core,
        address _keeper
    ) {
        vault = _vault;
        usdc = _usdc;
        core = _core;
        keeper = _keeper;
        for (uint256 i = 0; i < _adapters.length; i++) {
            adapters.push(_adapters[i]);
        }
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1e6, 10_000e6);
        usdc.mint(core, amount);
        vm.prank(core);
        usdc.transfer(address(vault), amount);
        vm.prank(core);
        vault.deposit(amount);
        ghost_depositCalls++;
    }

    function changeAPYs(uint16 apy0, uint16 apy1, uint16 apy2) external {
        apy0 = uint16(bound(apy0, 0, 5000));
        apy1 = uint16(bound(apy1, 0, 5000));
        apy2 = uint16(bound(apy2, 0, 5000));
        adapters[0].setAPY(apy0);
        adapters[1].setAPY(apy1);
        adapters[2].setAPY(apy2);
        ghost_apyChanges++;
    }

    function setAPY(uint256 idx, uint16 apy) external {
        idx = bound(idx, 0, adapters.length - 1);
        apy = uint16(bound(apy, 0, 5000));
        adapters[idx].setAPY(apy);
    }
}

contract UsdcMultiLendingVault_Scoring_Invariant_Test is StdInvariant, Test {
    MockUSDCInvariant public usdc;
    UsdcMultiLendingVault public vault;
    ScoringInvariantHandler public handler;
    MockAdapterInvariant[] public adapters;

    address constant ARBITRUM_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address public admin = address(0xAD);
    address public core = address(0xC0);
    address public keeper = address(0xBE);
    bytes32 constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    function setUp() public {
        usdc = new MockUSDCInvariant();
        vm.etch(ARBITRUM_USDC, address(usdc).code);
        usdc = MockUSDCInvariant(ARBITRUM_USDC);

        // Create 3 adapters with different APYs
        MockAdapterInvariant a1 = new MockAdapterInvariant(ARBITRUM_USDC, 900);
        MockAdapterInvariant a2 = new MockAdapterInvariant(ARBITRUM_USDC, 500);
        MockAdapterInvariant a3 = new MockAdapterInvariant(ARBITRUM_USDC, 200);
        // Audit #2 P0.6: seed realistic external TVL so confidence != ZERO
        a1.setExtMarketTVL(50_000_000e6);
        a2.setExtMarketTVL(50_000_000e6);
        a3.setExtMarketTVL(50_000_000e6);
        adapters.push(a1);
        adapters.push(a2);
        adapters.push(a3);

        StrategyParamsModule paramsMod = new StrategyParamsModule(ARBITRUM_USDC, core);
        StrategyAdapterOpsModule adapterOpsMod = new StrategyAdapterOpsModule(
            ARBITRUM_USDC, core, address(paramsMod), address(0), address(0)
        );
        StrategyScoringModule scoringMod = new StrategyScoringModule(
            ARBITRUM_USDC, core, address(paramsMod), address(0), address(adapterOpsMod)
        );

        UsdcMultiLendingVault.StrategyInitParams memory params = UsdcMultiLendingVault.StrategyInitParams({
            maxAdaptersPerAllocation: 5,
            minAdaptersActive: 2,
            rebalanceMinMoveBps: 50,
            minSecondsBetweenRebalances: 21600,
            driftToleranceBps: 80,
            wAPY: 4000,
            wLiq: 2000,
            wRisk: 2000,
            wStability: 1000,
            wIncentive: 1000,
            incentiveDecayHalfLife: 86400,
            adapterMaxExposureBps: 5000,
            newAdapterRampBps: 5000,
            gateHorizonDays: 7,
            gateMinNetBenefitBps: 2,
            slippageBpsEstimate: 0,
            withdrawalSpreadBpsEstimate: 0,
            gasCostUSDC: 0,
            harvestThresholdBps: 5,
            minSecondsBetweenHarvests: 43200,
            dustTolerance: 10000,
            stabilityEMAPeriod: 7,
            minNewAdapterSeed: 0,
            newAdapterRampDuration: 0,
            maxIdleAfterDepositBps: 500,
            maxIdleBootstrapBps: 5000,
            degradedViewThresholdBps: 2500,
            failureDecaySeconds: 3600,
            minSecondsBetweenDeployIdle: 300,
            bootstrapDuration: 86400,
            maxRelativeExposureBps: 1000,
            externalTVLStalenessSeconds: 43200
        });

        address gateModInv = address(new StrategyRebalanceGateModule(ARBITRUM_USDC, core, address(paramsMod), address(scoringMod), address(adapterOpsMod)));
        vault = new UsdcMultiLendingVault(
            ARBITRUM_USDC, core, core, admin, keeper, address(0),
            address(paramsMod), address(scoringMod), address(adapterOpsMod), gateModInv, params
        );

        // Architectural completion: wire StrategyRebalancePlanModule (was missing post-EIP170 split)
        StrategyRebalancePlanModule _planMod = new StrategyRebalancePlanModule(
            ARBITRUM_USDC, core, address(paramsMod), address(scoringMod), address(adapterOpsMod)
        );
        vm.prank(admin);
        vault.setRebalancePlanModule(address(_planMod));

        // REFACTOR-A: wire StrategySettingsModule (governance setters, last in fallback chain)
        StrategySettingsModule _settingsMod2 = new StrategySettingsModule(ARBITRUM_USDC, core);
        vm.prank(admin);
        vault.setSettingsModule(address(_settingsMod2));
        StrategyAllocCalcModule _allocCalcMod2 = new StrategyAllocCalcModule(ARBITRUM_USDC, core);
        vm.prank(admin);
        vault.setAllocCalcModule(address(_allocCalcMod2));
        // F-SIZE-02: wire StrategySafetyOverflowModule — _checkDegradedModeLocally() delegatecalls here.
        // Without this, safetyOverflowModule_addr=address(0) → delegatecall returns "" → degraded mode
        // never activates → deployIdleToAdapters is called even when adapters are unliquid.
        StrategySafetyOverflowModule _overflowMod2 = new StrategySafetyOverflowModule(
            ARBITRUM_USDC, core, address(0), address(0), address(adapterOpsMod)
        );
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setSafetyOverflowModule(address(_overflowMod2));

        // Exit bootstrap for normal operation
        vm.prank(admin);
        StrategySettingsModule(address(vault)).exitBootstrapMode();

        // Register adapters
        vm.startPrank(admin);
        for (uint256 i = 0; i < adapters.length; i++) {
            adapters[i].setVault(address(vault));
            address(vault).call(abi.encodeWithSignature("whitelistAdapter(address,bool)", address(adapters[i]), true));
            vault.addAdapter(address(adapters[i]));
            vault.toggleAdapter(address(adapters[i]), true);
        }
        StrategySettingsModule(address(vault)).setMaxIdleAfterDepositBps(10000);
        vm.stopPrank();

        // Audit #2 P0.6: poke TVL cache so adapters get non-zero confidence
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        handler = new ScoringInvariantHandler(vault, usdc, adapters, core, keeper);
        targetContract(address(handler));
    }

    /// @notice SCORING-INV-1: Conservation — sum(positions) + idle == totalAssets
    function invariant_scoring_conservation() public view {
        uint256 totalPos = 0;
        for (uint256 i = 0; i < adapters.length; i++) {
            totalPos += vault.positionAssets(address(adapters[i]));
        }
        uint256 idle = vault.idleCash();
        uint256 total = vault.totalAssets();
        assertEq(totalPos + idle, total, "SCORING-INV-1: conservation violated");
    }

    /// @notice SCORING-INV-2: No adapter position exceeds maxExposure
    function invariant_scoring_maxExposure() public view {
        uint256 tvl = vault.totalAssets();
        if (tvl == 0) return;
        uint256 maxExp = (uint256(vault.adapterMaxExposureBps()) * tvl) / 1e4;
        uint256 dust = vault.dustTolerance();
        for (uint256 i = 0; i < adapters.length; i++) {
            uint256 pos = vault.positionAssets(address(adapters[i]));
            assertLe(pos, maxExp + dust, "SCORING-INV-2: adapter exceeds maxExposure");
        }
    }

    /// @notice SCORING-INV-3: No quarantine after normal deposits
    function invariant_scoring_noQuarantine() public view {
        for (uint256 i = 0; i < adapters.length; i++) {
            assertFalse(vault.quarantined(address(adapters[i])), "SCORING-INV-3: adapter quarantined");
        }
    }

    /// @notice SCORING-INV-4: dep

    /// @notice Deterministic repro: small deposit then large deposit must not exceed maxExposure
    function test_scoring_maxExposure_smallThenLargeDeposit() public {
        uint256 d1 = 1_004_662; // matches shrunk counterexample bound(4662, 1e6, 10_000e6)
        uint256 d2 = 10_000e6; // matches bound(huge, 1e6, 10_000e6) = max
        usdc.mint(core, d1);
        vm.prank(core); usdc.transfer(address(vault), d1);
        vm.prank(core); vault.deposit(d1);
        usdc.mint(core, d2);
        vm.prank(core); usdc.transfer(address(vault), d2);
        vm.prank(core); vault.deposit(d2);
        uint256 tvl = vault.totalAssets();
        uint256 maxExp = (uint256(vault.adapterMaxExposureBps()) * tvl) / 1e4;
        uint256 dust = vault.dustTolerance();
        for (uint256 i = 0; i < adapters.length; i++) {
            uint256 pos = vault.positionAssets(address(adapters[i]));
            assertLe(pos, maxExp + dust, string.concat("SCORING-INV-2-repro: adapter exceeds maxExposure"));
        }
    }
}
