// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ═══════════════════════════════════════════════════════════════════════════
// DeployAndDepositReadiness.fork.t.sol — end-to-end "is it ready" check
// ───────────────────────────────────────────────────────────────────────────
// Forks real Arbitrum One mainnet, runs the ACTUAL DeployUsdcLendingStrategy
// script against the real, already-deployed core system (CoreVault,
// StrategyRouter, BufferManager, StrategyHealthRegistry -- verified to exist
// on-chain), then drives a real deposit through the freshly-deployed strategy
// against REAL Aave/Comet/Euler/Dolomite/Fluid/Venus/Morpho protocol contracts.
//
// This answers two questions with an actual on-chain simulation rather than
// mocks:
//   1. "Deploy ready?"  -- does the real script run to completion against the
//      real core system's current state, with every internal assertion
//      (address predictions, BOOTSTRAP_ROLE renounce, CORE_ROLE grants,
//      Dolomite market config, Euler market init, PARAM_ROLE grants) passing?
//   2. "Deposit ready?" -- once deployed, does CoreVault pushing USDC in and
//      calling deposit() actually get real capital allocated into at least
//      one real external lending market, without reverting?
//
// RPC:  ARBITRUM_RPC_URL env var -- skips gracefully when absent (CI without
//       secrets), matching test/fork_pre/helpers/ForkTestBase.sol convention.
//
// Run:
//   ARBITRUM_RPC_URL=<rpc> forge test --match-contract DeployAndDepositReadiness -vvv
// ═══════════════════════════════════════════════════════════════════════════

import { Test, console2 } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { DeployUsdcLendingStrategy } from "../../../../script/DeployUsdcLendingStrategy.s.sol";
import { UsdcMultiLendingVault } from "../../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";

