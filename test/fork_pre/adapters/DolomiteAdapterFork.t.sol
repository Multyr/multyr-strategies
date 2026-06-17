// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ═══════════════════════════════════════════════════════════════════════════
// DolomiteAdapterFork.t.sol — Phase F1: Dolomite adapter deposit + withdraw
// ───────────────────────────────────────────────────────────────────────────
// Fork: Arbitrum mainnet, block 472761449
// Run: ARBITRUM_RPC_URL=<rpc> forge test --match-contract DolomiteAdapterFork -vvv
//
// DOLOMITE_dUSDC = 0x444868B6e8079ac2c55eea115250f92C2b2c4D14 (from deploy config)
// The adapter auto-detects dUSDC as ERC4626 via _tryERC4626() during _loadFromRegistry().
// validateDolomiteConfig() is a no-op for ERC4626 markets (sets dolomiteConfigValid=true).
//
// F1-Dolomite-1 — deposit 100K USDC → dUSDC shares increase correctly
// F1-Dolomite-2 — withdraw 50K USDC after deposit + 1-day warp
// ═══════════════════════════════════════════════════════════════════════════

import {ForkTestBase} from "../helpers/ForkTestBase.sol";
import {DolomiteUsdcMultiMarketAdapter}
    from "@multyr-strategies/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IDoloVault {
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function asset() external view returns (address);
}

/// @dev Minimal registry stub: returns DOLOMITE_dUSDC for any ProtocolType.
/// DolomiteUsdcMultiMarketAdapter calls getEnabledVaults(ProtocolType.DOLOMITE)
/// where ProtocolType is a uint8 enum. The mock accepts any uint8.
/// The adapter then auto-detects dUSDC as ERC4626 via _tryERC4626().
contract MockDolomiteRegistry {
    address private _market;

    constructor(address market) { _market = market; }

    function getEnabledVaults(uint8) external view returns (address[] memory vaults) {
        vaults = new address[](1);
        vaults[0] = _market;
    }
}

contract DolomiteAdapterFork is ForkTestBase {

    DolomiteUsdcMultiMarketAdapter internal adapter;

    address internal admin = address(0xAD);
    address internal vault = address(this);

    function setUp() public {
        _setupFork();

        // Verify dUSDC asset is USDC (sanity check)
        require(IDoloVault(DOLOMITE_dUSDC).asset() == USDC, "dUSDC.asset != USDC");

        // Deploy mock registry: adapter calls getEnabledVaults(DOLOMITE) during initialize().
        // _loadFromRegistry() auto-detects dUSDC as ERC4626 via _tryERC4626().
        MockDolomiteRegistry reg = new MockDolomiteRegistry(DOLOMITE_dUSDC);

        // V10 deploy+init pattern
        adapter = new DolomiteUsdcMultiMarketAdapter();
        adapter.initialize(USDC, admin, vault, MAX_CAP, address(reg));

        // validateDolomiteConfig() is a no-op for ERC4626-only setups (sets valid flag).
        vm.prank(admin);
        adapter.validateDolomiteConfig();

        _dealUsdc(vault, SEED_USDC);
    }

    // ── F1-Dolomite-1: deposit 100K USDC ────────────────────────────────────

    function test_F1_Dolomite_deposit_realChainState() public {
        uint256 depositAmt = 100_000e6;

        uint256 vaultUsdcBefore = IERC20(USDC).balanceOf(vault);
        uint256 sharesBefore    = IDoloVault(DOLOMITE_dUSDC).balanceOf(address(adapter));

        IERC20(USDC).approve(address(adapter), depositAmt);
        adapter.deposit(depositAmt);

        uint256 vaultUsdcAfter = IERC20(USDC).balanceOf(vault);
        uint256 sharesAfter    = IDoloVault(DOLOMITE_dUSDC).balanceOf(address(adapter));

        assertEq(vaultUsdcBefore - vaultUsdcAfter, depositAmt, "vault USDC decrease mismatch");
        assertGt(sharesAfter, sharesBefore, "dUSDC shares should increase after deposit");
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
