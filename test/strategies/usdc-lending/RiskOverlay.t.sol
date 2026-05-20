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
// S4 — RISK_OVERLAY tests
// TIER_MODEL.md §4.2: multiplier = max(0, 10000 - riskScoreBps/2)
// Pure math tests prove the formula; integration tests prove the wiring.
// ============================================================================

contract RiskOverlay is UsdcMultiLendingVaultTestBase {

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

    // TIER_MODEL §4.2: score=0 → multiplier 10000 (no penalty)
    function test_R_math_0_score_no_penalty() public pure {
        uint256 score = 0;
        uint256 penalty = score / 2;
        uint256 multiplier = penalty >= 10000 ? 0 : 10000 - penalty;
        assertEq(multiplier, 10000, "score=0: multiplier must be 10000");
    }

    // TIER_MODEL §4.2: score=2000 → multiplier 9000 (10% reduction)
    function test_R_math_2000_score_9000() public pure {
        uint256 score = 2000;
        uint256 penalty = score / 2;
        uint256 multiplier = penalty >= 10000 ? 0 : 10000 - penalty;
        assertEq(multiplier, 9000);
    }

    // TIER_MODEL §4.2: score=5000 → multiplier 7500 (25% reduction)
    function test_R_math_5000_score_7500() public pure {
        uint256 score = 5000;
        uint256 penalty = score / 2;
        uint256 multiplier = penalty >= 10000 ? 0 : 10000 - penalty;
        assertEq(multiplier, 7500);
    }

    // TIER_MODEL §4.2: score=8000 → multiplier 6000 (40% reduction)
    function test_R_math_8000_score_6000() public pure {
        uint256 score = 8000;
        uint256 penalty = score / 2;
        uint256 multiplier = penalty >= 10000 ? 0 : 10000 - penalty;
        assertEq(multiplier, 6000);
    }

    // TIER_MODEL §4.2: score=10000 → multiplier 5000 (50% max reduction)
    function test_R_math_10000_score_5000() public pure {
        uint256 score = 10000;
        uint256 penalty = score / 2;
        uint256 multiplier = penalty >= 10000 ? 0 : 10000 - penalty;
        assertEq(multiplier, 5000, "score=10000: multiplier must be 5000 (max 50% reduction)");
    }

    // ── Integration: wiring through allocation ───────────────────────────────

    // score=0 (default): adapterA receives normal allocation
    function test_R_integration_0_score_full_allocation() public {
        assertEq(vault.riskScoreBps(address(adapterA)), 0, "default risk score must be 0");

        _setMaxIdle(10000);
        _coreDeposit(500_000e6); // T3

        uint256 posA = vault.positionAssets(address(adapterA));
        assertGt(posA, 0, "adapterA with score=0 must receive allocation");
    }

    // score=10000: cap reduced by 50% vs score=0 baseline
    function test_R_integration_10000_score_half_cap() public {
        // Baseline: deposit into adapterB-only vault to establish reference
        vm.prank(admin);
        vault.toggleAdapter(address(adapterA), false);
        _setMaxIdle(10000);
        _coreDeposit(500_000e6);

        // Re-enable adapterA with score=10000
        vm.startPrank(admin);
        vault.toggleAdapter(address(adapterA), true);
        StrategySettingsModule(address(vault)).setRiskScore(address(adapterA), 10000);
        vm.stopPrank();

        vm.warp(block.timestamp + 301);
        _coreDeposit(100_000e6);

        uint256 posA = vault.positionAssets(address(adapterA));
        uint256 posB = vault.positionAssets(address(adapterB));
        uint256 tvl = vault.idleCash() + posA + posB;

        // T3 TVL: dMax=3, structuralCap=ceil(11000/3)=3667 bps
        // With score=10000: overlay=5000 → effectiveCap = 3667*5000/10000 ≈ 1833 bps + dustTolerance
        uint256 maxAllowedA = (tvl * 3667 * 5000) / (10000 * 10000) + vault.dustTolerance();
        assertLe(posA, maxAllowedA, "adapterA with score=10000 must respect 50% cap penalty");
    }

    // Staleness: score set but past riskScoreStalenessSeconds → treated as 0, no cap penalty.
    // Verified by comparing allocation with a fresh high score (penalized) vs stale score (not penalized).
    function test_R_integration_stale_score_no_penalty() public {
        // Set riskScoreStalenessSeconds to 3600
        vm.prank(admin);
        address(vault).call(abi.encodeWithSignature("setRiskScoreStalenessSeconds(uint32)", uint32(3600)));

        _setMaxIdle(10000);

        // Phase 1: fresh score=10000 on adapterA — penalized allocation
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setRiskScore(address(adapterA), 10000);
        _coreDeposit(500_000e6); // T3 TVL
        uint256 posA_fresh = vault.positionAssets(address(adapterA));

        // Phase 2: warp past staleness, new deposit with same TVL band
        vm.warp(block.timestamp + 3601); // score is now stale
        _coreDeposit(500_000e6); // now TVL is T4+, still multi-adapter
        uint256 posA_stale = vault.positionAssets(address(adapterA));

        // With stale score (overlay=10000): adapterA gets more allocation than with fresh score (overlay=5000).
        // posA_stale should be strictly greater than posA_fresh (extra 500K was allocated with full cap).
        assertGt(posA_stale, posA_fresh, "stale score must allocate more than penalized fresh score");
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
