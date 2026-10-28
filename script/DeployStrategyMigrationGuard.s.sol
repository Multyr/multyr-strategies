// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Script} from "forge-std/Script.sol";
import {StrategyMigrationGuard} from "../src/strategies/usdc-lending/gas/StrategyMigrationGuard.sol";

contract DeployStrategyMigrationGuard is Script {
    function run() external returns (StrategyMigrationGuard guard) {
        require(block.chainid == 42161, "ARBITRUM_ONLY");
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        guard = new StrategyMigrationGuard();
        vm.stopBroadcast();
    }
}
