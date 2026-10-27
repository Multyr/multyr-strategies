// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import { UsdcMultiLendingVaultTestBase, MockLendingAdapter } from "./UsdcMultiLendingVault.t.sol";
import { StrategySettingsModule } from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import { StrategyScoringModule } from "../../../src/strategies/usdc-lending/controller/StrategyScoringModule.sol";
contract StrictExposureCapTest is UsdcMultiLendingVaultTestBase {
    function testSmallVaultWithoutGlobalCeilingUsesSingleAdapterTier() public {
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setRebalanceParams(7,2,50,86400,80,0,500);
        assertEq(StrategyScoringModule(address(vault)).effectiveMaxAdaptersPerAllocation(), 1);
        assertLe(StrategyScoringModule(address(vault)).effectiveAbsCapBps(address(adapter1)), 10000);
    }
    function testSingleEligibleAdapterMayDeployFullSmallVaultWithoutReserveOrCeiling() public {
        _addAndEnableAdapter(adapter1);
        _prepareCache();
        vm.startPrank(admin);
        StrategySettingsModule(address(vault)).setRebalanceParams(7,2,50,86400,80,0,500);
        StrategySettingsModule(address(vault)).setMaxIdleAfterDepositBps(10000);
        vm.stopPrank();
        _mintAndTransferToVault(core,1000e6);
        vm.warp(block.timestamp + 301);
        vm.prank(keeper); StrategyScoringModule(address(vault)).deployIdle();
        assertGt(adapter1.totalAssets(), 0);
        assertEq(adapter1.totalAssets(), 1000e6);
    }
    function testSmallVaultCeilingDoesNotExpandTargetCountAndOverrideCannotBypassIt() public {
        vm.startPrank(admin);
        StrategySettingsModule(address(vault)).setRebalanceParams(7,2,50,86400,80,2500,500);
        MockLendingAdapter a = new MockLendingAdapter(ARBITRUM_USDC);
        StrategySettingsModule(address(vault)).setAdapterAbsCapOverride(address(a), 8000);
        vm.stopPrank();
        assertEq(StrategyScoringModule(address(vault)).effectiveMaxAdaptersPerAllocation(), 1);
        assertLe(StrategyScoringModule(address(vault)).effectiveAbsCapBps(address(a)), 2500);
    }
    function testSafetyFallbackCannotDepositAboveGlobalCeiling() public {
        _addAndEnableAdapter(adapter1);
        _prepareCache();
        vm.startPrank(admin);
        StrategySettingsModule(address(vault)).setRebalanceParams(7,2,50,86400,80,2500,500);
        StrategySettingsModule(address(vault)).addSafetyFallbackAdapter(address(adapter1),8000,1000);
        StrategySettingsModule(address(vault)).setMaxIdleBps(100);
        StrategySettingsModule(address(vault)).setMaxIdleAfterDepositBps(10000);
        vm.stopPrank();
        _mintAndTransferToVault(core,1000e6);
        vm.warp(block.timestamp + 301);
        vm.prank(keeper); StrategyScoringModule(address(vault)).deployIdle();
        assertGt(adapter1.totalAssets(), 0, "fallback must actually deposit");
        assertLe(adapter1.totalAssets(), 250e6, "fallback bypassed global ceiling");
    }
}
