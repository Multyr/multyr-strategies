// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UsdcMultiLendingVaultTestBase} from "./UsdcMultiLendingVault.t.sol";
import {StrategySettingsModule} from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {StrategyScoringModule} from "../../../src/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import {StrategyExplainabilityLens} from "../../../src/strategies/usdc-lending/lens/StrategyExplainabilityLens.sol";

contract LendingLensCapParityTest is UsdcMultiLendingVaultTestBase {
    function test_lensUsesDynamicCapWhenGovernanceCeilingIsZero() public {
        _setupAdaptersForRebalance();
        _mintAndTransferToVault(core, 1000e6);
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setRebalanceParams(3, 1, 50, 21600, 80, 0, 5000);
        _assertCaps();
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setRiskScore(address(adapter1), 2000);
        _assertCaps();
    }

    function _assertCaps() internal {
        StrategyExplainabilityLens lens = new StrategyExplainabilityLens(address(vault));
        (StrategyExplainabilityLens.AdapterAllocationInfo[] memory infos,,) = lens.explainAllocation(0);
        assertEq(infos.length, 3);
        for (uint256 i; i < infos.length; ++i) {
            uint256 expected = uint256(StrategyScoringModule(address(vault)).effectiveAbsCapBps(infos[i].adapter)) * vault.totalAssets() / 10000;
            assertGt(expected, 0);
            assertEq(infos[i].maxExposure, expected);
        }
    }
}
