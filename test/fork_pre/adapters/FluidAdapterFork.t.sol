// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ═══════════════════════════════════════════════════════════════════════════
// FluidAdapterFork.t.sol — Phase F1: Fluid adapter deposit + withdraw
// ───────────────────────────────────────────────────────────────────────────
// Fork: Arbitrum mainnet, block 472761449
// Run: ARBITRUM_RPC_URL=<rpc> FLUID_FUSDC=<addr> \
//        forge test --match-contract FluidAdapterFork -vvv
//
// ADDRESS REQUIRED: FLUID_FUSDC env var must be set.
// This is the Fluid fUSDC ERC-4626 vault on Arbitrum.
// DefiLlama: fluid-lending USDC on Arbitrum, ~27M TVL (largest Fluid pool).
// Enabled in backtest from 2024-10-15 — exists at block 472761449.
//
// F1-Fluid-1 — deposit 100K USDC into real Fluid fUSDC vault
// F1-Fluid-2 — withdraw 50K USDC after deposit + 1-day warp
// ═══════════════════════════════════════════════════════════════════════════

import {ForkTestBase} from "../helpers/ForkTestBase.sol";
import {FluidUsdcMultiMarketAdapter}
    from "../../../../src/strategies/usdc-lending/adapters/lending/FluidUsdcMultiMarket.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFluidVault {
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function asset() external view returns (address);
}

contract FluidAdapterFork is ForkTestBase {

    FluidUsdcMultiMarketAdapter internal adapter;

    address internal admin      = address(0xAD);
    address internal vault      = address(this);
    address internal fluidFusdc;

    function setUp() public {
        (, fluidFusdc) = _setupForkWithAddr("FLUID_FUSDC");
        if (fluidFusdc == address(0)) return; // skipped by _setupForkWithAddr

        // Verify fToken asset is USDC before initializing
        require(IFluidVault(fluidFusdc).asset() == USDC, "fToken.asset != USDC");

        // V10 deploy+init pattern: empty constructor + initialize
        // Fluid initialize: (usdc_, admin_, vault_, capacity_, fToken_)
        adapter = new FluidUsdcMultiMarketAdapter();
        adapter.initialize(USDC, admin, vault, MAX_CAP, fluidFusdc);

        _dealUsdc(vault, SEED_USDC);
    }

    // ── F1-Fluid-1: deposit 100K USDC ───────────────────────────────────────

    function test_F1_Fluid_deposit_realChainState() public {
        uint256 depositAmt = 100_000e6;

        uint256 vaultUsdcBefore = IERC20(USDC).balanceOf(vault);
        uint256 sharesBefore    = IFluidVault(fluidFusdc).balanceOf(address(adapter));

        IERC20(USDC).approve(address(adapter), depositAmt);
        adapter.deposit(depositAmt);

        uint256 vaultUsdcAfter = IERC20(USDC).balanceOf(vault);
        uint256 sharesAfter    = IFluidVault(fluidFusdc).balanceOf(address(adapter));

        assertEq(vaultUsdcBefore - vaultUsdcAfter, depositAmt, "vault USDC decrease mismatch");
        assertGt(sharesAfter, sharesBefore, "fUSDC shares should increase after deposit");
        assertApproxEqAbs(adapter.totalAssets(), depositAmt, 1e4, "totalAssets mismatch");
    }

    // ── F1-Fluid-2: withdraw 50K USDC after deposit ─────────────────────────

    function test_F1_Fluid_withdraw_realChainState() public {
        uint256 depositAmt  = 100_000e6;
        uint256 withdrawAmt = 50_000e6;

        IERC20(USDC).approve(address(adapter), depositAmt);
        adapter.deposit(depositAmt);

        vm.warp(block.timestamp + 1 days);

        uint256 vaultUsdcBefore = IERC20(USDC).balanceOf(vault);
        adapter.withdraw(withdrawAmt, vault);
        uint256 vaultUsdcAfter = IERC20(USDC).balanceOf(vault);

        assertApproxEqAbs(
            vaultUsdcAfter - vaultUsdcBefore,
            withdrawAmt,
            1e4,
            "vault USDC increase mismatch"
        );
        assertGe(adapter.totalAssets(), depositAmt - withdrawAmt, "remaining position underflow");
    }
}
