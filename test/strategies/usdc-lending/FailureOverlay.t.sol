// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { UsdcMultiLendingVault } from "../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
import { StrategyParamsModule } from "../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import { StrategySettingsModule } from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import { StrategyAllocCalcModule } from "../../../src/strategies/usdc-lending/controller/StrategyAllocCalcModule.sol";
import { StrategyScoringModule } from "../../../src/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import { StrategyAdapterOpsModule } from "../../../src/strategies/usdc-lending/controller/StrategyAdapterOpsModule.sol";
import { StrategyRebalanceGateModule } from "../../../src/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol";
import { StrategyRebalancePlanModule } from "../../../src/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol";
import { MockUSDC, MockLendingAdapter, UsdcMultiLendingVaultTestBase } from "./UsdcMultiLendingVault.t.sol";

// ============================================================================
// S3 — FAILURE_OVERLAY tests
// TIER_MODEL.md §4.3: multiplier = max(0, 10000 - failures × 1500)
// Pure math tests prove the formula; integration tests prove the wiring.
// ============================================================================

contract FailureOverlay is UsdcMultiLendingVaultTestBase {

    MockLendingAdapter public adapterA;
    MockLendingAdapter public adapterB;

    function setUp() public override {
        super.setUp();

        adapterA = new MockLendingAdapter(ARBITRUM_USDC);
        adapterB = new MockLendingAdapter(ARBITRUM_USDC);
        adapterA.setAPY(800);
        adapterB.setAPY(600);
        adapterA.setExtMarketTVL(50_000_000e6);
        adapterB.setExtMarketTVL(50_000_000e6);
        adapterA.setVault(address(vault));
        adapterB.setVault(address(vault));

        vm.startPrank(admin);
        address(vault).call(abi.encodeWithSignature("whitelistAdapter(address,bool)", address(adapterA), true));
        vault.addAdapter(address(adapterA));
        vault.toggleAdapter(address(adapterA), true);
        address(vault).call(abi.encodeWithSignature("setAdapterDepositMode(address,bool)", address(adapterA), false));
        address(vault).call(abi.encodeWithSignature("whitelistAdapter(address,bool)", address(adapterB), true));
        vault.addAdapter(address(adapterB));
        vault.toggleAdapter(address(adapterB), true);
        address(vault).call(abi.encodeWithSignature("setAdapterDepositMode(address,bool)", address(adapterB), false));
        vm.stopPrank();

        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();
        vm.prank(keeper);
        address(vault).call(abi.encodeWithSignature("pokeLiquidityBatch(uint256,uint256)", 0, 10));

        vm.prank(admin);
        StrategySettingsModule(address(vault)).exitBootstrapMode();
    }

    // ── Pure math: formula verification ─────────────────────────────────────

    // TIER_MODEL §4.3: 0 failures → multiplier 10000 (no penalty)
    function test_F_math_0_failures_no_penalty() public view {
        assertEq(vault.adapterConsecutiveFailures(address(adapterA)), 0);
        // effectiveAbsCapBps reads _failureOverlay → with 0 failures returns 10000 → no effect on cap
        // Verify indirectly: at T5+ TVL, structural cap = ceil(11000/5)=2200. With overlay=10000 → unchanged.
        // Direct formula check via storage:
        uint256 failures = vault.adapterConsecutiveFailures(address(adapterA));
        uint256 penalty = failures * 1500;
        uint256 multiplier = penalty >= 10000 ? 0 : 10000 - penalty;
        assertEq(multiplier, 10000, "0 failures: multiplier must be 10000");
    }

    // TIER_MODEL §4.3: 1 failure → 8500 bps (15% reduction)
    function test_F_math_1_failure_8500() public pure {
        uint256 failures = 1;
        uint256 penalty = failures * 1500;
        uint256 multiplier = penalty >= 10000 ? 0 : 10000 - penalty;
        assertEq(multiplier, 8500);
    }

    // TIER_MODEL §4.3: 3 failures → 5500 bps (45% reduction)
    function test_F_math_3_failures_5500() public pure {
        uint256 failures = 3;
        uint256 penalty = failures * 1500;
        uint256 multiplier = penalty >= 10000 ? 0 : 10000 - penalty;
        assertEq(multiplier, 5500);
    }

    // TIER_MODEL §4.3: 6 failures → 1000 bps (90% reduction, pre-quarantine)
    function test_F_math_6_failures_1000() public pure {
        uint256 failures = 6;
        uint256 penalty = failures * 1500;
        uint256 multiplier = penalty >= 10000 ? 0 : 10000 - penalty;
        assertEq(multiplier, 1000);
    }

    // TIER_MODEL §4.3: 7+ failures → 0 (full quarantine via overlay)
    function test_F_math_7_failures_zero() public pure {
        uint256 failures = 7;
        uint256 penalty = failures * 1500;
        uint256 multiplier = penalty >= 10000 ? 0 : 10000 - penalty;
        assertEq(multiplier, 0);
    }

    // TIER_MODEL §4.3: 100 failures → 0 (no underflow)
    function test_F_math_overflow_no_underflow() public pure {
        uint256 failures = 100;
        uint256 penalty = failures * 1500;
        uint256 multiplier = penalty >= 10000 ? 0 : 10000 - penalty;
        assertEq(multiplier, 0, "large failure count must not underflow");
    }

    // ── Integration: wiring through allocation ───────────────────────────────

    // Inject N failures on the given adapter by calling deployIdle() (bestEffort=true)
    // with only that adapter reachable. Each failed deposit → _recordAdapterFailure → count++.
    // Strategy: disable adapterB so only adapterA is targeted, make adapterA revert.
    function _injectFailures(MockLendingAdapter adapter, uint8 count) internal {
        // Disable the non-target adapter so all idle goes to the target
        address other = address(adapter) == address(adapterA) ? address(adapterB) : address(adapterA);
        vm.prank(admin);
        vault.toggleAdapter(other, false);

        adapter.setDepositReverts(true);

        // Seed idle cash for each failure cycle.
        // Warp uses absolute timestamps — must advance by 301 each iteration cumulatively.
        uint256 t = block.timestamp;
        for (uint8 i = 0; i < count; i++) {
            MockUSDC(ARBITRUM_USDC).mint(core, 1_000e6);
            vm.prank(core);
            MockUSDC(ARBITRUM_USDC).transfer(address(vault), 1_000e6);
            t += 301;
            vm.warp(t);
            vm.prank(keeper);
            address(vault).call(abi.encodeWithSignature("deployIdle()"));
        }

        adapter.setDepositReverts(false);
        vm.prank(admin);
        vault.toggleAdapter(other, true);
    }

    // With 0 failures: adapterA receives full allocation (normal cap applies)
    function test_F_integration_0_failures_full_allocation() public {
        _setMaxIdle(10000);
        _coreDeposit(500_000e6); // T3 TVL → dMax=3

        uint256 posA = vault.positionAssets(address(adapterA));
        assertGt(posA, 0, "adapterA should receive allocation with 0 failures");
    }

    // With 7 failures: overlay = 0 → effectiveAbsCapBps = 0 → no new allocation
    function test_F_integration_7_failures_no_allocation() public {
        // First deposit to have some idle without triggering adapterA allocation
        // Use adapterB only: disable adapterA temporarily
        vm.prank(admin);
        vault.toggleAdapter(address(adapterA), false);
        _setMaxIdle(10000);
        _coreDeposit(500_000e6);
        vm.prank(admin);
        vault.toggleAdapter(address(adapterA), true);

        // Inject 7 failures on adapterA
        _injectFailures(adapterA, 7);
        assertGe(vault.adapterConsecutiveFailures(address(adapterA)), 7);

        // Now deposit more — adapterA should get 0 (overlay=0 → cap=0)
        vm.warp(block.timestamp + 301); // past minSecondsBetweenDeployIdle
        uint256 posBefore = vault.positionAssets(address(adapterA));
        _coreDeposit(100_000e6);
        uint256 posAfter = vault.positionAssets(address(adapterA));

        assertEq(posAfter, posBefore, "adapterA with 7 failures must receive no new allocation");
    }

    // With 3 failures: overlay = 5500 → adapterA cap reduced 45%
    function test_F_integration_3_failures_reduced_cap() public {
        // Inject 3 failures on adapterA
        _injectFailures(adapterA, 3);
        assertGe(vault.adapterConsecutiveFailures(address(adapterA)), 3);

        vm.warp(block.timestamp + 301);
        _setMaxIdle(10000);
        _coreDeposit(500_000e6);

        uint256 posA = vault.positionAssets(address(adapterA));
        uint256 posB = vault.positionAssets(address(adapterB));
        uint256 tvl = vault.idleCash() + posA + posB;

        // At T3 (TVL≈500K): dMax=3, structural=ceil(11000/3)=3667 bps
        // With 3 failures: overlay=5500 → effectiveCap = 3667*5500/10000 ≈ 2017 bps
        uint256 maxAllowedA = (tvl * 3667 * 5500) / (10000 * 10000) + vault.dustTolerance();
        assertLe(posA, maxAllowedA, "adapterA cap must respect 3-failure penalty");
    }

    // Failure decay: after failureDecaySeconds, _recordAdapterFailure resets count to 0 then +1
    function test_F_integration_decay_resets_count() public {
        _injectFailures(adapterA, 3);
        uint256 countBefore = vault.adapterConsecutiveFailures(address(adapterA));
        assertGe(countBefore, 3, "must have 3+ failures before decay");

        // Warp past failureDecaySeconds (3600 in base params)
        vm.warp(block.timestamp + 3601);

        // Trigger one more failure — _recordAdapterFailure sees decay window passed → resets to 0 then +1
        _injectFailures(adapterA, 1);
        uint256 countAfter = vault.adapterConsecutiveFailures(address(adapterA));
        assertEq(countAfter, 1, "after decay window, failure count must reset to 1");
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _setMaxIdle(uint16 bps) internal {
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setMaxIdleAfterDepositBps(bps);
    }

    function _coreDeposit(uint256 amount) internal {
        MockUSDC(ARBITRUM_USDC).mint(core, amount);
        vm.prank(core);
        MockUSDC(ARBITRUM_USDC).transfer(address(vault), amount);
        vm.prank(core);
        vault.deposit(amount);
    }
}
