// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ═══════════════════════════════════════════════════════════════════════════
// MorphoAdapterFork.t.sol — Phase F1: Morpho (MetaMorpho) adapter deposit + withdraw
// ───────────────────────────────────────────────────────────────────────────
// Fork: Arbitrum mainnet, block 472761449
// Run: ARBITRUM_RPC_URL=<rpc> MORPHO_METAMORPHO_USDC=<addr> \
//        forge test --match-contract MorphoAdapterFork -vvv
//
// ADDRESS REQUIRED: MORPHO_METAMORPHO_USDC env var must be set.
// This is a MetaMorpho ERC-4626 USDC vault on Arbitrum.
// DefiLlama notes (2025): bbqUSDC (~16M), gtUSDCp Prime (~4.6M),
//   gtUSDCc Core (~4.1M), hyperUSDCa (~975K), yDG-USDC (~452K).
// NOTE: DefiLlama first tracked Morpho on Arbitrum from 2025-10-09.
//   If the vaults did not exist at block 472761449, update to a newer block.
//   Use MORPHO_FORK_BLOCK env var override if needed.
//
// F1-Morpho-1 — deposit 100K USDC into real MetaMorpho vault
// F1-Morpho-2 — withdraw 50K USDC after deposit + 1-day warp
// ═══════════════════════════════════════════════════════════════════════════

import {ForkTestBase} from "../helpers/ForkTestBase.sol";
import {MorphoUsdcMultiMarketAdapter}
    from "../../../../src/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMetaMorpho {
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function asset() external view returns (address);
}

contract MorphoAdapterFork is ForkTestBase {

    MorphoUsdcMultiMarketAdapter internal adapter;

    address internal admin        = address(0xAD);
    address internal vault        = address(this);
    address internal metaMorpho;

    function setUp() public {
        (, metaMorpho) = _setupForkWithAddr("MORPHO_METAMORPHO_USDC");
        if (metaMorpho == address(0)) return; // skipped by _setupForkWithAddr

        // Verify MetaMorpho vault asset is USDC
        require(IMetaMorpho(metaMorpho).asset() == USDC, "MetaMorpho.asset != USDC");

        // V10 deploy+init pattern: empty constructor + initialize (registry=address(0))
        // Markets added manually via addMarket() after initialization
        adapter = new MorphoUsdcMultiMarketAdapter();
        adapter.initialize(USDC, admin, vault, MAX_CAP, address(0));

        // Add the MetaMorpho vault as a market
        vm.prank(admin);
        adapter.addMarket(metaMorpho);

        _dealUsdc(vault, SEED_USDC);
    }

    // ── F1-Morpho-1: deposit 100K USDC ──────────────────────────────────────

    function test_F1_Morpho_deposit_realChainState() public {
        uint256 depositAmt = 100_000e6;

        uint256 vaultUsdcBefore = IERC20(USDC).balanceOf(vault);
        uint256 sharesBefore    = IMetaMorpho(metaMorpho).balanceOf(address(adapter));

        IERC20(USDC).approve(address(adapter), depositAmt);
        adapter.deposit(depositAmt);

        uint256 vaultUsdcAfter = IERC20(USDC).balanceOf(vault);
        uint256 sharesAfter    = IMetaMorpho(metaMorpho).balanceOf(address(adapter));

        assertEq(vaultUsdcBefore - vaultUsdcAfter, depositAmt, "vault USDC decrease mismatch");
        assertGt(sharesAfter, sharesBefore, "MetaMorpho shares should increase after deposit");
        assertApproxEqAbs(adapter.totalAssets(), depositAmt, 1e4, "totalAssets mismatch");
    }

    // ── F1-Morpho-2: withdraw 50K USDC after deposit ────────────────────────

    function test_F1_Morpho_withdraw_realChainState() public {
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