contract DeployAndDepositReadiness_Fork_Test is Test {
    // Real, verified-on-chain core system addresses (see
    // multyr-core/broadcast/core-addresses.json -- confirmed to have real
    // bytecode and correct asset() on Arbitrum One before writing this test).
    address constant REAL_VAULT           = 0x685Ec439Fc62736934FF6A74301B50173E34446b;
    address constant REAL_STRATEGY_ROUTER = 0x003BF0faD6b644536c14dcbF822b9fE1A3626b74;
    address constant REAL_BUFFER_MANAGER  = 0x4560B3E16B335358dA6bF14ec8f9B9A5D07413a1;
    address constant REAL_HEALTH_REGISTRY = 0x2bF1C86af4267C068B3c928538F7AA82219cf1D4;
    address constant REAL_GUARDIAN        = 0x7407E68a5553E948eed862f19fc6B292eb48d677;

    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    // Throwaway test-only deployer -- NOT the real DEPLOYER_PRIVATE_KEY.
    // Funded locally on the fork; never touches real funds or real state.
    uint256 constant TEST_DEPLOYER_PK = 0xA11CE5EED;

    uint256 constant DEPOSIT_AMOUNT = 200_000e6; // 200K USDC

    function _skipIfNoRpc() internal returns (string memory rpc) {
        rpc = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
        }
    }

    function test_full_deploy_and_deposit_against_real_arbitrum_state() public {
        string memory rpc = _skipIfNoRpc();
        vm.createSelectFork(rpc);
        require(block.chainid == 42161, "not Arbitrum One");

        // Sanity: the real core system this script is meant to run against
        // must actually exist at these addresses on THIS fork's chain state.
        require(REAL_VAULT.code.length > 0, "REAL_VAULT has no code on this fork");
        require(REAL_STRATEGY_ROUTER.code.length > 0, "REAL_STRATEGY_ROUTER has no code on this fork");
        require(REAL_BUFFER_MANAGER.code.length > 0, "REAL_BUFFER_MANAGER has no code on this fork");
        require(REAL_HEALTH_REGISTRY.code.length > 0, "REAL_HEALTH_REGISTRY has no code on this fork");

        address testDeployer = vm.addr(TEST_DEPLOYER_PK);
        vm.deal(testDeployer, 10 ether);
        deal(USDC, testDeployer, 1_000_000); // 1 USDC — covers the 0.001 USDC Euler Permit2 dust

        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(TEST_DEPLOYER_PK));
        vm.setEnv("VAULT_ADDRESS", vm.toString(REAL_VAULT));
        vm.setEnv("STRATEGY_ROUTER_ADDRESS", vm.toString(REAL_STRATEGY_ROUTER));
        vm.setEnv("BUFFER_MANAGER_ADDRESS", vm.toString(REAL_BUFFER_MANAGER));
        vm.setEnv("HEALTH_REGISTRY_ADDRESS", vm.toString(REAL_HEALTH_REGISTRY));
        vm.setEnv("GUARDIAN_ADDRESS", vm.toString(REAL_GUARDIAN));
        // DO_SEAL left unset (false): test deployer isn't the real timelock,
        // and sealing isn't required to prove deploy/deposit readiness.
        // Explicit output path: an ambient .env with STRATEGY_OUTPUT_JSON= (blank)
        // would otherwise make vm.writeJson try to write to "", which reverts.
        vm.setEnv("STRATEGY_OUTPUT_JSON", "broadcast/fork-test-strategy-addresses.json");

        // ── "Deploy ready?" — run the REAL script against REAL core state ──
        DeployUsdcLendingStrategy deployScript = new DeployUsdcLendingStrategy();
        DeployUsdcLendingStrategy.DeploymentResult memory result = deployScript.run();

        console2.log("[DEPLOY READY] UsdcMultiLendingVault:", address(result.strategy));
        console2.log("[DEPLOY READY] 7 adapters + bootstrap + upkeep completed without revert");

        UsdcMultiLendingVault strategy = result.strategy;
        bytes32 CORE_ROLE = keccak256("CORE_ROLE");
        bytes32 BOOTSTRAP_ROLE = strategy.BOOTSTRAP_ROLE();

        assertTrue(strategy.hasRole(CORE_ROLE, REAL_VAULT), "REAL_VAULT must hold CORE_ROLE");
        assertTrue(strategy.hasRole(CORE_ROLE, REAL_STRATEGY_ROUTER), "REAL_STRATEGY_ROUTER must hold CORE_ROLE");
        assertFalse(strategy.hasRole(BOOTSTRAP_ROLE, result.bootstrapper), "BOOTSTRAP_ROLE must be renounced");
        assertEq(strategy.adapterCount(), 7, "all 7 adapters must be registered");
        assertFalse(strategy.paused(), "strategy must not be paused post-deploy");

        // Phase 2.6 (added after this test first caught the gap): the deploy
        // script now pokes external TVL + liquidity for all adapters itself,
        // briefly granting the deployer KEEPER_ROLE and revoking it right
        // after. Without this, cachedExternalTVL defaults to 0 on every
        // adapter -> CONFIDENCE_ZERO ("< 100K -- NO ALLOCATION") -> nothing
        // is allocatable -> the first deposit reverts with
        // BootstrapIdleTooHigh(). Confirm the deployer's KEEPER_ROLE grant
        // was cleaned up, not left behind.
        bytes32 KEEPER_ROLE = keccak256("KEEPER_ROLE");
        address testDeployerAddr = vm.addr(TEST_DEPLOYER_PK);
        assertFalse(
            strategy.hasRole(KEEPER_ROLE, testDeployerAddr),
            "deployer's temporary KEEPER_ROLE (used for the Phase 2.6 poke) must be revoked before the script finishes"
        );

        // ── "Deposit ready?" — real CoreVault pushes USDC in, calls deposit() ──
        // This must now succeed on the FIRST try, no manual poke required.
        deal(USDC, address(strategy), DEPOSIT_AMOUNT);
        vm.prank(REAL_VAULT);
        strategy.deposit(DEPOSIT_AMOUNT);

        uint256 totalAfter = strategy.totalAssets();
        uint256 idleAfter = strategy.idleCash();
        console2.log("[DEPOSIT READY] totalAssets after deposit:", totalAfter);
        console2.log("[DEPOSIT READY] idleCash after deposit:    ", idleAfter);

        assertGe(totalAfter, DEPOSIT_AMOUNT, "deposited capital must be accounted for");

        // Real capital must have actually moved into at least one real
        // external market -- not just sat idle in the strategy contract.
        assertLt(idleAfter, DEPOSIT_AMOUNT, "at least some capital must have been deployed, not left fully idle");

        uint256 deployedSum = totalAfter - idleAfter;
        console2.log("[DEPOSIT READY] capital actually deployed to real adapters:", deployedSum);
        assertGt(deployedSum, 0, "at least one real adapter must hold a nonzero position");

        console2.log("[VERDICT] Deploy ready: YES (real script completes end-to-end against live core system)");
        console2.log("[VERDICT] Deposit ready: YES (first deposit succeeds immediately post-deploy, no manual poke needed)");
    }
}
