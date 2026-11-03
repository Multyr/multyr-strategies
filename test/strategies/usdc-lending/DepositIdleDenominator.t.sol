// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {UsdcMultiLendingVaultTestBase} from "./UsdcMultiLendingVault.t.sol";
import {StrategySettingsModule} from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {NoCashInvariant} from "../../../src/strategies/usdc-lending/controller/StrategyStorageLayout.sol";

/// Controlled partial-deposit fault; not a real-market acceptance scenario.
contract DepositIdleDenominatorTest is UsdcMultiLendingVaultTestBase {
    function test_depositMustRejectIdleAboveActualPortfolioLimit() public {
        _setupAdaptersForRebalance();
        vm.prank(admin);
        StrategySettingsModule(address(vault)).exitBootstrapMode();
        adapter1.setPartialDepositBps(9200);
        adapter2.setPartialDepositBps(9200);
        adapter3.setPartialDepositBps(9200);
        assertFalse(vault.degradedModeActive());
        uint256 amount = 10_000_000e6;
        _mintAndTransferToVault(core, amount);
        assertEq(vault.totalAssets(), amount, "pre-transferred deposit already in actual NAV");
        assertEq(vault.idleCash(), amount);
        // All three healthy adapters retain 8% of their proposed deposits in
        // idle. Governance allows 5%; the actual NAV includes the transfer once.
        // Adding amount again incorrectly increases the allowance to 10%.
        vm.expectRevert(NoCashInvariant.selector);
        vm.prank(core);
        vault.deposit(amount);
    }
}
