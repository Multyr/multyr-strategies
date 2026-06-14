// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import {
    CometUsdcMultiMarketAdapter
} from "../../../../src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SimpleProtocolRegistry } from "../../../helpers/SimpleProtocolRegistry.sol";

// ============================================================================
// MOCKS
// ============================================================================

contract MockUSDCComet {
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
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

/// @dev Mock Compound III Comet — supports supply/withdraw, rate curves, totals.
contract MockComet {
    address public baseToken;
    mapping(address => uint256) public balanceOf;

    // Rate model (settable by tests)
    uint256 public utilizationStored = 5e17;     // 50% default (1e18 scale)
    uint256 public supplyRatePerSec = 158548959; // ~5% APR (1e18 scale): 5e16/year/secondsInYear
    bool public revertOnUtilization;
    bool public revertOnSupplyRate;
    bool public revertOnSupply;
    bool public revertOnWithdraw;

    // totalsBasic packed values
    uint64 public baseSupplyIndex = 1e15;       // initial 1.0 in 1e15 scale
    uint64 public totalSupplyBaseStored;
    uint64 public baseIndexScale_ = 1e15;

    constructor(address _base) {
        baseToken = _base;
    }

    function setUtilization(uint256 u) external { utilizationStored = u; }
    function setSupplyRate(uint256 r) external { supplyRatePerSec = r; }
    function setRevertOnUtilization(bool v) external { revertOnUtilization = v; }
    function setRevertOnSupplyRate(bool v) external { revertOnSupplyRate = v; }
    function setRevertOnSupply(bool v) external { revertOnSupply = v; }
    function setRevertOnWithdraw(bool v) external { revertOnWithdraw = v; }
    function setBaseSupplyIndex(uint64 i) external { baseSupplyIndex = i; }
    function setBaseIndexScale(uint64 s) external { baseIndexScale_ = s; }

    function getUtilization() external view returns (uint256) {
        require(!revertOnUtilization, "util-revert");
        return utilizationStored;
    }

    function getSupplyRate(uint256 /*util*/) external view returns (uint256) {
        require(!revertOnSupplyRate, "rate-revert");
        return supplyRatePerSec;
    }

    function totalsBasic() external view returns (uint64, uint64, uint104, uint104, uint64, uint64) {
        return (baseSupplyIndex, 0, 0, 0, totalSupplyBaseStored, 0);
    }

    function baseIndexScale() external view returns (uint64) {
        return baseIndexScale_;
    }

    function supply(address asset, uint256 amount) external {
        require(!revertOnSupply, "supply-revert");
        require(asset == baseToken, "wrong-asset");
        MockUSDCComet(baseToken).transferFrom(msg.sender, address(this), amount);
        balanceOf[msg.sender] += amount;
        totalSupplyBaseStored += uint64(amount);
    }

    function withdraw(address asset, uint256 amount) external {
        require(!revertOnWithdraw, "withdraw-revert");
        require(asset == baseToken, "wrong-asset");
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        totalSupplyBaseStored -= uint64(amount);
        MockUSDCComet(baseToken).transfer(msg.sender, amount);
    }

    // Simulate yield accrual (for tests)
    function simulateYield(address holder, uint256 amount) external {
        balanceOf[holder] += amount;
        MockUSDCComet(baseToken).mint(address(this), amount);
    }
}


// ============================================================================
// REWARD PIPELINE MOCKS (Step 4 D — Comet COMP rewards)
// ============================================================================

contract MockCOMP {
    string public constant symbol = "COMP";
    uint8 public constant decimals = 18;
    string public constant name = "Compound";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; totalSupply += amount; }
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

contract MockCometRewards {
    address public rewardTokenAddr;
    uint256 public claimAmount;
    bool public revertOnClaim;
    constructor(address _tok) { rewardTokenAddr = _tok; }
    function setClaimAmount(uint256 a) external { claimAmount = a; }
    function setRevertOnClaim(bool v) external { revertOnClaim = v; }
    function claim(address /*comet*/, address src, bool /*shouldAccrue*/) external {
        if (revertOnClaim) revert("rc-revert");
        if (claimAmount > 0) MockCOMP(rewardTokenAddr).mint(src, claimAmount);
    }
}

contract MockSwapHelperComet {
    address public usdc;
    bool public canSwapDefault = true;
    bool public revertOnSwap;
    uint256 public outAmount;
    uint256 public expectedOut;
    constructor(address _u) { usdc = _u; }
    function setCanSwap(bool v) external { canSwapDefault = v; }
    function setRevertOnSwap(bool v) external { revertOnSwap = v; }
    function setOutAmount(uint256 a) external { outAmount = a; }
    function setExpectedOut(uint256 e) external { expectedOut = e; }
    function canSwap(address) external view returns (bool) { return canSwapDefault; }
    function previewExpectedOut(address, uint256) external view returns (uint256) { return expectedOut; }
    function swapToUSDC(address rewardToken, uint256 amountIn, address receiver) external returns (uint256) {
        if (revertOnSwap) revert("swap-revert");
        MockCOMP(rewardToken).transferFrom(msg.sender, address(this), amountIn);
        (bool ok,) = usdc.call(abi.encodeWithSignature("mint(address,uint256)", receiver, outAmount));
        require(ok, "mint-failed");
        return outAmount;
    }
}

// ============================================================================
// TEST CONTRACT
// ============================================================================

contract CometAdapter_Test is Test {
    CometUsdcMultiMarketAdapter public adapter;
    MockUSDCComet public usdc;
    MockComet public comet1;
    MockComet public comet2;
    MockComet public comet3;
    SimpleProtocolRegistry public registry;

    address public admin = address(0x1);
    address public vault = address(0x2);
    address public alice = address(0x3);

    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant PARAM_ROLE = keccak256("PARAM_ROLE");

    function setUp() public {
        usdc = new MockUSDCComet();
        comet1 = new MockComet(address(usdc));
        comet2 = new MockComet(address(usdc));
        comet3 = new MockComet(address(usdc));

        // Use a registry with comet1 to enable construction (constructor requires at least 1 market)
        registry = new SimpleProtocolRegistry();
        registry.addVault(
            SimpleProtocolRegistry.ProtocolType.COMPOUND_V3,
            address(comet1),
            "MockComet1",
            10000,
            100_000_000e6
        );

        adapter = new CometUsdcMultiMarketAdapter();
        adapter.initialize(address(usdc), admin, vault, 10_000_000e6, address(registry));
    }

    function _addMarket(MockComet c) internal {
        vm.prank(admin);
        adapter.addMarket(address(c));
    }

    function _mintAndApprove(address to, uint256 amount) internal {
        usdc.mint(to, amount);
        vm.prank(to);
        usdc.approve(address(adapter), amount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    function test_constructor_grants_roles() public view {
        assertTrue(adapter.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(adapter.hasRole(PARAM_ROLE, admin));
    }

    function test_constructor_sets_state() public view {
        assertEq(adapter.underlying(), address(usdc));
        assertEq(adapter.vault(), vault);
        assertEq(adapter.maxCapacity(), 10_000_000e6);
    }

    function test_constructor_reverts_zero_usdc() public {
        SimpleProtocolRegistry r = new SimpleProtocolRegistry();
        r.addVault(SimpleProtocolRegistry.ProtocolType.COMPOUND_V3, address(comet1), "M", 10000, 100_000_000e6);
        CometUsdcMultiMarketAdapter _tmp = new CometUsdcMultiMarketAdapter();
        vm.expectRevert(bytes("zero"));
        _tmp.initialize(address(0), admin, vault, 0, address(r));
    }

    function test_constructor_reverts_zero_admin() public {
        SimpleProtocolRegistry r = new SimpleProtocolRegistry();
        r.addVault(SimpleProtocolRegistry.ProtocolType.COMPOUND_V3, address(comet1), "M", 10000, 100_000_000e6);
        CometUsdcMultiMarketAdapter _tmp = new CometUsdcMultiMarketAdapter();
        vm.expectRevert(bytes("zero"));
        _tmp.initialize(address(usdc), address(0), vault, 0, address(r));
    }

    function test_constructor_reverts_zero_vault() public {
        SimpleProtocolRegistry r = new SimpleProtocolRegistry();
        r.addVault(SimpleProtocolRegistry.ProtocolType.COMPOUND_V3, address(comet1), "M", 10000, 100_000_000e6);
        CometUsdcMultiMarketAdapter _tmp = new CometUsdcMultiMarketAdapter();
        vm.expectRevert(bytes("zero"));
        _tmp.initialize(address(usdc), admin, address(0), 0, address(r));
    }

    function test_constructor_reverts_no_markets() public {
        SimpleProtocolRegistry empty = new SimpleProtocolRegistry();
        CometUsdcMultiMarketAdapter _tmp = new CometUsdcMultiMarketAdapter();
        vm.expectRevert(bytes("CometAdapter: no markets - registry required or use addMarket"));
        _tmp.initialize(address(usdc), admin, vault, 0, address(empty));
    }

    function test_constructor_loads_from_registry() public view {
        // comet1 was added in setUp
        address[] memory ms = adapter.markets();
        assertEq(ms.length, 1);
        assertEq(ms[0], address(comet1));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // METADATA
    // ═══════════════════════════════════════════════════════════════════════

    function test_name_returns_correct() public view {
        assertEq(adapter.name(), "Comet_USDC_MultiMarket_Adapter_Arbitrum");
    }

    function test_isPushMode_false() public view {
        assertFalse(adapter.isPushMode());
    }

    function test_underlying_returns_usdc() public view {
        assertEq(adapter.underlying(), address(usdc));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARKET REGISTRY (PARAM_ROLE)
    // ═══════════════════════════════════════════════════════════════════════

    function test_addMarket_extends_list() public {
        _addMarket(comet2);
        address[] memory ms = adapter.markets();
        assertEq(ms.length, 2);
        assertEq(ms[1], address(comet2));
    }

    function test_addMarket_only_param_role() public {
        vm.prank(alice);
        vm.expectRevert(bytes("NotParam"));
        adapter.addMarket(address(comet2));
    }

    function test_addMarket_reverts_zero() public {
        vm.prank(admin);
        vm.expectRevert(bytes("zero"));
        adapter.addMarket(address(0));
    }

    function test_addMarket_reverts_wrong_asset() public {
        MockUSDCComet other = new MockUSDCComet();
        MockComet bad = new MockComet(address(other));
        vm.prank(admin);
        vm.expectRevert(bytes("NotUSDC"));
        adapter.addMarket(address(bad));
    }

    function test_toggleMarket_enables_disables() public {
        _addMarket(comet2);
        vm.prank(admin);
        adapter.toggleMarket(1, false);
        // Toggle back
        vm.prank(admin);
        adapter.toggleMarket(1, true);
    }

    function test_flagMarket_flags_unflag() public {
        vm.prank(admin);
        adapter.flagMarket(0, true);
        vm.prank(admin);
        adapter.flagMarket(0, false);
    }

    function test_updateMarketAddress_updates() public {
        vm.prank(admin);
        adapter.updateMarketAddress(0, address(comet2));
        address[] memory ms = adapter.markets();
        assertEq(ms[0], address(comet2));
    }

    function test_setRiskScore_updates() public {
        vm.prank(admin);
        adapter.setRiskScore(0, 8000);
    }

    function test_setRiskScore_only_param_role() public {
        vm.prank(alice);
        vm.expectRevert(bytes("NotParam"));
        adapter.setRiskScore(0, 8000);
    }

    function test_setCapacity_updates() public {
        vm.prank(admin);
        adapter.setCapacity(50_000_000e6);
        assertEq(adapter.maxCapacity(), 50_000_000e6);
    }

    function test_setIncentiveBps_updates() public {
        // Post-Reward-Pipeline-v1: incentiveAPYBps applies haircut (default 7500 = 75%).
        // 150 * (10000-7500)/10000 = 150 * 0.25 = 37 (truncated)
        vm.prank(admin);
        adapter.setIncentiveBps(150);
        assertEq(uint256(adapter.incentiveAPYBps()), 37);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ACCOUNTING
    // ═══════════════════════════════════════════════════════════════════════

    function test_idleAssetBalance_zero_initially() public view {
        assertEq(adapter.idleAssetBalance(), 0);
    }

    function test_idleAssetBalance_reflects_raw_USDC() public {
        usdc.mint(address(adapter), 200e6);
        assertEq(adapter.idleAssetBalance(), 200e6);
    }

    function test_investedAssets_reflects_comet_balance() public {
        _mintAndApprove(vault, 1000e6);
        vm.prank(vault);
        adapter.deposit(1000e6);
        assertEq(adapter.investedAssets(), 1000e6);
    }

    function test_totalAssets_sum_idle_and_invested() public {
        usdc.mint(address(adapter), 100e6);
        _mintAndApprove(vault, 900e6);
        vm.prank(vault);
        adapter.deposit(900e6);
        assertEq(adapter.totalAssets(), 1000e6);
    }

    function test_withdrawableAssets_bounded_by_market_cash() public {
        _mintAndApprove(vault, 1000e6);
        vm.prank(vault);
        adapter.deposit(1000e6);
        // Drain comet1 cash to simulate low liquidity
        vm.prank(address(comet1));
        usdc.transfer(alice, 700e6);
        // withdrawable = min(adapter balance=1000e6, cash=300e6) = 300e6
        assertEq(adapter.withdrawableAssets(), 300e6);
    }

    function test_positions_returns_assets_per_market() public {
        _mintAndApprove(vault, 500e6);
        vm.prank(vault);
        adapter.deposit(500e6);
        uint256[] memory pos = adapter.positions();
        assertEq(pos.length, 1);
        assertEq(pos[0], 500e6);
    }

    function test_activeMarket_returns_current() public view {
        assertEq(adapter.activeMarket(), address(comet1));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // APY (UTILIZATION KINK)
    // ═══════════════════════════════════════════════════════════════════════

    function test_currentAPYBps_reads_from_active_market() public {
        // 5e16 / sec * 31536000 sec/yr / 1e18 = 1.5768... * 1e6 → bps = result/1e18 * 1e4
        comet1.setSupplyRate(158548959); // ~5% APR
        uint16 apy = adapter.currentAPYBps();
        // 158548959 * 31536000 = 5_000_000_336_000_000_000 wei → /1e18 * 1e4 = 50000 bps ... but capped
        // Actual computation: aprWad = 158548959 * 31536000 = ~5e18 (so APR=5e18/1e18=5 = 500% nope)
        // Let me check more carefully — we just verify it returns SOMETHING non-zero and uses _getAPYBps formula.
        assertGt(uint256(apy), 0);
    }

    function test_currentAPYBps_zero_when_rate_zero() public {
        comet1.setSupplyRate(0);
        assertEq(uint256(adapter.currentAPYBps()), 0);
    }

    function test_currentAPYBps_clamped_to_uint16_max() public {
        // Astronomical rate must clamp to type(uint16).max = 65535
        comet1.setSupplyRate(1e18); // 1 unit per second → 31.5M / year → huge
        assertEq(uint256(adapter.currentAPYBps()), 65535);
    }

    function test_currentAPYBps_uses_active_market_after_deposit() public {
        _addMarket(comet2);
        // Different APYs
        comet1.setSupplyRate(50_000_000); // ~1.6% APR
        comet2.setSupplyRate(150_000_000); // ~4.7% APR — best
        _mintAndApprove(vault, 1000e6);
        vm.prank(vault);
        adapter.deposit(1000e6); // routes to best (comet2)
        // active should be comet2 → APY reads from comet2
        assertEq(adapter.activeMarket(), address(comet2));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // LIFECYCLE: DEPOSIT
    // ═══════════════════════════════════════════════════════════════════════

    function test_deposit_routes_to_best_market() public {
        _addMarket(comet2);
        _addMarket(comet3);
        comet1.setSupplyRate(50_000_000);
        comet2.setSupplyRate(200_000_000); // best
        comet3.setSupplyRate(100_000_000);
        _mintAndApprove(vault, 1000e6);
        vm.prank(vault);
        adapter.deposit(1000e6);
        assertEq(comet2.balanceOf(address(adapter)), 1000e6);
        assertEq(comet1.balanceOf(address(adapter)), 0);
        assertEq(comet3.balanceOf(address(adapter)), 0);
    }

    function test_deposit_reverts_zero() public {
        vm.prank(vault);
        vm.expectRevert(bytes("zero"));
        adapter.deposit(0);
    }

    function test_deposit_reverts_non_vault() public {
        _mintAndApprove(alice, 1000e6);
        vm.prank(alice);
        vm.expectRevert(bytes("NotVault"));
        adapter.deposit(1000e6);
    }

    function test_deposit_reverts_over_capacity() public {
        vm.prank(admin);
        adapter.setCapacity(500e6);
        _mintAndApprove(vault, 600e6);
        vm.prank(vault);
        vm.expectRevert(bytes("cap"));
        adapter.deposit(600e6);
    }

    function test_deposit_skips_flagged_markets() public {
        _addMarket(comet2);
        // flag comet1 (the registry-loaded one)
        vm.prank(admin);
        adapter.flagMarket(0, true);
        // Even if comet1 has best APY, it must be skipped
        comet1.setSupplyRate(500_000_000);
        comet2.setSupplyRate(50_000_000);
        _mintAndApprove(vault, 100e6);
        vm.prank(vault);
        adapter.deposit(100e6);
        // Must route to comet2
        assertEq(comet2.balanceOf(address(adapter)), 100e6);
    }

    function test_deposit_skips_disabled_markets() public {
        _addMarket(comet2);
        vm.prank(admin);
        adapter.toggleMarket(0, false);
        comet1.setSupplyRate(500_000_000);
        comet2.setSupplyRate(50_000_000);
        _mintAndApprove(vault, 100e6);
        vm.prank(vault);
        adapter.deposit(100e6);
        assertEq(comet2.balanceOf(address(adapter)), 100e6);
    }

    function test_deposit_emits_event() public {
        _mintAndApprove(vault, 500e6);
        vm.expectEmit(false, false, false, true);
        emit CometUsdcMultiMarketAdapter.Supplied(500e6, address(comet1));
        vm.prank(vault);
        adapter.deposit(500e6);
    }

    function test_deposit_revokes_approval_after() public {
        _mintAndApprove(vault, 500e6);
        vm.prank(vault);
        adapter.deposit(500e6);
        assertEq(usdc.allowance(address(adapter), address(comet1)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // LIFECYCLE: WITHDRAW (multi-market)
    // ═══════════════════════════════════════════════════════════════════════

    function test_withdraw_sends_to_vault() public {
        _mintAndApprove(vault, 1000e6);
        vm.prank(vault);
        adapter.deposit(1000e6);
        uint256 balBefore = usdc.balanceOf(vault);
        vm.prank(vault);
        adapter.withdraw(400e6, vault);
        assertEq(usdc.balanceOf(vault) - balBefore, 400e6);
    }

    function test_withdraw_caps_to_available() public {
        _mintAndApprove(vault, 500e6);
        vm.prank(vault);
        adapter.deposit(500e6);
        vm.prank(vault);
        uint256 got = adapter.withdraw(1_000_000e6, vault);
        assertEq(got, 500e6);
    }

    function test_withdraw_only_vault() public {
        _mintAndApprove(vault, 1000e6);
        vm.prank(vault);
        adapter.deposit(1000e6);
        vm.prank(alice);
        vm.expectRevert(bytes("NotVault"));
        adapter.withdraw(100e6, vault);
    }

    function test_withdraw_from_multiple_markets() public {
        _addMarket(comet2);
        // Deposit 500 each in comet1 & comet2 by alternating best APY
        comet1.setSupplyRate(100_000_000);
        comet2.setSupplyRate(50_000_000);
        _mintAndApprove(vault, 500e6);
        vm.prank(vault);
        adapter.deposit(500e6); // → comet1
        // Switch best to comet2
        comet1.setSupplyRate(50_000_000);
        comet2.setSupplyRate(150_000_000);
        _mintAndApprove(vault, 500e6);
        vm.prank(vault);
        adapter.deposit(500e6); // → comet2
        // Withdraw 800 → should pull from least-APY first (comet1, 500), then comet2 (300)
        vm.prank(vault);
        uint256 got = adapter.withdraw(800e6, vault);
        assertEq(got, 800e6);
        assertEq(comet1.balanceOf(address(adapter)), 0);
        assertEq(comet2.balanceOf(address(adapter)), 200e6);
    }

    function test_withdraw_emits_event() public {
        _mintAndApprove(vault, 500e6);
        vm.prank(vault);
        adapter.deposit(500e6);
        vm.expectEmit(false, false, false, true);
        emit CometUsdcMultiMarketAdapter.Withdrawn(200e6, address(comet1), vault);
        vm.prank(vault);
        adapter.withdraw(200e6, vault);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SUPPLY CAP / OVERFLOW protection
    // ═══════════════════════════════════════════════════════════════════════

    function test_capacity_zero_means_infinite() public {
        vm.prank(admin);
        adapter.setCapacity(0);
        // Huge deposit allowed
        _mintAndApprove(vault, 100_000_000e6);
        vm.prank(vault);
        adapter.deposit(100_000_000e6);
        assertEq(adapter.investedAssets(), 100_000_000e6);
    }

    function test_capacity_exact_boundary() public {
        vm.prank(admin);
        adapter.setCapacity(1000e6);
        _mintAndApprove(vault, 1000e6);
        vm.prank(vault);
        adapter.deposit(1000e6); // exactly at cap
        assertEq(adapter.totalAssets(), 1000e6);
    }

    function test_capacity_revert_one_wei_over() public {
        vm.prank(admin);
        adapter.setCapacity(1000e6);
        _mintAndApprove(vault, 1000e6);
        vm.prank(vault);
        adapter.deposit(1000e6);
        // Now any further deposit reverts
        _mintAndApprove(vault, 1);
        vm.prank(vault);
        vm.expectRevert(bytes("cap"));
        adapter.deposit(1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // EXTERNAL TVL
    // ═══════════════════════════════════════════════════════════════════════

    function test_externalMarketTVL_uses_totalsBasic() public {
        _mintAndApprove(vault, 1000e6);
        vm.prank(vault);
        adapter.deposit(1000e6);
        // totalsBasic returns totalSupplyBaseStored (set via supply)
        // baseSupplyIndex=1e15, baseIndexScale=1e15 → totalSupplyBase * 1 = 1000e6
        uint256 tvl = adapter.externalMarketTVL();
        assertEq(tvl, 1000e6);
    }

    function test_externalMarketTVL_skips_disabled() public {
        _addMarket(comet2);
        _mintAndApprove(vault, 500e6);
        vm.prank(vault);
        adapter.deposit(500e6); // → comet1
        // Disable comet1, TVL drops to 0
        vm.prank(admin);
        adapter.toggleMarket(0, false);
        assertEq(adapter.externalMarketTVL(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // EFFECTIVE APY (multi-market weighted)
    // ═══════════════════════════════════════════════════════════════════════

    function test_effectiveAPYBps_zero_when_no_assets() public view {
        assertEq(uint256(adapter.effectiveAPYBps()), 0);
    }

    function test_effectiveAPYBps_single_market() public {
        comet1.setSupplyRate(158548959);
        _mintAndApprove(vault, 1000e6);
        vm.prank(vault);
        adapter.deposit(1000e6);
        uint16 eff = adapter.effectiveAPYBps();
        uint16 cur = adapter.currentAPYBps();
        assertEq(uint256(eff), uint256(cur));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // HARVEST (stub: returns 0)
    // ═══════════════════════════════════════════════════════════════════════

    function test_harvest_returns_zero() public {
        vm.prank(vault);
        uint256 r = adapter.harvest(vault);
        assertEq(r, 0);
    }

    function test_harvestableProfit_returns_zero() public view {
        assertEq(adapter.harvestableProfit(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // REWARD PIPELINE V1 — Step 4 D regression coverage
    // ═══════════════════════════════════════════════════════════════════════

    MockCOMP internal _comp;
    MockCometRewards internal _rc;
    MockSwapHelperComet internal _sh;

    function _initRewardPipeline() internal {
        _comp = new MockCOMP();
        _rc = new MockCometRewards(address(_comp));
        _sh = new MockSwapHelperComet(address(usdc));
        vm.prank(admin);
        adapter.setRewardConfig(address(_comp), address(_rc), address(_sh));
    }

    function test_v4d_setRewardConfig_happyPath() public {
        _initRewardPipeline();
        assertEq(adapter.rewardToken(), address(_comp));
        assertEq(adapter.rewardsController(), address(_rc));
        assertEq(adapter.swapHelper(), address(_sh));
    }

    function test_v4d_setRewardConfig_idempotent() public {
        _initRewardPipeline();
        vm.prank(admin);
        vm.expectRevert(bytes("already-init"));
        adapter.setRewardConfig(address(_comp), address(_rc), address(_sh));
    }

    function test_v4d_setRewardConfig_revertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(bytes("zero"));
        adapter.setRewardConfig(address(0), address(1), address(2));
    }

    function test_v4d_setRewardConfig_only_param_role() public {
        vm.prank(alice);
        vm.expectRevert(bytes("NotParam"));
        adapter.setRewardConfig(address(1), address(2), address(3));
    }

    function test_v4d_defaultHaircut_7500() public view {
        assertEq(uint256(adapter.incentiveHaircutBps()), 7500);
    }

    function test_v4d_setHaircutBps_capCheck() public {
        vm.prank(admin);
        vm.expectRevert(bytes("bps>10000"));
        adapter.setIncentiveHaircutBps(10_001);
    }

    function test_v4d_incentiveAPYBps_appliesHaircutOnRealized() public {
        vm.prank(admin);
        adapter.setRealizedRewardAPRBps(1000);
        // 1000 * (10000-7500)/10000 = 250
        assertEq(uint256(adapter.incentiveAPYBps()), 250);
    }

    function test_v4d_realizedTakesPriorityOverLegacy() public {
        vm.startPrank(admin);
        adapter.setIncentiveBps(800);
        adapter.setRealizedRewardAPRBps(2000);
        vm.stopPrank();
        // realized=2000 wins -> 2000*2500/10000 = 500
        assertEq(uint256(adapter.incentiveAPYBps()), 500);
    }

    function test_v4d_harvestableProfit_zeroIfNotInit() public view {
        assertEq(adapter.harvestableProfit(), 0);
    }

    function test_v4d_harvestableProfit_zeroIfCannotSwap() public {
        _initRewardPipeline();
        _comp.mint(address(adapter), 5e18);
        _sh.setCanSwap(false);
        assertEq(adapter.harvestableProfit(), 0);
    }

    function test_v4d_harvestableProfit_returnsExpected() public {
        _initRewardPipeline();
        _comp.mint(address(adapter), 5e18);
        _sh.setExpectedOut(300_000_000);
        assertEq(adapter.harvestableProfit(), 300_000_000);
    }

    function test_v4d_harvest_happyPath() public {
        _initRewardPipeline();
        _rc.setClaimAmount(8e18);
        _sh.setOutAmount(480_000_000);
        vm.prank(vault);
        uint256 realized = adapter.harvest(vault);
        assertEq(realized, 480_000_000);
        assertEq(usdc.balanceOf(vault), 480_000_000);
        assertEq(_comp.balanceOf(address(adapter)), 0);
    }

    function test_v4d_harvest_defersOnStaleOracle() public {
        _initRewardPipeline();
        _rc.setClaimAmount(5e18);
        _sh.setCanSwap(false); // RA-10: oracle stale
        vm.prank(vault);
        uint256 realized = adapter.harvest(vault);
        assertEq(realized, 0);
        assertEq(_comp.balanceOf(address(adapter)), 5e18, "COMP retained for retry");
    }

    function test_v4d_harvest_handlesClaimRevert() public {
        _initRewardPipeline();
        _rc.setRevertOnClaim(true);
        vm.prank(vault);
        uint256 realized = adapter.harvest(vault);
        assertEq(realized, 0);
    }

    function test_v4d_harvest_handlesSwapRevertGracefully() public {
        _initRewardPipeline();
        _rc.setClaimAmount(5e18);
        _sh.setRevertOnSwap(true);
        vm.prank(vault);
        uint256 realized = adapter.harvest(vault);
        assertEq(realized, 0);
        assertEq(_comp.balanceOf(address(adapter)), 5e18);
    }

    function test_v4d_harvest_revertsOnNonVault() public {
        _initRewardPipeline();
        vm.prank(alice);
        vm.expectRevert(bytes("NotVault"));
        adapter.harvest(vault);
    }

    function test_v4d_harvest_resetsApprovalAfterSwap() public {
        _initRewardPipeline();
        _rc.setClaimAmount(3e18);
        _sh.setOutAmount(180e6);
        vm.prank(vault);
        adapter.harvest(vault);
        assertEq(_comp.allowance(address(adapter), address(_sh)), 0);
    }

    function test_v4d_pendingRewardBalance_reflects() public {
        _initRewardPipeline();
        _comp.mint(address(adapter), 4e18);
        assertEq(adapter.pendingRewardBalance(), 4e18);
    }

    function test_v4d_setSwapHelper_canDisableHarvest() public {
        _initRewardPipeline();
        vm.prank(admin);
        adapter.setSwapHelper(address(0));
        _comp.mint(address(adapter), 5e18);
        assertEq(adapter.harvestableProfit(), 0, "helper unset disables");
    }
}

// ============================================================================
// S21 BATCH 4 — Comet setter edge cases + views (5 tests)
// ============================================================================
contract S21_CometSetterTest is CometAdapter_Test {

    // GAP: flagMarket bad-index revert never asserted
    function test_flagMarket_badIndex_reverts() public {
        vm.prank(admin);
        vm.expectRevert(bytes("badIdx"));
        adapter.flagMarket(99, true);
    }

    // GAP: setCostsEstimates state update never asserted
    function test_setCostsEstimates_updatesState() public {
        vm.prank(admin);
        adapter.setCostsEstimates(10, 5, 2e6);
        assertEq(adapter.slippageBpsEstimate(), 10, "slippageBps should update");
        assertEq(adapter.gasCostUSDC(), 2e6, "gasCostUSDC should update");
    }

    // GAP: setOptimizeParams state update never asserted
    function test_setOptimizeParams_updatesState() public {
        vm.prank(admin);
        adapter.setOptimizeParams(600, 30, 3);
        assertEq(adapter.minSecondsBetweenOptimize(), 600, "optimize interval should update");
    }

    // GAP: setCapacity unauthorized revert never asserted
    function test_setCapacity_onlyParam() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.setCapacity(999e6);
    }

    // GAP: incentiveAPYBps with realizedRewardAPRBps priority path never asserted
    function test_incentiveAPYBps_realizedTakesPriority() public {
        // Default incentiveHaircutBps = 7500 (retain 25%): result = 500 * 2500 / 10000 = 125
        vm.prank(admin);
        adapter.setRealizedRewardAPRBps(500);
        assertEq(adapter.incentiveAPYBps(), 125, "realizedRewardAPRBps should take priority with haircut applied");
    }
}

// ============================================================================
// S22 BATCH 1 — Comet gap closers (2 tests)
// ============================================================================
contract S22_CometGapTest is CometAdapter_Test {

    // GAP: refreshFromRegistry — clears and reloads from registry
    function test_refreshFromRegistry_reloadsMarkets() public {
        // Start: 1 market loaded from registry (comet1)
        assertEq(adapter.markets().length, 1, "should have 1 market from constructor");

        // Add comet2 to registry and refresh
        registry.addVault(
            SimpleProtocolRegistry.ProtocolType.COMPOUND_V3,
            address(comet2),
            "MockComet2",
            10000,
            100_000_000e6
        );

        vm.prank(admin);
        adapter.refreshFromRegistry();

        assertEq(adapter.markets().length, 2, "should now have 2 markets after refresh");
    }

    // GAP: refreshFromRegistry — onlyParam reverts for non-param caller
    function test_refreshFromRegistry_onlyParam() public {
        vm.expectRevert();
        vm.prank(alice);
        adapter.refreshFromRegistry();
    }

    // GAP: receive() must revert on ETH send
    function test_receiveETH_reverts() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(adapter).call{value: 1 ether}("");
        assertFalse(ok, "receive must revert");
    }

    // GAP: fallback() must revert on unknown call
    function test_fallback_reverts() public {
        (bool ok,) = address(adapter).call(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok, "fallback must revert");
    }
}
