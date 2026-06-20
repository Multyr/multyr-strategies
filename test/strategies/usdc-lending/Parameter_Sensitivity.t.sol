// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, console2 } from "forge-std/Test.sol";

/// @title Parameter Sensitivity Review — BLOCCO E
/// @notice Offline scoring simulation using LIVE APY data from fork test.
///         Computes allocation % for each weight configuration.
/// @dev No fork needed — pure math based on observed APY/risk/liq values.
///
/// Live APY snapshot (2026-03-28):
///   Venus=932, Fluid=517, Euler=323, Dolomite=296, Morpho=282, Comet=233, Aave=159
///
/// Assumptions (V9.1 defaults):
///   - riskScoreBps: all unset → DEFAULT_RISK_BPS = 7000
///   - stabilityEMA: all unset → DEFAULT_STABILITY_BPS = 7000
///   - liquidity: all fully liquid (liq = 10000) except Euler dust (also 10000 after fix)
///   - incentive: all 0
///   - maxExposure: 3000 bps (30%)
contract Parameter_Sensitivity is Test {

    // Live APY data (bps)
    uint256 constant VENUS_APY    = 932;
    uint256 constant FLUID_APY    = 517;
    uint256 constant EULER_APY    = 323;
    uint256 constant DOLOMITE_APY = 296;
    uint256 constant MORPHO_APY   = 282;
    uint256 constant COMET_APY    = 233;
    uint256 constant AAVE_APY     = 159;

    // V9.1 defaults for unset components
    uint256 constant DEFAULT_RISK = 7000;
    uint256 constant DEFAULT_STABILITY = 7000;
    uint256 constant LIQ_FULL = 10000;
    uint256 constant INCENTIVE = 0;

    uint256 constant MAX_EXP_BPS = 3000; // 30%

    string[7] names = ["Venus  ", "Fluid  ", "Euler  ", "Dolomite", "Morpho ", "Comet  ", "Aave   "];
    uint256[7] apys = [VENUS_APY, FLUID_APY, EULER_APY, DOLOMITE_APY, MORPHO_APY, COMET_APY, AAVE_APY];

    struct WeightConfig {
        string label;
        uint256 wAPY;
        uint256 wLiq;
        uint256 wRisk;
        uint256 wStability;
        uint256 wIncentive;
    }

    function _computeAndLog(WeightConfig memory cfg) internal view {
        uint256[7] memory scores;
        uint256 totalScore = 0;

        for (uint256 i = 0; i < 7; i++) {
            uint256 score = cfg.wAPY * apys[i]
                + cfg.wLiq * LIQ_FULL
                + cfg.wRisk * DEFAULT_RISK
                + cfg.wStability * DEFAULT_STABILITY
                + cfg.wIncentive * INCENTIVE;
            scores[i] = score;
            totalScore += score;
        }

        console2.log("");
        console2.log("===", cfg.label, "===");
        console2.log("wAPY:", cfg.wAPY, "| wLiq:", cfg.wLiq);
        console2.log("wRisk:", cfg.wRisk, "| wStab:", cfg.wStability);

        uint256 topConcentration = 0;
        uint256 avgApyWeighted = 0;
        uint256 cappedCount = 0;
        uint256 idleBps = 0;
        uint256 allocSum = 0;

        for (uint256 i = 0; i < 7; i++) {
            uint256 allocBps = (scores[i] * 10000) / totalScore;
            uint256 effectiveBps = allocBps > MAX_EXP_BPS ? MAX_EXP_BPS : allocBps;
            allocSum += effectiveBps;
            if (allocBps > MAX_EXP_BPS) cappedCount++;
            if (effectiveBps > topConcentration) topConcentration = effectiveBps;
            avgApyWeighted += effectiveBps * apys[i];

            console2.log(names[i], "score:", allocBps);
            console2.log("  -> alloc:", effectiveBps);
        }

        if (allocSum < 10000) {
            idleBps = 10000 - allocSum;
        }
        uint256 avgApy = allocSum > 0 ? avgApyWeighted / allocSum : 0;

        console2.log("---");
        console2.log("Top concentration:", topConcentration, "bps");
        console2.log("Avg APY (weighted):", avgApy, "bps");
        console2.log("Idle:", idleBps, "bps");
        console2.log("Capped adapters:", cappedCount);
        console2.log("Active adapters: 7 (all enabled)");
    }

    // ═══════════════════════════════════════════════════════════
    // CONFIG 1: Current defaults (wAPY=4000)
    // ═══════════════════════════════════════════════════════════

    function test_sensitivity_default_weights() public view {
        _computeAndLog(WeightConfig({
            label: "DEFAULT (4000/2000/2000/1000/1000)",
            wAPY: 4000,
            wLiq: 2000,
            wRisk: 2000,
            wStability: 1000,
            wIncentive: 1000
        }));
    }

    // ═══════════════════════════════════════════════════════════
    // CONFIG 2: APY-heavy (wAPY=5000)
    // ═══════════════════════════════════════════════════════════

    function test_sensitivity_apy_heavy_5000() public view {
        _computeAndLog(WeightConfig({
            label: "APY-HEAVY (5000/1500/1500/1000/1000)",
            wAPY: 5000,
            wLiq: 1500,
            wRisk: 1500,
            wStability: 1000,
            wIncentive: 0
        }));
    }

    // ═══════════════════════════════════════════════════════════
    // CONFIG 3: APY-dominant (wAPY=6000)
    // ═══════════════════════════════════════════════════════════

    function test_sensitivity_apy_dominant_6000() public view {
        _computeAndLog(WeightConfig({
            label: "APY-DOMINANT (6000/1000/1500/1000/500)",
            wAPY: 6000,
            wLiq: 1000,
            wRisk: 1500,
            wStability: 1000,
            wIncentive: 500
        }));
    }

    // ═══════════════════════════════════════════════════════════
    // CONFIG 4: Risk-heavy (wRisk=3000)
    // ═══════════════════════════════════════════════════════════

    function test_sensitivity_risk_heavy() public view {
        _computeAndLog(WeightConfig({
            label: "RISK-HEAVY (3000/2000/3000/1000/1000)",
            wAPY: 3000,
            wLiq: 2000,
            wRisk: 3000,
            wStability: 1000,
            wIncentive: 1000
        }));
    }

    // ═══════════════════════════════════════════════════════════
    // CONFIG 5: Liquidity-heavy (wLiq=3000)
    // ═══════════════════════════════════════════════════════════

    function test_sensitivity_liq_heavy() public view {
        _computeAndLog(WeightConfig({
            label: "LIQ-HEAVY (3000/3000/2000/1000/1000)",
            wAPY: 3000,
            wLiq: 3000,
            wRisk: 2000,
            wStability: 1000,
            wIncentive: 1000
        }));
    }

    // ═══════════════════════════════════════════════════════════
    // CONFIG 6: Balanced-conservative (lower APY weight)
    // ═══════════════════════════════════════════════════════════

    function test_sensitivity_balanced_conservative() public view {
        _computeAndLog(WeightConfig({
            label: "BALANCED-CONSERVATIVE (3000/2500/2500/1000/1000)",
            wAPY: 3000,
            wLiq: 2500,
            wRisk: 2500,
            wStability: 1000,
            wIncentive: 0
        }));
    }

    // ═══════════════════════════════════════════════════════════
    // CONFIG 7: Equal-weight (stress test)
    // ═══════════════════════════════════════════════════════════

    function test_sensitivity_equal_weight() public view {
        _computeAndLog(WeightConfig({
            label: "EQUAL-WEIGHT (2000/2000/2000/2000/2000)",
            wAPY: 2000,
            wLiq: 2000,
            wRisk: 2000,
            wStability: 2000,
            wIncentive: 2000
        }));
    }

    // ═══════════════════════════════════════════════════════════
    // CONFIG 8: Custom risk per adapter (Venus=2000, Euler=4000)
    // ═══════════════════════════════════════════════════════════

    function test_sensitivity_differentiated_risk() public view {
        // With real risk scores: Venus=2000 (safe), Euler=4000 (higher risk)
        uint256[7] memory risks;
        risks[0] = 10000 - 2000; // Venus: riskScore=2000 → risk=8000
        risks[1] = 10000 - 1500; // Fluid: 8500
        risks[2] = 10000 - 4000; // Euler: 6000 (riskier)
        risks[3] = 10000 - 3000; // Dolomite: 7000
        risks[4] = 10000 - 2500; // Morpho: 7500
        risks[5] = 10000 - 1000; // Comet: 9000 (safest)
        risks[6] = 10000 - 500;  // Aave: 9500 (safest)

        uint256 wAPY = 4000;
        uint256 wLiq = 2000;
        uint256 wRisk = 2000;
        uint256 wStab = 1000;
        uint256 wInc = 1000;

        uint256[7] memory scores;
        uint256 totalScore = 0;

        for (uint256 i = 0; i < 7; i++) {
            uint256 score = wAPY * apys[i]
                + wLiq * LIQ_FULL
                + wRisk * risks[i]
                + wStab * DEFAULT_STABILITY
                + wInc * INCENTIVE;
            scores[i] = score;
            totalScore += score;
        }

        console2.log("");
        console2.log("=== DIFFERENTIATED RISK (default weights) ===");
        console2.log("Risk scores: Venus=2000 Fluid=1500 Euler=4000 Dolomite=3000 Morpho=2500 Comet=1000 Aave=500");

        uint256 topConcentration = 0;
        uint256 avgApyWeighted = 0;
        uint256 allocSum = 0;
        uint256 cappedCount = 0;

        for (uint256 i = 0; i < 7; i++) {
            uint256 allocBps = (scores[i] * 10000) / totalScore;
            uint256 effectiveBps = allocBps > MAX_EXP_BPS ? MAX_EXP_BPS : allocBps;
            allocSum += effectiveBps;
            if (allocBps > MAX_EXP_BPS) cappedCount++;
            if (effectiveBps > topConcentration) topConcentration = effectiveBps;
            avgApyWeighted += effectiveBps * apys[i];

            console2.log(names[i], "risk:", risks[i]);
            console2.log("  score:", allocBps, "-> alloc:", effectiveBps);
        }

        uint256 idleBps = allocSum < 10000 ? 10000 - allocSum : 0;
        uint256 avgApy = allocSum > 0 ? avgApyWeighted / allocSum : 0;

        console2.log("---");
        console2.log("Top concentration:", topConcentration, "bps");
        console2.log("Avg APY:", avgApy, "bps");
        console2.log("Idle:", idleBps, "bps");
        console2.log("Capped:", cappedCount);
    }
}
