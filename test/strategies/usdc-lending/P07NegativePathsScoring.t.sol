// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ═══════════════════════════════════════════════════════════════════════════════
// P07NegativePathsScoring.t.sol — E.8 + H-02 diff branch coverage (2026-06-13)
// ───────────────────────────────────────────────────────────────────────────────
// Tests for guard branches in StrategyScoringModule._executeSafetyOverflow.
//
// E.8 original (3 tests):
//   (1) nSafety == 0 → early return (L483)
//   (2) quarantined[a] → continue (L500)
//   (3) extTVL < 500_000e6 → continue (L506)
//
// H-02 additions (3 tests):
//   (4) extTVL < 500k → adapter skipped, next safety adapter receives deposit
//   (5) deposit reverts → adapter skipped, next safety adapter receives deposit,
//       accounting conserved (positionAssets unchanged for failing adapter)
//   (6) flagged[a] → adapter skipped, next safety adapter receives deposit
//
// Each E.8 test verifies no SafetyOverflowDeployed event emitted for the guarded adapter.
// Each H-02 test verifies: skipped adapter untouched, next adapter receives deposit.
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

    /// @dev Check that SafetyOverflowDeployed WAS emitted for `expected` adapter.
    function _assertOverflowEmittedFor(Vm.Log[] memory logs, address expected) internal pure {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SAFETY_OVERFLOW_TOPIC) {
                // topics[1] = adapter address (indexed)
                address emittedAdapter = address(uint160(uint256(logs[i].topics[1])));
                if (emittedAdapter == expected) return;
            }
        }
        revert("SafetyOverflowDeployed not emitted for expected adapter");
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

    // ── H-02 Guard (4): extTVL < 500k — next adapter receives deposit ────────

    /// @notice When adapterA has extTVL below 500k (guard L506), the overflow
    ///         skips adapterA and routes to adapterB (second safety adapter).
    ///
    ///         Event-based isolation: `SafetyOverflowDeployed` is the canonical
    ///         record of which adapter the OVERFLOW path deposited to. Checking
    ///         events rather than positionAssets isolates the overflow path from
    ///         the normal scoring deploy (which also runs and may allocate to
    ///         adapterA as a regular enabled adapter).
    ///
    ///         Verified: (a) overflow did NOT deposit to adapterA (no event for A),
    ///                   (b) overflow DID deposit to adapterB (event for B emitted).
    function test_safetyOverflow_skips_extTVL_below_500k_minimum() public {
        vm.startPrank(admin);
        StrategySettingsModule(address(vault)).addSafetyFallbackAdapter(address(adapterA), 7000, 0);
        StrategySettingsModule(address(vault)).addSafetyFallbackAdapter(address(adapterB), 7000, 0);
        vm.stopPrank();

        // adapterA has shallow extTVL — overflow guard L506 must skip it.
        adapterA.setExtMarketTVL(400_000e6);
        // adapterB remains deep (500M default from setUp).

        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        vm.warp(block.timestamp + 301);

        vm.recordLogs();
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Guard L506 must have skipped adapterA — no SafetyOverflowDeployed for A.
        // (Normal scoring path may have allocated to adapterA; that's irrelevant —
        //  the OVERFLOW guard is what this test exercises.)
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SAFETY_OVERFLOW_TOPIC) {
                address emitted = address(uint160(uint256(logs[i].topics[1])));
                assertNotEq(emitted, address(adapterA),
                    "adapterA must NOT receive SafetyOverflowDeployed: extTVL below 500k guard");
            }
        }

        // adapterB must have received the overflow deposit.
        _assertOverflowEmittedFor(logs, address(adapterB));
    }

    // ── H-02 Guard (5): deposit revert — next adapter receives deposit ────────

    /// @notice When adapterA's deposit() reverts (guard L525), the overflow
    ///         catches the failure, records it, and falls through to adapterB.
    ///         Accounting invariant: positionAssets[adapterA] unchanged.
    function test_safetyOverflow_handles_deposit_revert() public {
        vm.startPrank(admin);
        StrategySettingsModule(address(vault)).addSafetyFallbackAdapter(address(adapterA), 7000, 0);
        StrategySettingsModule(address(vault)).addSafetyFallbackAdapter(address(adapterB), 7000, 0);
        vm.stopPrank();

        // Make adapterA's deposit() revert.
        adapterA.setDepositReverts(true);

        vm.warp(block.timestamp + 301);

        uint256 posA_before = vault.positionAssets(address(adapterA));
        uint256 posB_before = vault.positionAssets(address(adapterB));

        vm.recordLogs();
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Accounting conserved for failing adapter: positionAssets must not increase.
        assertEq(vault.positionAssets(address(adapterA)), posA_before,
            "positionAssets[adapterA] must be unchanged after deposit revert");

        // Overflow fell through to adapterB.
        assertGt(vault.positionAssets(address(adapterB)), posB_before,
            "adapterB must receive overflow deposit after adapterA deposit failure");

        // Only adapterB emits SafetyOverflowDeployed.
        _assertOverflowEmittedFor(logs, address(adapterB));
    }

    // ── H-02 Guard (6): flagged[a] → adapter skipped ─────────────────────────

    /// @notice When adapterA is flagged (guard L499), the overflow loop skips it
    ///         and routes to adapterB (next safety adapter).
    ///         Verifies: flagged adapter untouched, next adapter receives deposit.
    function test_safetyOverflow_skips_flagged_adapter() public {
        vm.startPrank(admin);
        StrategySettingsModule(address(vault)).addSafetyFallbackAdapter(address(adapterA), 7000, 0);
        StrategySettingsModule(address(vault)).addSafetyFallbackAdapter(address(adapterB), 7000, 0);
        // Flag adapterA — this marks it as degraded but not quarantined.
        StrategySettingsModule(address(vault)).setFlaggedAdapter(address(adapterA), true);
        vm.stopPrank();

        vm.warp(block.timestamp + 301);

        uint256 posA_before = vault.positionAssets(address(adapterA));
        uint256 posB_before = vault.positionAssets(address(adapterB));

        vm.recordLogs();
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Flagged adapter must be skipped.
        assertEq(vault.positionAssets(address(adapterA)), posA_before,
            "adapterA must be skipped: flagged state blocks overflow deposit");

        // adapterB receives the deposit.
        assertGt(vault.positionAssets(address(adapterB)), posB_before,
            "adapterB must receive overflow deposit when adapterA is flagged");

        _assertOverflowEmittedFor(logs, address(adapterB));
    }
}
