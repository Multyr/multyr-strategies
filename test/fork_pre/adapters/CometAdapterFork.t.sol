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
//
// NOTE: CometUsdcMultiMarketAdapter.initialize() requires mkts.length > 0.
// Since no real registry exists in tests, we pass a MockCometRegistry that
// returns COMET_USDC for getEnabledVaults(). The adapter loads it during init.
// ═══════════════════════════════════════════════════════════════════════════

import {ForkTestBase} from "../helpers/ForkTestBase.sol";
import {CometUsdcMultiMarketAdapter}
    from "@multyr-strategies/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IComet {
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Minimal registry stub: returns a single Comet market for COMPOUND_V3.
/// The adapter calls getEnabledVaults(ProtocolType.COMPOUND_V3) where ProtocolType
/// is an enum that maps to uint8. The mock accepts any uint8 and returns COMET_USDC.
contract MockCometRegistry {
    address private _market;

    constructor(address market) { _market = market; }

    function getEnabledVaults(uint8) external view returns (address[] memory vaults) {
        vaults = new address[](1);
        vaults[0] = _market;
    }
}

contract CometAdapterFork is ForkTestBase {

    CometUsdcMultiMarketAdapter internal adapter;

    address internal admin = address(0xAD);
    address internal vault = address(this);

    function setUp() public {
        _setupFork();

        // Deploy mock registry so initialize() passes the mkts.length > 0 require.
        MockCometRegistry reg = new MockCometRegistry(COMET_USDC);

        // V10 deploy+init pattern: empty constructor + initialize (with registry)
        adapter = new CometUsdcMultiMarketAdapter();
        adapter.initialize(USDC, admin, vault, MAX_CAP, address(reg));

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
