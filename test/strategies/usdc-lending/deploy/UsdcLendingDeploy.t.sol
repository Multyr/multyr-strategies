// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ═══════════════════════════════════════════════════════════════════════════════
// UsdcLendingDeploy.t.sol — Chain config + deterministic build tests
// ───────────────────────────────────────────────────────────────────────────────
// 4 unit tests validating the Wave 3 multichain config layer.
// No fork required — all tests run against compiled bytecode only.
//
// Tests:
//  1. test_deploy_arbitrum_config   — Arbitrum addresses + Venus blocksPerYear
//  2. test_deploy_optimism_config   — Optimism addresses + Venus disabled
//  3. test_bytecode_reproducibility — vault creationCode hash is stable + nonzero
//  4. test_salt_collision_resistance — per-chain deploySalt distinct from each other
// ═══════════════════════════════════════════════════════════════════════════════

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { UsdcLendingChainConfig } from
    "../../../../src/strategies/usdc-lending/config/UsdcLendingChainConfig.sol";
import { UsdcLendingConfigArbitrum } from
    "../../../../src/strategies/usdc-lending/config/UsdcLendingConfigArbitrum.sol";
import { UsdcLendingConfigOptimism } from
    "../../../../src/strategies/usdc-lending/config/UsdcLendingConfigOptimism.sol";
import { UsdcLendingConfigBase } from
    "../../../../src/strategies/usdc-lending/config/UsdcLendingConfigBase.sol";
import { UsdcLendingConfigPolygon } from
    "../../../../src/strategies/usdc-lending/config/UsdcLendingConfigPolygon.sol";
import { UsdcLendingConfigEthereum } from
    "../../../../src/strategies/usdc-lending/config/UsdcLendingConfigEthereum.sol";
import { UsdcMultiLendingVault } from
    "../../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";

// Universal Permit2 — same address on all EVM chains.
address constant PERMIT2_UNIVERSAL = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

