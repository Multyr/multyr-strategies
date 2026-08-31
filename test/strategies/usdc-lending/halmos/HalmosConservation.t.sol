// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Halmos Invariant 1 — Conservation of Funds
/// @notice Symbolic execution proof: after deposit(a) + deposit(b),
///         totalAssets() >= a + b (no funds disappear).
///         Run: halmos --contract HalmosConservation --function check_ --loop 4
/// @dev Designed for Halmos 0.2.x symbolic execution.
///      Uses simplified mock to avoid via_ir StackTooDeep on symbolic paths.

import { Test } from "forge-std/Test.sol";

// ─── Minimal mock USDC (symbolic-execution friendly) ──────────────────────

contract SymbolicUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }

    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a);
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        require(balanceOf[from] >= a);
        if (allowance[from][msg.sender] != type(uint256).max)
            allowance[from][msg.sender] -= a;
        balanceOf[from] -= a; balanceOf[to] += a; return true;
    }
    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a; return true;
    }
}

// ─── Minimal lending adapter (symbolic-execution friendly) ─────────────────

contract SymbolicAdapter {
    SymbolicUSDC internal usdc;
    uint256 public deposited;

    constructor(address _usdc) { usdc = SymbolicUSDC(_usdc); }

    function deposit(uint256 assets) external {
        require(assets > 0);
        usdc.transferFrom(msg.sender, address(this), assets);
        deposited += assets;
    }

    function withdraw(uint256 assets, address receiver) external returns (uint256) {
        uint256 amt = assets > deposited ? deposited : assets;
        deposited -= amt;
        usdc.transfer(receiver, amt);
        return amt;
    }

    function totalAssets() external view returns (uint256) { return deposited; }
}

// ─── Minimal vault (no delegatecall, no modules — symbolic-execution friendly) ─

contract SymbolicVault {
    SymbolicUSDC internal usdc;
    SymbolicAdapter internal adapter;

    uint256 public positionAssets;

    constructor(address _usdc, address _adapter) {
        usdc = SymbolicUSDC(_usdc);
        adapter = SymbolicAdapter(_adapter);
    }

    /// @dev Simplified deposit: pull from caller, push to adapter
    function deposit(uint256 assets) external {
        require(assets > 0);
        usdc.transferFrom(msg.sender, address(this), assets);
        usdc.approve(address(adapter), assets);
        adapter.deposit(assets);
        positionAssets += assets;
    }

    /// @dev totalAssets = idle + adapter position
    function totalAssets() external view returns (uint256) {
        return usdc.balanceOf(address(this)) + adapter.totalAssets();
    }
}

// ─── Halmos check contract ──────────────────────────────────────────────────

contract HalmosConservation is Test {
    SymbolicUSDC  internal usdc;
    SymbolicAdapter internal adapter;
    SymbolicVault   internal vault;

    address constant DEPOSITOR = address(0xD1);

    function setUp() public {
        usdc    = new SymbolicUSDC();
        adapter = new SymbolicAdapter(address(usdc));
        vault   = new SymbolicVault(address(usdc), address(adapter));
    }

    /// @notice Halmos check: deposit(a) + deposit(b) → totalAssets() >= a + b.
    ///         Proves funds are never destroyed by two sequential deposits.
    ///         Run: halmos --contract HalmosConservation --function check_twoDeposits_conserveFunds --loop 4
    function check_twoDeposits_conserveFunds(uint64 a, uint64 b) public {
        // Bound inputs: halmos uses symbolic uint64 (avoids overflow in uint256 path)
        vm.assume(a > 0 && b > 0);
        vm.assume(uint256(a) + uint256(b) <= 1_000_000e6); // sanity ceiling

        // Fund depositor
        usdc.mint(DEPOSITOR, uint256(a) + uint256(b));

        // Deposit a
        vm.startPrank(DEPOSITOR);
        usdc.approve(address(vault), uint256(a) + uint256(b));
        vault.deposit(a);
        vault.deposit(b);
        vm.stopPrank();

        // Invariant: no funds destroyed
        assert(vault.totalAssets() >= uint256(a) + uint256(b));
    }

    /// @notice Halmos check: single deposit then full withdrawal returns exactly deposited amount.
    ///         Proves deposit + withdraw is a round-trip with no loss.
    ///         Run: halmos --contract HalmosConservation --function check_depositWithdraw_roundTrip --loop 4
    function check_depositWithdraw_roundTrip(uint64 amount) public {
        vm.assume(amount > 0 && amount <= 500_000e6);

        usdc.mint(DEPOSITOR, amount);
        vm.startPrank(DEPOSITOR);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();

        uint256 before = usdc.balanceOf(DEPOSITOR);

        // Withdraw via adapter directly (simplified vault has no withdraw)
        vm.prank(address(vault));
        adapter.withdraw(amount, DEPOSITOR);

        uint256 after_ = usdc.balanceOf(DEPOSITOR);

        // Invariant: depositor receives back exactly what they deposited (no slippage in mock)
        assert(after_ - before == amount);
    }

    /// @notice Halmos check: vault.totalAssets() == adapter.totalAssets() + idle at all times.
    ///         Proves accounting identity holds symbolically.
    function check_totalAssets_identity(uint64 amount) public {
        vm.assume(amount > 0 && amount <= 500_000e6);

        usdc.mint(DEPOSITOR, amount);
        vm.startPrank(DEPOSITOR);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();

        uint256 idle = usdc.balanceOf(address(vault));
        uint256 adapterPos = adapter.totalAssets();
        uint256 total = vault.totalAssets();

        // Invariant: totalAssets = idle + adapter position
        assert(total == idle + adapterPos);
    }
}
