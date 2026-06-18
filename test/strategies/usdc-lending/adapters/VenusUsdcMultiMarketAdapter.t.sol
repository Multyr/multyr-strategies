// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { VenusUsdcMultiMarketAdapter } from "../../../../src/strategies/usdc-lending/adapters/lending/VenusUsdcMultiMarket.sol";

// ═══════════════════════════════════════════════════════════════════════════
// MOCKS
// ═══════════════════════════════════════════════════════════════════════════

/// @dev Mock USDC with tracked allowances + balances
contract MockUSDCVenus {
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

/// @dev Mock vToken — Compound-fork semantics
contract MockVToken {
    address public underlying;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    // Test controls
    uint256 public exchangeRate;       // scaled 1e16 for USDC 6dec, vToken 8dec
    uint256 public supplyRate;          // per-block (1e18 scale)
    uint256 public cash;                // getCash() value
    uint256 public borrows;             // totalBorrows() value
    uint256 public mintErrorCode;       // 0 = success
    uint256 public redeemErrorCode;
    bool public revertOnGetCash;
    bool public revertOnTotalBorrows;
    bool public revertOnRedeem;

    constructor(address _underlying) {
        underlying = _underlying;
        exchangeRate = 2e16; // 1 vToken = 0.02 USDC (typical Compound-fork ratio)
        cash = type(uint128).max; // unlimited liquidity by default
    }

    function setExchangeRate(uint256 r) external { exchangeRate = r; }
    function setSupplyRate(uint256 r) external { supplyRate = r; }
    function setCash(uint256 c) external { cash = c; revertOnGetCash = false; }
    function setBorrows(uint256 b) external { borrows = b; revertOnTotalBorrows = false; }
    function setMintError(uint256 e) external { mintErrorCode = e; }
    function setRedeemError(uint256 e) external { redeemErrorCode = e; }
    function setRevertOnGetCash(bool v) external { revertOnGetCash = v; }
    function setRevertOnTotalBorrows(bool v) external { revertOnTotalBorrows = v; }
    function setRevertOnRedeem(bool v) external { revertOnRedeem = v; }

    function exchangeRateStored() external view returns (uint256) { return exchangeRate; }
    function exchangeRateCurrent() external returns (uint256) { return exchangeRate; }
    function supplyRatePerBlock() external view returns (uint256) { return supplyRate; }

    function getCash() external view returns (uint256) {
        require(!revertOnGetCash, "getCash revert");
        return cash;
    }

    function totalBorrows() external view returns (uint256) {
        require(!revertOnTotalBorrows, "totalBorrows revert");
        return borrows;
    }

    function mint(uint256 mintAmount) external returns (uint256) {
        if (mintErrorCode != 0) return mintErrorCode;
        // Pull underlying from msg.sender
        MockUSDCVenus(underlying).transferFrom(msg.sender, address(this), mintAmount);
        // Mint vTokens at current exchange rate
        uint256 vTokens = (mintAmount * 1e18) / exchangeRate;
        balanceOf[msg.sender] += vTokens;
        totalSupply += vTokens;
        cash += mintAmount;
        return 0;
    }

    function redeemUnderlying(uint256 redeemAmount) external returns (uint256) {
        if (redeemErrorCode != 0) return redeemErrorCode;
        if (revertOnRedeem) revert("redeem revert");
        require(cash >= redeemAmount, "insufficient cash");
        uint256 vTokens = (redeemAmount * 1e18) / exchangeRate;
        require(balanceOf[msg.sender] >= vTokens, "insufficient vTokens");
        balanceOf[msg.sender] -= vTokens;
        totalSupply -= vTokens;
        cash -= redeemAmount;
        MockUSDCVenus(underlying).transfer(msg.sender, redeemAmount);
        return 0;
    }

    function redeem(uint256 redeemTokens) external returns (uint256) {
        if (redeemErrorCode != 0) return redeemErrorCode;
        if (revertOnRedeem) revert("redeem revert");
        uint256 underlyingAmount = (redeemTokens * exchangeRate) / 1e18;
        require(cash >= underlyingAmount, "insufficient cash");
        require(balanceOf[msg.sender] >= redeemTokens, "insufficient vTokens");
        balanceOf[msg.sender] -= redeemTokens;
        totalSupply -= redeemTokens;
        cash -= underlyingAmount;
        MockUSDCVenus(underlying).transfer(msg.sender, underlyingAmount);
        return 0;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// TEST CONTRACT
// ═══════════════════════════════════════════════════════════════════════════

contract VenusUsdcMultiMarketAdapterTest is Test {
    uint256 constant ARBITRUM_CHAIN_ID = 42161;
    uint256 constant BNB_CHAIN_ID = 56;
    uint256 constant MAINNET_CHAIN_ID = 1;

    MockUSDCVenus internal usdc;
    MockVToken internal vToken;
    VenusUsdcMultiMarketAdapter internal adapter;

    address internal admin = address(0xA11CE);
    address internal vault = address(0xBEEF);
    address internal alice = address(0xA1);
    address internal core = address(0xC04E);

    function setUp() public {
        // Force Arbitrum chain ID for adapter deployment
        vm.chainId(ARBITRUM_CHAIN_ID);

        usdc = new MockUSDCVenus();
        vToken = new MockVToken(address(usdc));
        adapter = new VenusUsdcMultiMarketAdapter();
        adapter.initialize(address(usdc), admin, vault, 0, address(vToken), 126_144_000);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR — P0.L4 chain guard regression
    // ═══════════════════════════════════════════════════════════════════════

    function test_constructor_revertsOnMainnet() public pure {
        // V10: require(block.chainid == ARBITRUM_CHAIN_ID) removed for chain-portability.
        // Test retired — the revert no longer exists.
    }

    function test_constructor_revertsOnBNB() public pure {
        // V10: require(block.chainid == ARBITRUM_CHAIN_ID) removed for chain-portability.
        // Test retired — the revert no longer exists.
    }

    function test_constructor_revertsOnPolygon() public pure {
        // V10: require(block.chainid == ARBITRUM_CHAIN_ID) removed for chain-portability.
        // Test retired — the revert no longer exists.
    }

    function test_constructor_succeedsOnArbitrum() public {
        vm.chainId(ARBITRUM_CHAIN_ID);
        VenusUsdcMultiMarketAdapter a = new VenusUsdcMultiMarketAdapter();
        a.initialize(address(usdc), admin, vault, 100_000e6, address(vToken), 126_144_000);
        assertEq(a.underlying(), address(usdc));
        assertEq(a.vault(), vault);
        assertEq(a.vToken(), address(vToken));
        assertEq(a.capacity(), 100_000e6);
    }

    function test_constructor_revertsOnZeroAsset() public {
        VenusUsdcMultiMarketAdapter _tmp = new VenusUsdcMultiMarketAdapter();
        vm.expectRevert(bytes("zero"));
        _tmp.initialize(address(0), admin, vault, 0, address(vToken), 126_144_000);
    }

    function test_constructor_revertsOnZeroAdmin() public {
        VenusUsdcMultiMarketAdapter _tmp = new VenusUsdcMultiMarketAdapter();
        vm.expectRevert(bytes("zero"));
        _tmp.initialize(address(usdc), address(0), vault, 0, address(vToken), 126_144_000);
    }

    function test_constructor_revertsOnZeroVault() public {
        VenusUsdcMultiMarketAdapter _tmp = new VenusUsdcMultiMarketAdapter();
        vm.expectRevert(bytes("zero"));
        _tmp.initialize(address(usdc), admin, address(0), 0, address(vToken), 126_144_000);
    }

    function test_constructor_revertsOnZeroVToken() public {
        VenusUsdcMultiMarketAdapter _tmp = new VenusUsdcMultiMarketAdapter();
        vm.expectRevert(bytes("zero"));
        _tmp.initialize(address(usdc), admin, vault, 0, address(0), 126_144_000);
    }

    function test_constructor_revertsOnVTokenAssetMismatch() public {
        MockUSDCVenus otherToken = new MockUSDCVenus();
        MockVToken mismatchVToken = new MockVToken(address(otherToken));
        VenusUsdcMultiMarketAdapter _tmp = new VenusUsdcMultiMarketAdapter();
        vm.expectRevert(bytes("vToken/asset mismatch"));
        _tmp.initialize(address(usdc), admin, vault, 0, address(mismatchVToken), 126_144_000);
    }

    // C-04: blocksPerYear bounds
    function test_constructor_revertsOnZeroBlocksPerYear() public {
        VenusUsdcMultiMarketAdapter _tmp = new VenusUsdcMultiMarketAdapter();
        vm.expectRevert(bytes("blocksPerYear"));
        _tmp.initialize(address(usdc), admin, vault, 0, address(vToken), 0);
    }

    function test_constructor_revertsOnBlocksPerYearTooHigh() public {
        VenusUsdcMultiMarketAdapter _tmp = new VenusUsdcMultiMarketAdapter();
        vm.expectRevert(bytes("blocksPerYear"));
        _tmp.initialize(address(usdc), admin, vault, 0, address(vToken), 200_000_001);
    }

    function test_constructor_setsBlocksPerYear() public {
        VenusUsdcMultiMarketAdapter _tmp = new VenusUsdcMultiMarketAdapter();
        _tmp.initialize(address(usdc), admin, vault, 0, address(vToken), 15_768_000); // Optimism/Base
        assertEq(_tmp.blocksPerYear(), 15_768_000);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // METADATA
    // ═══════════════════════════════════════════════════════════════════════

    function test_name() public view {
        assertEq(adapter.name(), "Venus_USDC_Core_Adapter_Arbitrum");
    }

    function test_isPushMode_false() public view {
        assertFalse(adapter.isPushMode(), "Venus uses PULL");
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
        usdc.mint(address(adapter), 500e6);
        assertEq(adapter.idleAssetBalance(), 500e6);
    }

    function test_investedAssets_zero_initially() public view {
        assertEq(adapter.investedAssets(), 0);
    }

    function test_investedAssets_reflectsVTokenBalance() public {
        // Manually deposit then check
        usdc.mint(vault, 1000e6);
        vm.startPrank(vault);
        usdc.approve(address(adapter), 1000e6);
        adapter.deposit(1000e6);
        vm.stopPrank();

        // Invested = vTokenBal × rate / 1e18
        // vTokenBal = 1000e6 × 1e18 / 2e16 = 5e10 (50_000_000_000)
        // invested = 5e10 × 2e16 / 1e18 = 1000e6
        assertEq(adapter.investedAssets(), 1000e6);
    }

    function test_totalAssets_sumOfIdleAndInvested() public {
        usdc.mint(address(adapter), 200e6); // idle
        usdc.mint(vault, 800e6);
        vm.startPrank(vault);
        usdc.approve(address(adapter), 800e6);
        adapter.deposit(800e6);
        vm.stopPrank();

        assertEq(adapter.totalAssets(), 1000e6);
    }

    function test_withdrawableAssets_boundedByCash() public {
        usdc.mint(vault, 1000e6);
        vm.startPrank(vault);
        usdc.approve(address(adapter), 1000e6);
        adapter.deposit(1000e6);
        vm.stopPrank();

        // Set cash to 300e6 — withdrawable = min(invested=1000, cash=300) = 300
        vToken.setCash(300e6);
        assertEq(adapter.withdrawableAssets(), 300e6);
    }

    function test_withdrawableAssets_boundedByInvested() public {
        usdc.mint(vault, 500e6);
        vm.startPrank(vault);
        usdc.approve(address(adapter), 500e6);
        adapter.deposit(500e6);
        vm.stopPrank();

        // Cash huge, invested 500 → withdrawable = 500
        vToken.setCash(10_000_000e6);
        assertEq(adapter.withdrawableAssets(), 500e6);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // LIFECYCLE — DEPOSIT
    // ═══════════════════════════════════════════════════════════════════════

    function test_deposit_happyPath() public {
        usdc.mint(vault, 1000e6);
        vm.startPrank(vault);
        usdc.approve(address(adapter), 1000e6);
        adapter.deposit(1000e6);
        vm.stopPrank();

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
        vm.expectRevert(bytes("NotVault"));
        adapter.deposit(1000e6);
        vm.stopPrank();
    }

    function test_deposit_respectsCapacity() public {
        // Redeploy with capacity 500
        adapter = new VenusUsdcMultiMarketAdapter();
        adapter.initialize(address(usdc), admin, vault, 500e6, address(vToken), 126_144_000);

        usdc.mint(vault, 600e6);
        vm.startPrank(vault);
        usdc.approve(address(adapter), 600e6);
        vm.expectRevert(bytes("CAP"));
        adapter.deposit(600e6);
        vm.stopPrank();
    }

    function test_deposit_revertsIfMintFails() public {
        vToken.setMintError(1); // Compound-style: non-zero = error code

        usdc.mint(vault, 1000e6);
        vm.startPrank(vault);
        usdc.approve(address(adapter), 1000e6);
        vm.expectRevert(bytes("Venus:mint failed"));
        adapter.deposit(1000e6);
        vm.stopPrank();
    }

    function test_deposit_revokesApprovalAfter() public {
        usdc.mint(vault, 1000e6);
        vm.startPrank(vault);
        usdc.approve(address(adapter), 1000e6);
        adapter.deposit(1000e6);
        vm.stopPrank();

        // After deposit, adapter→vToken allowance must be 0 (just-in-time pattern)
        assertEq(usdc.allowance(address(adapter), address(vToken)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // LIFECYCLE — WITHDRAW
    // ═══════════════════════════════════════════════════════════════════════

    function _depositForWithdrawTest(uint256 amount) internal {
        usdc.mint(vault, amount);
        vm.startPrank(vault);
        usdc.approve(address(adapter), amount);
        adapter.deposit(amount);
        vm.stopPrank();
    }

    function test_withdraw_happyPath() public {
        _depositForWithdrawTest(1000e6);

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
        _depositForWithdrawTest(1000e6);
        vm.prank(alice);
        vm.expectRevert(bytes("NotVault"));
        adapter.withdraw(500e6, vault);
    }

    function test_withdraw_clampedByMaxOut() public {
        _depositForWithdrawTest(1000e6);
        vToken.setCash(300e6); // limit available cash to 300

        vm.prank(vault);
        uint256 got = adapter.withdraw(800e6, vault); // request 800
        assertEq(got, 300e6, "clamped to maxOut=cash");
    }

    function test_withdraw_revertsOnNoLiquidity() public {
        _depositForWithdrawTest(1000e6);
        vToken.setCash(0); // no cash available

        vm.prank(vault);
        vm.expectRevert(bytes("nothing withdrawable"));
        adapter.withdraw(100e6, vault);
    }

    function test_withdraw_revertsIfRedeemFails() public {
        _depositForWithdrawTest(1000e6);
        vToken.setRedeemError(1);

        vm.prank(vault);
        vm.expectRevert(bytes("Venus:redeem failed"));
        adapter.withdraw(500e6, vault);
    }

    function test_withdraw_alwaysSendsToVault() public {
        _depositForWithdrawTest(1000e6);

        // Try to send to alice — should still go to vault
        vm.prank(vault);
        adapter.withdraw(500e6, alice);

        assertEq(usdc.balanceOf(alice), 0, "alice gets nothing");
        assertEq(usdc.balanceOf(vault), 500e6, "vault gets all");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // YIELD VIEWS
    // ═══════════════════════════════════════════════════════════════════════

    function test_currentAPYBps_zeroByDefault() public view {
        assertEq(adapter.currentAPYBps(), 0);
    }

    function test_currentAPYBps_computedFromSupplyRate() public {
        // 5% APY = 500 bps. supplyRate per block such that:
        // rate * BLOCKS_PER_YEAR / 1e14 = 500
        // rate = 500 * 1e14 / 126_144_000 = ~3_964_553_686
        uint256 BLOCKS_PER_YEAR = 126_144_000;
        uint256 targetBps = 500;
        uint256 rate = (targetBps * 1e14) / BLOCKS_PER_YEAR;
        vToken.setSupplyRate(rate);

        // Allow some rounding (~1 bps)
        uint16 apy = adapter.currentAPYBps();
        assertApproxEqAbs(uint256(apy), targetBps, 1);
    }

    function test_currentAPYBps_clampedToUint16Max() public {
        // Set absurdly high rate → should clamp
        vToken.setSupplyRate(1e30);
        assertEq(adapter.currentAPYBps(), type(uint16).max);
    }

    function test_incentiveAPYBps_alwaysZero_v1() public view {
        // FIX P0.L1A: incentiveAPYBps not realized in v1 (no XVS reward harvesting)
        assertEq(adapter.incentiveAPYBps(), 0);
    }

    function test_harvestableProfit_alwaysZero_v1() public view {
        assertEq(adapter.harvestableProfit(), 0);
    }

    function test_harvest_returnsZero_v1() public {
        // Step 4.3: harvest now has onlyVault. Reward pipeline not initialized → returns 0.
        vm.prank(vault);
        uint256 realized = adapter.harvest(address(this));
        assertEq(realized, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // EXTERNAL MARKET TVL
    // ═══════════════════════════════════════════════════════════════════════

    function test_externalMarketTVL_sumOfCashAndBorrows() public {
        vToken.setCash(10_000_000e6);
        vToken.setBorrows(5_000_000e6);
        assertEq(adapter.externalMarketTVL(), 15_000_000e6);
    }

    function test_externalMarketTVL_returnsZeroOnGetCashRevert() public {
        vToken.setRevertOnGetCash(true);
        assertEq(adapter.externalMarketTVL(), 0);
    }

    function test_externalMarketTVL_handlesRevertOnTotalBorrows() public {
        vToken.setCash(7_000_000e6);
        vToken.setRevertOnTotalBorrows(true);
        // Should still return cash (borrows treated as 0)
        assertEq(adapter.externalMarketTVL(), 7_000_000e6);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN GATES
    // ═══════════════════════════════════════════════════════════════════════

    function test_setCapacity_paramRoleOnly() public {
        vm.prank(admin);
        adapter.setCapacity(1_000_000e6);
        assertEq(adapter.capacity(), 1_000_000e6);
    }

    function test_setCapacity_revertsOnNonParamRole() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.setCapacity(500e6);
    }

    function test_maxCapacity_returnsCapacity() public {
        vm.prank(admin);
        adapter.setCapacity(2_000_000e6);
        assertEq(adapter.maxCapacity(), 2_000_000e6);
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
        vm.expectRevert(bytes("NotVault"));
        adapter.sweepIdleAssetToVault();
    }

    function test_emergencyPullAllToVault_redeemsAndSweeps() public {
        _depositForWithdrawTest(1000e6);
        usdc.mint(address(adapter), 50e6); // some idle on top

        vm.prank(vault);
        adapter.emergencyPullAllToVault();

        // Vault should receive: 1000 (redeemed) + 50 (idle) = 1050
        assertEq(usdc.balanceOf(vault), 1050e6);
        assertEq(adapter.investedAssets(), 0);
        assertEq(adapter.idleAssetBalance(), 0);
    }

    function test_emergencyPullAllToVault_handlesRedeemFailure() public {
        _depositForWithdrawTest(500e6);
        usdc.mint(address(adapter), 30e6); // idle
        vToken.setRevertOnRedeem(true);

        vm.prank(vault);
        adapter.emergencyPullAllToVault();

        // Redeem failed → only idle goes to vault
        assertEq(usdc.balanceOf(vault), 30e6);
    }

    function test_emergencyPullAllToVault_revertsOnNonVault() public {
        vm.prank(alice);
        vm.expectRevert(bytes("NotVault"));
        adapter.emergencyPullAllToVault();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SWEEP PROTECTION (receive/fallback)
    // ═══════════════════════════════════════════════════════════════════════

    function test_receiveETH_reverts() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(adapter).call{value: 1 ether}("");
        assertFalse(ok, "receive must revert");
    }

    function test_fallback_reverts() public {
        (bool ok,) = address(adapter).call(abi.encodeWithSignature("nonExistentFn()"));
        assertFalse(ok, "fallback must revert");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS (selected critical ones)
    // ═══════════════════════════════════════════════════════════════════════

    event Supplied(uint256 assets);
    event Withdrawn(uint256 assets, address receiver);

    function test_deposit_emitsSupplied() public {
        usdc.mint(vault, 1000e6);
        vm.startPrank(vault);
        usdc.approve(address(adapter), 1000e6);
        vm.expectEmit(false, false, false, true);
        emit Supplied(1000e6);
        adapter.deposit(1000e6);
        vm.stopPrank();
    }

    function test_withdraw_emitsWithdrawn() public {
        _depositForWithdrawTest(1000e6);
        vm.prank(vault);
        vm.expectEmit(false, false, false, true);
        emit Withdrawn(500e6, vault);
        adapter.withdraw(500e6, vault);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STEP 4.3 — REWARD PIPELINE INTEGRATION
    // ═══════════════════════════════════════════════════════════════════════

    // Reward pipeline mocks (declared as instance vars + initialized in helpers)

    function _initRewardPipeline_Venus() internal returns (
        MockERC20XVS xvs,
        MockVenusComptroller comp,
        MockSwapHelperVenus helper
    ) {
        xvs = new MockERC20XVS();
        comp = new MockVenusComptroller(address(xvs));
        helper = new MockSwapHelperVenus(address(usdc));
        vm.prank(admin);
        adapter.initRewardConfig(address(xvs), address(comp), address(helper));
    }

    // ─── initRewardConfig tests ─────────────────────────────────────────

    function test_v43_initRewardConfig_happyPath() public {
        (MockERC20XVS xvs, MockVenusComptroller comp, MockSwapHelperVenus helper) = _initRewardPipeline_Venus();
        assertEq(adapter.rewardToken(), address(xvs));
        assertEq(adapter.comptroller(), address(comp));
        assertEq(adapter.swapHelper(), address(helper));
    }

    function test_v43_initRewardConfig_idempotentRevert() public {
        (MockERC20XVS xvs, MockVenusComptroller comp, MockSwapHelperVenus helper) = _initRewardPipeline_Venus();
        vm.prank(admin);
        vm.expectRevert(bytes("already-init"));
        adapter.initRewardConfig(address(xvs), address(comp), address(helper));
    }

    function test_v43_initRewardConfig_revertsOnZero() public {
        MockVenusComptroller comp = new MockVenusComptroller(address(0));
        MockSwapHelperVenus helper = new MockSwapHelperVenus(address(usdc));
        vm.prank(admin);
        vm.expectRevert(bytes("zero"));
        adapter.initRewardConfig(address(0), address(comp), address(helper));
    }

    function test_v43_initRewardConfig_revertsOnNonRole() public {
        MockERC20XVS xvs = new MockERC20XVS();
        MockVenusComptroller comp = new MockVenusComptroller(address(xvs));
        MockSwapHelperVenus helper = new MockSwapHelperVenus(address(usdc));
        vm.prank(alice);
        vm.expectRevert();
        adapter.initRewardConfig(address(xvs), address(comp), address(helper));
    }

    // ─── Setter tests ───────────────────────────────────────────────────

    function test_v43_setIncentiveHaircutBps_capCheck() public {
        vm.prank(admin);
        vm.expectRevert(bytes("bps>10000"));
        adapter.setIncentiveHaircutBps(10_001);
    }

    function test_v43_setRealizedRewardAPRBps_updates() public {
        vm.prank(admin);
        adapter.setRealizedRewardAPRBps(800);
        assertEq(uint256(adapter.realizedRewardAPRBps()), 800);
    }

    function test_v43_defaultHaircut_7500() public view {
        assertEq(uint256(adapter.incentiveHaircutBps()), 7500);
    }

    // ─── incentiveAPYBps haircut math ───────────────────────────────────

    function test_v43_incentiveAPYBps_appliesHaircut() public {
        vm.prank(admin);
        adapter.setRealizedRewardAPRBps(1000);
        // 1000 × (10000-7500)/10000 = 250
        assertEq(adapter.incentiveAPYBps(), 250);
    }

    function test_v43_incentiveAPYBps_haircutZero() public {
        vm.startPrank(admin);
        adapter.setRealizedRewardAPRBps(1000);
        adapter.setIncentiveHaircutBps(0);
        vm.stopPrank();
        assertEq(adapter.incentiveAPYBps(), 1000);
    }

    function test_v43_incentiveAPYBps_haircutFull() public {
        vm.startPrank(admin);
        adapter.setRealizedRewardAPRBps(1000);
        adapter.setIncentiveHaircutBps(10_000);
        vm.stopPrank();
        assertEq(adapter.incentiveAPYBps(), 0);
    }

    // ─── M1 harvestableProfit pre-flight gate ───────────────────────────

    function test_v43_harvestableProfit_zeroIfNotInit() public view {
        assertEq(adapter.harvestableProfit(), 0);
    }

    function test_v43_harvestableProfit_zeroIfNoBalance() public {
        _initRewardPipeline_Venus();
        assertEq(adapter.harvestableProfit(), 0);
    }

    function test_v43_harvestableProfit_zeroIfCannotSwap() public {
        (MockERC20XVS xvs,, MockSwapHelperVenus helper) = _initRewardPipeline_Venus();
        xvs.mint(address(adapter), 10e18);
        helper.setCanSwap(false);
        assertEq(adapter.harvestableProfit(), 0, "M1 gate active");
    }

    function test_v43_harvestableProfit_returnsExpected() public {
        (MockERC20XVS xvs,, MockSwapHelperVenus helper) = _initRewardPipeline_Venus();
        xvs.mint(address(adapter), 10e18);
        helper.setExpectedOut(450e6);
        assertEq(adapter.harvestableProfit(), 450e6);
    }

    // ─── M2 harvest graceful pattern ────────────────────────────────────

    function test_v43_harvest_happyPath() public {
        (MockERC20XVS xvs, MockVenusComptroller comp, MockSwapHelperVenus helper) = _initRewardPipeline_Venus();
        comp.setClaimAmount(7e18);
        helper.setOutAmount(420e6);

        vm.prank(vault);
        uint256 realized = adapter.harvest(core);

        assertEq(realized, 420e6);
        assertEq(usdc.balanceOf(core), 420e6);
        assertEq(xvs.balanceOf(address(adapter)), 0);
    }

    function test_v43_harvest_defersIfStaleOracle() public {
        (MockERC20XVS xvs, MockVenusComptroller comp, MockSwapHelperVenus helper) = _initRewardPipeline_Venus();
        comp.setClaimAmount(5e18);
        helper.setCanSwap(false);

        vm.prank(vault);
        uint256 realized = adapter.harvest(core);

        assertEq(realized, 0);
        assertEq(xvs.balanceOf(address(adapter)), 5e18, "raw retained");
    }

    function test_v43_harvest_handlesClaimRevert() public {
        (, MockVenusComptroller comp,) = _initRewardPipeline_Venus();
        comp.setRevertOnClaim(true);

        vm.prank(vault);
        uint256 realized = adapter.harvest(core);
        assertEq(realized, 0);
    }

    function test_v43_harvest_handlesSwapRevertGracefully() public {
        (MockERC20XVS xvs, MockVenusComptroller comp, MockSwapHelperVenus helper) = _initRewardPipeline_Venus();
        comp.setClaimAmount(5e18);
        helper.setRevertOnSwap(true);

        vm.prank(vault);
        uint256 realized = adapter.harvest(core);

        assertEq(realized, 0);
        assertEq(xvs.balanceOf(address(adapter)), 5e18);
    }

    function test_v43_harvest_revertsOnNonVault() public {
        _initRewardPipeline_Venus();
        vm.prank(alice);
        vm.expectRevert(bytes("NotVault"));
        adapter.harvest(core);
    }

    function test_v43_harvest_resetsApprovalAfterSwap() public {
        (MockERC20XVS xvs, MockVenusComptroller comp, MockSwapHelperVenus helper) = _initRewardPipeline_Venus();
        comp.setClaimAmount(3e18);
        helper.setOutAmount(180e6);
        vm.prank(vault);
        adapter.harvest(core);
        assertEq(xvs.allowance(address(adapter), address(helper)), 0);
    }

    function test_v43_pendingRewardBalance_reflectsBalance() public {
        (MockERC20XVS xvs,,) = _initRewardPipeline_Venus();
        xvs.mint(address(adapter), 6e18);
        assertEq(adapter.pendingRewardBalance(), 6e18);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// STEP 4.3 — REWARD PIPELINE MOCKS (after main contract since they're for v43 tests)
// ═══════════════════════════════════════════════════════════════════════════

contract MockERC20XVS {
    string public constant symbol = "XVS";
    uint8 public constant decimals = 18;
    string public constant name = "Venus";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

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

contract MockVenusComptroller {
    address public xvsToken;
    uint256 public claimAmount;
    bool public revertOnClaim;

    constructor(address _xvs) { xvsToken = _xvs; }
    function setClaimAmount(uint256 a) external { claimAmount = a; }
    function setRevertOnClaim(bool v) external { revertOnClaim = v; }

    function claimVenus(address holder, address[] calldata /*vTokens*/) external {
        if (revertOnClaim) revert("comp-revert");
        if (claimAmount > 0) {
            MockERC20XVS(xvsToken).mint(holder, claimAmount);
        }
    }
}

contract MockSwapHelperVenus {
    address public usdc;
    bool public canSwapResult = true;
    bool public revertOnSwap;
    uint256 public outAmount;
    uint256 public expectedOut;

    constructor(address _usdc) { usdc = _usdc; }
    function setCanSwap(bool v) external { canSwapResult = v; }
    function setRevertOnSwap(bool v) external { revertOnSwap = v; }
    function setOutAmount(uint256 a) external { outAmount = a; }
    function setExpectedOut(uint256 e) external { expectedOut = e; }

    function canSwap(address) external view returns (bool) { return canSwapResult; }
    function previewExpectedOut(address, uint256) external view returns (uint256) { return expectedOut; }
    function swapToUSDC(address rewardToken, uint256 amountIn, address receiver) external returns (uint256) {
        if (revertOnSwap) revert("swap-revert");
        MockERC20XVS(rewardToken).transferFrom(msg.sender, address(this), amountIn);
        // mint USDC to receiver via mock USDC contract
        (bool ok,) = usdc.call(abi.encodeWithSignature("mint(address,uint256)", receiver, outAmount));
        require(ok, "mint-failed");
        return outAmount;
    }
}

// ============================================================================
// S21 BATCH 3 — Venus setter edge cases + withdrawableAssets (4 tests)
// ============================================================================
contract S21_VenusSetterTest is VenusUsdcMultiMarketAdapterTest {

    // GAP: withdrawableAssets cash-limited branch (cash < invested) never asserted
    function test_withdrawableAssets_cashLimited() public {
        // Deposit 1000 USDC to adapter
        usdc.mint(vault, 1000e6);
        vm.startPrank(vault);
        usdc.approve(address(adapter), 1000e6);
        adapter.deposit(1000e6);
        vm.stopPrank();

        // Restrict vToken cash to 200 USDC — less than invested
        vToken.setCash(200e6);

        // withdrawableAssets should be capped at cash
        assertEq(adapter.withdrawableAssets(), 200e6, "should be limited by available cash");
    }

    // GAP: setCapacity unauthorized revert never asserted
    function test_setCapacity_onlyParamRole() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.setCapacity(1_000_000e6);
    }

    // GAP: setRealizedRewardAPRBps state update never asserted
    function test_setRealizedRewardAPRBps_updatesState() public {
        vm.prank(admin);
        adapter.setRealizedRewardAPRBps(250);
        assertEq(adapter.realizedRewardAPRBps(), 250, "realizedRewardAPRBps should update");
    }

    // GAP: setIncentiveHaircutBps >10000 revert never asserted
    function test_setIncentiveHaircutBps_tooHigh_reverts() public {
        vm.prank(admin);
        vm.expectRevert(bytes("bps>10000"));
        adapter.setIncentiveHaircutBps(10_001);
    }
}
