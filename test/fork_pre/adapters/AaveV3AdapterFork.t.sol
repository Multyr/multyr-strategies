// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ═══════════════════════════════════════════════════════════════════════════
// AaveV3AdapterFork.t.sol — Phase F1: Aave V3 adapter deposit + withdraw
// ───────────────────────────────────────────────────────────────────────────
// Fork: Arbitrum mainnet, block 472761449
// Run: ARBITRUM_RPC_URL=<rpc> forge test --match-contract AaveV3AdapterFork -vvv
//
// Verifies V10 deploy+init pattern against real Aave V3 Pool on Arbitrum:
//   F1-Aave-1 — deposit 100K USDC → aUSDC balance increases correctly
//   F1-Aave-2 — withdraw 50K USDC after deposit + 1-day warp → returns USDC
// ═══════════════════════════════════════════════════════════════════════════

import {ForkTestBase} from "../helpers/ForkTestBase.sol";
import {AaveV3USDCAdapter}
    from "../../../../src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AaveV3AdapterFork is ForkTestBase {

    AaveV3USDCAdapter internal adapter;

    address internal admin = address(0xAD);
    address internal vault = address(this);

    function setUp() public {
        _setupFork();

        // V10 deploy+init pattern: empty constructor + initialize
        adapter = new AaveV3USDCAdapter();
        adapter.initialize(USDC, AAVE_V3_POOL, AAVE_AUSDC, admin, vault, MAX_CAP);

        // Seed vault (this contract) with USDC
        _dealUsdc(vault, SEED_USDC);
    }

    // ── F1-Aave-1: deposit 100K USDC ────────────────────────────────────────

    function test_F1_Aave_deposit_realChainState() public {
        uint256 depositAmt = 100_000e6;

        uint256 vaultUsdcBefore  = IERC20(USDC).balanceOf(vault);
        uint256 adapterAusdcBefore = IERC20(AAVE_AUSDC).balanceOf(address(adapter));

        IERC20(USDC).approve(address(adapter), depositAmt);
        adapter.deposit(depositAmt);

        uint256 vaultUsdcAfter   = IERC20(USDC).balanceOf(vault);
        uint256 adapterAusdcAfter  = IERC20(AAVE_AUSDC).balanceOf(address(adapter));

        assertEq(vaultUsdcBefore - vaultUsdcAfter, depositAmt, "vault USDC decrease mismatch");
        assertApproxEqAbs(
            adapterAusdcAfter - adapterAusdcBefore,
            depositAmt,
            1e4, // 0.01 USDC tolerance for Aave index rounding
            "aUSDC increase mismatch"
        );
        // Adapter reports correct totalAssets
        assertApproxEqAbs(adapter.totalAssets(), depositAmt, 1e4, "totalAssets mismatch");
    }

    // ── F1-Aave-2: withdraw 50K USDC after deposit ──────────────────────────

    function test_F1_Aave_withdraw_realChainState() public {
        uint256 depositAmt  = 100_000e6;
        uint256 withdrawAmt = 50_000e6;

        IERC20(USDC).approve(address(adapter), depositAmt);
        adapter.deposit(depositAmt);

        // Advance time to accrue minimal interest
        vm.warp(block.timestamp + 1 days);

        uint256 vaultUsdcBefore   = IERC20(USDC).balanceOf(vault);
        uint256 adapterAusdcBefore = IERC20(AAVE_AUSDC).balanceOf(address(adapter));

        adapter.withdraw(withdrawAmt, vault);

        uint256 vaultUsdcAfter   = IERC20(USDC).balanceOf(vault);
        uint256 adapterAusdcAfter  = IERC20(AAVE_AUSDC).balanceOf(address(adapter));

        assertApproxEqAbs(
            vaultUsdcAfter - vaultUsdcBefore,
            withdrawAmt,
            1e4,
            "vault USDC increase mismatch"
        );
        assertLt(adapterAusdcAfter, adapterAusdcBefore, "aUSDC should decrease after withdraw");
        // Remaining position >= depositAmt - withdrawAmt (yield may add a few wei)
        assertGe(adapter.totalAssets(), depositAmt - withdrawAmt, "remaining position underflow");
    }
}
