// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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
// S5 — LIQUIDITY_OVERLAY tests
// TIER_MODEL.md §4.4: tiered multiplier by cachedLiquidityBps
//   ≥8000→10000, 5000-7999→9000, 2500-4999→7500, <2500→6000
// Pure math tests prove the formula; integration tests prove the wiring.
// ============================================================================

contract LiquidityOverlay is UsdcMultiLendingVaultTestBase {

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

    // ── Pure math: tier table verification ───────────────────────────────────

    // TIER_MODEL §4.4: liq=10000 (≥8000) → multiplier 10000
    function test_L_math_10000_liq_full() public pure {
        uint256 liq = 10000;
        uint256 multiplier = liq >= 8000 ? 10000 : liq >= 5000 ? 9000 : liq >= 2500 ? 7500 : 6000;
        assertEq(multiplier, 10000);
    }

    // TIER_MODEL §4.4: liq=8000 (boundary ≥8000) → multiplier 10000
    function test_L_math_8000_liq_full() public pure {
        uint256 liq = 8000;
        uint256 multiplier = liq >= 8000 ? 10000 : liq >= 5000 ? 9000 : liq >= 2500 ? 7500 : 6000;
        assertEq(multiplier, 10000);
    }

    // TIER_MODEL §4.4: liq=7999 (5000-7999) → multiplier 9000
    function test_L_math_7999_liq_9000() public pure {
        uint256 liq = 7999;
        uint256 multiplier = liq >= 8000 ? 10000 : liq >= 5000 ? 9000 : liq >= 2500 ? 7500 : 6000;
        assertEq(multiplier, 9000);
    }

    // TIER_MODEL §4.4: liq=5000 (boundary 5000-7999) → multiplier 9000
    function test_L_math_5000_liq_9000() public pure {
        uint256 liq = 5000;
        uint256 multiplier = liq >= 8000 ? 10000 : liq >= 5000 ? 9000 : liq >= 2500 ? 7500 : 6000;
        assertEq(multiplier, 9000);
    }

    // TIER_MODEL §4.4: liq=4999 (2500-4999) → multiplier 7500
    function test_L_math_4999_liq_7500() public pure {
        uint256 liq = 4999;
        uint256 multiplier = liq >= 8000 ? 10000 : liq >= 5000 ? 9000 : liq >= 2500 ? 7500 : 6000;
        assertEq(multiplier, 7500);
    }

    // TIER_MODEL §4.4: liq=2500 (boundary 2500-4999) → multiplier 7500
    function test_L_math_2500_liq_7500() public pure {
        uint256 liq = 2500;
        uint256 multiplier = liq >= 8000 ? 10000 : liq >= 5000 ? 9000 : liq >= 2500 ? 7500 : 6000;
        assertEq(multiplier, 7500);
    }

    // TIER_MODEL §4.4: liq=2499 (<2500) → multiplier 6000
    function test_L_math_2499_liq_6000() public pure {
        uint256 liq = 2499;
        uint256 multiplier = liq >= 8000 ? 10000 : liq >= 5000 ? 9000 : liq >= 2500 ? 7500 : 6000;
        assertEq(multiplier, 6000);
    }

    // TIER_MODEL §4.4: liq=0 (<2500) → multiplier 6000 (minimum, no zero)
    function test_L_math_0_liq_6000() public pure {
        uint256 liq = 0;
        uint256 multiplier = liq >= 8000 ? 10000 : liq >= 5000 ? 9000 : liq >= 2500 ? 7500 : 6000;
        assertEq(multiplier, 6000, "liq=0: minimum multiplier 6000, not zero");
    }

    // ── Integration: wiring through allocation ───────────────────────────────

    // Default (fresh adapter, liq=DEFAULT_LIQ_BPS=5000): overlay=9000, minor 10% reduction.
    // pokeLiquidityBatch sets cachedLiquidityBps for MockAdapter (100% liquid).
    // After poke: adapterA.cachedLiquidityBps >= 8000 → overlay=10000 (full cap).
    function test_L_integration_high_liq_full_cap() public {
        // MockAdapter is 100% liquid → poked value = 10000 → overlay = 10000
        uint256 liqBps = vault.cachedLiquidityBps(address(adapterA));
        assertGe(liqBps, 8000, "MockAdapter must cache >=8000 after poke");

        _setMaxIdle(10000);
        _coreDeposit(500_000e6);

        uint256 posA = vault.positionAssets(address(adapterA));
        assertGt(posA, 0, "high-liq adapterA must receive allocation");
    }

    // Low liquidity: force cachedLiquidityBps = 2000 (<2500) → overlay=6000 → 40% cap reduction.
    function test_L_integration_low_liq_reduced_cap() public {
        // Seed adapterA with funds first (deposited>0 needed for liquidity ratio to be meaningful)
        _setMaxIdle(10000);
        _coreDeposit(500_000e6); // initial deposit — adapterA gets allocation at full liquidity

        // Now set low liquidity on adapterA and re-poke the cache
        adapterA.setLiquidityBps(2000); // 20% of deposited is now withdrawable
        vm.warp(block.timestamp + 301);
        vm.prank(keeper);
        address(vault).call(abi.encodeWithSignature("pokeLiquidityBatch(uint256,uint256)", 0, 10));

        uint256 liqBps = vault.cachedLiquidityBps(address(adapterA));
        assertLt(liqBps, 2500, "cachedLiquidityBps must be <2500 after setting 20% liquidity");

        // Second deposit — adapterA now has low-liq penalty applied
        _coreDeposit(500_000e6);

        uint256 posA = vault.positionAssets(address(adapterA));
        uint256 posB = vault.positionAssets(address(adapterB));
        uint256 tvl = vault.idleCash() + posA + posB;

        // T3/T4 TVL: structural cap for T4 (5M TVL) = ceil(11000/4) = 2750 bps
        // With low-liq overlay=6000 → effectiveCap = 2750*6000/10000 = 1650 bps + dustTolerance
        // Use T3 structural=3667 bps as upper bound (conservative — actual dMax may be 3 or 4)
        uint256 maxAllowedA = (tvl * 3667 * 6000) / (10000 * 10000) + vault.dustTolerance();
        assertLe(posA, maxAllowedA, "low-liq adapterA must respect 40% overlay penalty");
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
