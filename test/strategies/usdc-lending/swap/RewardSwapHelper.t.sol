// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { RewardSwapHelper } from "../../../../src/strategies/usdc-lending/swap/RewardSwapHelper.sol";

// ═══════════════════════════════════════════════════════════════════════════
// MOCKS
// ═══════════════════════════════════════════════════════════════════════════

contract MockERC20 {
    string public symbol;
    uint8 public decimals;
    string public name;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory _name, string memory _sym, uint8 _dec) {
        name = _name; symbol = _sym; decimals = _dec;
    }
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount; totalSupply += amount;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount; balanceOf[to] += amount; return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allow");
        require(balanceOf[from] >= amount, "bal");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount; balanceOf[to] += amount; return true;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount; return true;
    }
}

/// @dev Mock Chainlink feed with controllable price + updatedAt
contract MockChainlinkFeed {
    int256 public answer;
    uint256 public updatedAt;
    uint8 public immutable decimalsValue;

    constructor(uint8 _dec) { decimalsValue = _dec; updatedAt = block.timestamp; }

    function set(int256 a, uint256 ts) external { answer = a; updatedAt = ts; }

    function latestRoundData() external view returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        return (1, answer, 0, updatedAt, 1);
    }
    function decimals() external view returns (uint8) { return decimalsValue; }
}

/// @dev Mock Uniswap V3 SwapRouter02 (no-deadline ABI)
contract MockUniswapV3Router {
    address public usdc;
    uint256 public outAmount;
    bool public revertOnSwap;
    uint256 public lastMinOut;

    constructor(address _usdc) { usdc = _usdc; }

    function setOutAmount(uint256 a) external { outAmount = a; }
    function setRevertOnSwap(bool v) external { revertOnSwap = v; }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata p) external returns (uint256) {
        if (revertOnSwap) revert("uni-revert");
        // pull rewardToken from msg.sender (we don't track rewardToken here; assume swap simulator)
        lastMinOut = p.amountOutMinimum;
        // We don't actually consume input — test config sets outAmount directly
        if (outAmount < p.amountOutMinimum) revert("amountOutMin");
        // mint USDC to recipient (simulate swap output)
        MockERC20(usdc).mint(p.recipient, outAmount);
        return outAmount;
    }
}

