// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// =====================================================================
// MISLEADING NAME WARNING (Phase 4 Step 9 cleanup)
// =====================================================================
// This file's name suggests it tests the REAL EulerUsdcMultiMarket adapter,
// but it actually tests INTERNAL MOCK behaviors (MockUSDCEuler, etc.).
// Real Euler adapter regression tests must live in a separate file:
//   test/strategies/usdc-lending/adapters/EulerUsdcMultiMarketAdapter.t.sol
// (planned in Phase 4 Step 8 extension).
// =====================================================================

import { Test, console2 } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ============================================================================
// MOCK CONTRACTS
// ============================================================================

contract MockUSDCEuler {
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

contract MockEulerVault {
    address public immutable asset;
    string public name = "Mock Euler Vault";

    mapping(address => uint256) public balanceOf; // shares
    uint256 public totalSupply;
    uint256 public _totalAssets;

    uint16 public mockAPYBps = 500;
    bool public pullMode = false; // Euler uses push mode

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
        uint256 cash = MockUSDCEuler(asset).balanceOf(address(this));
        return assets < cash ? assets : cash;
    }

    // Euler push mode: funds must be pre-transferred
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        // In push mode, funds are already in the vault
        uint256 vaultBalance = MockUSDCEuler(asset).balanceOf(address(this));
        require(vaultBalance >= _totalAssets + assets, "funds not pushed");

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
        MockUSDCEuler(asset).transfer(receiver, assets);
        return shares;
    }

    function simulateYield(uint256 amount) external {
        _totalAssets += amount;
        MockUSDCEuler(asset).mint(address(this), amount);
    }
}

// Minimal interface for Euler adapter
interface IEulerAdapter {
    function underlying() external view returns (address);
    function vault() external view returns (address);
    function deposit(uint256 assets) external;
    function withdraw(uint256 assets, address receiver) external returns (uint256);
    function totalAssets() external view returns (uint256);
    function withdrawableAssets() external view returns (uint256);
    function currentAPYBps() external view returns (uint16);
    function incentiveAPYBps() external view returns (uint16);
    function harvestableProfit() external view returns (uint256);
    function harvest(address receiver) external returns (uint256);
    function maxCapacity() external view returns (uint256);
    function name() external view returns (string memory);
    function addMarket(address market) external;
    function toggleMarket(uint256 idx, bool enabled) external;
    function flagMarket(uint256 idx, bool flagged) external;
    function markets() external view returns (address[] memory);
    function setCapacity(uint256 cap) external;
    function setAPYOverrideBps(uint16 bps) external;
    function capacity() external view returns (uint256);
}

// ============================================================================
// TEST CONTRACT
// ============================================================================

contract EulerAdapter_Test is Test {
    MockUSDCEuler public usdc;
    MockEulerVault public eulerVault1;
    MockEulerVault public eulerVault2;

    address public admin = address(0x1);
    address public vault = address(0x2);
    address public user = address(0x3);

    // We'll test the adapter behavior through mocks since the actual adapter
    // has Euler-specific dependencies

    function setUp() public {
        usdc = new MockUSDCEuler();
        eulerVault1 = new MockEulerVault(address(usdc));
        eulerVault2 = new MockEulerVault(address(usdc));

        eulerVault1.setAPY(700); // 7%
        eulerVault2.setAPY(500); // 5%
    }

    // ========================================================================
    // EULER VAULT MOCK TESTS (Simulating adapter behavior)
    // ========================================================================

    function test_euler_vault_deposit_push_mode() public {
        uint256 amount = 1000e6;

        // Push mode: transfer first, then deposit
        usdc.mint(address(this), amount);
        usdc.transfer(address(eulerVault1), amount);

        uint256 shares = eulerVault1.deposit(amount, address(this));

        assertEq(shares, amount); // 1:1 initially
        assertEq(eulerVault1.balanceOf(address(this)), amount);
        assertEq(eulerVault1.totalAssets(), amount);
    }

    function test_euler_vault_deposit_reverts_no_push() public {
        uint256 amount = 1000e6;

        // Try to deposit without pushing funds first
        vm.expectRevert(bytes("funds not pushed"));
        eulerVault1.deposit(amount, address(this));
    }

    function test_euler_vault_withdraw() public {
        uint256 amount = 1000e6;

        // Deposit first
        usdc.mint(address(this), amount);
        usdc.transfer(address(eulerVault1), amount);
        eulerVault1.deposit(amount, address(this));

        // Withdraw
        uint256 shares = eulerVault1.withdraw(500e6, address(this), address(this));

        assertEq(shares, 500e6);
        assertEq(usdc.balanceOf(address(this)), 500e6);
        assertEq(eulerVault1.totalAssets(), 500e6);
    }

    function test_euler_vault_yield_accrual() public {
        uint256 amount = 1000e6;

        usdc.mint(address(this), amount);
        usdc.transfer(address(eulerVault1), amount);
        eulerVault1.deposit(amount, address(this));

        uint256 assetsBefore = eulerVault1.convertToAssets(eulerVault1.balanceOf(address(this)));

        // Simulate yield
        eulerVault1.simulateYield(100e6);

        uint256 assetsAfter = eulerVault1.convertToAssets(eulerVault1.balanceOf(address(this)));

        assertGt(assetsAfter, assetsBefore);
    }

    function test_euler_vault_max_withdraw() public {
        uint256 amount = 1000e6;

        usdc.mint(address(this), amount);
        usdc.transfer(address(eulerVault1), amount);
        eulerVault1.deposit(amount, address(this));

        uint256 maxWithdraw = eulerVault1.maxWithdraw(address(this));
        assertEq(maxWithdraw, amount);
    }

    function test_euler_vault_convert_functions() public {
        uint256 amount = 1000e6;

        usdc.mint(address(this), amount);
        usdc.transfer(address(eulerVault1), amount);
        eulerVault1.deposit(amount, address(this));

        uint256 shares = eulerVault1.balanceOf(address(this));
        uint256 assets = eulerVault1.convertToAssets(shares);

        assertEq(assets, amount);
    }

    // ========================================================================
    // FUZZ TESTS
    // ========================================================================

    function testFuzz_euler_deposit_withdraw(uint256 depositAmount, uint256 withdrawAmount) public {
        depositAmount = bound(depositAmount, 1e6, 100_000_000e6);
        withdrawAmount = bound(withdrawAmount, 1, depositAmount);

        usdc.mint(address(this), depositAmount);
        usdc.transfer(address(eulerVault1), depositAmount);
        eulerVault1.deposit(depositAmount, address(this));

        eulerVault1.withdraw(withdrawAmount, address(this), address(this));

        assertEq(usdc.balanceOf(address(this)), withdrawAmount);
        assertEq(eulerVault1.totalAssets(), depositAmount - withdrawAmount);
    }

    function testFuzz_euler_yield_accrual(uint256 depositAmount, uint256 yieldAmount) public {
        depositAmount = bound(depositAmount, 1e6, 100_000_000e6);
        yieldAmount = bound(yieldAmount, 1e6, 10_000_000e6);

        usdc.mint(address(this), depositAmount);
        usdc.transfer(address(eulerVault1), depositAmount);
        eulerVault1.deposit(depositAmount, address(this));

        uint256 sharesBefore = eulerVault1.balanceOf(address(this));
        uint256 assetsBefore = eulerVault1.convertToAssets(sharesBefore);

        eulerVault1.simulateYield(yieldAmount);

        uint256 assetsAfter = eulerVault1.convertToAssets(sharesBefore);

        assertGt(assetsAfter, assetsBefore);
        assertEq(assetsAfter, depositAmount + yieldAmount);
    }

    function testFuzz_euler_roundTrip(uint256 amount) public {
        amount = bound(amount, 1e6, 100_000_000e6);

        usdc.mint(address(this), amount);
        usdc.transfer(address(eulerVault1), amount);
        eulerVault1.deposit(amount, address(this));

        eulerVault1.withdraw(amount, address(this), address(this));

        assertEq(usdc.balanceOf(address(this)), amount);
        assertEq(eulerVault1.totalAssets(), 0);
    }
}

