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

    // ── Governance ───────────────────────────────────────────────────────────
    // Chain-specific governance multisig / timelock that receives DEFAULT_ADMIN_ROLE.
    // address(0) = must be set before deploy.
    address governanceMultisig;

    // ── Deterministic deploy ─────────────────────────────────────────────────
    // Chain-unique CREATE2 salt for the strategy vault deployment.
    // Prevents address collision if the same factory is used across chains.
    bytes32 deploySalt;

    // ── Permit2 ──────────────────────────────────────────────────────────────
    // Canonical Permit2 contract address. Universal across EVM chains.
    // 0x000000000022D473030F116dDEE9F6B43aC78BA3
    address permit2;
}
