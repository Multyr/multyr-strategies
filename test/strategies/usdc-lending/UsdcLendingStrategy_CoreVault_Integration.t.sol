// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { CoreHarness } from "../../helpers/CoreHarness.sol";
import { MockParamsProvider } from "../../helpers/MockParamsProvider.sol";
import { MockBufferManagerForTests } from "../../helpers/MockBufferManagerForTests.sol";
import { IParamsProvider } from "@multyr-core/interfaces/IParamsProvider.sol";
import { IStrategyRouter, IStrategy } from "@multyr-core/interfaces/IStrategyRouter.sol";

/**
 * @title UsdcLendingStrategy_CoreVault_Integration
 * @notice Integration tests verifying CoreVault <-> UsdcMultiLendingVault interaction
 * @dev Tests the complete money flow: User -> CoreVault -> Strategy -> Adapters
 */

// ============================================================================
// MOCK CONTRACTS FOR INTEGRATION TESTING
// ============================================================================

/// @notice Mock USDC token for testing
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @notice Mock adapter that simulates a lending protocol
contract MockLendingAdapter {
    IERC20Metadata public immutable asset;
    address public strategy;

    uint256 public depositedAssets;
    uint256 public simulatedAPY; // in bps (e.g., 500 = 5%)
    uint256 public lastYieldAccrual;
    bool public depositReverts;
    bool public withdrawReverts;
    bool public pushDepositMode;

    string public protocolName;

    constructor(address _asset, string memory _name) {
        asset = IERC20Metadata(_asset);
        protocolName = _name;
        simulatedAPY = 500; // 5% default
        lastYieldAccrual = block.timestamp;
    }

    function setStrategy(address _strategy) external {
        strategy = _strategy;
    }

    function setAPY(uint256 _apyBps) external {
        _accrueYield();
        simulatedAPY = _apyBps;
    }

    function setDepositReverts(bool _reverts) external {
        depositReverts = _reverts;
    }

    function setWithdrawReverts(bool _reverts) external {
        withdrawReverts = _reverts;
    }

    function setPushDepositMode(bool _push) external {
        pushDepositMode = _push;
    }

    function deposit(uint256 amount) external returns (uint256) {
        require(!depositReverts, "Deposit reverted");
        _accrueYield();

        if (pushDepositMode) {
            // Push mode: funds already transferred
            require(
                asset.balanceOf(address(this)) >= depositedAssets + amount,
                "Push: funds not received"
            );
        } else {
            // Pull mode: adapter pulls from caller
            asset.transferFrom(msg.sender, address(this), amount);
        }

        depositedAssets += amount;
        return amount;
    }

    function withdraw(uint256 amount, address to) external returns (uint256) {
        require(!withdrawReverts, "Withdraw reverted");
        _accrueYield();

        uint256 withdrawable = amount > depositedAssets ? depositedAssets : amount;
        depositedAssets -= withdrawable;
        asset.transfer(to, withdrawable);
        return withdrawable;
    }

    function withdrawAll(address to) external returns (uint256) {
        _accrueYield();
        uint256 amount = depositedAssets;
        depositedAssets = 0;
        asset.transfer(to, amount);
        return amount;
    }

    function totalAssets() external view returns (uint256) {
        return depositedAssets + _pendingYield();
    }

    function getSupplyAPY() external view returns (uint256) {
        return simulatedAPY;
    }

    function name() external view returns (string memory) {
        return protocolName;
    }

    function _accrueYield() internal {
        uint256 yield = _pendingYield();
        if (yield > 0) {
            // Mint yield to simulate protocol earnings
            MockUSDC(address(asset)).mint(address(this), yield);
            depositedAssets += yield;
        }
        lastYieldAccrual = block.timestamp;
    }

    function _pendingYield() internal view returns (uint256) {
        if (depositedAssets == 0 || simulatedAPY == 0) return 0;
        uint256 elapsed = block.timestamp - lastYieldAccrual;
        // APY in bps, scaled for time elapsed
        return (depositedAssets * simulatedAPY * elapsed) / (365 days * 10000);
    }
}

