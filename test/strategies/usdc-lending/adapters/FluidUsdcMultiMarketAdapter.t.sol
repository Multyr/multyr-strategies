// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { FluidUsdcMultiMarketAdapter } from "../../../../src/strategies/usdc-lending/adapters/lending/FluidUsdcMultiMarket.sol";

// ═══════════════════════════════════════════════════════════════════════════
// MOCKS
// ═══════════════════════════════════════════════════════════════════════════

/// @dev Minimal USDC mock (6-dec)
contract MockUSDCFluid {
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
    string public constant name = "USD Coin";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @dev Mock ERC-4626 fToken (Fluid-style).
///      shares scale: 1e18 (PPS uses 1e18 base). assets scale: 6 (USDC).
///      convertToAssets(shares) = shares * pps / 1e30 to get USDC-decimals assets.
///      convertToShares(assets) = assets * 1e30 / pps to get 1e18-shares.
///      With pps=1e18 → 1 share ≡ 1 USDC unit (6dec on assets, 18dec on shares).
///      Default pps=1e18 (1 share = 1 USDC). bumpPPS() simulates yield accrual.
contract MockFluidFToken {
    address public asset;
    mapping(address => uint256) public balanceOf; // shares (1e18 scale)
    uint256 public totalSupply;

    // Test controls
    uint256 public pps; // price per share (1e18 base)
    uint256 public totalAssetsValue;
    uint256 public maxWithdrawCap; // type(uint256).max means uncapped
    uint256 public maxDepositCap;
    bool public revertOnTotalAssets;
    bool public revertOnRedeem;
    bool public revertOnWithdraw;
    uint256 public withdrawShortfallBps; // basis-points: 0=full, 100=99% delivered

    constructor(address _asset) {
        asset = _asset;
        pps = 1e18;
        maxWithdrawCap = type(uint256).max;
        maxDepositCap = type(uint256).max;
    }

    function setPPS(uint256 p) external { pps = p; }
    function setTotalAssetsValue(uint256 v) external { totalAssetsValue = v; }
    function setMaxWithdrawCap(uint256 c) external { maxWithdrawCap = c; }
    function setMaxDepositCap(uint256 c) external { maxDepositCap = c; }
    function setRevertOnTotalAssets(bool v) external { revertOnTotalAssets = v; }
    function setRevertOnRedeem(bool v) external { revertOnRedeem = v; }
    function setRevertOnWithdraw(bool v) external { revertOnWithdraw = v; }
    function setWithdrawShortfallBps(uint256 b) external { withdrawShortfallBps = b; }

    function totalAssets() external view returns (uint256) {
        require(!revertOnTotalAssets, "totalAssets revert");
        return totalAssetsValue;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * pps) / 1e30;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return (assets * 1e30) / pps;
    }

    function maxWithdraw(address /*owner*/) external view returns (uint256) {
        // Compute ownable: convertToAssets(shares of owner)
        uint256 ownable = (balanceOf[msg.sender] * pps) / 1e30; // not used; passing param
        // For simplicity, return min(maxWithdrawCap, balance value of caller)
        // But Solidity `address owner` is here ignored, we use the argument.
        // Re-read the param via view — we simulate "maxWithdraw of any owner = capped by maxWithdrawCap".
        ownable = maxWithdrawCap;
        return ownable;
    }

    function maxDeposit(address /*receiver*/) external view returns (uint256) {
        return maxDepositCap;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        // pull assets from msg.sender (the adapter)
        MockUSDCFluid(asset).transferFrom(msg.sender, address(this), assets);
        shares = (assets * 1e30) / pps;
        balanceOf[receiver] += shares;
        totalSupply += shares;
        totalAssetsValue += assets;
        return shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 sharesBurned) {
        if (revertOnWithdraw) revert("withdraw revert");
        // Compute shares to burn
        sharesBurned = (assets * 1e30) / pps;
        if (sharesBurned == 0) sharesBurned = 1;
        require(balanceOf[owner] >= sharesBurned, "insufficient shares");
        balanceOf[owner] -= sharesBurned;
        totalSupply -= sharesBurned;

        // Apply optional shortfall (Fluid doc says actual may differ)
        uint256 delivered = assets;
        if (withdrawShortfallBps > 0) {
            delivered = assets - (assets * withdrawShortfallBps / 10_000);
        }

        totalAssetsValue = totalAssetsValue >= delivered ? totalAssetsValue - delivered : 0;
        MockUSDCFluid(asset).transfer(receiver, delivered);
        return sharesBurned;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assetsOut) {
        if (revertOnRedeem) revert("redeem revert");
        require(balanceOf[owner] >= shares, "insufficient shares");
        assetsOut = (shares * pps) / 1e30;
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        totalAssetsValue = totalAssetsValue >= assetsOut ? totalAssetsValue - assetsOut : 0;
        MockUSDCFluid(asset).transfer(receiver, assetsOut);
        return assetsOut;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// TEST CONTRACT
// ═══════════════════════════════════════════════════════════════════════════

contract FluidUsdcMultiMarketAdapterTest is Test {
    MockUSDCFluid internal usdc;
    MockFluidFToken internal fToken;
    FluidUsdcMultiMarketAdapter internal adapter;

    address internal admin = address(0xA11CE);
    address internal vault = address(0xBEEF);
    address internal alice = address(0xA1);

    function setUp() public {
        usdc = new MockUSDCFluid();
        fToken = new MockFluidFToken(address(usdc));
        adapter = new FluidUsdcMultiMarketAdapter();
        adapter.initialize(address(usdc), admin, vault, 0, address(fToken));
    }

    // Helper: deposit via vault
    function _deposit(uint256 amount) internal {
        usdc.mint(vault, amount);
        vm.startPrank(vault);
        usdc.approve(address(adapter), amount);
        adapter.deposit(amount);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    function test_constructor_revertsOnZeroAsset() public {
        FluidUsdcMultiMarketAdapter _tmp = new FluidUsdcMultiMarketAdapter();
        vm.expectRevert(bytes("zero"));
        _tmp.initialize(address(0), admin, vault, 0, address(fToken));
    }

    function test_constructor_revertsOnZeroAdmin() public {
        FluidUsdcMultiMarketAdapter _tmp = new FluidUsdcMultiMarketAdapter();
        vm.expectRevert(bytes("zero"));
        _tmp.initialize(address(usdc), address(0), vault, 0, address(fToken));
    }

    function test_constructor_revertsOnZeroVault() public {
        FluidUsdcMultiMarketAdapter _tmp = new FluidUsdcMultiMarketAdapter();
        vm.expectRevert(bytes("zero"));
        _tmp.initialize(address(usdc), admin, address(0), 0, address(fToken));
    }

    function test_constructor_revertsOnZeroFToken() public {
        FluidUsdcMultiMarketAdapter _tmp = new FluidUsdcMultiMarketAdapter();
        vm.expectRevert(bytes("zero"));
        _tmp.initialize(address(usdc), admin, vault, 0, address(0));
    }

    function test_constructor_revertsOnAssetMismatch() public {
        MockUSDCFluid otherUsdc = new MockUSDCFluid();
        MockFluidFToken otherFToken = new MockFluidFToken(address(otherUsdc));
        FluidUsdcMultiMarketAdapter _tmp = new FluidUsdcMultiMarketAdapter();
        vm.expectRevert(bytes("fToken/asset mismatch"));
        _tmp.initialize(address(usdc), admin, vault, 0, address(otherFToken));
    }

    function test_constructor_initializesSnapshot() public {
        // Mock pps=1e18 → convertToAssets(1e18) = 1e18*1e18/1e30 = 1e6 (USDC 6-dec scale)
        (uint256 pps, uint64 ts) = adapter.getAPYSnapshot();
        assertEq(pps, 1e6);
        assertEq(uint256(ts), block.timestamp);
    }

    function test_constructor_setsCapacity() public {
        FluidUsdcMultiMarketAdapter a = new FluidUsdcMultiMarketAdapter();
        a.initialize(address(usdc), admin, vault, 500_000e6, address(fToken));
        assertEq(a.capacity(), 500_000e6);
        assertEq(a.maxCapacity(), 500_000e6);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // METADATA
    // ═══════════════════════════════════════════════════════════════════════

    function test_name() public view {
        assertEq(adapter.name(), "Fluid_USDC_Adapter_Arbitrum");
    }

    function test_isPushMode_false() public view {
        assertFalse(adapter.isPushMode());
    }

    function test_underlying_isUSDC() public view {
        assertEq(adapter.underlying(), address(usdc));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ACCOUNTING
    // ═══════════════════════════════════════════════════════════════════════

    function test_idleAssetBalance_zero_initially() public view {
        assertEq(adapter.idleAssetBalance(), 0);
    }

    function test_idleAssetBalance_reflectsRawUSDC() public {
        usdc.mint(address(adapter), 250e6);
        assertEq(adapter.idleAssetBalance(), 250e6);
    }

    function test_investedAssets_zero_initially() public view {
        assertEq(adapter.investedAssets(), 0);
    }

    function test_investedAssets_reflectsConvertToAssets() public {
        _deposit(1000e6);
        // PPS=1e18 → shares = 1000e6 * 1e30 / 1e18 = 1000e18
        // invested = 1000e18 * 1e18 / 1e30 = 1000e6
        assertEq(adapter.investedAssets(), 1000e6);
    }

    function test_investedAssets_reflectsPPSAccrual() public {
        _deposit(1000e6);
        // Bump PPS by 5% → invested grows 5%
        fToken.setPPS(1.05e18);
        assertEq(adapter.investedAssets(), 1050e6);
    }

    function test_totalAssets_sumOfIdleAndInvested() public {
        usdc.mint(address(adapter), 100e6); // idle
        _deposit(900e6);
        assertEq(adapter.totalAssets(), 1000e6);
    }

    function test_withdrawableAssets_returnsMaxWithdraw() public {
        fToken.setMaxWithdrawCap(750e6);
        assertEq(adapter.withdrawableAssets(), 750e6);
    }

    function test_shareBalance_returnsFTokenBalance() public {
        _deposit(500e6);
        // shares = 500e6 * 1e30 / 1e18 = 500e18
        assertEq(adapter.shareBalance(), 500e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // LIFECYCLE — DEPOSIT
    // ═══════════════════════════════════════════════════════════════════════

    function test_deposit_happyPath() public {
        _deposit(1000e6);
        assertEq(usdc.balanceOf(vault), 0);
        assertEq(adapter.investedAssets(), 1000e6);
    }

    function test_deposit_revertsOnZeroAmount() public {
        vm.prank(vault);
        vm.expectRevert(bytes("ZERO_ASSETS"));
        adapter.deposit(0);
    }

    function test_deposit_revertsOnNonVault() public {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(adapter), 1000e6);
        vm.expectRevert(bytes("not vault"));
        adapter.deposit(1000e6);
        vm.stopPrank();
    }

    function test_deposit_respectsCapacity() public {
        adapter = new FluidUsdcMultiMarketAdapter();
        adapter.initialize(address(usdc), admin, vault, 500e6, address(fToken));
        usdc.mint(vault, 600e6);
        vm.startPrank(vault);
        usdc.approve(address(adapter), 600e6);
        vm.expectRevert(bytes("CAP"));
        adapter.deposit(600e6);
        vm.stopPrank();
    }

    function test_deposit_revokesApprovalAfter() public {
        _deposit(1000e6);
        // After deposit, adapter→fToken allowance must be 0 (just-in-time)
        assertEq(usdc.allowance(address(adapter), address(fToken)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // LIFECYCLE — WITHDRAW
    // ═══════════════════════════════════════════════════════════════════════

    function test_withdraw_happyPath() public {
        _deposit(1000e6);
        vm.prank(vault);
        uint256 got = adapter.withdraw(500e6, vault);
        assertEq(got, 500e6);
        assertEq(usdc.balanceOf(vault), 500e6);
    }

    function test_withdraw_revertsOnZeroAmount() public {
        vm.prank(vault);
        vm.expectRevert(bytes("ZERO_ASSETS"));
        adapter.withdraw(0, vault);
    }

    function test_withdraw_revertsOnNonVault() public {
        _deposit(1000e6);
        vm.prank(alice);
        vm.expectRevert(bytes("not vault"));
        adapter.withdraw(500e6, vault);
    }

    function test_withdraw_clampedByMaxWithdraw() public {
        _deposit(1000e6);
        fToken.setMaxWithdrawCap(300e6);
        vm.prank(vault);
        uint256 got = adapter.withdraw(800e6, vault);
        assertEq(got, 300e6, "clamped to maxWithdraw");
    }

    function test_withdraw_returnsZeroIfMaxWithdrawZero() public {
        _deposit(500e6);
        fToken.setMaxWithdrawCap(0);
        vm.prank(vault);
        uint256 got = adapter.withdraw(100e6, vault);
        assertEq(got, 0);
        assertEq(usdc.balanceOf(vault), 0);
    }

    function test_withdraw_alwaysSendsToVault() public {
        _deposit(1000e6);
        vm.prank(vault);
        adapter.withdraw(500e6, alice); // try to send to alice
        assertEq(usdc.balanceOf(alice), 0, "alice nothing");
        assertEq(usdc.balanceOf(vault), 500e6, "vault all");
    }

    function test_withdraw_handlesActualReceivedShortfall() public {
        // Fluid docs warn fToken.withdraw may deliver slightly less.
        // Adapter measures actual received via balance delta.
        _deposit(1000e6);
        fToken.setWithdrawShortfallBps(100); // 1% shortfall
        vm.prank(vault);
        uint256 got = adapter.withdraw(500e6, vault);
        // Expected delivered = 500e6 - 5e6 = 495e6
        assertEq(got, 495e6, "actual received tracked");
        assertEq(usdc.balanceOf(vault), 495e6);
    }

    function test_withdraw_revertsIfFTokenWithdrawReverts() public {
        _deposit(500e6);
        fToken.setRevertOnWithdraw(true);
        vm.prank(vault);
        vm.expectRevert(bytes("withdraw revert"));
        adapter.withdraw(100e6, vault);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // YIELD VIEWS
    // ═══════════════════════════════════════════════════════════════════════

    function test_currentAPYBps_zeroBeforeAccrual() public view {
        // Default snapshot at deploy + no time passed → elapsed=0 → 0
        assertEq(adapter.currentAPYBps(), 0);
    }

    function test_currentAPYBps_zeroIfPPSUnchanged() public {
        skip(30 days);
        // PPS still 1e18, no delta → 0
        assertEq(adapter.currentAPYBps(), 0);
    }

    function test_currentAPYBps_computedFromPPSDelta() public {
        // Start: PPS=1e18, ts=t0
        // Skip 30 days, PPS=1.005e18 (0.5% over 30d)
        // annualBps = (5e15 * 365d * 10000) / (1e18 * 30d)
        //           = (5e15 * 31536000 * 10000) / (1e18 * 2592000)
        //           = (5e15 * 365 * 10000) / (1e18 * 30)
        //           = 1.825e22 / 3e19
        //           = 608 bps approximately
        skip(30 days);
        fToken.setPPS(1.005e18);
        uint16 apy = adapter.currentAPYBps();
        assertApproxEqAbs(uint256(apy), 608, 2);
    }

    function test_currentAPYBps_clampedToUint16Max() public {
        // Massive PPS jump over 1 second → astronomic APY → clamps
        skip(1);
        fToken.setPPS(1000e18); // 1000x
        assertEq(adapter.currentAPYBps(), type(uint16).max);
    }

    function test_currentAPYBps_apyOverridePriority() public {
        vm.prank(admin);
        adapter.setAPYOverrideBps(700);
        // Even with PPS up + time passed, override wins
        skip(30 days);
        fToken.setPPS(1.05e18);
        assertEq(adapter.currentAPYBps(), 700);
    }

    function test_incentiveAPYBps_defaultZero() public view {
        assertEq(adapter.incentiveAPYBps(), 0);
    }

    function test_incentiveAPYBps_reflectsSetter() public {
        vm.prank(admin);
        adapter.setIncentiveBps(300);
        assertEq(adapter.incentiveAPYBps(), 300);
    }

    function test_harvestableProfit_alwaysZero_v1() public view {
        assertEq(adapter.harvestableProfit(), 0);
    }

    function test_harvest_returnsZero_v1() public {
        uint256 r = adapter.harvest(address(this));
        assertEq(r, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // EXTERNAL MARKET TVL
    // ═══════════════════════════════════════════════════════════════════════

    function test_externalMarketTVL_returnsTotalAssets() public {
        fToken.setTotalAssetsValue(100_000_000e6);
        assertEq(adapter.externalMarketTVL(), 100_000_000e6);
    }

    function test_externalMarketTVL_returnsZeroOnRevert() public {
        fToken.setRevertOnTotalAssets(true);
        assertEq(adapter.externalMarketTVL(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN GATES
    // ═══════════════════════════════════════════════════════════════════════

    function test_setCapacity_paramRoleOnly() public {
        vm.prank(admin);
        adapter.setCapacity(1_000_000e6);
        assertEq(adapter.capacity(), 1_000_000e6);
    }

    function test_setCapacity_revertsOnNonRole() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.setCapacity(500e6);
    }

    function test_setIncentiveBps_paramRoleOnly() public {
        vm.prank(admin);
        adapter.setIncentiveBps(500);
        assertEq(adapter.incentiveAPYBps(), 500);
    }

    function test_setIncentiveBps_revertsOnTooHigh() public {
        vm.prank(admin);
        vm.expectRevert(bytes("bps>10000"));
        adapter.setIncentiveBps(10_001);
    }

    function test_setIncentiveBps_revertsOnNonRole() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.setIncentiveBps(100);
    }

    function test_setAPYOverrideBps_paramRoleOnly() public {
        vm.prank(admin);
        adapter.setAPYOverrideBps(800);
    }

    function test_setAPYOverrideBps_revertsOnTooHigh() public {
        vm.prank(admin);
        vm.expectRevert(bytes("bps>10000"));
        adapter.setAPYOverrideBps(10_001);
    }

    function test_setAPYOverrideBps_revertsOnNonRole() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.setAPYOverrideBps(500);
    }

    function test_pokeAPYSnapshots_updatesState() public {
        skip(1 days);
        fToken.setPPS(1.001e18);
        vm.prank(admin);
        adapter.pokeAPYSnapshots();
        (uint256 pps, uint64 ts) = adapter.getAPYSnapshot();
        // mock convertToAssets(1e18) with pps=1.001e18 → 1.001e6
        assertEq(pps, 1_001_000);
        assertEq(uint256(ts), block.timestamp);
    }

    function test_pokeAPYSnapshots_revertsOnNonRole() public {
        vm.prank(alice);
        vm.expectRevert(bytes("not param role"));
        adapter.pokeAPYSnapshots();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // IDLE & EMERGENCY
    // ═══════════════════════════════════════════════════════════════════════

    function test_sweepIdleAssetToVault_happyPath() public {
        usdc.mint(address(adapter), 250e6);
        vm.prank(vault);
        adapter.sweepIdleAssetToVault();
        assertEq(usdc.balanceOf(vault), 250e6);
        assertEq(adapter.idleAssetBalance(), 0);
    }

    function test_sweepIdleAssetToVault_revertsOnZeroIdle() public {
        vm.prank(vault);
        vm.expectRevert(bytes("no idle"));
        adapter.sweepIdleAssetToVault();
    }

    function test_sweepIdleAssetToVault_revertsOnNonVault() public {
        usdc.mint(address(adapter), 100e6);
        vm.prank(alice);
        vm.expectRevert(bytes("not vault"));
        adapter.sweepIdleAssetToVault();
    }

    function test_emergencyPullAllToVault_redeemsAndSweeps() public {
        _deposit(1000e6);
        usdc.mint(address(adapter), 50e6); // some idle on top
        vm.prank(vault);
        adapter.emergencyPullAllToVault();
        // Vault should get 1000 + 50 = 1050
        assertEq(usdc.balanceOf(vault), 1050e6);
        assertEq(adapter.investedAssets(), 0);
        assertEq(adapter.idleAssetBalance(), 0);
    }

    function test_emergencyPullAllToVault_handlesRedeemFailure() public {
        _deposit(500e6);
        usdc.mint(address(adapter), 30e6); // idle
        fToken.setRevertOnRedeem(true);
        vm.prank(vault);
        adapter.emergencyPullAllToVault();
        // Redeem failed → only idle (30e6) goes to vault
        assertEq(usdc.balanceOf(vault), 30e6);
    }

    function test_emergencyPullAllToVault_revertsOnNonVault() public {
        vm.prank(alice);
        vm.expectRevert(bytes("not vault"));
        adapter.emergencyPullAllToVault();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SWEEP PROTECTION
    // ═══════════════════════════════════════════════════════════════════════

    function test_receiveETH_reverts() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(adapter).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_fallback_reverts() public {
        (bool ok,) = address(adapter).call(abi.encodeWithSignature("nope()"));
        assertFalse(ok);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event Deposited(uint256 assets, uint256 shares);
    event Withdrawn(uint256 assets, address receiver);
    event APYSnapshotPoked(uint256 pps, uint64 ts);

    function test_deposit_emitsDeposited() public {
        usdc.mint(vault, 1000e6);
        vm.startPrank(vault);
        usdc.approve(address(adapter), 1000e6);
        vm.expectEmit(false, false, false, true);
        emit Deposited(1000e6, 1000e18); // shares = 1000e6 * 1e30 / 1e18
        adapter.deposit(1000e6);
        vm.stopPrank();
    }

    function test_withdraw_emitsWithdrawn() public {
        _deposit(1000e6);
        vm.prank(vault);
        vm.expectEmit(false, false, false, true);
        emit Withdrawn(500e6, vault);
        adapter.withdraw(500e6, vault);
    }

    function test_pokeAPYSnapshots_emitsEvent() public {
        skip(1 hours);
        fToken.setPPS(1.0001e18);
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        // pps emitted = convertToAssets(1e18) = 1.0001e18*1e18/1e30 = 1.0001e6
        emit APYSnapshotPoked(1_000_100, uint64(block.timestamp));
        adapter.pokeAPYSnapshots();
    }
}

// ============================================================================
// S21 BATCH 3 — Fluid setter edge cases (3 tests)
// ============================================================================
contract S21_FluidSetterTest is FluidUsdcMultiMarketAdapterTest {

    // GAP: setCapacity unauthorized revert never asserted
    function test_setCapacity_onlyParamRole() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.setCapacity(1_000_000e6);
    }

    // GAP: setIncentiveBps >10000 revert never asserted
    function test_setIncentiveBps_tooHigh_reverts() public {
        vm.prank(admin);
        vm.expectRevert(bytes("bps>10000"));
        adapter.setIncentiveBps(10_001);
    }

    // GAP: setAPYOverrideBps >10000 revert never asserted
    function test_setAPYOverrideBps_tooHigh_reverts() public {
        vm.prank(admin);
        vm.expectRevert(bytes("bps>10000"));
        adapter.setAPYOverrideBps(10_001);
    }
}
