// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console2 } from "forge-std/Test.sol";

/**
 * @title MultiAdapterBase Test Suite — INTERNAL MOCK PATTERNS ONLY
 * @notice Phase 4 Step 9 (misleading-name cleanup):
 *         This file tests COMMON MOCK PATTERNS shared across multi-market adapters.
 *         It does NOT test real Silo/Comet/Dolomite/Gains adapter bytecode.
 *         For real adapter coverage, see:
 *           - CometUsdcMultiMarketAdapter.t.sol  (Phase 4 Step 6)
 *           - DolomiteConfigCorrectness.t.sol + extensions (Phase 4 Step 7)
 *           - (Silo/Gains: out of scope for current lending suite)
 * @dev Mock-pattern utility tests (kept for code-review reference)
 */

// ============================================================================
// MOCK CONTRACTS
// ============================================================================

contract MockUSDCMulti {
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

// Generic ERC4626-like vault mock
contract MockERC4626Vault {
    address public immutable asset;
    string public name;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    uint256 public _totalAssets;

    uint16 public mockAPYBps;

    constructor(address _asset, string memory _name, uint16 _apy) {
        asset = _asset;
        name = _name;
        mockAPYBps = _apy;
    }

    function setAPY(uint16 apy) external {
        mockAPYBps = apy;
    }

    function getAPYBps() external view returns (uint16) {
        return mockAPYBps;
    }

    function totalAssets() external view returns (uint256) {
        return _totalAssets;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        if (totalSupply == 0) return shares;
        return (shares * _totalAssets) / totalSupply;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        if (_totalAssets == 0) return assets;
        return (assets * totalSupply) / _totalAssets;
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        if (_totalAssets == 0) return assets;
        return (assets * totalSupply) / _totalAssets;
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        uint256 shares = balanceOf[owner];
        if (totalSupply == 0) return shares;
        uint256 assets = (shares * _totalAssets) / totalSupply;
        uint256 cash = MockUSDCMulti(asset).balanceOf(address(this));
        return assets < cash ? assets : cash;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        MockUSDCMulti(asset).transferFrom(msg.sender, address(this), assets);
        shares = assets;
        if (_totalAssets > 0 && totalSupply > 0) {
            shares = (assets * totalSupply) / _totalAssets;
        }
        balanceOf[receiver] += shares;
        totalSupply += shares;
        _totalAssets += assets;
        return shares;
    }

    function withdraw(uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares)
    {
        shares = assets;
        if (_totalAssets > 0 && totalSupply > 0) {
            shares = (assets * totalSupply) / _totalAssets;
        }
        require(balanceOf[owner] >= shares, "insufficient shares");
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        _totalAssets -= assets;
        MockUSDCMulti(asset).transfer(receiver, assets);
        return shares;
    }

    function simulateYield(uint256 amount) external {
        _totalAssets += amount;
        MockUSDCMulti(asset).mint(address(this), amount);
    }
}

// Gains-specific mock with epoch-based withdrawals
contract MockGainsVault {
    address public immutable asset;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    uint256 public _totalAssets;

    // Epoch system
    uint256 public currentEpoch;
    mapping(address => mapping(uint256 => uint256)) public withdrawRequests; // user => epoch => amount

    uint16 public mockAPYBps = 500;

    constructor(address _asset) {
        asset = _asset;
    }

    function setAPY(uint16 apy) external {
        mockAPYBps = apy;
    }

    function getAPYBps() external view returns (uint16) {
        return mockAPYBps;
    }

    function totalAssets() external view returns (uint256) {
        return _totalAssets;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        if (totalSupply == 0) return shares;
        return (shares * _totalAssets) / totalSupply;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        MockUSDCMulti(asset).transferFrom(msg.sender, address(this), assets);
        shares = assets;
        if (_totalAssets > 0 && totalSupply > 0) {
            shares = (assets * totalSupply) / _totalAssets;
        }
        balanceOf[receiver] += shares;
        totalSupply += shares;
        _totalAssets += assets;
        return shares;
    }

    // Two-step withdrawal: request first, then claim after epoch
    function requestWithdraw(uint256 shares) external {
        require(balanceOf[msg.sender] >= shares, "insufficient");
        withdrawRequests[msg.sender][currentEpoch + 1] = shares;
        balanceOf[msg.sender] -= shares;
    }

    function claimWithdraw(uint256 epoch) external returns (uint256 assets) {
        uint256 shares = withdrawRequests[msg.sender][epoch];
        require(shares > 0, "no request");
        require(epoch <= currentEpoch, "epoch not ended");

        assets = shares;
        if (totalSupply > 0) {
            assets = (shares * _totalAssets) / totalSupply;
        }

        withdrawRequests[msg.sender][epoch] = 0;
        totalSupply -= shares;
        _totalAssets -= assets;
        MockUSDCMulti(asset).transfer(msg.sender, assets);
        return assets;
    }

    // Instant withdraw (for vault operations with liquidity)
    function instantWithdraw(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = assets;
        if (_totalAssets > 0 && totalSupply > 0) {
            shares = (assets * totalSupply) / _totalAssets;
        }
        require(balanceOf[msg.sender] >= shares, "insufficient shares");
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        _totalAssets -= assets;
        MockUSDCMulti(asset).transfer(receiver, assets);
        return shares;
    }

    function advanceEpoch() external {
        currentEpoch++;
    }

    function simulateYield(uint256 amount) external {
        _totalAssets += amount;
        MockUSDCMulti(asset).mint(address(this), amount);
    }
}

// Pool-like mock for Dolomite/Comet style
contract MockPoolLike {
    address public immutable asset;

    mapping(address => uint256) public accountBalances;
    uint256 public _totalAssets;

    uint16 public mockAPYBps = 500;

    constructor(address _asset) {
        asset = _asset;
    }

    function setAPY(uint16 apy) external {
        mockAPYBps = apy;
    }

    function getAPYBps() external view returns (uint16) {
        return mockAPYBps;
    }

    function supply(uint256 amount) external {
        MockUSDCMulti(asset).transferFrom(msg.sender, address(this), amount);
        accountBalances[msg.sender] += amount;
        _totalAssets += amount;
    }

    function withdraw(uint256 amount, address receiver) external returns (uint256) {
        uint256 toWithdraw =
            amount > accountBalances[msg.sender] ? accountBalances[msg.sender] : amount;
        accountBalances[msg.sender] -= toWithdraw;
        _totalAssets -= toWithdraw;
        MockUSDCMulti(asset).transfer(receiver, toWithdraw);
        return toWithdraw;
    }

    function balanceOf(address user) external view returns (uint256) {
        return accountBalances[user];
    }

    function simulateYield(uint256 amount) external {
        _totalAssets += amount;
        MockUSDCMulti(asset).mint(address(this), amount);
    }
}

// ============================================================================
// SILO ADAPTER TESTS
// ============================================================================

contract SiloAdapter_Test is Test {
    MockUSDCMulti public usdc;
    MockERC4626Vault public siloVault1;
    MockERC4626Vault public siloVault2;
    MockPoolLike public siloCore;

    address public vault = address(0x2);

    function setUp() public {
        usdc = new MockUSDCMulti();
        siloVault1 = new MockERC4626Vault(address(usdc), "Silo USDC Vault 1", 600);
        siloVault2 = new MockERC4626Vault(address(usdc), "Silo USDC Vault 2", 400);
        siloCore = new MockPoolLike(address(usdc));
    }

    function test_silo_erc4626_deposit() public {
        uint256 amount = 1000e6;
        usdc.mint(address(this), amount);
        usdc.approve(address(siloVault1), amount);

        uint256 shares = siloVault1.deposit(amount, address(this));

        assertEq(shares, amount);
        assertEq(siloVault1.totalAssets(), amount);
    }

    function test_silo_erc4626_withdraw() public {
        uint256 amount = 1000e6;
        usdc.mint(address(this), amount);
        usdc.approve(address(siloVault1), amount);
        siloVault1.deposit(amount, address(this));

        siloVault1.withdraw(500e6, address(this), address(this));

        assertEq(usdc.balanceOf(address(this)), 500e6);
        assertEq(siloVault1.totalAssets(), 500e6);
    }

    function test_silo_core_supply() public {
        uint256 amount = 1000e6;
        usdc.mint(address(this), amount);
        usdc.approve(address(siloCore), amount);

        siloCore.supply(amount);

        assertEq(siloCore.balanceOf(address(this)), amount);
    }

    function test_silo_core_withdraw() public {
        uint256 amount = 1000e6;
        usdc.mint(address(this), amount);
        usdc.approve(address(siloCore), amount);
        siloCore.supply(amount);

        siloCore.withdraw(500e6, address(this));

        assertEq(usdc.balanceOf(address(this)), 500e6);
    }

    function test_silo_multi_market_allocation() public {
        uint256 total = 10000e6;
        usdc.mint(address(this), total);

        usdc.approve(address(siloVault1), 6000e6);
        siloVault1.deposit(6000e6, address(this));

        usdc.approve(address(siloVault2), 4000e6);
        siloVault2.deposit(4000e6, address(this));

        assertEq(siloVault1.totalAssets(), 6000e6);
        assertEq(siloVault2.totalAssets(), 4000e6);
    }

    function testFuzz_silo_roundTrip(uint256 amount) public {
        amount = bound(amount, 1e6, 100_000_000e6);

        usdc.mint(address(this), amount);
        usdc.approve(address(siloVault1), amount);
        siloVault1.deposit(amount, address(this));

        siloVault1.withdraw(amount, address(this), address(this));

        assertEq(usdc.balanceOf(address(this)), amount);
    }
}

// ============================================================================
// COMET ADAPTER TESTS
// ============================================================================

contract CometAdapter_Test is Test {
    MockUSDCMulti public usdc;
    MockPoolLike public comet;

    function setUp() public {
        usdc = new MockUSDCMulti();
        comet = new MockPoolLike(address(usdc));
    }

    function test_comet_supply() public {
        uint256 amount = 1000e6;
        usdc.mint(address(this), amount);
        usdc.approve(address(comet), amount);

        comet.supply(amount);

        assertEq(comet.balanceOf(address(this)), amount);
    }

    function test_comet_withdraw() public {
        uint256 amount = 1000e6;
        usdc.mint(address(this), amount);
        usdc.approve(address(comet), amount);
        comet.supply(amount);

        uint256 withdrawn = comet.withdraw(500e6, address(this));

        assertEq(withdrawn, 500e6);
        assertEq(usdc.balanceOf(address(this)), 500e6);
    }

    function test_comet_yield_accrual() public {
        uint256 amount = 1000e6;
        usdc.mint(address(this), amount);
        usdc.approve(address(comet), amount);
        comet.supply(amount);

        // Balance doesn't change with yield in this mock
        // Real Comet would increase balance
        comet.simulateYield(100e6);

        assertGe(comet._totalAssets(), amount);
    }

    function testFuzz_comet_supplyWithdraw(uint256 supplyAmount, uint256 withdrawAmount) public {
        supplyAmount = bound(supplyAmount, 1e6, 100_000_000e6);
        withdrawAmount = bound(withdrawAmount, 1, supplyAmount);

        usdc.mint(address(this), supplyAmount);
        usdc.approve(address(comet), supplyAmount);
        comet.supply(supplyAmount);

        uint256 withdrawn = comet.withdraw(withdrawAmount, address(this));

        assertEq(withdrawn, withdrawAmount);
    }
}

// ============================================================================
// DOLOMITE ADAPTER TESTS
// ============================================================================

contract DolomiteAdapter_Test is Test {
    MockUSDCMulti public usdc;
    MockPoolLike public dolomite;
    MockERC4626Vault public dolomiteVault;

    function setUp() public {
        usdc = new MockUSDCMulti();
        dolomite = new MockPoolLike(address(usdc));
        dolomiteVault = new MockERC4626Vault(address(usdc), "Dolomite USDC Vault", 450);
    }

    function test_dolomite_pool_supply() public {
        uint256 amount = 1000e6;
        usdc.mint(address(this), amount);
        usdc.approve(address(dolomite), amount);

        dolomite.supply(amount);

        assertEq(dolomite.balanceOf(address(this)), amount);
    }

    function test_dolomite_erc4626_deposit() public {
        uint256 amount = 1000e6;
        usdc.mint(address(this), amount);
        usdc.approve(address(dolomiteVault), amount);

        uint256 shares = dolomiteVault.deposit(amount, address(this));

        assertEq(shares, amount);
    }

    function test_dolomite_multi_type_markets() public {
        uint256 total = 10000e6;
        usdc.mint(address(this), total);

        // Pool-like market
        usdc.approve(address(dolomite), 5000e6);
        dolomite.supply(5000e6);

        // ERC4626 market
        usdc.approve(address(dolomiteVault), 5000e6);
        dolomiteVault.deposit(5000e6, address(this));

        assertEq(dolomite.balanceOf(address(this)), 5000e6);
        assertEq(dolomiteVault.totalAssets(), 5000e6);
    }

    function testFuzz_dolomite_roundTrip(uint256 amount) public {
        amount = bound(amount, 1e6, 100_000_000e6);

        usdc.mint(address(this), amount);
        usdc.approve(address(dolomite), amount);
        dolomite.supply(amount);

        dolomite.withdraw(amount, address(this));

        assertEq(usdc.balanceOf(address(this)), amount);
    }
}

// ============================================================================
// GAINS ADAPTER TESTS
// ============================================================================

contract GainsAdapter_Test is Test {
    MockUSDCMulti public usdc;
    MockGainsVault public gains;

    function setUp() public {
        usdc = new MockUSDCMulti();
        gains = new MockGainsVault(address(usdc));
    }

    function test_gains_deposit() public {
        uint256 amount = 1000e6;
        usdc.mint(address(this), amount);
        usdc.approve(address(gains), amount);

        uint256 shares = gains.deposit(amount, address(this));

        assertEq(shares, amount);
        assertEq(gains.totalAssets(), amount);
    }

    function test_gains_instant_withdraw() public {
        uint256 amount = 1000e6;
        usdc.mint(address(this), amount);
        usdc.approve(address(gains), amount);
        gains.deposit(amount, address(this));

        gains.instantWithdraw(500e6, address(this));

        assertEq(usdc.balanceOf(address(this)), 500e6);
    }

    function test_gains_epoch_withdrawal_request() public {
        uint256 amount = 1000e6;
        usdc.mint(address(this), amount);
        usdc.approve(address(gains), amount);
        gains.deposit(amount, address(this));

        uint256 sharesToWithdraw = 500e6;
        gains.requestWithdraw(sharesToWithdraw);

        // Shares are locked
        assertEq(gains.balanceOf(address(this)), amount - sharesToWithdraw);
    }

    function test_gains_epoch_withdrawal_claim() public {
        uint256 amount = 1000e6;
        usdc.mint(address(this), amount);
        usdc.approve(address(gains), amount);
        gains.deposit(amount, address(this));

        gains.requestWithdraw(500e6);

        // Advance epoch
        gains.advanceEpoch();

        // Claim
        uint256 assets = gains.claimWithdraw(1);

        assertEq(assets, 500e6);
        assertEq(usdc.balanceOf(address(this)), 500e6);
    }

    function test_gains_claim_before_epoch_reverts() public {
        uint256 amount = 1000e6;
        usdc.mint(address(this), amount);
        usdc.approve(address(gains), amount);
        gains.deposit(amount, address(this));

        gains.requestWithdraw(500e6);

        // Try to claim before epoch advances
        vm.expectRevert(bytes("epoch not ended"));
        gains.claimWithdraw(1);
    }

    function test_gains_yield_accrual() public {
        uint256 amount = 1000e6;
        usdc.mint(address(this), amount);
        usdc.approve(address(gains), amount);
        gains.deposit(amount, address(this));

        gains.simulateYield(100e6);

        uint256 assets = gains.convertToAssets(gains.balanceOf(address(this)));
        assertGt(assets, amount);
    }

    function testFuzz_gains_depositInstantWithdraw(uint256 depositAmount, uint256 withdrawAmount)
        public
    {
        depositAmount = bound(depositAmount, 1e6, 100_000_000e6);
        withdrawAmount = bound(withdrawAmount, 1, depositAmount);

        usdc.mint(address(this), depositAmount);
        usdc.approve(address(gains), depositAmount);
        gains.deposit(depositAmount, address(this));

        gains.instantWithdraw(withdrawAmount, address(this));

        assertEq(usdc.balanceOf(address(this)), withdrawAmount);
    }

    function testFuzz_gains_epochWithdrawal(uint256 amount) public {
        amount = bound(amount, 1e6, 100_000_000e6);

        usdc.mint(address(this), amount);
        usdc.approve(address(gains), amount);
        gains.deposit(amount, address(this));

        gains.requestWithdraw(amount);
        gains.advanceEpoch();
        uint256 assets = gains.claimWithdraw(1);

        assertEq(assets, amount);
        assertEq(usdc.balanceOf(address(this)), amount);
    }
}

// ============================================================================
// CROSS-ADAPTER COMPARISON TESTS
// ============================================================================

contract MultiAdapterComparison_Test is Test {
    MockUSDCMulti public usdc;
    MockERC4626Vault public siloVault;
    MockPoolLike public comet;
    MockPoolLike public dolomite;
    MockGainsVault public gains;

    function setUp() public {
        usdc = new MockUSDCMulti();
        siloVault = new MockERC4626Vault(address(usdc), "Silo", 600);
        comet = new MockPoolLike(address(usdc));
        dolomite = new MockPoolLike(address(usdc));
        gains = new MockGainsVault(address(usdc));

        siloVault.setAPY(600);
        comet.setAPY(500);
        dolomite.setAPY(450);
        gains.setAPY(550);
    }

    function test_all_adapters_deposit() public {
        uint256 amount = 1000e6;

        // Silo
        usdc.mint(address(this), amount);
        usdc.approve(address(siloVault), amount);
        siloVault.deposit(amount, address(this));
        assertEq(siloVault.totalAssets(), amount);

        // Comet
        usdc.mint(address(this), amount);
        usdc.approve(address(comet), amount);
        comet.supply(amount);
        assertEq(comet.balanceOf(address(this)), amount);

        // Dolomite
        usdc.mint(address(this), amount);
        usdc.approve(address(dolomite), amount);
        dolomite.supply(amount);
        assertEq(dolomite.balanceOf(address(this)), amount);

        // Gains
        usdc.mint(address(this), amount);
        usdc.approve(address(gains), amount);
        gains.deposit(amount, address(this));
        assertEq(gains.totalAssets(), amount);
    }

    function test_all_adapters_yield_accrual() public {
        uint256 amount = 1000e6;
        uint256 yield = 100e6;

        // Silo
        usdc.mint(address(this), amount);
        usdc.approve(address(siloVault), amount);
        siloVault.deposit(amount, address(this));
        siloVault.simulateYield(yield);
        assertEq(siloVault.totalAssets(), amount + yield);

        // Comet
        usdc.mint(address(this), amount);
        usdc.approve(address(comet), amount);
        comet.supply(amount);
        comet.simulateYield(yield);
        assertEq(comet._totalAssets(), amount + yield);

        // Dolomite
        usdc.mint(address(this), amount);
        usdc.approve(address(dolomite), amount);
    }
}
