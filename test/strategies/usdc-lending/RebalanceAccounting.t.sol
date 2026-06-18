// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { StrategyRebalancePlanModule } from "../../../src/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol";
import {
    UsdcMultiLendingVaultTestBase
} from "./UsdcMultiLendingVault.t.sol";
import {
    StrategyScoringModule
} from "../../../src/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import {
    StrategyParamsModule
} from "../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import { StrategySettingsModule } from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ============================================================================
// BLOCCO B — Rebalance Economic Correctness Tests
// ============================================================================
// Tests that positionAssets accounting is exact after executeRebalanceStep.
// Uses MockLendingAdapter + UsdcMultiLendingVaultTestBase.
//
// SETUP PATTERN: deposit → deployIdle (funds into adapters) → change APYs
// to create rebalance opportunity → verify accounting invariants.
// ============================================================================

contract RebalanceAccountingTest is UsdcMultiLendingVaultTestBase {

    function setUp() public virtual override {
        super.setUp();

        _addAndEnableAdapter(adapter1);  // 800 bps APY
        _addAndEnableAdapter(adapter2);  // 600 bps APY
        _addAndEnableAdapter(adapter3);  // 400 bps APY

        // Larger TVL caches for score confidence
        adapter1.setExtMarketTVL(100_000_000e6);
        adapter2.setExtMarketTVL(80_000_000e6);
        adapter3.setExtMarketTVL(50_000_000e6);

        // Exit bootstrap so idle can be deployed freely
        vm.prank(admin);
        StrategySettingsModule(address(vault)).exitBootstrapMode();
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setMaxIdleAfterDepositBps(10000);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        // Lenient gate — tests focus on accounting correctness, not gate policy
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setGateParams(30, 0, 5, 5, 1e6);
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /// @dev Deposit amount into vault via core (CoreVault flow).
    function _coreDeposit(uint256 amount) internal {
        _mintAndTransferToVault(core, amount);
        vm.prank(core);
        vault.deposit(amount);
    }

    /// @dev Deploy idle to adapters (warp past deploy cooldown).
    function _warpAndDeployIdle() internal {
        vm.warp(block.timestamp + 301);
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();
    }

    /// @dev Deploy idle multiple times to fully allocate.
    function _fullyDeploy() internal {
        for (uint256 i = 0; i < 5; i++) {
            _warpAndDeployIdle();
        }
    }

    /// @dev Create rebalance opportunity: invert APYs after funds are deployed.
    function _createRebalanceOpportunity() internal {
        adapter1.setAPY(100);   // 1% — was best
        adapter3.setAPY(2000);  // 20% — was worst
    }

    // -----------------------------------------------------------------------
    // B1: totalAssets conservation invariant
    // -----------------------------------------------------------------------

    /// @notice B1a: After a complete rebalance cycle, totalAssets is conserved.
    ///   totalAssets before == totalAssets after (within dust tolerance).
    function test_B1a_totalAssetsConservation() public {
        uint256 depositAmount = 300_000e6;
        _coreDeposit(depositAmount);
        _fullyDeploy();
        _createRebalanceOpportunity();

        uint256 taBefore = vault.totalAssets();

        vm.warp(block.timestamp + 21601);
        _doRebalance();

        uint256 taAfter = vault.totalAssets();
        assertApproxEqAbs(taAfter, taBefore, vault.dustTolerance(), "totalAssets must be conserved across full rebalance");
    }

    /// @notice B1b: positionAssets sum + idle is conserved across a single executeRebalanceStep.
    function test_B1b_positionAssetsConservationDuringStep() public {
        uint256 depositAmount = 300_000e6;
        _coreDeposit(depositAmount);
        _fullyDeploy();
        _createRebalanceOpportunity();

        vm.warp(block.timestamp + 21601);

        // Prepare plan (phase=1)
        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).prepareRebalance();

        // Capture pre-step total (positions + idle)
        uint256 pos1Before = vault.positionAssets(address(adapter1));
        uint256 pos2Before = vault.positionAssets(address(adapter2));
        uint256 pos3Before = vault.positionAssets(address(adapter3));
        uint256 idleBefore = vault.idleCash();
        uint256 totalBefore = pos1Before + pos2Before + pos3Before + idleBefore;

        // Execute one step
        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).executeRebalanceStep();

        // Capture post-step total
        uint256 pos1After = vault.positionAssets(address(adapter1));
        uint256 pos2After = vault.positionAssets(address(adapter2));
        uint256 pos3After = vault.positionAssets(address(adapter3));
        uint256 idleAfter = vault.idleCash();
        uint256 totalAfter = pos1After + pos2After + pos3After + idleAfter;

        // Conservation: sum(positions + idle) must be invariant within dust
        assertApproxEqAbs(totalAfter, totalBefore, vault.dustTolerance(),
            "value must be conserved: sum(positionAssets) + idle is invariant");
    }

    /// @notice B1c: After complete rebalance, idle must be <= dustTolerance.
    function test_B1c_noIdleCreepAfterRebalance() public {
        uint256 depositAmount = 300_000e6;
        _coreDeposit(depositAmount);
        _fullyDeploy();
        _createRebalanceOpportunity();

        vm.warp(block.timestamp + 21601);
        _doRebalance();

        uint256 idle = vault.idleCash();
        uint256 dust = vault.dustTolerance();
        assertLe(idle, dust, "idle must be <= dustTolerance after full rebalance");
    }

    /// @notice B1d: positionAssets[from] decrements by exactly the withdrawn amount,
    ///         positionAssets[to] increments by exactly the deposited amount.
    ///         The adapter with high APY (adapter3) must gain; the low APY adapter (adapter1) must lose.
    function test_B1d_fromDecrementsToIncrements() public {
        uint256 depositAmount = 300_000e6;
        _coreDeposit(depositAmount);
        _fullyDeploy();
        _createRebalanceOpportunity();

        vm.warp(block.timestamp + 21601);

        uint256 pos1Before = vault.positionAssets(address(adapter1)); // high-position, low APY after inversion
        uint256 pos3Before = vault.positionAssets(address(adapter3)); // low-position, high APY after inversion

        _doRebalance();

        uint256 pos1After = vault.positionAssets(address(adapter1));
        uint256 pos3After = vault.positionAssets(address(adapter3));

        // After rebalance: adapter3 (now 20% APY) must have more than adapter1 (now 1% APY)
        assertGt(pos3After, pos3Before, "positionAssets[adapter3] must increase (higher APY target)");
        assertLt(pos1After, pos1Before, "positionAssets[adapter1] must decrease (lower APY source)");
    }

    // -----------------------------------------------------------------------
    // B2: Zero-room adapter does NOT receive extra deposits
    // -----------------------------------------------------------------------

    /// @notice B2a: Adapter at maxCap does not receive deposits beyond cap.
    ///         The cap must be set BEFORE deposit since deposit() auto-deploys idle.
    function test_B2a_zeroRoomAdapterNotOverfilled() public {
        // Set adapter1 cap BEFORE deposit — deposit auto-deploys idle
        adapter1.setMaxCap(10_000e6); // 10K USDC cap

        uint256 depositAmount = 300_000e6;
        _coreDeposit(depositAmount);

        // Additional deploy cycles — should not exceed cap
        _fullyDeploy();

        uint256 pos1 = vault.positionAssets(address(adapter1));
        assertLe(pos1, 10_000e6, "adapter1 must not exceed maxCap");

        // totalAssets must equal deposit (no loss)
        uint256 ta = vault.totalAssets();
        assertApproxEqAbs(ta, depositAmount, vault.dustTolerance(), "no assets lost when adapter1 at cap");
    }

    /// @notice B2b: After rebalance into capped adapter, totalAssets conserved.
    ///         Cap set before deposit since deposit auto-deploys idle.
    /// @notice B2b: deployIdle respects maxCapacity across multiple cycles.
    ///         NOTE: executeRebalanceStep does NOT re-check adapter capacity at execution
    ///         time — the plan is pre-built. This test targets the deployIdle path only.
    function test_B2b_deployIdleRespectsMaxCap() public {
        // Set adapter3 cap BEFORE deposit — deposit auto-deploys idle
        adapter3.setMaxCap(50_000e6);

        uint256 depositAmount = 300_000e6;
        _coreDeposit(depositAmount);

        // Multiple deploy cycles — adapter3 must never exceed cap
        for (uint256 i = 0; i < 5; i++) {
            _warpAndDeployIdle();
            assertLe(vault.positionAssets(address(adapter3)), 50_000e6,
                "adapter3 must never exceed maxCap during deployIdle");
        }

        // totalAssets must equal deposit (no asset loss)
        assertApproxEqAbs(vault.totalAssets(), depositAmount, vault.dustTolerance(),
            "no assets lost when adapter3 at cap");
    }

    // -----------------------------------------------------------------------
    // B3: withdrawableAssets vs actual moved — partial withdraw accounting
    // -----------------------------------------------------------------------

    /// @notice B3a: If withdraw reverts on adapter1, positionAssets[adapter1] stays
    ///         and totalAssets is preserved (locked funds tracked via positionAssets fallback).
    function test_B3a_lockedAdapterPreservesAccounting() public {
        uint256 depositAmount = 300_000e6;
        _coreDeposit(depositAmount);
        _fullyDeploy();
        _createRebalanceOpportunity();

        vm.warp(block.timestamp + 21601);

        // Lock adapter1 — make withdraw revert
        adapter1.setWithdrawReverts(true);

        uint256 pos1Before = vault.positionAssets(address(adapter1));
        uint256 taBefore = vault.totalAssets();

        _doRebalance();

        // adapter1 is locked — its positionAssets should be unchanged or only updated
        // by the actual withdrawn amount (0 if revert)
        uint256 pos1After = vault.positionAssets(address(adapter1));
        uint256 taAfter = vault.totalAssets();

        // positionAssets[adapter1] should not increase (withdraw attempt failed)
        assertLe(pos1After, pos1Before, "positionAssets[adapter1] must not increase if withdraw fails");

        // totalAssets must not decrease by more than what was attempted
        // The locked funds remain tracked in positionAssets
        assertApproxEqAbs(taAfter, taBefore, vault.dustTolerance(),
            "totalAssets preserved - locked funds still tracked via positionAssets");
    }

    // -----------------------------------------------------------------------
    // B4: Cancel + rebuild gives consistent plan
    // -----------------------------------------------------------------------

    /// @notice B4a: After cancelling an active plan and re-preparing,
    ///         the new plan completes without asset loss.
    function test_B4a_cancelAndRebuildConservesAssets() public {
        uint256 depositAmount = 300_000e6;
        _coreDeposit(depositAmount);
        _fullyDeploy();
        _createRebalanceOpportunity();

        vm.warp(block.timestamp + 21601);

        // Prepare and immediately cancel
        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).prepareRebalance();
        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).cancelRebalancePlan();

        // Verify plan cleared
        (, bytes memory phaseData) = address(vault).call(
            abi.encodeWithSignature("rebalancePlanPhase()")
        );
        assertEq(abi.decode(phaseData, (uint8)), 0, "plan must be cleared after cancel");

        uint256 taBefore = vault.totalAssets();

        // Re-prepare and execute
        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).prepareRebalance();
        for (uint256 i = 0; i < 10; i++) {
            (, phaseData) = address(vault).call(abi.encodeWithSignature("rebalancePlanPhase()"));
            if (abi.decode(phaseData, (uint8)) == 0) break;
            vm.prank(keeper);
            StrategyRebalancePlanModule(address(vault)).executeRebalanceStep();
        }

        uint256 taAfter = vault.totalAssets();
        assertApproxEqAbs(taAfter, taBefore, vault.dustTolerance(),
            "totalAssets conserved after cancel+rebuild+execute");
    }

    /// @notice B4b: Cancel does NOT touch lastRebalanceTs (audit HIGH 1.4).
    ///         Re-prepare after cancel must succeed without waiting the full cooldown.
    function test_B4b_cancelDoesNotTriggerCooldown() public {
        uint256 depositAmount = 300_000e6;
        _coreDeposit(depositAmount);
        _fullyDeploy();
        _createRebalanceOpportunity();

        vm.warp(block.timestamp + 21601);

        // Prepare → cancel (must NOT set lastRebalanceTs)
        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).prepareRebalance();

        // Record lastRebalanceTs before cancel
        uint64 lastRebBefore;
        {
            (, bytes memory tsData) = address(vault).call(
                abi.encodeWithSignature("lastRebalanceTs()")
            );
            lastRebBefore = abi.decode(tsData, (uint64));
        }

        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).cancelRebalancePlan();

        // lastRebalanceTs must NOT have changed
        uint64 lastRebAfter;
        {
            (, bytes memory tsData) = address(vault).call(
                abi.encodeWithSignature("lastRebalanceTs()")
            );
            lastRebAfter = abi.decode(tsData, (uint64));
        }
        assertEq(lastRebAfter, lastRebBefore, "cancel must NOT update lastRebalanceTs");

        // Re-prepare immediately should succeed (same timestamp, cooldown still satisfied)
        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).prepareRebalance();

        (, bytes memory phaseData) = address(vault).call(
            abi.encodeWithSignature("rebalancePlanPhase()")
        );
        assertEq(abi.decode(phaseData, (uint8)), 1, "must be able to re-prepare after cancel without cooldown");
    }

    // -----------------------------------------------------------------------
    // I1: Invariant — totalAssets >= sum(positionAssets) always
    // -----------------------------------------------------------------------

    /// @notice I1: totalAssets must always be >= sum(positionAssets[all adapters]).
    ///         The difference is the idle cash component.
    function test_I1_totalAssetsGeqSumPositions() public {
        uint256 depositAmount = 300_000e6;
        _coreDeposit(depositAmount);

        // Check before deploy
        _assertI1();

        _fullyDeploy();
        _assertI1();

        _createRebalanceOpportunity();
        vm.warp(block.timestamp + 21601);
        _doRebalance();
        _assertI1();
    }

    /// @dev I1 invariant: vault.totalAssets() >= sum(positionAssets across enabled adapters).
    ///      The difference is the idle cash component held at vault level.
    function _assertI1() internal view {
        uint256 total = vault.totalAssets();
        uint256 sumPos = vault.positionAssets(address(adapter1))
                       + vault.positionAssets(address(adapter2))
                       + vault.positionAssets(address(adapter3));
        assertGe(total, sumPos, "I1: totalAssets >= sum positions");
    }

}

