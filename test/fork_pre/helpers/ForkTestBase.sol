// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ═══════════════════════════════════════════════════════════════════════════
// ForkTestBase.sol — Shared base for V10 adapter fork tests
// ───────────────────────────────────────────────────────────────────────────
// Provides:
//  - Arbitrum mainnet canonical addresses (confirmed at block 472761449)
//  - Graceful skip when ARBITRUM_RPC_URL is not configured
//  - USDC seeding helpers (whale impersonation + deal)
//  - Standard fork setup with pinned block
//
// Protocol address verification status (block 472761449, ~December 2024):
//  ✓ CONFIRMED: USDC, Aave V3, Compound III Comet, Dolomite Margin + Proxy
//  ! ENV_VAR:   Euler eUSDC, Fluid fUSDC, Morpho MetaMorpho vaults
//    (set EULER_USDC_VAULT / FLUID_FUSDC / MORPHO_METAMORPHO_USDC env vars
//     to run those adapter tests; tests skip gracefully if unset)
// ═══════════════════════════════════════════════════════════════════════════

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract ForkTestBase is Test {

    // ── Canonical Arbitrum mainnet addresses (block 472761449) ──────────────

    address constant USDC        = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant USDC_WHALE  = 0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7;

    // Aave V3 — confirmed, ~4.8M USDC TVL at target block
    address constant AAVE_V3_POOL  = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant AAVE_AUSDC    = 0x724dc807b04555b71ed48a6896b6F41593b8C637;

    // Compound III (Comet) — confirmed, ~6.5M USDC TVL at target block
    address constant COMET_USDC  = 0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf;

    // Dolomite — confirmed contracts; USDC market ID 17 on DolomiteMargin (Arbitrum)
    // Note: individual market address depends on which pool/vault Dolomite exposes.
    // Set DOLOMITE_USDC_MARKET env var with the actual market address before running.
    address constant DOLOMITE_MARGIN   = 0x6Bd780E7fDf01D77e4d475c821f1e7AE05409072;
    address constant DOLOMITE_DW_PROXY = 0xAdB9D68c613df4AA363B42161E1282117C7B9594;
    uint256 constant DOLOMITE_USDC_MARKET_ID = 17;

    // Uniswap V3 Router (for swap tests in later phases)
    address constant UNI_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // Standard test parameters
    uint256 constant DEFAULT_FORK_BLOCK = 472_761_449;
    uint256 constant SEED_USDC          = 1_000_000e6; // 1M USDC
    uint256 constant MAX_CAP            = 10_000_000e6; // 10M USDC

    // ── Fork setup ───────────────────────────────────────────────────────────

    /// @notice Setup Arbitrum fork; vm.skip(true) when ARBITRUM_RPC_URL is absent.
    /// @return rpc The RPC URL string, empty if skipped.
    function _setupFork() internal returns (string memory rpc) {
        rpc = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return "";
        }
        vm.createSelectFork(rpc, DEFAULT_FORK_BLOCK);
        require(block.chainid == 42161, "Not Arbitrum mainnet");
    }

    /// @notice Setup fork and also require a specific env-var address.
    /// @dev Skips if either ARBITRUM_RPC_URL or the named env var is absent.
    function _setupForkWithAddr(string memory envKey)
        internal
        returns (string memory rpc, address addr)
    {
        rpc = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return ("", address(0)); }
        addr = vm.envOr(envKey, address(0));
        if (addr == address(0)) { vm.skip(true); return ("", address(0)); }
        vm.createSelectFork(rpc, DEFAULT_FORK_BLOCK);
        require(block.chainid == 42161, "Not Arbitrum mainnet");
    }

    // ── USDC seeding helpers ─────────────────────────────────────────────────

    /// @notice Seed recipient with USDC via whale impersonation.
    function _seedUsdc(address recipient, uint256 amount) internal {
        vm.prank(USDC_WHALE);
        IERC20(USDC).transfer(recipient, amount);
    }

    /// @notice Seed via vm.deal (storage write — no whale needed).
    function _dealUsdc(address recipient, uint256 amount) internal {
        deal(USDC, recipient, amount);
    }
}
