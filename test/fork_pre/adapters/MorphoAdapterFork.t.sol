// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ═══════════════════════════════════════════════════════════════════════════
// MorphoAdapterFork.t.sol — Phase F1: Morpho (MetaMorpho) adapter deposit + withdraw
// ───────────────────────────────────────────────────────────────────────────
// Fork: Arbitrum mainnet, block 472761449
// Run: ARBITRUM_RPC_URL=<rpc> forge test --match-contract MorphoAdapterFork -vvv
//
// MORPHO_VAULT_1 = 0x7e97fa6893871A2751B5fE961978DCCb2c201E65 (Gauntlet USDC Core)
// NOTE: DefiLlama first tracked Morpho MetaMorpho on Arbitrum from 2025-10-09.
//   If the vaults do not exist at block 472761449 (code.length == 0), the test
//   skips gracefully with a clear message. Update DEFAULT_FORK_BLOCK in
//   ForkTestBase.sol to a post-2025-10 block to run these tests for real.
//
// F1-Morpho-1 — deposit 100K USDC into real MetaMorpho vault
// F1-Morpho-2 — withdraw 50K USDC after deposit + 1-day warp
// ═══════════════════════════════════════════════════════════════════════════

import {ForkTestBase} from "../helpers/ForkTestBase.sol";
import {MorphoUsdcMultiMarketAdapter}
    from "@multyr-strategies/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMetaMorpho {
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function asset() external view returns (address);
}

/// @dev Minimal registry stub: returns 5 Morpho MetaMorpho USDC vaults for any ProtocolType.
/// MorphoUsdcMultiMarketAdapter calls getEnabledVaults(ProtocolType.MORPHO)
/// where ProtocolType is a uint8 enum. The mock accepts any uint8.
contract MockMorphoRegistry {
    address[5] private _vaults;
    uint256 private _count;

    constructor(address v1, address v2, address v3, address v4, address v5) {
        _vaults[0] = v1; _vaults[1] = v2; _vaults[2] = v3;
        _vaults[3] = v4; _vaults[4] = v5;
        _count = 5;
    }

    function getEnabledVaults(uint8) external view returns (address[] memory vaults) {
        vaults = new address[](_count);
        for (uint256 i = 0; i < _count; i++) vaults[i] = _vaults[i];
    }
}

contract MorphoAdapterFork is ForkTestBase {

    MorphoUsdcMultiMarketAdapter internal adapter;

    address internal admin = address(0xAD);
    address internal vault = address(this);

    function setUp() public {
        _setupFork();

        // Check if Morpho vaults exist at this block — code.length == 0 means not yet deployed.
        if (MORPHO_VAULT_1.code.length == 0) {
            // solhint-disable-next-line reason-string
            vm.skip(true);
            // Morpho MetaMorpho USDC vaults not present at block 472761449.
            // Update DEFAULT_FORK_BLOCK to a block >= late 2025 to run these tests.
            return;
        }

        // Verify primary vault asset is USDC
        require(IMetaMorpho(MORPHO_VAULT_1).asset() == USDC, "MetaMorpho.asset != USDC");

        // Deploy mock registry so initialize() passes the mkts.length > 0 require.
        // Registry pattern mirrors production deployment (SimpleProtocolRegistry).
        MockMorphoRegistry reg = new MockMorphoRegistry(
            MORPHO_VAULT_1, MORPHO_VAULT_2, MORPHO_VAULT_4, MORPHO_VAULT_6, MORPHO_VAULT_8
        );

        // V10 deploy+init pattern
        adapter = new MorphoUsdcMultiMarketAdapter();
        adapter.initialize(USDC, admin, vault, MAX_CAP, address(reg));

        _dealUsdc(vault, SEED_USDC);
    }

    // ── F1-Morpho-1: deposit 100K USDC ──────────────────────────────────────

    function test_F1_Morpho_deposit_realChainState() public {
        uint256 depositAmt = 100_000e6;

        uint256 vaultUsdcBefore = IERC20(USDC).balanceOf(vault);

        IERC20(USDC).approve(address(adapter), depositAmt);
        adapter.deposit(depositAmt);

        uint256 vaultUsdcAfter = IERC20(USDC).balanceOf(vault);

        assertEq(vaultUsdcBefore - vaultUsdcAfter, depositAmt, "vault USDC decrease mismatch");
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