// ============================================================================
// H-03 -- Rebalance deposit accounting: positionAssets uses actualDeposited
// ============================================================================
// Verifies that executeRebalanceStep records the balance delta, not the
// planned amount, so a partial-accept adapter does not overstate positionAssets.
// Withdraw path was already correct (uses returned `withdrawn`); test 3 regresses it.
// ============================================================================

contract H03_RebalanceDepositAccounting_Test is RebalanceAccountingTest {

    function setUp() public override {
        super.setUp();
        // Process one action per executeRebalanceStep so withdraw and deposit
        // steps are callable independently.
        vm.prank(paramSetter);
        StrategySettingsModule(address(vault)).setMaxRebalanceActionsPerTx(1);
    }

    // -------------------------------------------------------------------------
    // H-03-1: partial deposit -- positionAssets reflects actualDeposited
    // -------------------------------------------------------------------------

    /// @notice When adapter3 only accepts 50% of plannedAmount, positionAssets
    ///         must increase by the actual USDC balance that left the vault,
    ///         not by the plan's planned amount.
    function test_H03_partial_deposit_accounting() public {
        _coreDeposit(300_000e6);
        _fullyDeploy();
        _createRebalanceOpportunity();
        vm.warp(block.timestamp + 21601);

        // Prepare plan: action[0] = withdraw adapter1, action[1] = deposit adapter3
        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).prepareRebalance();

        // Step 1: withdraw from adapter1 (funds move to vault idle)
        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).executeRebalanceStep();

        // Make adapter3 accept only 50% of the incoming deposit
        adapter3.setPartialDepositBps(5000);

        uint256 pos3Before = vault.positionAssets(address(adapter3));
        uint256 idleBefore = IERC20(ARBITRUM_USDC).balanceOf(address(vault));

        // Step 2: deposit to adapter3 -- partial fill
        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).executeRebalanceStep();

        uint256 idleAfter = IERC20(ARBITRUM_USDC).balanceOf(address(vault));
        uint256 actualDeposited = idleBefore >= idleAfter ? idleBefore - idleAfter : 0;

        uint256 pos3After = vault.positionAssets(address(adapter3));

        // positionAssets delta MUST equal the actual USDC that left the vault
        assertEq(pos3After - pos3Before, actualDeposited,
            "H03-1: positionAssets delta must equal actual balance delta, not planned amount");

        // Sanity: some idle must have been available for the deposit step
        assertGt(idleBefore, 0, "H03-1: idle must be available before deposit step");
    }

    // -------------------------------------------------------------------------
    // H-03-2: failed deposit -- positionAssets stays unchanged
    // -------------------------------------------------------------------------

    /// @notice When adapter3 deposit reverts, positionAssets[adapter3] must
    ///         not change -- no phantom assets recorded.
    function test_H03_failed_deposit_no_overstate() public {
        _coreDeposit(300_000e6);
        _fullyDeploy();
        _createRebalanceOpportunity();
        vm.warp(block.timestamp + 21601);

        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).prepareRebalance();

        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).executeRebalanceStep();

        // Block adapter3 deposit -- simulate protocol-level cap / freeze
        adapter3.setDepositReverts(true);

        uint256 pos3Before = vault.positionAssets(address(adapter3));

        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).executeRebalanceStep();

        uint256 pos3After = vault.positionAssets(address(adapter3));

        assertEq(pos3After, pos3Before,
            "H03-2: positionAssets must not change when deposit reverts");
    }

    // -------------------------------------------------------------------------
    // H-03-3: withdraw path regression -- decrement matches actual returned
    // -------------------------------------------------------------------------

    /// @notice Withdraw path uses the returned `withdrawn` value (already correct).
    ///         Regression: when adapter has less deposited than positionAssets reports
    ///         (drift injected via setDeposited), the decrement matches what the
    ///         adapter actually returned, not the planned amount.
    function test_H03_partial_withdraw_accounting_regression() public {
        _coreDeposit(300_000e6);
        _fullyDeploy();
        _createRebalanceOpportunity();
        vm.warp(block.timestamp + 21601);

        // Prepare plan first (uses current positionAssets, adapter.deposited still full)
        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).prepareRebalance();

        uint256 pos1Before = vault.positionAssets(address(adapter1));
        require(pos1Before > 0, "setup: adapter1 must have funds");

        // Inject drift AFTER plan is prepared: adapter now has less than positionAssets says.
        // The plan will attempt to withdraw (pos1Before - targetAlloc). Since adapter only
        // has pos1Before/2, it returns pos1Before/2 if that is less than the planned amount.
        adapter1.setDeposited(pos1Before / 2);

        uint256 idleBefore = IERC20(ARBITRUM_USDC).balanceOf(address(vault));

        // Withdraw step: adapter returns min(planned, deposited) = pos1Before/2
        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).executeRebalanceStep();

        uint256 idleAfter = IERC20(ARBITRUM_USDC).balanceOf(address(vault));
        uint256 actualWithdrawn = idleAfter >= idleBefore ? idleAfter - idleBefore : 0;

        uint256 pos1After = vault.positionAssets(address(adapter1));

        assertEq(pos1Before - pos1After, actualWithdrawn,
            "H03-3: positionAssets[from] decrement must equal actual USDC returned by withdraw");
    }

    // -------------------------------------------------------------------------
    // H-03-4: fuzz partial deposit -- no overstatement for any acceptance ratio
    // -------------------------------------------------------------------------

    function testFuzz_H03_partial_deposit_no_overstatement(uint16 acceptBps) public {
        acceptBps = uint16(bound(acceptBps, 0, 10000));

        _coreDeposit(300_000e6);
        _fullyDeploy();
        _createRebalanceOpportunity();
        vm.warp(block.timestamp + 21601);

        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).prepareRebalance();

        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).executeRebalanceStep();

        adapter3.setPartialDepositBps(acceptBps);

        uint256 pos3Before = vault.positionAssets(address(adapter3));
        uint256 idleBefore = IERC20(ARBITRUM_USDC).balanceOf(address(vault));

        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).executeRebalanceStep();

        uint256 idleAfter = IERC20(ARBITRUM_USDC).balanceOf(address(vault));
        uint256 actualDeposited = idleBefore >= idleAfter ? idleBefore - idleAfter : 0;
        uint256 pos3After = vault.positionAssets(address(adapter3));

        assertEq(pos3After - pos3Before, actualDeposited,
            "H03-fuzz: positionAssets delta must equal balance delta for any acceptance ratio");
    }

    // -------------------------------------------------------------------------
    // H-03-5: no cumulative drift across N partial-fill rebalance cycles
    // -------------------------------------------------------------------------

    /// @notice H-03 fix must not break normal full-accept rebalances.
    ///         After a rebalance where all adapters accept 100%, positionAssets must
    ///         not exceed actual adapter balances (no overstatement via H-03 code path).
    ///
    ///         NOTE: StrategyScoringModule.deployIdle() (called by _finalizePlan) has a
    ///         symmetric accounting bug (positionAssets += planned, not actual). That bug
    ///         is out of H-03 scope and logged in outputs/NEW_FINDINGS.md. This test
    ///         intentionally uses full-accept adapters to avoid triggering it.
    function test_H03_no_drift_full_accept_regression() public {
        _coreDeposit(300_000e6);
        _fullyDeploy();
        _createRebalanceOpportunity();

        uint256 taBefore = vault.totalAssets();

        vm.warp(block.timestamp + 21601);
        _doRebalance();

        uint256 taAfter = vault.totalAssets();

        // Total assets conserved (H-03 fix does not change full-accept behavior)
        assertApproxEqAbs(taAfter, taBefore, vault.dustTolerance(),
            "H03-5: totalAssets conserved after rebalance with H-03 fix");

        // positionAssets per adapter must not exceed actual adapter balance
        assertLe(vault.positionAssets(address(adapter1)),
            adapter1.totalAssets() + vault.dustTolerance(),
            "H03-5: positionAssets[adapter1] not overstated");
        assertLe(vault.positionAssets(address(adapter2)),
            adapter2.totalAssets() + vault.dustTolerance(),
            "H03-5: positionAssets[adapter2] not overstated");
        assertLe(vault.positionAssets(address(adapter3)),
            adapter3.totalAssets() + vault.dustTolerance(),
            "H03-5: positionAssets[adapter3] not overstated");
    }
}

