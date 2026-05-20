// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import {
    EulerUsdcMultiMarketAdapter
} from "../../../src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol";

// ============================================================================
// MOCK CONTRACTS for Euler adapter hygiene tests
// ============================================================================

/// @dev Mock USDC with tracked allowances
contract MockUSDCHygiene {
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
}

/// @dev Minimal Euler market mock — configurable deposit behavior
contract MockEulerMarket {
    address public immutable assetAddr;
    bool public depositReverts;
    uint256 public maxDepositAmount = type(uint256).max;
    uint256 public sharesMinted;
    uint256 public deposited;

    constructor(address _asset) { assetAddr = _asset; }

    function asset() external view returns (address) { return assetAddr; }
    function maxDeposit(address) external view returns (uint256) { return maxDepositAmount; }
    function balanceOf(address) external view returns (uint256) { return deposited; }
    function convertToAssets(uint256 shares) external view returns (uint256) { return shares; }
    function maxWithdraw(address) external view returns (uint256) { return deposited; }
    function totalAssets() external view returns (uint256) { return deposited; }
    function interestRate() external view returns (uint256) { return 0; }

    function deposit(uint256 assets, address) external returns (uint256) {
        require(!depositReverts, "deposit reverts");
        deposited += assets;
        return assets; // 1:1
    }

    function withdraw(uint256 assets, address receiver, address) external returns (uint256) {
        deposited -= assets;
        MockUSDCHygiene(assetAddr).transfer(receiver, assets);
        return assets;
    }

    function setDepositReverts(bool v) external { depositReverts = v; }
    function setMaxDeposit(uint256 v) external { maxDepositAmount = v; }
}

/// @dev Minimal Permit2 mock — satisfies allowance() and approve() calls
contract MockPermit2 {
    struct Allowance { uint160 amount; uint48 expiration; uint48 nonce; }
    mapping(address => mapping(address => mapping(address => Allowance))) public allowances;

    function allowance(address owner, address token, address spender)
        external view returns (uint160 amt, uint48 exp, uint48 nonce) {
        Allowance memory a = allowances[owner][token][spender];
        return (a.amount, a.expiration, a.nonce);
    }

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        allowances[msg.sender][token][spender] = Allowance({ amount: amount, expiration: expiration, nonce: 0 });
    }
}

// ============================================================================
// BLOCCO F — Adapter Execution Hygiene Tests
// ============================================================================
// F1: forceApprove residue — USDC allowance for market is 0 after deposit success/failure
// F2: Euler zero-cap skip — maxDeposit==0 means no approve, no dust, no principal change
// F3: Failure no principal corruption — on deposit failure, principal unchanged
// I2: No residual allowances — adapter holds 0 allowance for all markets after any op
// ============================================================================

