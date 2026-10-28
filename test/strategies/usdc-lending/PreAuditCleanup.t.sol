// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {UsdcMultiLendingVault} from "../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";

import {UsdcMultiLendingVaultTestBase} from "./UsdcMultiLendingVault.t.sol";
import {
    StrategySettingsModule
} from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {
    StrategyScoringModule
} from "../../../src/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import {
    StrategyExplainabilityLens
} from "../../../src/strategies/usdc-lending/lens/StrategyExplainabilityLens.sol";
import {
    ParamOutOfRange
} from "../../../src/strategies/usdc-lending/controller/StrategyStorageLayout.sol";

contract ExposedTierLens is StrategyExplainabilityLens {
    constructor(address s) StrategyExplainabilityLens(s) {}

    function tiers(uint256 tvl) external view returns (uint16, uint256) {
        return (_effectiveMaxAdapters(tvl), _effectiveMinNewAdapterSeed(tvl));
    }
}

contract PreAuditCleanupTest is UsdcMultiLendingVaultTestBase {
    function test_lensMatchesStrategyAtEveryTierBoundary() public {
        ExposedTierLens lens = new ExposedTierLens(address(vault));
        uint256[6] memory boundaries =
            [uint256(0), 25_000e6, 250_000e6, 1_000_000e6, 5_000_000e6, 25_000_000e6];
        for (uint256 i; i < boundaries.length; ++i) {
            for (uint256 j; j < 3; ++j) {
                uint256 tvl = boundaries[i] + j;
                if (i > 0) tvl -= 1;
                deal(ARBITRUM_USDC, address(vault), tvl);
                (uint16 count, uint256 seed) = lens.tiers(tvl);
                assertEq(
                    count, StrategyScoringModule(address(vault)).effectiveMaxAdaptersPerAllocation()
                );
                assertEq(seed, StrategyScoringModule(address(vault)).effectiveMinNewAdapterSeed());
                uint16 expected = tvl < 25_000e6
                    ? 1
                    : tvl < 250_000e6 ? 2 : tvl < 1_000_000e6 ? 3 : tvl < 5_000_000e6 ? 4 : 5;
                uint16 cap = vault.maxAdaptersPerAllocation();
                if (cap > 0 && cap < expected) expected = cap;
                assertEq(count, expected);
            }
        }
    }

    function test_constructorRejectsDeprecatedDiversificationFloor() public {
        defaultParams.minAdaptersActive = 2;
        address params = vault.paramsModule();
        address scoring = vault.scoringModule();
        address ops = vault.adapterOpsModule();
        address gate = vault.rebalanceGateModule_addr();
        vm.expectRevert(ParamOutOfRange.selector);
        new UsdcMultiLendingVault(ARBITRUM_USDC, core, router, admin, keeper, address(0),
            params, scoring, ops, gate, defaultParams);
    }

    function test_deprecatedControlsRejectNonNeutralValues() public {
        StrategySettingsModule settings = StrategySettingsModule(address(vault));
        vm.startPrank(admin);
        vm.expectRevert(ParamOutOfRange.selector);
        settings.setHysteresisParams(0, 500, 1, 0);
        vm.expectRevert(ParamOutOfRange.selector);
        settings.setCoordinationParams(0, 0, 1);
        vm.expectRevert(ParamOutOfRange.selector);
        settings.setRegimeParams(0, 9999, 10000, 30, 10000);
        vm.expectRevert(ParamOutOfRange.selector);
        settings.setRegimeParams(0, 10000, 10001, 30, 10000);
        settings.setRebalanceParams(1, 1, 50, 86400, 80, 5000, 500);
        vm.stopPrank();
        assertEq(StrategyScoringModule(address(vault)).effectiveMaxAdaptersPerAllocation(), 1);
    }
}