/// @dev Mock Camelot V3 (with deadline)
contract MockCamelotV3Router {
    address public usdc;
    uint256 public outAmount;
    bool public revertOnSwap;

    constructor(address _usdc) { usdc = _usdc; }

    function setOutAmount(uint256 a) external { outAmount = a; }
    function setRevertOnSwap(bool v) external { revertOnSwap = v; }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata p) external returns (uint256) {
        if (revertOnSwap) revert("camelot-revert");
        if (block.timestamp > p.deadline) revert("deadline");
        if (outAmount < p.amountOutMinimum) revert("amountOutMin");
        MockERC20(usdc).mint(p.recipient, outAmount);
        return outAmount;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// TEST CONTRACT
// ═══════════════════════════════════════════════════════════════════════════

contract RewardSwapHelperTest is Test {
    RewardSwapHelper internal helper;
    MockERC20 internal usdc;
    MockERC20 internal comp;
    MockChainlinkFeed internal feed;
    MockUniswapV3Router internal uniRouter;
    MockCamelotV3Router internal camelotRouter;

    address internal admin = address(0xA11CE);
    address internal alice = address(0xA1);
    address internal core = address(0xC04E);

    // dummy paths
    bytes internal uniPath = abi.encodePacked(uint8(0xAB)); // non-empty bytes
    bytes internal camelotPath = abi.encodePacked(uint8(0xCD));

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        comp = new MockERC20("Compound", "COMP", 18);
        feed = new MockChainlinkFeed(8);
        uniRouter = new MockUniswapV3Router(address(usdc));
        camelotRouter = new MockCamelotV3Router(address(usdc));

        helper = new RewardSwapHelper();
        helper.initialize(address(usdc), admin, address(uniRouter), address(camelotRouter));

        // Grant KEEPER_ROLE to alice — she acts as the adapter/keeper in swap tests
        // Note: store the hash before vm.prank to avoid consuming the prank on the view call
        bytes32 keeperRole = keccak256("KEEPER_ROLE");
        vm.prank(admin);
        helper.grantRole(keeperRole, alice);

        // Default config for COMP: $60, slippage 1%, maxAge 25h (1h buffer over 24h heartbeat)
        feed.set(60e8, block.timestamp);
        vm.prank(admin);
        helper.setRewardConfig(
            address(comp),
            address(feed),
            8, 18,
            90_000, // realistic Arbitrum 24h heartbeat + buffer
            uniPath,
            camelotPath,
            100 // 1% slippage
        );
    }

    function _seedCallerWithComp(address caller, uint256 amount) internal {
        comp.mint(caller, amount);
        vm.prank(caller);
        comp.approve(address(helper), amount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    function test_constructor_revertsOnZeroUsdc() public {
        RewardSwapHelper _tmp = new RewardSwapHelper();
        vm.expectRevert(RewardSwapHelper.ZeroAddress.selector);
        _tmp.initialize(address(0), admin, address(uniRouter), address(camelotRouter));
    }

    function test_constructor_revertsOnZeroAdmin() public {
        RewardSwapHelper _tmp = new RewardSwapHelper();
        vm.expectRevert(RewardSwapHelper.ZeroAddress.selector);
        _tmp.initialize(address(usdc), address(0), address(uniRouter), address(camelotRouter));
    }

    function test_constructor_revertsOnZeroUniRouter() public {
        RewardSwapHelper _tmp = new RewardSwapHelper();
        vm.expectRevert(RewardSwapHelper.ZeroAddress.selector);
        _tmp.initialize(address(usdc), admin, address(0), address(camelotRouter));
    }

    function test_constructor_camelotZeroAllowed() public {
        // Camelot is optional — address(0) is OK
        RewardSwapHelper h = new RewardSwapHelper();
        h.initialize(address(usdc), admin, address(uniRouter), address(0));
        assertEq(h.camelotV3Router(), address(0));
    }

    function test_constructor_setsImmutables() public view {
        assertEq(helper.usdc(), address(usdc));
        assertEq(helper.uniswapV3Router(), address(uniRouter));
        assertEq(helper.camelotV3Router(), address(camelotRouter));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN — setRewardConfig
    // ═══════════════════════════════════════════════════════════════════════

    function test_setRewardConfig_revertsOnZeroToken() public {
        vm.prank(admin);
        vm.expectRevert(RewardSwapHelper.ZeroAddress.selector);
        helper.setRewardConfig(address(0), address(feed), 8, 18, 3600, uniPath, camelotPath, 100);
    }

    function test_setRewardConfig_revertsOnZeroFeed() public {
        vm.prank(admin);
        vm.expectRevert(RewardSwapHelper.ZeroAddress.selector);
        helper.setRewardConfig(address(comp), address(0), 8, 18, 3600, uniPath, camelotPath, 100);
    }

    function test_setRewardConfig_revertsOnSlippageTooHigh() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(RewardSwapHelper.SlippageTooHigh.selector, uint16(1001)));
        helper.setRewardConfig(address(comp), address(feed), 8, 18, 3600, uniPath, camelotPath, 1001);
    }

    function test_setRewardConfig_acceptsSlippageAtCap() public {
        // Cap tightened to 500 bps (5%) by HIGH-R1
        vm.prank(admin);
        helper.setRewardConfig(address(comp), address(feed), 8, 18, 3600, uniPath, camelotPath, 500);
        // No revert
    }

    function test_setRewardConfig_revertsOnEmptyUniPath() public {
        bytes memory emptyPath;
        vm.prank(admin);
        vm.expectRevert(RewardSwapHelper.InvalidConfig.selector);
        helper.setRewardConfig(address(comp), address(feed), 8, 18, 3600, emptyPath, camelotPath, 100);
    }

    function test_setRewardConfig_revertsOnMaxAgeBelowFloor() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(RewardSwapHelper.MaxFeedAgeOutOfRange.selector, uint32(3_599)));
        helper.setRewardConfig(address(comp), address(feed), 8, 18, 3_599, uniPath, camelotPath, 100);
    }

    function test_setRewardConfig_revertsOnMaxAgeAboveCeiling() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(RewardSwapHelper.MaxFeedAgeOutOfRange.selector, uint32(7 days + 1)));
        helper.setRewardConfig(address(comp), address(feed), 8, 18, uint32(7 days + 1), uniPath, camelotPath, 100);
    }

    function test_setRewardConfig_acceptsAtFloor() public {
        vm.prank(admin);
        helper.setRewardConfig(address(comp), address(feed), 8, 18, 3_600, uniPath, camelotPath, 100);
        // No revert
    }

    function test_setRewardConfig_acceptsAtCeiling() public {
        vm.prank(admin);
        helper.setRewardConfig(address(comp), address(feed), 8, 18, uint32(7 days), uniPath, camelotPath, 100);
        // No revert
    }

    function test_setRewardConfig_revertsOnNonRole() public {
        vm.prank(alice);
        vm.expectRevert();
        helper.setRewardConfig(address(comp), address(feed), 8, 18, 3600, uniPath, camelotPath, 100);
    }

    function test_setRewardConfig_camelotPathOptional() public {
        bytes memory empty;
        vm.prank(admin);
        helper.setRewardConfig(address(comp), address(feed), 8, 18, 3600, uniPath, empty, 100);
        // No revert; Camelot fallback simply disabled for this token
        assertTrue(helper.isEnabled(address(comp)));
    }

    function test_setRewardConfig_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit RewardSwapHelper.RewardConfigured(address(comp), address(feed), 200, 7200);
        vm.prank(admin);
        helper.setRewardConfig(address(comp), address(feed), 8, 18, 7200, uniPath, camelotPath, 200);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN — disableReward
    // ═══════════════════════════════════════════════════════════════════════

    function test_disableReward_setsEnabledFalse() public {
        vm.prank(admin);
        helper.disableReward(address(comp));
        assertFalse(helper.isEnabled(address(comp)));
    }

    function test_disableReward_revertsOnNonRole() public {
        vm.prank(alice);
        vm.expectRevert();
        helper.disableReward(address(comp));
    }

    function test_disableReward_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit RewardSwapHelper.RewardConfigDisabled(address(comp));
        vm.prank(admin);
        helper.disableReward(address(comp));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SWAP — happy path Uniswap V3
    // ═══════════════════════════════════════════════════════════════════════

    function test_swapToUSDC_uniswapHappyPath() public {
        // 10 COMP × $60 = $600 USDC = 600_000_000 (6-dec)
        // expected = 600e6, slippage 1% → minOut = 594e6
        uniRouter.setOutAmount(595e6); // satisfies minOut

        _seedCallerWithComp(alice, 10e18);
        vm.prank(alice);
        uint256 out = helper.swapToUSDC(address(comp), 10e18, core);

        assertEq(out, 595e6);
        assertEq(usdc.balanceOf(core), 595e6);
        assertEq(uniRouter.lastMinOut(), 594e6);
    }

    function test_swapToUSDC_returnsZeroOnZeroAmountIn() public {
        vm.prank(alice);
        uint256 out = helper.swapToUSDC(address(comp), 0, core);
        assertEq(out, 0);
    }

    function test_swapToUSDC_revertsOnDisabledToken() public {
        vm.prank(admin);
        helper.disableReward(address(comp));

        _seedCallerWithComp(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RewardSwapHelper.NotEnabled.selector, address(comp)));
        helper.swapToUSDC(address(comp), 10e18, core);
    }

    function test_swapToUSDC_revertsOnZeroReceiver() public {
        _seedCallerWithComp(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(RewardSwapHelper.ZeroAddress.selector);
        helper.swapToUSDC(address(comp), 10e18, address(0));
    }

    function test_swapToUSDC_revertsOnStaleOracle() public {
        // setUp uses maxAge=90_000 (25h, realistic Arbitrum heartbeat).
        // Skip 26h → feed becomes stale.
        skip(26 hours);

        _seedCallerWithComp(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert();
        helper.swapToUSDC(address(comp), 10e18, core);
    }

    function test_swapToUSDC_revertsOnNegativeOraclePrice() public {
        feed.set(-1, block.timestamp);

        _seedCallerWithComp(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert();
        helper.swapToUSDC(address(comp), 10e18, core);
    }

    function test_swapToUSDC_revertsOnZeroOraclePrice() public {
        feed.set(0, block.timestamp);
        _seedCallerWithComp(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert();
        helper.swapToUSDC(address(comp), 10e18, core);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SWAP — Uniswap revert → Camelot fallback
    // ═══════════════════════════════════════════════════════════════════════

    function test_swapToUSDC_fallsBackToCamelot() public {
        uniRouter.setRevertOnSwap(true);
        camelotRouter.setOutAmount(596e6);

        _seedCallerWithComp(alice, 10e18);
        vm.prank(alice);
        uint256 out = helper.swapToUSDC(address(comp), 10e18, core);

        assertEq(out, 596e6, "Camelot fallback used");
        assertEq(usdc.balanceOf(core), 596e6);
    }

    function test_swapToUSDC_uniSlippageBreach_camelotSucceeds() public {
        // Uniswap returns less than minOut → reverts internally → outAmount=0 → fallback
        uniRouter.setOutAmount(500e6); // < 594e6 minOut → uni reverts
        camelotRouter.setOutAmount(595e6);

        _seedCallerWithComp(alice, 10e18);
        vm.prank(alice);
        uint256 out = helper.swapToUSDC(address(comp), 10e18, core);
        assertEq(out, 595e6);
    }

    function test_swapToUSDC_revertsIfBothDexesFail() public {
        uniRouter.setRevertOnSwap(true);
        camelotRouter.setRevertOnSwap(true);

        _seedCallerWithComp(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(RewardSwapHelper.AllRoutesFailed.selector);
        helper.swapToUSDC(address(comp), 10e18, core);
    }

    function test_swapToUSDC_revertsIfCamelotPathDisabled_AndUniFails() public {
        // Reconfigure with empty Camelot path
        bytes memory empty;
        vm.prank(admin);
        helper.setRewardConfig(address(comp), address(feed), 8, 18, 3600, uniPath, empty, 100);

        uniRouter.setRevertOnSwap(true);

        _seedCallerWithComp(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(RewardSwapHelper.AllRoutesFailed.selector);
        helper.swapToUSDC(address(comp), 10e18, core);
    }

    function test_swapToUSDC_uniRevertsOnSlippageTooHigh_BothFail() public {
        // Both DEXes return less than minOut → both revert → AllRoutesFailed
        uniRouter.setOutAmount(500e6);
        camelotRouter.setOutAmount(400e6);

        _seedCallerWithComp(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(RewardSwapHelper.AllRoutesFailed.selector);
        helper.swapToUSDC(address(comp), 10e18, core);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SWAP — events
    // ═══════════════════════════════════════════════════════════════════════

    function test_swapToUSDC_emitsSwappedEventUni() public {
        uniRouter.setOutAmount(596e6);
        _seedCallerWithComp(alice, 10e18);

        vm.expectEmit(true, true, true, true);
        emit RewardSwapHelper.Swapped(alice, address(comp), 10e18, 596e6, core, 1);

        vm.prank(alice);
        helper.swapToUSDC(address(comp), 10e18, core);
    }

    function test_swapToUSDC_emitsSwappedEventCamelot() public {
        uniRouter.setRevertOnSwap(true);
        camelotRouter.setOutAmount(597e6);

        _seedCallerWithComp(alice, 10e18);
        vm.expectEmit(true, true, true, true);
        emit RewardSwapHelper.Swapped(alice, address(comp), 10e18, 597e6, core, 2);
        vm.prank(alice);
        helper.swapToUSDC(address(comp), 10e18, core);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ORACLE EXPECTED-OUT MATH
    // ═══════════════════════════════════════════════════════════════════════

    function test_previewExpectedOut_correctMath() public view {
        // 10 COMP × $60 = $600 = 600_000_000 (6-dec)
        uint256 e = helper.previewExpectedOut(address(comp), 10e18);
        assertEq(e, 600_000_000);
    }

    function test_previewExpectedOut_smallAmount() public view {
        // 0.1 COMP × $60 = $6 = 6_000_000
        uint256 e = helper.previewExpectedOut(address(comp), 0.1e18);
        assertEq(e, 6_000_000);
    }

    function test_previewExpectedOut_returnsZeroOnDisabled() public {
        vm.prank(admin);
        helper.disableReward(address(comp));
        assertEq(helper.previewExpectedOut(address(comp), 10e18), 0);
    }

    function test_previewExpectedOut_handlesPriceChange() public {
        feed.set(120e8, block.timestamp); // $120
        uint256 e = helper.previewExpectedOut(address(comp), 10e18);
        assertEq(e, 1_200_000_000); // $1200 = 1.2 billion 6-dec
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SLIPPAGE BPS APPLIED
    // ═══════════════════════════════════════════════════════════════════════

    function test_slippage_appliedToMinOut_500bps() public {
        // Reconfigure with 5% slippage
        vm.prank(admin);
        helper.setRewardConfig(address(comp), address(feed), 8, 18, 3600, uniPath, camelotPath, 500);

        // expected 600e6, slippage 5% → minOut = 570e6
        uniRouter.setOutAmount(575e6);

        _seedCallerWithComp(alice, 10e18);
        vm.prank(alice);
        helper.swapToUSDC(address(comp), 10e18, core);
        assertEq(uniRouter.lastMinOut(), 570_000_000);
    }

    function test_slippage_appliedToMinOut_zeroBps() public {
        vm.prank(admin);
        helper.setRewardConfig(address(comp), address(feed), 8, 18, 3600, uniPath, camelotPath, 0);

        // 0% slippage → minOut = expected exactly
        uniRouter.setOutAmount(600e6);

        _seedCallerWithComp(alice, 10e18);
        vm.prank(alice);
        helper.swapToUSDC(address(comp), 10e18, core);
        assertEq(uniRouter.lastMinOut(), 600_000_000);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // RESCUE
    // ═══════════════════════════════════════════════════════════════════════

    function test_rescueERC20_admin_canRescueUnconfiguredToken() public {
        MockERC20 randomToken = new MockERC20("Random", "RND", 18);
        randomToken.mint(address(helper), 100e18);

        vm.prank(admin);
        helper.rescueERC20(address(randomToken), admin, 100e18);
        assertEq(randomToken.balanceOf(admin), 100e18);
    }

    function test_rescueERC20_revertsOnEnabledRewardToken() public {
        comp.mint(address(helper), 5e18);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(RewardSwapHelper.NotEnabled.selector, address(comp)));
        helper.rescueERC20(address(comp), admin, 5e18);
    }

    function test_rescueERC20_canRescueDisabledRewardToken() public {
        comp.mint(address(helper), 5e18);
        vm.prank(admin);
        helper.disableReward(address(comp));
        vm.prank(admin);
        helper.rescueERC20(address(comp), admin, 5e18);
        assertEq(comp.balanceOf(admin), 5e18);
    }

    function test_rescueERC20_revertsOnZeroReceiver() public {
        MockERC20 r = new MockERC20("X", "X", 18);
        r.mint(address(helper), 1e18);
        vm.prank(admin);
        vm.expectRevert(RewardSwapHelper.ZeroAddress.selector);
        helper.rescueERC20(address(r), address(0), 1e18);
    }

    function test_rescueERC20_revertsOnNonAdmin() public {
        MockERC20 r = new MockERC20("X", "X", 18);
        r.mint(address(helper), 1e18);
        vm.prank(alice);
        vm.expectRevert();
        helper.rescueERC20(address(r), alice, 1e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEWS
    // ═══════════════════════════════════════════════════════════════════════

    function test_isEnabled_trueAfterConfig() public view {
        assertTrue(helper.isEnabled(address(comp)));
    }

    function test_isEnabled_falseForUnknownToken() public view {
        assertFalse(helper.isEnabled(address(0xDEAD)));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SWEEP PROTECTION
    // ═══════════════════════════════════════════════════════════════════════

    function test_receiveETH_reverts() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(helper).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_fallback_reverts() public {
        (bool ok,) = address(helper).call(abi.encodeWithSignature("nope()"));
        assertFalse(ok);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // canSwap PRE-FLIGHT GATE (M1 — LINK-burn mitigation)
    // ═══════════════════════════════════════════════════════════════════════

    function test_canSwap_trueWhenHealthy() public view {
        assertTrue(helper.canSwap(address(comp)));
    }

    function test_canSwap_falseWhenDisabled() public {
        vm.prank(admin);
        helper.disableReward(address(comp));
        assertFalse(helper.canSwap(address(comp)));
    }

    function test_canSwap_falseWhenStaleOracle() public {
        skip(26 hours); // setUp maxAge=90_000 (25h), 26h > stale
        assertFalse(helper.canSwap(address(comp)));
    }

    function test_canSwap_falseWhenNegativePrice() public {
        feed.set(-1, block.timestamp);
        assertFalse(helper.canSwap(address(comp)));
    }

    function test_canSwap_falseWhenZeroPrice() public {
        feed.set(0, block.timestamp);
        assertFalse(helper.canSwap(address(comp)));
    }

    function test_canSwap_falseForUnconfiguredToken() public view {
        address unconf = address(0xDEAD);
        assertFalse(helper.canSwap(unconf));
    }

    function test_canSwap_handlesFutureUpdatedAt() public {
        // Simulate corrupted feed with future updatedAt
        feed.set(60e8, block.timestamp + 1 hours);
        assertFalse(helper.canSwap(address(comp)));
    }

    function test_canSwap_recoversAfterFeedRefresh() public {
        skip(26 hours);
        assertFalse(helper.canSwap(address(comp)));
        // Refresh feed
        feed.set(60e8, block.timestamp);
        assertTrue(helper.canSwap(address(comp)));
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// HIGH-R1 + HIGH-R2 — tighter slippage cap + KEEPER_ROLE access control
// ═══════════════════════════════════════════════════════════════════════════

contract RewardSwapHelper_R1R2_Test is RewardSwapHelperTest {

    // ── R1: boundary test — 501 bps now exceeds the 500 bps cap ──────────
    function test_setRewardConfig_revertsOnSlippage_501_above_new_cap() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(RewardSwapHelper.SlippageTooHigh.selector, uint16(501)));
        helper.setRewardConfig(address(comp), address(feed), 8, 18, 3600, uniPath, camelotPath, 501);
    }

    // ── R1: boundary test — exactly 500 bps is accepted ──────────────────
    function test_setRewardConfig_accepts_exactly_500_bps() public {
        vm.prank(admin);
        helper.setRewardConfig(address(comp), address(feed), 8, 18, 3600, uniPath, camelotPath, 500);
        (,,,,,, uint16 bps, bool enabled) = helper.configs(address(comp));
        assertEq(bps, 500, "500 bps accepted and stored");
        assertTrue(enabled);
    }

    // ── R2: unauthorized caller cannot call swapToUSDC ───────────────────
    // Validates that KEEPER_ROLE is enforced — non-role EOA reverts even with
    // valid token approval and enabled config.
    function test_swapToUSDC_reverts_without_keeper_role() public {
        address stranger = address(0xBAD);
        comp.mint(stranger, 10e18);
        vm.prank(stranger);
        comp.approve(address(helper), 10e18);
        uniRouter.setOutAmount(594e6);

        vm.prank(stranger);
        vm.expectRevert(); // AccessControl: missing role
        helper.swapToUSDC(address(comp), 10e18, stranger);
    }

    // ── R2: keeper (alice, granted KEEPER_ROLE in setUp) can call swapToUSDC ─
    function test_swapToUSDC_succeeds_with_keeper_role() public {
        uniRouter.setOutAmount(595e6);
        _seedCallerWithComp(alice, 10e18);

        vm.prank(alice);
        uint256 out = helper.swapToUSDC(address(comp), 10e18, core);
        assertEq(out, 595e6, "keeper swap succeeds");
        assertEq(usdc.balanceOf(core), 595e6);
    }
}