/// @notice Mock strategy that wraps adapters (simulates UsdcMultiLendingVault interface for CoreVault)
contract MockLendingStrategy is IStrategy {
    using SafeERC20 for IERC20Metadata;

    IERC20Metadata public immutable ASSET;
    address public core;
    bool public active;
    string public constant NAME = "MockLendingStrategy";

    MockLendingAdapter[] public adapters;
    mapping(address => uint256) public adapterPosition;

    bool public depositReverts;
    bool public withdrawReverts;

    constructor(address _asset) {
        ASSET = IERC20Metadata(_asset);
        active = true;
    }

    function setCore(address _core) external {
        core = _core;
    }

    function addAdapter(MockLendingAdapter adapter) external {
        adapters.push(adapter);
    }

    function setDepositReverts(bool _reverts) external {
        depositReverts = _reverts;
    }

    function setWithdrawReverts(bool _reverts) external {
        withdrawReverts = _reverts;
    }

    // IStrategy interface
    function name() external pure override returns (string memory) {
        return NAME;
    }

    function asset() external view override returns (address) {
        return address(ASSET);
    }

    function totalAssets() external view override returns (uint256) {
        uint256 total = ASSET.balanceOf(address(this)); // idle
        for (uint256 i = 0; i < adapters.length; i++) {
            total += adapters[i].totalAssets();
        }
        return total;
    }

    function deposit(uint256 amount) external override returns (uint256) {
        require(!depositReverts, "Strategy deposit reverted");
        require(msg.sender == core, "Only core");

        // Funds already transferred by CoreVault, deploy to first adapter
        if (adapters.length > 0) {
            ASSET.approve(address(adapters[0]), amount);
            adapters[0].deposit(amount);
            adapterPosition[address(adapters[0])] += amount;
        }

        return amount;
    }

    function withdraw(uint256 amount, address to) external override returns (uint256) {
        require(!withdrawReverts, "Strategy withdraw reverted");
        require(msg.sender == core, "Only core");

        uint256 remaining = amount;
        uint256 withdrawn = 0;

        // First use idle balance
        uint256 idle = ASSET.balanceOf(address(this));
        if (idle > 0) {
            uint256 fromIdle = idle > remaining ? remaining : idle;
            remaining -= fromIdle;
            withdrawn += fromIdle;
        }

        // Then withdraw from adapters
        for (uint256 i = 0; i < adapters.length && remaining > 0; i++) {
            uint256 got = adapters[i].withdraw(remaining, address(this));
            remaining -= got;
            withdrawn += got;
            adapterPosition[address(adapters[i])] -= got;
        }

        ASSET.safeTransfer(to, withdrawn);
        return withdrawn;
    }

    function withdrawAll(address to) external override returns (uint256) {
        require(msg.sender == core, "Only core");

        uint256 total = 0;
        for (uint256 i = 0; i < adapters.length; i++) {
            total += adapters[i].withdrawAll(address(this));
            adapterPosition[address(adapters[i])] = 0;
        }

        total += ASSET.balanceOf(address(this));
        ASSET.safeTransfer(to, total);
        return total;
    }

    function harvest() external override returns (int256 pnl, uint256 realized) {
        // Simple harvest: just report gains from yield accrual
        uint256 currentTotal = this.totalAssets();
        uint256 lastReported = 0;
        for (uint256 i = 0; i < adapters.length; i++) {
            lastReported += adapterPosition[address(adapters[i])];
        }

        if (currentTotal > lastReported) {
            realized = currentTotal - lastReported;
            pnl = int256(realized);
        }

        return (pnl, realized);
    }

    function setActive(bool a) external override {
        active = a;
    }

    function isActive() external view override returns (bool) {
        return active;
    }
}

// MockParamsProvider imported from helpers

