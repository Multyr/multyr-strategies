// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ═══════════════════════════════════════════════════════════════════════════
// EulerAdapterFork.t.sol — Phase F1: Euler V2 adapter deposit + withdraw
// ───────────────────────────────────────────────────────────────────────────
// Fork: Arbitrum mainnet, block 472761449
// Run: ARBITRUM_RPC_URL=<rpc> forge test --match-contract EulerAdapterFork -vvv
//
// Uses 4 production Euler USDC EVaults (from DeployUsdcLendingStrategy.s.sol).
// Euler V2 deployed 2024-09-04 — all 4 vaults confirmed present at target block.
//
// IMPORTANT — Euler uses push semantics:
//   The vault TRANSFERS USDC to the adapter before calling adapter.deposit().
//   Do NOT use the approve+deposit pattern — the adapter does not pull funds.
//   withdraw() returns USDC directly to vault (safeTransfer in adapter code).
//
// F1-Euler-1 — deposit 100K USDC into real Euler EVault cluster
// F1-Euler-2 — withdraw 50K USDC after deposit + 1-day warp
// ═══════════════════════════════════════════════════════════════════════════

import {ForkTestBase} from "../helpers/ForkTestBase.sol";
import {EulerUsdcMultiMarketAdapter}
    from "@multyr-strategies/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract EulerAdapterFork is ForkTestBase {

    EulerUsdcMultiMarketAdapter internal adapter;

    address internal admin = address(0xAD);
    address internal vault = address(this);

    function setUp() public {
        _setupFork();

        // Build 4-vault markets array (matches production deployment)
        address[] memory markets = new address[](4);
        markets[0] = EULER_VAULT_1;
        markets[1] = EULER_VAULT_2;
        markets[2] = EULER_VAULT_3;
        markets[3] = EULER_VAULT_4;

        // V10 deploy+init: markets array passed directly (registry=address(0))
        adapter = new EulerUsdcMultiMarketAdapter();
        adapter.initialize(vault, USDC, markets, address(0), admin);

        // Set Permit2 per-vault allowances (required before first deposit)
        vm.prank(admin);
        adapter.initializeMarkets();

        // Seed vault (this contract) with USDC
        _dealUsdc(vault, SEED_USDC);
    }

    // ── F1-Euler-1: deposit 100K USDC ───────────────────────────────────────

    function test_F1_Euler_deposit_realChainState() public {
        uint256 depositAmt = 100_000e6;

        uint256 vaultUsdcBefore = IERC20(USDC).balanceOf(vault);

        // Euler push semantics: vault transfers USDC to adapter, then calls deposit().
        IERC20(USDC).transfer(address(adapter), depositAmt);
        adapter.deposit(depositAmt);

        uint256 vaultUsdcAfter = IERC20(USDC).balanceOf(vault);

        // Vault USDC decreased by depositAmt (transferred to adapter → Euler vault)
        assertEq(vaultUsdcBefore - vaultUsdcAfter, depositAmt, "vault USDC decrease mismatch");
        assertApproxEqAbs(adapter.totalAssets(), depositAmt, 1e4, "totalAssets mismatch");
    }

    // ── F1-Euler-2: withdraw 50K USDC after deposit ─────────────────────────

    function test_F1_Euler_withdraw_realChainState() public {
        uint256 depositAmt  = 100_000e6;
        uint256 withdrawAmt = 50_000e6;

        // Push deposit
        IERC20(USDC).transfer(address(adapter), depositAmt);
        adapter.deposit(depositAmt);

        vm.warp(block.timestamp + 1 days);

        uint256 vaultUsdcBefore = IERC20(USDC).balanceOf(vault);
        adapter.withdraw(withdrawAmt, vault);
        uint256 vaultUsdcAfter = IERC20(USDC).balanceOf(vault);

        // Adapter sends USDC back to vault via safeTransfer in withdraw()
        assertApproxEqAbs(
            vaultUsdcAfter - vaultUsdcBefore,
            withdrawAmt,
            1e4,
            "vault USDC increase mismatch"
        );
        assertGe(adapter.totalAssets(), depositAmt - withdrawAmt, "remaining position underflow");
    }
}
