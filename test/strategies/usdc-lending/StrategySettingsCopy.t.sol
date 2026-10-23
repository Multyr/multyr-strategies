// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UsdcMultiLendingVaultTestBase, MockLendingAdapter} from "./UsdcMultiLendingVault.t.sol";
import {UsdcMultiLendingVault as Strategy} from "../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
import {StrategySettingsModule as Settings} from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {StrategySettingsCopy as Copy} from "../../../script/StrategySettingsCopy.sol";

contract StrategySettingsCopyTest is UsdcMultiLendingVaultTestBase {
    function replacement(address source) internal returns (Strategy next) {
        next = new Strategy(ARBITRUM_USDC, core, router, admin, admin, address(0),
            vault.paramsModule(), vault.scoringModule(), vault.adapterOpsModule(),
            vault.rebalanceGateModule_addr(), Copy.initParams(source));
        address settings = vault.settingsModule_addr();
        vm.prank(admin);
        next.setSettingsModule(settings);
    }

    function test_preservesConstructorAndNonDefaultSettingsIncludingRegime() public {
        vm.startPrank(admin);
        Settings(address(vault)).setDustTolerance(3000);
        Settings(address(vault)).setHysteresisParams(18000, 250, 100, 1234e6);
        Settings(address(vault)).setLiquidityStalenessSeconds(7200);
        Settings(address(vault)).setMaxRebalanceActionsPerTx(3);
        Settings(address(vault)).setCoordinationParams(2500, 2 days, 8000);
        Settings(address(vault)).setScoringStalenessParams(7200, 2 days);
        Settings(address(vault)).setDepositsDisabled(true);
        vm.stopPrank();
        vm.prank(keeper);
        Settings(address(vault)).setRegime(2);
        vm.prank(admin);
        Settings(address(vault)).setRegimeParams(2, 18000, 20000, 14, 7500);
        Strategy next = replacement(address(vault));
        bytes32 beforeHash = Copy.globals(address(vault), address(0), false);
        vm.startPrank(admin);
        assertEq(Copy.globals(address(vault), address(next), true), beforeHash);
        vm.stopPrank();
        assertEq(Copy.globals(address(vault), address(next), false), beforeHash);
        Copy.verifyInit(address(vault), address(next));
        assertEq(next.currentRegime(), 2);
        assertTrue(next.depositsDisabled());
        assertEq(next.regimeConfidenceMultBps(), 7500);
    }

    function test_zeroDefaultsArePreservedWithoutCallingRejectingSetters() public {
        Strategy next = replacement(address(vault));
        assertEq(vault.liquidityStalenessSeconds(), 0);
        vm.startPrank(admin);
        Copy.globals(address(vault), address(next), true);
        vm.stopPrank();
        assertEq(next.liquidityStalenessSeconds(), 0);
        Copy.verifyInit(address(vault), address(next));
    }

    function test_parityRejectsChangedTarget() public {
        Strategy next = replacement(address(vault));
        vm.prank(admin);
        Settings(address(next)).setMaxIdleBps(321);
        vm.expectRevert(abi.encodeWithSelector(Copy.ParityFailed.selector, "setMaxIdleBps(uint16)"));
        this.checkParity(address(vault), address(next));
    }

    function checkParity(address source, address target) external {
        Copy.globals(source, target, false);
    }

    function test_adapterControlsAndOrderedFallbackAreMapped() public {
        _addAndEnableAdapter(adapter1);
        _addAndEnableAdapter(adapter2);
        vm.startPrank(admin);
        Settings(address(vault)).setAdapterAbsCapOverride(address(adapter1), 4200);
        Settings(address(vault)).setRiskScore(address(adapter1), 3333);
        Settings(address(vault)).addSafetyFallbackAdapter(address(adapter2), 6000, 1000);
        Settings(address(vault)).setFlaggedAdapter(address(adapter1), true);
        Settings(address(vault)).setQuarantined(address(adapter2), true);
        vault.toggleAdapter(address(adapter2), false);
        vm.stopPrank();
        Strategy next = replacement(address(vault));
        MockLendingAdapter a = new MockLendingAdapter(ARBITRUM_USDC);
        MockLendingAdapter b = new MockLendingAdapter(ARBITRUM_USDC);
        a.setVault(address(next)); b.setVault(address(next));
        vm.startPrank(admin);
        Settings(address(next)).whitelistAdapter(address(a), true);
        Settings(address(next)).whitelistAdapter(address(b), true);
        next.addAdapter(address(a)); next.toggleAdapter(address(a), true);
        next.addAdapter(address(b)); next.toggleAdapter(address(b), true);
        Copy.copyAdapters(address(vault), address(next));
        vm.stopPrank();
        Copy.verifyAdapters(address(vault), address(next));
        assertEq(next.adapterAbsCapOverrideBps(address(a)), 4200);
        assertEq(next.riskScoreBps(address(a)), 3333);
        assertEq(next.safetyFallbackAdapters(0), address(b));
        assertTrue(next.flagged(address(a)));
        assertTrue(next.quarantined(address(b)));
        assertFalse(next.enabled(address(b)));
    }

    function test_expiredBootstrapDoesNotRestart() public {
        vm.warp(vault.bootstrapEndsAt() + 1 days);
        Strategy next = replacement(address(vault));
        assertFalse(next.isBootstrapActive());
        assertEq(next.bootstrapEndsAt(), 0);
        Copy.verifyInit(address(vault), address(next));
    }

    function test_liveConfigurationCanBeCopiedOnPinnedFork() public {
        if (!vm.envOr("RUN_ROUTER_HARVEST_FORK", false)) { vm.skip(true); return; }
        // Persist the local fixture modules; only source configuration is read from the fork.
        vm.makePersistent(address(vault));
        vm.makePersistent(vault.paramsModule());
        vm.makePersistent(vault.scoringModule());
        vm.makePersistent(vault.adapterOpsModule());
        vm.makePersistent(vault.rebalanceGateModule_addr());
        vm.makePersistent(vault.settingsModule_addr());
        vm.createSelectFork(vm.envString("ROUTER_HARVEST_RPC"), vm.envUint("ROUTER_HARVEST_BLOCK"));
        address source = 0x7bF0f446BB20b54597E66a602cB94D0F231D24E2;
        Strategy next = replacement(source);
        vm.startPrank(admin);
        Copy.globals(source, address(next), true);
        vm.stopPrank();
        Copy.globals(source, address(next), false);
        Copy.verifyInit(source, address(next));
    }
}
