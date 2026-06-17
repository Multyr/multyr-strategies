// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ═══════════════════════════════════════════════════════════════════════════
// DolomiteAdapterFork.t.sol — Phase F1: Dolomite adapter deposit + withdraw
// ───────────────────────────────────────────────────────────────────────────
// Fork: Arbitrum mainnet, block 472761449
// Run: ARBITRUM_RPC_URL=<rpc> DOLOMITE_USDC_MARKET=<addr> \
//        forge test --match-contract DolomiteAdapterFork -vvv
//
// ADDRESS REQUIRED: DOLOMITE_USDC_MARKET env var must be set.
// This is the ERC-4626 or PoolLike market contract that Dolomite exposes
// for USDC deposits on Arbitrum (e.g., the "Dolomite Balance USDC" vault).
// DolomiteMargin: 0x6Bd780E7fDf01D77e4d475c821f1e7AE05409072 (known).
//
// F1-Dolomite-1 — deposit 100K USDC → market balance increases correctly
// F1-Dolomite-2 — withdraw 50K USDC after deposit + 1-day warp
// ═══════════════════════════════════════════════════════════════════════════

import {ForkTestBase} from "../helpers/ForkTestBase.sol";
import {DolomiteUsdcMultiMarketAdapter}
    from "../../../../src/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DolomiteAdapterFork is ForkTestBase {

    DolomiteUsdcMultiMarketAdapter internal adapter;

    address internal admin      = address(0xAD);
    address internal vault      = address(this);
    address internal mktAddress;

    function setUp() public {
        (, mktAddress) = _setupForkWithAddr("DOLOMITE_USDC_MARKET");
        if (mktAddress == address(0)) return; // skipped by _setupForkWithAddr

        // V10 deploy+init pattern: empty constructor + initialize (registry=address(0))
        adapter = new DolomiteUsdcMultiMarketAdapter();
        adapter.initialize(USDC, admin, vault, MAX_CAP, address(0));

        // Add the market. The adapter auto-detects the type via _detectMarketType():
        //   ERC4626 if mktAddress.asset() == USDC
        //   PoolLike if mktAddress.baseToken() == USDC
        // Default: ERC4626 (Dolomite Balance USDC is an ERC-4626 vault).
        // Change to MarketType.PoolLike if the market uses Dolomite's pool interface.
        vm.prank(admin);
        adapter.addMarket(mktAddress, DolomiteUsdcMultiMarketAdapter.MarketType.ERC4626);

        // Validate Dolomite config (required for PoolLike markets with accountWei accounting)
        vm.prank(admin);
        adapter.validateDolomiteConfig();

        _dealUsdc(vault, SEED_USDC);
    }

    // ── F1-Dolomite-1: deposit 100K USDC ────────────────────────────────────

    function test_F1_Dolomite_deposit_realChainState() public {
        uint256 depositAmt = 100_000e6;

        uint256 vaultUsdcBefore = IERC20(USDC).balanceOf(vault);

        IERC20(USDC).approve(address(adapter), depositAmt);
        adapter.deposit(depositAmt);

        uint256 vaultUsdcAfter = IERC20(USDC).balanceOf(vault);

        assertEq(vaultUsdcBefore - vaultUsdcAfter, depositAmt, "vault USDC decrease mismatch");
        assertApproxEqAbs(adapter.totalAssets(), depositAmt, 1e4, "totalAssets mismatch");
    }

    // ── F1-Dolomite-2: withdraw 50K USDC after deposit ──────────────────────

    function test_F1_Dolomite_withdraw_realChainState() public {
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
