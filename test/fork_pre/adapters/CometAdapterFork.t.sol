// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ═══════════════════════════════════════════════════════════════════════════
// CometAdapterFork.t.sol — Phase F1: Compound III (Comet) adapter deposit + withdraw
// ───────────────────────────────────────────────────────────────────────────
// Fork: Arbitrum mainnet, block 472761449
// Run: ARBITRUM_RPC_URL=<rpc> forge test --match-contract CometAdapterFork -vvv
//
// Verifies V10 deploy+init pattern against real Compound III USDC Comet:
//   F1-Comet-1 — deposit 100K USDC → Comet balance increases correctly
//   F1-Comet-2 — withdraw 50K USDC after deposit + 1-day warp → returns USDC
// ═══════════════════════════════════════════════════════════════════════════

import {ForkTestBase} from "../helpers/ForkTestBase.sol";
import {CometUsdcMultiMarketAdapter}
    from "../../../../src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IComet {
    function balanceOf(address account) external view returns (uint256);
}

contract CometAdapterFork is ForkTestBase {

    CometUsdcMultiMarketAdapter internal adapter;

    address internal admin = address(0xAD);
    address internal vault = address(this);

    function setUp() public {
        _setupFork();

        // V10 deploy+init pattern: empty constructor + initialize
        // registry = address(0): markets added manually via addMarket()
        adapter = new CometUsdcMultiMarketAdapter();
        adapter.initialize(USDC, admin, vault, MAX_CAP, address(0));

        // Add the real Compound III USDC Comet as active market
        vm.prank(admin);
        adapter.addMarket(COMET_USDC);

        // Seed vault (this contract) with USDC
        _dealUsdc(vault, SEED_USDC);
    }

    // ── F1-Comet-1: deposit 100K USDC ───────────────────────────────────────

    function test_F1_Comet_deposit_realChainState() public {
        uint256 depositAmt = 100_000e6;

        uint256 vaultUsdcBefore  = IERC20(USDC).balanceOf(vault);
        uint256 cometBalBefore   = IComet(COMET_USDC).balanceOf(address(adapter));

        IERC20(USDC).approve(address(adapter), depositAmt);
        adapter.deposit(depositAmt);

        uint256 vaultUsdcAfter  = IERC20(USDC).balanceOf(vault);
        uint256 cometBalAfter   = IComet(COMET_USDC).balanceOf(address(adapter));

        assertEq(vaultUsdcBefore - vaultUsdcAfter, depositAmt, "vault USDC decrease mismatch");
        assertApproxEqAbs(
            cometBalAfter - cometBalBefore,
            depositAmt,
            1e4,
            "Comet balance increase mismatch"
        );
        assertApproxEqAbs(adapter.totalAssets(), depositAmt, 1e4, "totalAssets mismatch");
    }

    // ── F1-Comet-2: withdraw 50K USDC after deposit ─────────────────────────

    function test_F1_Comet_withdraw_realChainState() public {
        uint256 depositAmt  = 100_000e6;
        uint256 withdrawAmt = 50_000e6;

        IERC20(USDC).approve(address(adapter), depositAmt);
        adapter.deposit(depositAmt);

        vm.warp(block.timestamp + 1 days);

        uint256 vaultUsdcBefore  = IERC20(USDC).balanceOf(vault);
        uint256 cometBalBefore   = IComet(COMET_USDC).balanceOf(address(adapter));

        adapter.withdraw(withdrawAmt, vault);

        uint256 vaultUsdcAfter  = IERC20(USDC).balanceOf(vault);
        uint256 cometBalAfter   = IComet(COMET_USDC).balanceOf(address(adapter));

        assertApproxEqAbs(
            vaultUsdcAfter - vaultUsdcBefore,
            withdrawAmt,
            1e4,
            "vault USDC increase mismatch"
        );
        assertLt(cometBalAfter, cometBalBefore, "Comet balance should decrease after withdraw");
        assertGe(adapter.totalAssets(), depositAmt - withdrawAmt, "remaining position underflow");
    }
}