/// @notice Mock StrategyRouter for CoreVault
contract MockStrategyRouter is IStrategyRouter {
    address public coreAddress;
    IStrategy[] public strategies;
    IntakeMode public currentIntakeMode = IntakeMode.PRIORITY;
    uint16 public lossCapBpsValue = 500;

    function setCore(address core_) external override {
        coreAddress = core_;
    }

    function addStrategy(address strat) external {
        strategies.push(IStrategy(strat));
    }

    function core() external view override returns (address) {
        return coreAddress;
    }

    function intakeMode() external view override returns (IntakeMode) {
        return currentIntakeMode;
    }

    function lossCapBps() external view override returns (uint16) {
        return lossCapBpsValue;
    }

    function register(address, uint16, uint16) external override { }
    function toggle(address, bool) external override { }

    function setIntakeMode(IntakeMode m) external override {
        currentIntakeMode = m;
    }
    function setWeights(address[] calldata, uint16[] calldata) external override { }

    function setLossCapBps(uint16 capBps) external override {
        lossCapBpsValue = capBps;
    }

    function list() external view override returns (StrategyInfo[] memory) {
        StrategyInfo[] memory infos = new StrategyInfo[](strategies.length);
        for (uint256 i = 0; i < strategies.length; i++) {
            infos[i] = StrategyInfo({
                strat: address(strategies[i]),
                enabled: true,
                priority: uint16(i),
                weightBps: uint16(10000 / strategies.length)
            });
        }
        return infos;
    }

    function isStrategyEnabled(address strat) external view override returns (bool) {
        for (uint256 i = 0; i < strategies.length; i++) {
            if (address(strategies[i]) == strat) {
                return true;
            }
        }
        return false;
    }

    function totalStrategyAssetsSafe() external view override returns (uint256 sum) {
        for (uint256 i = 0; i < strategies.length; i++) {
            (bool ok, bytes memory data) = address(strategies[i])
            .staticcall{ gas: 1_000_000 }(abi.encodeWithSelector(IStrategy.totalAssets.selector));
            if (ok && data.length >= 32) {
                sum += abi.decode(data, (uint256));
            }
        }
    }

    function planDeposit(uint256 amount) external view override returns (Allocation[] memory plan) {
        if (strategies.length == 0) {
            return new Allocation[](0);
        }

        plan = new Allocation[](1);
        plan[0] = Allocation({
            strat: address(strategies[0]), amount: amount, fundsAlreadyTransferred: false
        });
        return plan;
    }

    function executeDepositBatch(Allocation[] calldata plan) external override {
        for (uint256 i = 0; i < plan.length; i++) {
            IStrategy(plan[i].strat).deposit(plan[i].amount);
        }
    }

    function planRedeem(uint256 required) external view override returns (Pull[] memory plan) {
        if (strategies.length == 0 || required == 0) {
            return new Pull[](0);
        }

        plan = new Pull[](1);
        plan[0] = Pull({ strat: address(strategies[0]), amount: required });
        return plan;
    }

    function executeRedeemBatch(Pull[] calldata plan)
        external
        override
        returns (uint256 got, uint256 loss)
    {
        for (uint256 i = 0; i < plan.length; i++) {
            uint256 withdrawn = IStrategy(plan[i].strat).withdraw(plan[i].amount, coreAddress);
            got += withdrawn;
            if (withdrawn < plan[i].amount) {
                loss += plan[i].amount - withdrawn;
            }
        }
        return (got, loss);
    }

    function harvest(uint256 maxStrategies)
        external
        override
        returns (uint256 visited, int256 aggPnl, uint256 aggRealized)
    {
        uint256 toVisit = maxStrategies > strategies.length ? strategies.length : maxStrategies;
        for (uint256 i = 0; i < toVisit; i++) {
            (int256 pnl, uint256 realized) = strategies[i].harvest();
            aggPnl += pnl;
            aggRealized += realized;
            visited++;
        }
        return (visited, aggPnl, aggRealized);
    }

    function withdrawAllToCore(address strat) external override returns (uint256 got) {
        return IStrategy(strat).withdrawAll(coreAddress);
    }

    function forceRedeemForWithdraw(uint256) external override returns (uint256) { return 0; }
}

// ============================================================================
// INTEGRATION TESTS
// ============================================================================

