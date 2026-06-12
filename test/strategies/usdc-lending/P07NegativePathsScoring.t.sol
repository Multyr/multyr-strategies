// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ═══════════════════════════════════════════════════════════════════════════════
// P07NegativePathsScoring.t.sol — E.8 diff branch coverage (2026-06-12)
// ───────────────────────────────────────────────────────────────────────────────
// Tests for guard branches in StrategyScoringModule._executeSafetyOverflow.
// Exercises 3 previously-uncovered skip-branches from E.7 analysis:
//   (1) nSafety == 0 → early return (L483)
//   (2) quarantined[a] → continue (L500)
//   (3) extTVL < 500_000e6 → continue (L506)
//
// Each test sets up conditions where the guard fires and verifies that
// no SafetyOverflowDeployed event was emitted for the guarded adapter.
//
// Run: forge test --match-contract P07NegativePathsScoring -vv
// ═══════════════════════════════════════════════════════════════════════════════

import { Vm } from "forge-std/Vm.sol";
import { CapDriftBase } from "./CapDriftMandate.t.sol";
import {
    StrategySettingsModule
} from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {
    StrategyScoringModule
} from "../../../src/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import {
    StrategyParamsModule
} from "../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";

contract P07NegativePathsScoring is CapDriftBase {

    // keccak256("SafetyOverflowDeployed(address,uint256,uint256,uint256)")
    bytes32 internal constant SAFETY_OVERFLOW_TOPIC =
        keccak256("SafetyOverflowDeployed(address,uint256,uint256,uint256)");

    // Mint idle directly into the vault (bypasses deposit auto-deploy cycle).
    // maxIdleBps = 500 → maxIdleAmt = 5% × TVL. With 200k idle and TVL 200k,
    // idle (200k) > maxIdleAmt (10k) → overflow path enters the loop.
    uint256 internal constant IDLE_SURPLUS = 200_000e6;

    function setUp() public {
        _deploy();
        // Enable safety overflow path (non-zero trigger threshold).
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setMaxIdleBps(500);
        // Mint USDC directly so no auto-deploy fires and vault holds idle.
        usdc.mint(address(vault), IDLE_SURPLUS);
    }

    /// @dev Check that no SafetyOverflowDeployed was emitted for any adapter.
    function _assertNoOverflowEmitted(Vm.Log[] memory logs) internal pure {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SAFETY_OVERFLOW_TOPIC) {
                revert("SafetyOverflowDeployed must NOT be emitted");
            }
        }
    }

    // ── Guard (1): nSafety == 0 ──────────────────────────────────────────────

    /// @notice When safetyFallbackAdapters is empty, _executeSafetyOverflow
    ///         returns immediately (L483) without any deposit.
    function test_overflow_skips_when_nSafety_zero() public {
        // No safety adapter registered — nSafety == 0.
        vm.warp(block.timestamp + 301);

        vm.recordLogs();
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();

        _assertNoOverflowEmitted(vm.getRecordedLogs());
    }

    // ── Guard (2): quarantined[a] ────────────────────────────────────────────

    /// @notice When the only safety adapter is quarantined, the loop
    ///         skips it (L500) and emits no SafetyOverflowDeployed.
    function test_overflow_skips_quarantined_adapter() public {
        vm.startPrank(admin);
        StrategySettingsModule(address(vault)).addSafetyFallbackAdapter(address(adapterA), 7000, 0);
        // Quarantine adapterA — overflow guard must skip it.
        StrategySettingsModule(address(vault)).setQuarantined(address(adapterA), true);
        vm.stopPrank();

        vm.warp(block.timestamp + 301);

        vm.recordLogs();
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();

        _assertNoOverflowEmitted(vm.getRecordedLogs());
    }

    // ── Guard (3): extTVL < 500_000e6 ───────────────────────────────────────

    /// @notice When the safety adapter's external TVL is below 500k USDC
    ///         (MICRO band), the loop skips it (L506) to prevent distorting
    ///         a shallow pool.
    function test_overflow_skips_below_extTVL_minimum_500k() public {
        vm.prank(admin);
        StrategySettingsModule(address(vault)).addSafetyFallbackAdapter(address(adapterA), 7000, 0);

        // Drop extTVL below the 500k USDC threshold.
        adapterA.setExtMarketTVL(499_999e6);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        vm.warp(block.timestamp + 301);

        vm.recordLogs();
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();

        _assertNoOverflowEmitted(vm.getRecordedLogs());
    }
}
