// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { AdapterFactory } from "../src/strategies/usdc-lending/factory/AdapterFactory.sol";

/// @title DeployAdapterFactory
/// @notice Per-chain deployment of AdapterFactory.
/// @dev AdapterFactory is the single chain-specific contract in the V10 deployment stack.
///      All adapter deployments on a given chain go through this factory via deployAndInit().
///      See script/MULTI_CHAIN_PLAYBOOK.md for the full deployment sequence.
///
/// ENVIRONMENT VARIABLES
///   MULTYR_TIMELOCK_ADMIN  — required: timelock or multisig address that will own the factory
///   DEPLOYER_PRIVATE_KEY   — required: deployer key (does NOT need to equal TIMELOCK_ADMIN)
///
/// POST-DEPLOY: verify factory ownership via factory.hasRole(DEFAULT_ADMIN_ROLE, admin).
///
/// V10.0 storage+initialize pattern: only this script is chain-specific.
/// All adapter bytecode is chain-agnostic (no chain-specific immutables).
contract DeployAdapterFactory is Script {
    function run() external returns (address factory_) {
        address admin = vm.envAddress("MULTYR_TIMELOCK_ADMIN");
        require(admin != address(0), "MULTYR_TIMELOCK_ADMIN env required");

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        console.log("=== AdapterFactory Deployment ===");
        console.log("Chain ID:  ", block.chainid);
        console.log("Admin:     ", admin);

        vm.startBroadcast(pk);
        AdapterFactory factory = new AdapterFactory(admin);
        factory_ = address(factory);
        vm.stopBroadcast();

        console.log("AdapterFactory:", factory_);
        console.log("");
        console.log("NEXT STEPS - see script/MULTI_CHAIN_PLAYBOOK.md:");
        console.log("  1. Record factory address in deployments/<chainId>/AdapterFactory.json");
        console.log("  2. Use factory.deployAndInit() for each adapter deployment");
        console.log("  3. Verify bytecode hash matches Arbitrum reference");
    }
}