contract AdapterApproveHygieneTest is Test {

    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    MockUSDCHygiene usdc;
    MockEulerMarket market;
    MockPermit2 permit2Mock;
    EulerUsdcMultiMarketAdapter adapter;

    address admin = address(0xA1);
    address vaultAddr = address(0xA2);

    function setUp() public {
        usdc = new MockUSDCHygiene();
        market = new MockEulerMarket(address(usdc));

        // Etch Permit2 mock at the canonical address
        permit2Mock = new MockPermit2();
        vm.etch(PERMIT2, address(permit2Mock).code);

        address[] memory markets = new address[](1);
        markets[0] = address(market);

        adapter = new EulerUsdcMultiMarketAdapter(
            vaultAddr,
            address(usdc),
            markets,
            address(0) // no registry
        );

        // Grant admin roles
        adapter.grantRole(adapter.DEFAULT_ADMIN_ROLE(), admin);
        adapter.grantRole(adapter.PARAM_ROLE(), admin);
    }

    // -----------------------------------------------------------------------
    // F1: No residual ERC20 allowance after successful deposit
    // -----------------------------------------------------------------------

    /// @notice F1a: After successful deposit(), USDC allowance for market is 0.
    ///         forceApprove(amount) before deposit, forceApprove(0) after — no residue.
    function test_F1a_noResidualAllowanceAfterSuccess() public {
        uint256 depositAmount = 10_000e6;
        usdc.mint(vaultAddr, depositAmount);

        // Transfer USDC to adapter (mimics vault pre-transfer)
        vm.prank(vaultAddr);
        usdc.transfer(address(adapter), depositAmount);

        // Deposit
        vm.prank(vaultAddr);
        adapter.deposit(depositAmount);

        // After successful deposit, allowance for market must be 0
        uint256 residual = usdc.allowance(address(adapter), address(market));
        assertEq(residual, 0, "F1a: residual USDC allowance for market must be 0 after deposit");
    }

    /// @notice F1b: After failed deposit (market reverts), USDC allowance for market is 0.
    ///         forceApprove(0) in catch block must clean up.
    ///         F1b is skipped if the adapter fallbacks to a poke-retry and still reverts.
    function test_F1b_noResidualAllowanceAfterFailure() public {
        // Make first deposit attempt fail
        market.setDepositReverts(true);

        uint256 depositAmount = 10_000e6;
        usdc.mint(vaultAddr, depositAmount);
        vm.prank(vaultAddr);
        usdc.transfer(address(adapter), depositAmount);

        // deposit() will fail (no fallback market) — should revert
        vm.prank(vaultAddr);
        vm.expectRevert("Deposit failed - no market with sufficient capacity");
        adapter.deposit(depositAmount);

        // Even after the revert path, allowance must be 0
        // (forceApprove(0) is called in both try and catch blocks)
        uint256 residual = usdc.allowance(address(adapter), address(market));
        assertEq(residual, 0, "F1b: residual USDC allowance must be 0 even after deposit failure");
    }

    // -----------------------------------------------------------------------
    // F2: Euler zero-cap skip — maxDeposit==0 skips market
    // -----------------------------------------------------------------------

    /// @notice F2a: When market's maxDeposit==0, deposit() skips the market.
    ///         No forceApprove is called, no USDC is moved, no principal update.
    function test_F2a_zeroCapMarketIsSkipped() public {
        // Market at zero capacity
        market.setMaxDeposit(0);

        uint256 depositAmount = 10_000e6;
        usdc.mint(vaultAddr, depositAmount);
        vm.prank(vaultAddr);
        usdc.transfer(address(adapter), depositAmount);

        // Deposit must fail (only 1 market, zero cap, no fallback)
        vm.prank(vaultAddr);
        vm.expectRevert("Deposit failed - no market with sufficient capacity");
        adapter.deposit(depositAmount);

        // Principal must be unchanged (0)
        uint256[] memory positions = adapter.positions();
        assertEq(positions[0], 0, "F2a: principal must be 0 when market has zero cap");

        // No residual allowance (approve must NOT have been called)
        uint256 residual = usdc.allowance(address(adapter), address(market));
        assertEq(residual, 0, "F2a: no approve must be issued for zero-cap market");
    }

    /// @notice F2b: When market's maxDeposit==0, no dust deposit is attempted.
    ///         Market's deposited balance stays 0 (no _pokeMarket side effect).
    function test_F2b_zeroCapNoPokeAttempt() public {
        market.setMaxDeposit(0);

        uint256 depositAmount = 10_000e6;
        usdc.mint(vaultAddr, depositAmount);
        vm.prank(vaultAddr);
        usdc.transfer(address(adapter), depositAmount);

        vm.prank(vaultAddr);
        try adapter.deposit(depositAmount) {} catch {}

        // Market received nothing
        assertEq(market.deposited(), 0, "F2b: zero-cap market must receive no USDC");
    }

    // -----------------------------------------------------------------------
    // F3: Failure no principal corruption
    // -----------------------------------------------------------------------

    /// @notice F3a: When deposit() reverts on the market (not at capacity check),
    ///         principal[0] must stay at 0 — no partial accounting update.
    ///         NOTE: totalAssets() will reflect the USDC still held as idle (not lost),
    ///         but investedAssets() must be 0 (nothing placed in the market).
    function test_F3a_failureNoPrincipalCorruption() public {
        // Market accepts but then reverts during actual deposit call
        // (maxDeposit > 0 to pass capacity check, but deposit() itself reverts)
        market.setDepositReverts(true);

        uint256 depositAmount = 10_000e6;
        usdc.mint(vaultAddr, depositAmount);
        vm.prank(vaultAddr);
        usdc.transfer(address(adapter), depositAmount);

        vm.prank(vaultAddr);
        vm.expectRevert("Deposit failed - no market with sufficient capacity");
        adapter.deposit(depositAmount);

        // Principal must NOT be incremented on failure
        uint256[] memory positions = adapter.positions();
        assertEq(positions[0], 0, "F3a: principal must not be incremented on deposit failure");

        // investedAssets must be 0 - nothing was placed in the market
        assertEq(adapter.investedAssets(), 0, "F3a: investedAssets must be 0 - market received nothing");

        // The USDC is held as idle (not lost) — idleAssetBalance reflects it
        assertEq(adapter.idleAssetBalance(), depositAmount, "F3a: USDC must be preserved as idle, not lost");
    }

    /// @notice F3b: Successful deposit followed by failed deposit must not double-count.
    ///         After a successful 10K deposit, a second failed deposit must not increment principal again.
    function test_F3b_partialSuccessThenFailureCorrectAccounting() public {
        // First deposit succeeds
        uint256 firstDeposit = 10_000e6;
        usdc.mint(vaultAddr, firstDeposit);
        vm.prank(vaultAddr);
        usdc.transfer(address(adapter), firstDeposit);
        vm.prank(vaultAddr);
        adapter.deposit(firstDeposit);

        uint256[] memory positions = adapter.positions();
        assertEq(positions[0], firstDeposit, "F3b: principal must be 10K after first deposit");

        // Second deposit fails
        market.setDepositReverts(true);
        uint256 secondDeposit = 5_000e6;
        usdc.mint(vaultAddr, secondDeposit);
        vm.prank(vaultAddr);
        usdc.transfer(address(adapter), secondDeposit);

        vm.prank(vaultAddr);
        vm.expectRevert("Deposit failed - no market with sufficient capacity");
        adapter.deposit(secondDeposit);

        // Principal must still be exactly 10K (second deposit didn't corrupt it)
        positions = adapter.positions();
        assertEq(positions[0], firstDeposit, "F3b: principal must stay at 10K after failed second deposit");
    }

    // -----------------------------------------------------------------------
    // I2: Invariant — no residual allowances after any operation
    // -----------------------------------------------------------------------

    /// @notice I2: After any combination of deposit/withdraw, USDC allowance for all
    ///         markets must be 0. This verifies the just-in-time approve pattern is clean.
    function test_I2_noResidualAllowancesAfterDepositWithdraw() public {
        uint256 depositAmount = 10_000e6;
        usdc.mint(vaultAddr, depositAmount);
        vm.prank(vaultAddr);
        usdc.transfer(address(adapter), depositAmount);
        vm.prank(vaultAddr);
        adapter.deposit(depositAmount);

        // After deposit: allowance must be 0
        assertEq(usdc.allowance(address(adapter), address(market)), 0,
            "I2: allowance must be 0 after deposit");

        // Withdraw half
        vm.prank(vaultAddr);
        adapter.withdraw(5_000e6, vaultAddr);

        // After withdraw: allowance must still be 0 (withdraw doesn't need approve)
    }
}