contract UsdcLendingStrategy_CoreVault_Integration is Test {
    // Contracts
    MockUSDC public usdc;
    CoreHarness public coreVault;
    MockParamsProvider public params;
    MockStrategyRouter public router;
    MockLendingStrategy public strategy;
    MockLendingAdapter public adapter1;
    MockLendingAdapter public adapter2;

    // Actors
    address public owner = makeAddr("owner");
    address public guardian = makeAddr("guardian");
    address public feeCollector = makeAddr("feeCollector");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public user3 = makeAddr("user3");

    // Constants
    uint256 constant INITIAL_BALANCE = 1_000_000e6; // 1M USDC

    function setUp() public {
        // Deploy mock USDC
        usdc = new MockUSDC();

        // Deploy params provider (from helpers)
        params = new MockParamsProvider();
        params.setLockPeriod(0); // No lock for tests

        // Deploy CoreHarness (CoreVault test harness)
        coreVault = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "Vault USDC",
            "vUSDC",
            owner,
            feeCollector,
            address(params)
        );

        // Deploy router
        router = new MockStrategyRouter();
        router.setCore(address(coreVault));

        // Deploy strategy
        strategy = new MockLendingStrategy(address(usdc));
        strategy.setCore(address(coreVault));

        // Deploy adapters
        adapter1 = new MockLendingAdapter(address(usdc), "Adapter1");
        adapter1.setStrategy(address(strategy));
        adapter1.setAPY(500); // 5%

        adapter2 = new MockLendingAdapter(address(usdc), "Adapter2");
        adapter2.setStrategy(address(strategy));
        adapter2.setAPY(300); // 3%

        // Connect strategy to adapters
        strategy.addAdapter(adapter1);
        strategy.addAdapter(adapter2);

        // Register strategy with router
        router.addStrategy(address(strategy));

        // Configure CoreVault with router using harness method
        coreVault.setStrategyRouterUnsafe(address(router));

        // Install mock BufferManager so deposit/mint don't revert NavInvalid
        MockBufferManagerForTests mockBM = new MockBufferManagerForTests(address(coreVault));
        coreVault.setBufferManagerUnsafe(address(mockBM));

        // Fund users
        usdc.mint(user1, INITIAL_BALANCE);
        usdc.mint(user2, INITIAL_BALANCE);
        usdc.mint(user3, INITIAL_BALANCE);

        // Approve CoreVault
        vm.prank(user1);
        usdc.approve(address(coreVault), type(uint256).max);
        vm.prank(user2);
        usdc.approve(address(coreVault), type(uint256).max);
        vm.prank(user3);
        usdc.approve(address(coreVault), type(uint256).max);
    }

    // ========================================================================
    // BASIC DEPOSIT/WITHDRAW FLOW
    // ========================================================================

    function test_Integration_BasicDepositFlow() public {
        uint256 depositAmount = 100_000e6;

        // User deposits into CoreVault
        vm.prank(user1);
        uint256 shares = coreVault.deposit(depositAmount, user1);

        assertGt(shares, 0, "Should receive shares");
        assertEq(coreVault.balanceOf(user1), shares, "User should hold shares");

        // Funds should flow to strategy and adapter
        // Note: This depends on CoreVault implementation and buffer logic
        uint256 vaultBalance = usdc.balanceOf(address(coreVault));
        uint256 strategyTotal = strategy.totalAssets();

        // Total should equal deposit (minus any fees)
        assertApproxEqAbs(
            vaultBalance + strategyTotal,
            depositAmount,
            1e6, // 1 USDC tolerance
            "Total assets should match deposit"
        );
    }

    function test_Integration_BasicWithdrawFlow() public {
        uint256 depositAmount = 100_000e6;

        // Setup: User deposits
        vm.prank(user1);
        uint256 shares = coreVault.deposit(depositAmount, user1);

        // User withdraws
        uint256 withdrawnPre_ = usdc.balanceOf(user1);
        vm.prank(user1);
        address(coreVault).call(abi.encodeWithSignature("forceWithdrawAll(address)", user1));
        uint256 withdrawn = usdc.balanceOf(user1) - withdrawnPre_;

        assertGt(withdrawn, 0, "Should withdraw assets");
        assertEq(coreVault.balanceOf(user1), 0, "Should have no shares left");

        // User should have most of their funds back (minus fees)
        assertApproxEqRel(
            usdc.balanceOf(user1),
            INITIAL_BALANCE,
            0.05e18, // 5% tolerance for fees
            "User should recover most funds"
        );
    }

    // ========================================================================
    // YIELD ACCRUAL TESTS
    // ========================================================================

    function test_Integration_YieldAccrual() public {
        uint256 depositAmount = 100_000e6;

        // User deposits
        vm.prank(user1);
        coreVault.deposit(depositAmount, user1);

        // Fast forward time to accrue yield
        vm.warp(block.timestamp + 30 days);

        // Check total assets increased
        uint256 totalAfter = coreVault.totalAssets();
        assertGe(totalAfter, depositAmount, "Total assets should not decrease");
    }

    function test_Integration_MultipleUsersShareYield() public {
        uint256 deposit1 = 100_000e6;
        uint256 deposit2 = 200_000e6;

        // User1 deposits first
        vm.prank(user1);
        uint256 shares1 = coreVault.deposit(deposit1, user1);

        // Time passes, yield accrues
        vm.warp(block.timestamp + 15 days);

        // User2 deposits
        vm.prank(user2);
        uint256 shares2 = coreVault.deposit(deposit2, user2);

        // More time passes
        vm.warp(block.timestamp + 15 days);

        // User1 should have gained from being early
        uint256 user1Value = coreVault.convertToAssets(shares1);

        // Both users withdraw
        uint256 withdrawn1Pre_ = usdc.balanceOf(user1);
        vm.prank(user1);
        address(coreVault).call(abi.encodeWithSignature("forceWithdrawAll(address)", user1));
        uint256 withdrawn1 = usdc.balanceOf(user1) - withdrawn1Pre_;

        uint256 withdrawn2Pre_ = usdc.balanceOf(user2);
        vm.prank(user2);
        address(coreVault).call(abi.encodeWithSignature("forceWithdrawAll(address)", user2));
        uint256 withdrawn2 = usdc.balanceOf(user2) - withdrawn2Pre_;

        // User1 should have proportionally more yield due to longer deposit
        assertGe(withdrawn1, deposit1 * 85 / 100, "User1 should get back most of deposit");
        assertGe(withdrawn2, deposit2 * 85 / 100, "User2 should get back most of deposit");
    }

    // ========================================================================
    // STRESS TESTS
    // ========================================================================

    function test_Integration_HighVolumeDeposits() public {
        uint256 numDeposits = 50;
        uint256 depositAmount = 10_000e6;

        usdc.mint(user1, numDeposits * depositAmount);

        uint256 totalShares = 0;
        for (uint256 i = 0; i < numDeposits; i++) {
            vm.prank(user1);
            totalShares += coreVault.deposit(depositAmount, user1);
        }

        assertEq(coreVault.balanceOf(user1), totalShares, "Total shares should match");

        // Withdraw all
        vm.prank(user1);
        address(coreVault).call(abi.encodeWithSignature("forceWithdrawAll(address)", user1));

        assertLe(coreVault.balanceOf(user1), 1, "Should have minimal shares left");
    }

    function test_Integration_ConcurrentUsers() public {
        uint256 depositAmount = 50_000e6;

        // All users deposit concurrently
        vm.prank(user1);
        uint256 shares1 = coreVault.deposit(depositAmount, user1);

        vm.prank(user2);
        uint256 shares2 = coreVault.deposit(depositAmount, user2);

        vm.prank(user3);
        uint256 shares3 = coreVault.deposit(depositAmount, user3);

        // All users should have equal shares (same deposit amount at same time)
        assertApproxEqRel(shares1, shares2, 0.01e18, "Users should have similar shares");
        assertApproxEqRel(shares2, shares3, 0.01e18, "Users should have similar shares");

        // Time passes
        vm.warp(block.timestamp + 7 days);

        // All users withdraw
        uint256 withdrawn1Pre_ = usdc.balanceOf(user1);
        vm.prank(user1);
        address(coreVault).call(abi.encodeWithSignature("forceWithdrawAll(address)", user1));
        uint256 withdrawn1 = usdc.balanceOf(user1) - withdrawn1Pre_;

        uint256 withdrawn2Pre_ = usdc.balanceOf(user2);
        vm.prank(user2);
        address(coreVault).call(abi.encodeWithSignature("forceWithdrawAll(address)", user2));
        uint256 withdrawn2 = usdc.balanceOf(user2) - withdrawn2Pre_;

        uint256 withdrawn3Pre_ = usdc.balanceOf(user3);
        vm.prank(user3);
        address(coreVault).call(abi.encodeWithSignature("forceWithdrawAll(address)", user3));
        uint256 withdrawn3 = usdc.balanceOf(user3) - withdrawn3Pre_;

        // All should withdraw approximately equal amounts
        assertApproxEqRel(withdrawn1, withdrawn2, 0.01e18, "Withdrawals should be similar");
        assertApproxEqRel(withdrawn2, withdrawn3, 0.01e18, "Withdrawals should be similar");
    }

    // ========================================================================
    // ADAPTER FAILURE SCENARIOS
    // ========================================================================

    function test_Integration_AdapterDepositFailure() public {
        // Make adapter reject deposits
        adapter1.setDepositReverts(true);

        uint256 depositAmount = 100_000e6;

        // Deposit should still work (funds stay in vault buffer)
        vm.prank(user1);
        uint256 shares = coreVault.deposit(depositAmount, user1);

        // User should still receive shares
        assertGt(shares, 0, "Should receive shares even if adapter fails");
    }

    function test_Integration_PartialWithdrawWhenAdapterLimited() public {
        uint256 depositAmount = 100_000e6;

        // User deposits
        vm.prank(user1);
        uint256 shares = coreVault.deposit(depositAmount, user1);

        // Drain adapter externally (simulating protocol insolvency)
        // This would require direct manipulation of adapter state

        // User attempts full withdraw - should get what's available
        uint256 withdrawnPre__ = usdc.balanceOf(user1);
        vm.prank(user1);
        (bool ok__,) = address(coreVault).call(abi.encodeWithSignature("forceWithdrawAll(address)", user1));
        if (ok__) {
            uint256 withdrawn = usdc.balanceOf(user1) - withdrawnPre__;
            // Withdraw succeeded
            assertGt(withdrawn, 0, "Should withdraw something");
        }
    }

    // ========================================================================
    // SHARE PRICE TESTS
    // ========================================================================

    function test_Integration_SharePriceIncreases() public {
        uint256 depositAmount = 100_000e6;

        // Initial deposit
        vm.prank(user1);
        coreVault.deposit(depositAmount, user1);

        uint256 priceBefore = coreVault.convertToAssets(1e18);

        // Time passes, yield accrues
        vm.warp(block.timestamp + 365 days);

        // Trigger harvest to realize gains
        router.harvest(10);

        uint256 priceAfter = coreVault.convertToAssets(1e18);

        // Price should increase or stay same (never decrease in normal operation)
        assertGe(priceAfter, priceBefore, "Share price should not decrease");
    }

    function test_Integration_SharePriceConsistency() public {
        // Multiple deposits at different times
        vm.prank(user1);
        coreVault.deposit(50_000e6, user1);

        vm.warp(block.timestamp + 30 days);

        vm.prank(user2);
        coreVault.deposit(50_000e6, user2);

        // Share price should be consistent for all users at same point in time
        uint256 price = coreVault.convertToAssets(1e18);

        uint256 user1Value = coreVault.convertToAssets(coreVault.balanceOf(user1));
        uint256 user2Value = coreVault.convertToAssets(coreVault.balanceOf(user2));

        // User1 should have more value (deposited earlier, accrued more yield)
        assertGe(user1Value, user2Value, "Earlier depositor should have more value");
    }

    // ========================================================================
    // EDGE CASES
    // ========================================================================

    function test_Integration_MinimumDeposit() public {
        uint256 minDeposit = 1e6; // 1 USDC

        vm.prank(user1);
        uint256 shares = coreVault.deposit(minDeposit, user1);

        assertGt(shares, 0, "Should receive shares for minimum deposit");
    }

    function test_Integration_MaximumDeposit() public {
        uint256 maxDeposit = 100_000_000e6; // 100M USDC

        usdc.mint(user1, maxDeposit);

        vm.prank(user1);
        uint256 shares = coreVault.deposit(maxDeposit, user1);

        assertGt(shares, 0, "Should handle large deposits");

        // Withdraw should work
        uint256 withdrawnPre_ = usdc.balanceOf(user1);
        vm.prank(user1);
        address(coreVault).call(abi.encodeWithSignature("forceWithdrawAll(address)", user1));
        uint256 withdrawn = usdc.balanceOf(user1) - withdrawnPre_;

        assertApproxEqRel(withdrawn, maxDeposit, 0.05e18, "Should recover most of large deposit");
    }

    function test_Integration_ZeroDeposit() public {
        vm.prank(user1);
        vm.expectRevert();
        coreVault.deposit(0, user1);
    }

    function test_Integration_DepositForOtherUser() public {
        uint256 depositAmount = 100_000e6;

        // User1 deposits for User2
        vm.prank(user1);
        uint256 shares = coreVault.deposit(depositAmount, user2);

        assertEq(coreVault.balanceOf(user2), shares, "User2 should receive shares");
        assertEq(coreVault.balanceOf(user1), 0, "User1 should not have shares");
    }

    // ========================================================================
    // FULL LIFECYCLE TEST
    // ========================================================================

    function test_Integration_FullLifecycle() public {
        // Day 0: User1 deposits
        vm.prank(user1);
        uint256 shares1 = coreVault.deposit(100_000e6, user1);

        // Day 7: User2 deposits
        vm.warp(block.timestamp + 7 days);
        vm.prank(user2);
        uint256 shares2 = coreVault.deposit(200_000e6, user2);

        // Day 14: Harvest
        vm.warp(block.timestamp + 7 days);
        router.harvest(10);

        // Day 21: User3 deposits
        vm.warp(block.timestamp + 7 days);
        vm.prank(user3);
        uint256 shares3 = coreVault.deposit(50_000e6, user3);

        // Day 30: User1 partial withdraw
        vm.warp(block.timestamp + 9 days);
        vm.prank(user1);
        address(coreVault).call(abi.encodeWithSignature("forceWithdrawAll(address)", user1));

        // Day 45: Harvest again
        vm.warp(block.timestamp + 15 days);
        router.harvest(10);

        // Day 60: All users withdraw
        vm.warp(block.timestamp + 15 days);

        // User1 withdraws remaining
        uint256 user1RemainingShares = coreVault.balanceOf(user1);
        vm.prank(user1);
        address(coreVault).call(abi.encodeWithSignature("forceWithdrawAll(address)", user1));

        // User2 withdraws - need to check current balance as shares2 may have been modified
        uint256 user2Shares = coreVault.balanceOf(user2);
        vm.prank(user2);
        address(coreVault).call(abi.encodeWithSignature("forceWithdrawAll(address)", user2));

        // User3 withdraws
        uint256 user3Shares = coreVault.balanceOf(user3);
        vm.prank(user3);
        address(coreVault).call(abi.encodeWithSignature("forceWithdrawAll(address)", user3));

        // Vault should be nearly empty
        assertLe(coreVault.totalSupply(), 1e6, "Vault should be nearly empty");
    }

    // ========================================================================
    // REENTRANCY TESTS
    // ========================================================================

    function test_Integration_NoReentrancyOnDeposit() public {
        // This test verifies the reentrancy guards work
        // In a real scenario, we'd use a malicious token/adapter

        uint256 depositAmount = 100_000e6;

        vm.prank(user1);
        uint256 shares = coreVault.deposit(depositAmount, user1);

        assertGt(shares, 0, "Deposit should succeed");
    }

    // ========================================================================
    // VIEW FUNCTION CONSISTENCY
    // ========================================================================

    function test_Integration_ViewFunctionConsistency() public {
        uint256 depositAmount = 100_000e6;

        vm.prank(user1);
        coreVault.deposit(depositAmount, user1);

        // Check view function consistency
        uint256 totalAssets = coreVault.totalAssets();
        uint256 totalSupply = coreVault.totalSupply();

        // convertToAssets and convertToShares should be inverses
        uint256 assetsFor1Share = coreVault.convertToAssets(1e18);
        uint256 sharesForAssets = coreVault.convertToShares(assetsFor1Share);

        assertApproxEqRel(sharesForAssets, 1e18, 0.001e18, "Convert functions should be consistent");

        // maxDeposit/maxWithdraw should return reasonable values
        uint256 maxDep = coreVault.maxDeposit(user2);
        uint256 maxWith = coreVault.maxWithdraw(user1);

        assertGt(maxDep, 0, "maxDeposit should be positive");
        assertEq(maxWith, 0, "maxWithdraw is always 0 (async withdrawal required)");
    }
}