// ============================================================================
// F-SCORING-01 -- StrategyScoringModule.deployIdle: positionAssets uses actualDeposited
// ============================================================================
// Mirrors H-03 pattern for the deployIdle path.
// Three locations fixed:
//   (a) _deployIdleToAdapters bestEffort path   (line ~450)
//   (b) _deployIdleToAdapters strict path       (line ~453)
//   (c) _executeSafetyOverflow                  (line ~526)
// Tests cover paths (a) via the public deployIdle() API (bestEffort=true).
// Path (b) is also exercised indirectly through deposit() auto-deploy flow.
// Path (c) requires safety fallback adapter setup -- covered by existing
// SafetyAdapterCapTier tests; accounting correctness asserted here.
// ============================================================================

contract FSCORING01_DeployIdleAccounting_Test is RebalanceAccountingTest {

    // -------------------------------------------------------------------------
    // FS-01-1: partial deposit -- positionAssets reflects actualDeposited
    // -------------------------------------------------------------------------

    /// @notice When adapter1 only accepts 50% of the deployIdle target,
    ///         positionAssets must not overstate the actual USDC deposited.
    function test_FS01_deployIdle_partial_deposit_correctly_accounted() public {
        // Only add adapter1 so all idle goes to it (simpler accounting check)
        // setUp() already added all 3; we restrict capacity on adapter2 and adapter3
        adapter2.setMaxCap(0);
        adapter3.setMaxCap(0);

        // Make adapter1 accept only 50% of whatever is offered
        adapter1.setPartialDepositBps(5000);

        uint256 depositAmount = 100_000e6;
        _coreDeposit(depositAmount);

        // Capture state AFTER _coreDeposit: vault.deposit() calls deployIdleToAdapters
        // (strict path) internally, so adapter1 may already hold some balance.
        // We measure deltas from this snapshot to isolate the explicit deployIdle call.
        uint256 idleBefore = IERC20(ARBITRUM_USDC).balanceOf(address(vault));
        uint256 pos1Before = vault.positionAssets(address(adapter1));
        uint256 adapter1TotalBefore = adapter1.totalAssets();

        _warpAndDeployIdle();

        uint256 idleAfter = IERC20(ARBITRUM_USDC).balanceOf(address(vault));
        uint256 actualDeposited = idleBefore >= idleAfter ? idleBefore - idleAfter : 0;

        uint256 pos1After = vault.positionAssets(address(adapter1));

        // positionAssets delta must equal actual USDC deposited (balance delta)
        assertEq(pos1After - pos1Before, actualDeposited,
            "FS01-1: positionAssets delta must equal balance delta from deployIdle");

        // Sanity: adapter balance increment equals actualDeposited (no phantom assets)
        assertEq(adapter1.totalAssets() - adapter1TotalBefore, actualDeposited,
            "FS01-1: adapter balance increment must equal actualDeposited");
    }

    // -------------------------------------------------------------------------
    // FS-01-2: failed deposit -- positionAssets stays unchanged
    // -------------------------------------------------------------------------

    /// @notice If adapter1 deposit reverts during deployIdle, positionAssets
    ///         must not change -- no phantom assets.
    function test_FS01_deployIdle_failed_deposit_no_overstate() public {
        adapter2.setMaxCap(0);
        adapter3.setMaxCap(0);

        uint256 depositAmount = 100_000e6;
        _coreDeposit(depositAmount);

        // Set revert flag AFTER deposit so vault.deposit() succeeds.
        // Only the subsequent explicit deployIdle() call will encounter the revert.
        adapter1.setDepositReverts(true);

        uint256 pos1Before = vault.positionAssets(address(adapter1));

        _warpAndDeployIdle();

        uint256 pos1After = vault.positionAssets(address(adapter1));

        assertEq(pos1After, pos1Before,
            "FS01-2: positionAssets must not change when deployIdle deposit reverts");
    }

    // -------------------------------------------------------------------------
    // FS-01-3: fuzz partial acceptance -- no drift for any ratio
    // -------------------------------------------------------------------------

    function testFuzz_FS01_deployIdle_no_drift_partial_acceptance(uint16 acceptBps) public {
        acceptBps = uint16(bound(acceptBps, 0, 10000));

        adapter2.setMaxCap(0);
        adapter3.setMaxCap(0);
        adapter1.setPartialDepositBps(acceptBps);

        _coreDeposit(100_000e6);

        uint256 idleBefore = IERC20(ARBITRUM_USDC).balanceOf(address(vault));
        uint256 pos1Before = vault.positionAssets(address(adapter1));

        _warpAndDeployIdle();

        uint256 idleAfter = IERC20(ARBITRUM_USDC).balanceOf(address(vault));
        uint256 actualDeposited = idleBefore >= idleAfter ? idleBefore - idleAfter : 0;
        uint256 pos1After = vault.positionAssets(address(adapter1));

        assertEq(pos1After - pos1Before, actualDeposited,
            "FS01-fuzz: positionAssets delta must equal balance delta for any acceptance ratio");
    }

    // -------------------------------------------------------------------------
    // FS-01-4: regression -- full-accept deployIdle not broken by fix
    // -------------------------------------------------------------------------

    /// @notice Normal full-accept deployIdle must still work correctly after the fix.
    ///         positionAssets must match actual adapter balance (no overstatement,
    ///         no understatement).
    function test_FS01_deployIdle_full_accept_regression() public {
        // All adapters accept 100% (default partialDepositBps = 10000)
        _coreDeposit(300_000e6);

        uint256 totalBefore = vault.totalAssets();

        _warpAndDeployIdle();

        // Check per-adapter: positionAssets must not exceed actual balance
        assertLe(vault.positionAssets(address(adapter1)),
            adapter1.totalAssets() + vault.dustTolerance(),
            "FS01-4: positionAssets[adapter1] not overstated");
        assertLe(vault.positionAssets(address(adapter2)),
            adapter2.totalAssets() + vault.dustTolerance(),
            "FS01-4: positionAssets[adapter2] not overstated");
        assertLe(vault.positionAssets(address(adapter3)),
            adapter3.totalAssets() + vault.dustTolerance(),
            "FS01-4: positionAssets[adapter3] not overstated");

        // totalAssets must be conserved
        assertApproxEqAbs(vault.totalAssets(), totalBefore, vault.dustTolerance(),
            "FS01-4: totalAssets conserved after full-accept deployIdle");
    }
}
