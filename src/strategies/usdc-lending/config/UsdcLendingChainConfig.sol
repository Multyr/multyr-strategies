// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @dev Per-chain addresses and parameters consumed by DeployUsdcLendingStrategy.
struct UsdcLendingChainConfig {
    // ── Core token ──────────────────────────────────────────────────────────
    address usdc;

    // ── Aave V3 ─────────────────────────────────────────────────────────────
    address aavePool;
    address aaveAUsdc;

    // ── Compound III ─────────────────────────────────────────────────────────
    address cometUsdcV3;

    // ── Dolomite ─────────────────────────────────────────────────────────────
    address dolomiteDUsdc;

    // ── Euler V2 (up to 4 vaults; zero address = slot unused) ───────────────
    address eulerVault1;
    address eulerVault2;
    address eulerVault3;
    address eulerVault4;

    // ── Fluid ────────────────────────────────────────────────────────────────
    address fluidFUsdc;

    // ── Morpho (up to 5 vaults; zero address = slot unused) ─────────────────
    address morphoVault1;
    address morphoVault2;
    address morphoVault4;
    address morphoVault6;
    address morphoVault8;

    // ── Venus ────────────────────────────────────────────────────────────────
    address venusVToken;
    // Per-chain block production rate for APY computation (C-04).
    // 0 = Venus adapter disabled on this chain.
    uint256 venusBlocksPerYear;
}
