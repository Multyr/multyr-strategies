// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ═══════════════════════════════════════════════════════════════════════════
// EulerAdapterFork.t.sol — Phase F1: Euler V2 adapter deposit + withdraw
// ───────────────────────────────────────────────────────────────────────────
// Fork: Arbitrum mainnet, block 472761449
// Run: ARBITRUM_RPC_URL=<rpc> EULER_USDC_VAULT=<addr> \
//        forge test --match-contract EulerAdapterFork -vvv
//
// ADDRESS REQUIRED: EULER_USDC_VAULT env var must be set.
// This is the Euler V2 EVault (ERC-4626) for USDC on Arbitrum.
// From pool_mapping.json notes: "eUSDC-5 (0x05d28A86...)" is one candidate.
// Options (confirm via Euler Finance docs or chain):
//   - Euler Earn USDC (~799K TVL)     [largest by TVL]
//   - eUSDC-2, eUSDC-6, eUSDC-1      [smaller vaults]
//
// NOTE: Euler V2 requires Permit2 allowance. The adapter's initialize()
// calls USDC.safeApprove(PERMIT2, MAX) automatically. Additionally,
// initializeMarkets() must be called to set up per-vault Permit2 allowances.
//
// F1-Euler-1 — deposit 100K USDC into real Euler EVault
// F1-Euler-2 — withdraw 50K USDC after deposit + 1-day warp
// ═══════════════════════════════════════════════════════════════════════════

import {ForkTestBase} from "../helpers/ForkTestBase.sol";
import {EulerUsdcMultiMarketAdapter}
    from "../../../../src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IEulerVault {
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

contract EulerAdapterFork is ForkTestBase {

    EulerUsdcMultiMarketAdapter internal adapter;

    address internal admin     = address(0xAD);
    address internal vault     = address(this);
    address internal eulerVault;

    function setUp() public {
        (, eulerVault) = _setupForkWithAddr("EULER_USDC_VAULT");
        if (eulerVault == address(0)) return; // skipped by _setupForkWithAddr

        // Build markets array with the single EVault address
        address[] memory markets = new address[](1);
        markets[0] = eulerVault;

        // V10 deploy+init pattern: empty constructor + initialize
        // Euler initialize signature: (vault, usdc, markets[], registry, admin)
        adapter = new EulerUsdcMultiMarketAdapter();
        adapter.initialize(vault, USDC, markets, address(0), admin);

        // Set up Permit2 per-vault allowances (required before first deposit)
        vm.prank(admin);
        adapter.initializeMarkets();

        _dealUsdc(vault, SEED_USDC);
    }

    // ── F1-Euler-1: deposit 100K USDC ───────────────────────────────────────

    function test_F1_Euler_deposit_realChainState() public {
        uint256 depositAmt = 100_000e6;

        uint256 vaultUsdcBefore = IERC20(USDC).balanceOf(vault);
        uint256 sharesBefore    = IEulerVault(eulerVault).balanceOf(address(adapter));

        IERC20(USDC).approve(address(adapter), depositAmt);
        adapter.deposit(depositAmt);

        uint256 vaultUsdcAfter = IERC20(USDC).balanceOf(vault);
        uint256 sharesAfter    = IEulerVault(eulerVault).balanceOf(address(adapter));

        assertEq(vaultUsdcBefore - vaultUsdcAfter, depositAmt, "vault USDC decrease mismatch");
        assertGt(sharesAfter, sharesBefore, "EVault shares should increase after deposit");
        assertApproxEqAbs(adapter.totalAssets(), depositAmt, 1e4, "totalAssets mismatch");
    }

    // ── F1-Euler-2: withdraw 50K USDC after deposit ─────────────────────────

    function test_F1_Euler_withdraw_realChainState() public {
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
