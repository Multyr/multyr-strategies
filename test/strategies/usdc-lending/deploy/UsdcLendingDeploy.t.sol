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
    // 5-7. Base / Polygon / Ethereum — placeholder chain configs
    // ─────────────────────────────────────────────────────────────────────────
    // These three configs are not yet wired to any deploy path (the deploy
    // script currently hard-requires block.chainid == 42161 / Arbitrum-only),
    // and are explicitly documented as "TBD -- fill before deploy" in-source.
    // These tests lock in that intentional placeholder state: the fields that
    // ARE meant to be live today (usdc/aavePool/aaveAUsdc/permit2/deploySalt)
    // must be correct, and the fields that are NOT yet filled must still read
    // as address(0) -- so an accidental partial-fill (e.g. someone sets
    // fluidFUsdc but forgets governanceMultisig) shows up as a failing test
    // instead of shipping silently.
    // ─────────────────────────────────────────────────────────────────────────

    function test_deploy_base_config_is_placeholder() public pure {
        UsdcLendingChainConfig memory cfg = UsdcLendingConfigBase.get();

        assertEq(cfg.usdc, 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, "Base USDC mismatch");
        assertEq(cfg.aavePool, 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5, "Base Aave pool mismatch");
        assertEq(cfg.aaveAUsdc, 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB, "Base aUSDC mismatch");
        assertEq(cfg.permit2, PERMIT2_UNIVERSAL, "Base Permit2 mismatch");
        assertNotEq(cfg.deploySalt, bytes32(0), "Base deploySalt must be non-zero");

        // Not yet filled -- deploy must not proceed on Base until these are set.
        assertEq(cfg.cometUsdcV3, address(0), "Base Comet is TBD");
        assertEq(cfg.dolomiteDUsdc, address(0), "Dolomite not on Base");
        assertEq(cfg.fluidFUsdc, address(0), "Base Fluid is TBD");
        assertEq(cfg.morphoVault1, address(0), "Base Morpho is TBD");
        assertEq(cfg.venusVToken, address(0), "Venus not on Base");
        assertEq(cfg.venusBlocksPerYear, 0, "Venus disabled on Base");
        assertEq(cfg.governanceMultisig, address(0), "Base governance multisig not yet set");
    }

    function test_deploy_polygon_config_is_placeholder() public pure {
        UsdcLendingChainConfig memory cfg = UsdcLendingConfigPolygon.get();

        assertEq(cfg.usdc, 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359, "Polygon USDC mismatch");
        assertEq(cfg.aavePool, 0x794a61358D6845594F94dc1DB02A252b5b4814aD, "Polygon Aave pool mismatch");
        assertEq(cfg.cometUsdcV3, 0xF25212E676D1F7F89Cd72fFEe66158f541246445, "Polygon Comet mismatch");
        assertEq(cfg.permit2, PERMIT2_UNIVERSAL, "Polygon Permit2 mismatch");
        assertNotEq(cfg.deploySalt, bytes32(0), "Polygon deploySalt must be non-zero");

        assertEq(cfg.dolomiteDUsdc, address(0), "Dolomite not on Polygon");
        assertEq(cfg.fluidFUsdc, address(0), "Polygon Fluid is TBD");
        assertEq(cfg.morphoVault1, address(0), "Polygon Morpho is TBD");
        assertEq(cfg.venusVToken, address(0), "Venus not on Polygon PoS");
        assertEq(cfg.venusBlocksPerYear, 0, "Venus disabled on Polygon");
        assertEq(cfg.governanceMultisig, address(0), "Polygon governance multisig not yet set");
    }

    function test_deploy_ethereum_config_is_placeholder() public pure {
        UsdcLendingChainConfig memory cfg = UsdcLendingConfigEthereum.get();

        assertEq(cfg.usdc, 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, "Ethereum USDC mismatch");
        assertEq(cfg.aavePool, 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2, "Ethereum Aave pool mismatch");
        assertEq(cfg.cometUsdcV3, 0xc3d688B66703497DAA19211EEdff47f25384cdc3, "Ethereum Comet mismatch");
        assertEq(cfg.permit2, PERMIT2_UNIVERSAL, "Ethereum Permit2 mismatch");
        assertNotEq(cfg.deploySalt, bytes32(0), "Ethereum deploySalt must be non-zero");

        assertEq(cfg.dolomiteDUsdc, address(0), "Dolomite not on Ethereum");
        assertEq(cfg.fluidFUsdc, address(0), "Ethereum Fluid is TBD");
        assertEq(cfg.morphoVault1, address(0), "Ethereum Morpho is TBD");
        assertEq(cfg.venusVToken, address(0), "Venus not on Ethereum");
        assertEq(cfg.venusBlocksPerYear, 0, "Venus disabled on Ethereum");
        assertEq(cfg.governanceMultisig, address(0), "Ethereum governance multisig not yet set");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 8. Cross-chain sanity: every live-token chain must have a distinct USDC
    //    and a distinct deploySalt from every other configured chain, and every
    //    config's governanceMultisig is currently address(0) everywhere --
    //    including Arbitrum, the one chain the deploy script can actually
    //    target today. Deliberately not gated on-chain (see script's own
    //    `cfg.timelock` / TIMELOCK_ADDRESS check, which IS enforced before the
    //    admin-role handoff) -- this test exists so that gap stays visible
    //    rather than silently assumed fixed by a future change.
    // ─────────────────────────────────────────────────────────────────────────

    function test_governanceMultisig_unset_across_all_configs() public pure {
        assertEq(UsdcLendingConfigArbitrum.get().governanceMultisig, address(0));
        assertEq(UsdcLendingConfigOptimism.get().governanceMultisig, address(0));
        assertEq(UsdcLendingConfigBase.get().governanceMultisig, address(0));
        assertEq(UsdcLendingConfigPolygon.get().governanceMultisig, address(0));
        assertEq(UsdcLendingConfigEthereum.get().governanceMultisig, address(0));
    }

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
