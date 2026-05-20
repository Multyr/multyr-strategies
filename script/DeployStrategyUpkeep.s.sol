// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { StrategyUpkeep } from "@multyr-strategies/strategies/usdc-lending/automation/LendingStrategyUpkeep.sol";

/**
 * @title DeployStrategyUpkeep
 * @notice Standalone redeploy of StrategyUpkeep (incident response / keeper migration).
 * @dev Use when the existing StrategyUpkeep is compromised or needs to be replaced
 *      without redeploying the full strategy.
 *
 * POST-DEPLOY MANUAL ACTIONS (timelock):
 *   1. strategy.grantRole(KEEPER_ROLE, newUpkeep)         — enable poke
 *   2. strategy.revokeRole(KEEPER_ROLE, oldUpkeep)        — disable old keeper
 *   3. Chainlink Automation: register new upkeep (5M gas limit recommended)
 *   4. Chainlink Automation: cancel old upkeep registration
 *
 * ENVIRONMENT VARIABLES
 *   DEPLOYER_PRIVATE_KEY   — required
 *   STRATEGY_ADDRESS       — existing UsdcMultiLendingVault address
 *
 * @custom:chain-id 42161
 */
contract DeployStrategyUpkeep is Script {
    function run() external returns (address upkeep) {
        require(block.chainid == 42161, "WRONG_CHAIN: DeployStrategyUpkeep is Arbitrum-only");

        uint256 pk       = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address strategy = vm.envAddress("STRATEGY_ADDRESS");

        require(strategy != address(0), "STRATEGY_ADDRESS is zero");

        vm.startBroadcast(pk);

        address[] memory strategies = new address[](1);
        strategies[0] = strategy;
        StrategyUpkeep keeper = new StrategyUpkeep(strategies);
        upkeep = address(keeper);

        vm.stopBroadcast();

        console.log("StrategyUpkeep deployed:", upkeep);
        console.log("Bound to strategy:      ", strategy);
        console.log("");
        console.log("ACTION REQUIRED (timelock):");
        console.log("  strategy.grantRole(KEEPER_ROLE, ", upkeep, ")");
    }
}