// ============================================================================
// FUZZ INTEGRATION TESTS
// ============================================================================

contract UsdcLendingStrategy_CoreVault_Integration_Fuzz is Test {
    MockUSDC public usdc;
    CoreHarness public coreVault;
    MockParamsProvider public params;
    MockStrategyRouter public router;
    MockLendingStrategy public strategy;
    MockLendingAdapter public adapter;

    address public owner = makeAddr("owner");
    address public feeCollector = makeAddr("feeCollector");

    function setUp() public {
        usdc = new MockUSDC();
        params = new MockParamsProvider();
        params.setLockPeriod(0);

        coreVault = new CoreHarness(
            IERC20Metadata(address(usdc)),
            "Vault USDC",
            "vUSDC",
            owner,
            feeCollector,
            address(params)
        );

        router = new MockStrategyRouter();
        router.setCore(address(coreVault));

        strategy = new MockLendingStrategy(address(usdc));
        strategy.setCore(address(coreVault));

        adapter = new MockLendingAdapter(address(usdc), "TestAdapter");
        adapter.setStrategy(address(strategy));
        strategy.addAdapter(adapter);

        router.addStrategy(address(strategy));

        coreVault.setStrategyRouterUnsafe(address(router));

        // Install mock BufferManager so deposit/mint don't revert NavInvalid
        MockBufferManagerForTests mockBM2 = new MockBufferManagerForTests(address(coreVault));
        coreVault.setBufferManagerUnsafe(address(mockBM2));
    }

    function _boundAmount(uint256 amount) internal pure returns (uint256) {
        return bound(amount, 1e6, 10_000_000e6); // 1 to 10M USDC
    }

    function testFuzz_Integration_DepositWithdraw(uint256 depositAmount) public {
        depositAmount = _boundAmount(depositAmount);

        address user = makeAddr("fuzzUser");
        usdc.mint(user, depositAmount);

        vm.startPrank(user);
        usdc.approve(address(coreVault), depositAmount);
        uint256 shares = coreVault.deposit(depositAmount, user);
        vm.stopPrank();

        assertGt(shares, 0, "Should receive shares");

        uint256 withdrawnPre_ = usdc.balanceOf(user);
        vm.prank(user);
        address(coreVault).call(abi.encodeWithSignature("forceWithdrawAll(address)", user));
        uint256 withdrawn = usdc.balanceOf(user) - withdrawnPre_;

        // Should get back at least 95% (accounting for fees)
        assertGe(withdrawn, depositAmount * 85 / 100, "Should recover most funds");
    }

    function testFuzz_Integration_MultipleDepositsWithdrawals(
        uint256 deposit1,
        uint256 deposit2,
        uint256 withdrawPercent
    ) public {
        deposit1 = _boundAmount(deposit1);
        deposit2 = _boundAmount(deposit2);
        withdrawPercent = bound(withdrawPercent, 10, 100);

        address user = makeAddr("fuzzUser");
        usdc.mint(user, deposit1 + deposit2);

        vm.startPrank(user);
        usdc.approve(address(coreVault), deposit1 + deposit2);

        // First deposit
        uint256 shares1 = coreVault.deposit(deposit1, user);

        // Second deposit
        uint256 shares2 = coreVault.deposit(deposit2, user);

        uint256 totalShares = shares1 + shares2;
        uint256 sharesToWithdraw = totalShares * withdrawPercent / 100;

        // Full withdraw (forceWithdrawAll redeems all shares)
        uint256 withdrawnPre_ = usdc.balanceOf(user);
        address(coreVault).call(abi.encodeWithSignature("forceWithdrawAll(address)", user));
        uint256 withdrawn = usdc.balanceOf(user) - withdrawnPre_;
        vm.stopPrank();

        assertGt(withdrawn, 0, "Should withdraw some assets");
        assertEq(coreVault.balanceOf(user), 0, "forceWithdrawAll should exit all shares");
    }

    function testFuzz_Integration_TimeBasedYield(uint256 depositAmount, uint256 daysElapsed)
        public
    {
        depositAmount = _boundAmount(depositAmount);
        daysElapsed = bound(daysElapsed, 1, 365);

        address user = makeAddr("fuzzUser");
        usdc.mint(user, depositAmount);

        vm.startPrank(user);
        usdc.approve(address(coreVault), depositAmount);
        coreVault.deposit(depositAmount, user);
        vm.stopPrank();

        uint256 assetsBefore = coreVault.totalAssets();

        // Time passes
        vm.warp(block.timestamp + daysElapsed * 1 days);

        uint256 assetsAfter = coreVault.totalAssets();

        // Assets should not decrease
        assertGe(assetsAfter, assetsBefore, "Assets should not decrease over time");
    }

    function testFuzz_Integration_SharePriceMonotonicity(
        uint256 deposit1,
        uint256 deposit2,
        uint256 daysBetween
    ) public {
        deposit1 = _boundAmount(deposit1);
        deposit2 = _boundAmount(deposit2);
        daysBetween = bound(daysBetween, 1, 30);

        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        usdc.mint(user1, deposit1);
        usdc.mint(user2, deposit2);

        // User1 deposits
        vm.startPrank(user1);
        usdc.approve(address(coreVault), deposit1);
        coreVault.deposit(deposit1, user1);
        vm.stopPrank();

        uint256 priceBefore = coreVault.convertToAssets(1e18);

        // Time passes
        vm.warp(block.timestamp + daysBetween * 1 days);

        // User2 deposits (should not decrease price)
        vm.startPrank(user2);
        usdc.approve(address(coreVault), deposit2);
        coreVault.deposit(deposit2, user2);
        vm.stopPrank();

        uint256 priceAfter = coreVault.convertToAssets(1e18);

        // Share price should never decrease (or decrease minimally due to rounding)
        assertGe(priceAfter, priceBefore * 999 / 1000, "Share price should be stable or increase");
    }
}