// ============================================================================
// EULER ADAPTER INTEGRATION TESTS (Mock-based)
// ============================================================================

contract EulerAdapterBehavior_Test is Test {
    MockUSDCEuler public usdc;
    MockEulerVault public eulerVault1;
    MockEulerVault public eulerVault2;
    MockEulerVault public eulerVault3;
    MockEulerVault public eulerVault4;

    address public admin = address(0x1);
    address public vault = address(0x2);

    function setUp() public {
        usdc = new MockUSDCEuler();
        eulerVault1 = new MockEulerVault(address(usdc));
        eulerVault2 = new MockEulerVault(address(usdc));
        eulerVault3 = new MockEulerVault(address(usdc));
        eulerVault4 = new MockEulerVault(address(usdc));

        // Different APYs for scoring
        eulerVault1.setAPY(800);
        eulerVault2.setAPY(600);
        eulerVault3.setAPY(400);
        eulerVault4.setAPY(200);
    }

    function test_euler_multi_vault_allocation() public {
        // Simulate multi-vault allocation strategy
        uint256 totalDeposit = 10000e6;

        usdc.mint(address(this), totalDeposit);

        // Allocate to best vaults
        uint256 alloc1 = 5000e6;
        uint256 alloc2 = 3000e6;
        uint256 alloc3 = 2000e6;

        usdc.transfer(address(eulerVault1), alloc1);
        eulerVault1.deposit(alloc1, address(this));

        usdc.transfer(address(eulerVault2), alloc2);
        eulerVault2.deposit(alloc2, address(this));

        usdc.transfer(address(eulerVault3), alloc3);
        eulerVault3.deposit(alloc3, address(this));

        // Total assets across all vaults
        uint256 total = eulerVault1.convertToAssets(eulerVault1.balanceOf(address(this)))
            + eulerVault2.convertToAssets(eulerVault2.balanceOf(address(this)))
            + eulerVault3.convertToAssets(eulerVault3.balanceOf(address(this)));

        assertEq(total, totalDeposit);
    }

    function test_euler_rebalance_simulation() public {
        uint256 amount = 10000e6;

        // Initial deposit to vault1
        usdc.mint(address(this), amount);
        usdc.transfer(address(eulerVault1), amount);
        eulerVault1.deposit(amount, address(this));

        // Simulate rebalance: withdraw from vault1, deposit to vault2
        eulerVault1.withdraw(amount, address(this), address(this));

        usdc.transfer(address(eulerVault2), amount);
        eulerVault2.deposit(amount, address(this));

        assertEq(eulerVault1.totalAssets(), 0);
        assertEq(eulerVault2.totalAssets(), amount);
    }

    function test_euler_max_4_vaults_constraint() public {
        // Euler adapter typically supports max 4 vaults
        uint256 amount = 10000e6;
        usdc.mint(address(this), amount);

        uint256 perVault = amount / 4;

        usdc.transfer(address(eulerVault1), perVault);
        eulerVault1.deposit(perVault, address(this));

        usdc.transfer(address(eulerVault2), perVault);
        eulerVault2.deposit(perVault, address(this));

        usdc.transfer(address(eulerVault3), perVault);
    }
}