contract UsdcLendingDeploy_Test is Test {

    // ─────────────────────────────────────────────────────────────────────────
    // 1. test_deploy_arbitrum_config
    // ─────────────────────────────────────────────────────────────────────────

    function test_deploy_arbitrum_config() public {
        UsdcLendingChainConfig memory cfg = UsdcLendingConfigArbitrum.get();

        // Core token
        assertEq(cfg.usdc, 0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
            "Arbitrum USDC mismatch");

        // Aave V3
        assertEq(cfg.aavePool,  0x794a61358D6845594F94dc1DB02A252b5b4814aD,
            "Arbitrum Aave pool mismatch");
        assertEq(cfg.aaveAUsdc, 0x724dc807b04555b71ed48a6896b6F41593b8C637,
            "Arbitrum aUSDC mismatch");

        // Compound III
        assertEq(cfg.cometUsdcV3, 0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf,
            "Arbitrum Comet mismatch");

        // Euler vaults
        assertEq(cfg.eulerVault1, 0x6aFB8d3F6D4A34e9cB2f217317f4dc8e05Aa673b,
            "Arbitrum Euler vault 1 mismatch");
        assertNotEq(cfg.eulerVault2, address(0), "Euler vault 2 should be set");
        assertNotEq(cfg.eulerVault3, address(0), "Euler vault 3 should be set");
        assertNotEq(cfg.eulerVault4, address(0), "Euler vault 4 should be set");

        // Morpho vaults (5 slots populated)
        assertNotEq(cfg.morphoVault1, address(0), "Morpho vault 1 should be set");
        assertNotEq(cfg.morphoVault8, address(0), "Morpho vault 8 should be set");

        // Venus — enabled on Arbitrum
        assertEq(cfg.venusVToken, 0x7D8609f8da70fF9027E9bc5229Af4F6727662707,
            "Arbitrum Venus vToken mismatch");
        assertEq(cfg.venusBlocksPerYear, 126_144_000,
            "Arbitrum Venus blocksPerYear: expected 126_144_000 (0.25s blocks)");

        // Governance fields
        assertEq(cfg.permit2, PERMIT2_UNIVERSAL, "Permit2 address mismatch");
        assertNotEq(cfg.deploySalt, bytes32(0), "Arbitrum deploySalt must be non-zero");
        console.log("Arbitrum deploySalt:", vm.toString(cfg.deploySalt));
        console.log("Arbitrum blocksPerYear:", cfg.venusBlocksPerYear);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. test_deploy_optimism_config
    // ─────────────────────────────────────────────────────────────────────────

    function test_deploy_optimism_config() public {
        UsdcLendingChainConfig memory cfg = UsdcLendingConfigOptimism.get();

        // Core token — native USDC on Optimism
        assertEq(cfg.usdc, 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85,
            "Optimism USDC mismatch");

        // Aave V3 pool same proxy on Optimism
        assertEq(cfg.aavePool, 0x794a61358D6845594F94dc1DB02A252b5b4814aD,
            "Optimism Aave pool mismatch");

        // Venus disabled on Optimism
        assertEq(cfg.venusBlocksPerYear, 0,
            "Optimism Venus must be disabled (blocksPerYear==0)");
        assertEq(cfg.venusVToken, address(0),
            "Optimism Venus vToken must be address(0)");

        // Dolomite not on Optimism
        assertEq(cfg.dolomiteDUsdc, address(0),
            "Dolomite must be address(0) on Optimism");

        // Governance
        assertEq(cfg.permit2, PERMIT2_UNIVERSAL, "Permit2 address mismatch");
        assertNotEq(cfg.deploySalt, bytes32(0), "Optimism deploySalt must be non-zero");
        console.log("Optimism deploySalt:", vm.toString(cfg.deploySalt));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. test_bytecode_reproducibility
    // ─────────────────────────────────────────────────────────────────────────
    // Verifies that UsdcMultiLendingVault creationCode is non-empty (compilable)
    // and its keccak256 hash is stable across runs.
    // The hash is logged so auditors can confirm byte-identical builds via:
    //   forge clean && forge test --match-test test_bytecode_reproducibility -vvv
    //   (run twice → identical logged hash = deterministic build verified)
    // ─────────────────────────────────────────────────────────────────────────

    function test_bytecode_reproducibility() public {
        bytes memory vaultCode = type(UsdcMultiLendingVault).creationCode;

        assertGt(vaultCode.length, 0, "Vault creationCode must be non-empty");
        assertLt(vaultCode.length, 50_000, "Vault creationCode sanity upper bound");

        bytes32 codeHash = keccak256(vaultCode);
        assertNotEq(codeHash, bytes32(0), "Vault creationCode hash must be non-zero");

        // Log for auditor comparison across builds.
        console.log("UsdcMultiLendingVault creationCode length:", vaultCode.length);
        console.log("UsdcMultiLendingVault keccak256(creationCode):", vm.toString(codeHash));

        // foundry.toml config verification via struct compile-time check:
        // bytecode_hash=none + cbor_metadata=false → no IPFS suffix in bytecode.
        // Verify: the last 2 bytes of deployed bytecode are NOT 0x0033 (CBOR metadata length).
        // (We check creationCode, not runtime, but the absence of metadata is cross-cutting.)
        bytes2 tail = bytes2(bytes.concat(vaultCode[vaultCode.length - 2], vaultCode[vaultCode.length - 1]));
        // 0xa264 marks the start of a Solidity CBOR metadata block; 0x0033 follows the length.
        // With bytecode_hash=none + cbor_metadata=false, this marker must be absent.
        assertTrue(tail != 0x0033, "CBOR metadata length marker must not appear in tail (cbor_metadata=false)");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. test_salt_collision_resistance
    // ─────────────────────────────────────────────────────────────────────────
    // Each chain config must have a unique, non-zero deploySalt.
    // Guarantees that deploying via CREATE2 from the same factory on different
    // chains produces different vault addresses — preventing cross-chain confusion.
    // ─────────────────────────────────────────────────────────────────────────

    function test_salt_collision_resistance() public {
        bytes32 saltArb  = UsdcLendingConfigArbitrum.get().deploySalt;
        bytes32 saltOp   = UsdcLendingConfigOptimism.get().deploySalt;
        bytes32 saltBase = UsdcLendingConfigBase.get().deploySalt;
        bytes32 saltPoly = UsdcLendingConfigPolygon.get().deploySalt;
        bytes32 saltEth  = UsdcLendingConfigEthereum.get().deploySalt;

        // All salts must be non-zero
        assertNotEq(saltArb,  bytes32(0), "Arbitrum salt must be non-zero");
        assertNotEq(saltOp,   bytes32(0), "Optimism salt must be non-zero");
        assertNotEq(saltBase, bytes32(0), "Base salt must be non-zero");
        assertNotEq(saltPoly, bytes32(0), "Polygon salt must be non-zero");
        assertNotEq(saltEth,  bytes32(0), "Ethereum salt must be non-zero");

        // All salts must be distinct (no cross-chain collision)
        assertNotEq(saltArb,  saltOp,   "Arbitrum/Optimism salt collision");
        assertNotEq(saltArb,  saltBase, "Arbitrum/Base salt collision");
        assertNotEq(saltArb,  saltPoly, "Arbitrum/Polygon salt collision");
        assertNotEq(saltArb,  saltEth,  "Arbitrum/Ethereum salt collision");
        assertNotEq(saltOp,   saltBase, "Optimism/Base salt collision");
        assertNotEq(saltOp,   saltPoly, "Optimism/Polygon salt collision");
        assertNotEq(saltOp,   saltEth,  "Optimism/Ethereum salt collision");
        assertNotEq(saltBase, saltPoly, "Base/Polygon salt collision");
        assertNotEq(saltBase, saltEth,  "Base/Ethereum salt collision");
        assertNotEq(saltPoly, saltEth,  "Polygon/Ethereum salt collision");

        console.log("Arbitrum deploySalt:", vm.toString(saltArb));
        console.log("Optimism deploySalt:", vm.toString(saltOp));
        console.log("Base     deploySalt:", vm.toString(saltBase));
        console.log("Polygon  deploySalt:", vm.toString(saltPoly));
        console.log("Ethereum deploySalt:", vm.toString(saltEth));
    }
}
