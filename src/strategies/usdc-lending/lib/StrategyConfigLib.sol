// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title StrategyConfigLib
/// @notice Canonical constants and pure/view helpers shared between StrategyStorageLayout
///         and StrategyExplainabilityLens. Single source of truth -- prevents independent
///         drift between the core scoring logic and the explainability read layer.
/// @dev    All functions are `internal` so they are inlined by the compiler into each
///         caller -- no deployed library address, no DELEGATECALL overhead.
library StrategyConfigLib {

    // ── Scoring defaults (safe fallback for unset components) ────────────────
    uint256 internal constant DEFAULT_STABILITY_BPS = 7000;
    uint256 internal constant DEFAULT_RISK_BPS      = 7000;
    uint256 internal constant DEFAULT_LIQ_BPS       = 5000;

    // ── External TVL confidence bands ────────────────────────────────────────
    // Calibrated on real Arbitrum USDC market depths; measures how protected
    // capital is from liquidity risk in the external market. 10000 = 1.0x.
    uint256 internal constant CONFIDENCE_ZERO  = 0;
    uint256 internal constant CONFIDENCE_MICRO = 3000;
    uint256 internal constant CONFIDENCE_SMALL = 5000;
    uint256 internal constant CONFIDENCE_LOW   = 7000;
    uint256 internal constant CONFIDENCE_MED   = 8500;
    uint256 internal constant CONFIDENCE_HIGH  = 9500;
    uint256 internal constant CONFIDENCE_VHIGH = 10000;

    // ── Pure helpers ─────────────────────────────────────────────────────────

    /// @dev Dynamic relative exposure cap -- scales with external market depth.
    function effectiveRelativeCapBps(uint256 extTVL) internal pure returns (uint16) {
        if (extTVL < 100_000e6)      return 0;
        if (extTVL < 500_000e6)      return 200;
        if (extTVL < 1_000_000e6)    return 500;
        if (extTVL < 2_000_000e6)    return 800;
        if (extTVL < 3_000_000e6)    return 1000;
        if (extTVL < 10_000_000e6)   return 1200;
        if (extTVL < 25_000_000e6)   return 1500;
        if (extTVL < 50_000_000e6)   return 1800;
        if (extTVL < 250_000_000e6)  return 2000;
        return 2500;
    }

    /// @dev TVL confidence -- 3-state: UNAVAILABLE (cacheTs==0), STALE (beyond window), FRESH.
    ///      Canonical semantic aligned with StrategyStorageLayout._tvlConfidence (Audit P0.6).
    ///      Parametrized so callers with different storage access patterns share one logic path.
    function tvlConfidence(
        uint256 extTVL,
        uint64  cacheTs,
        uint32  staleness
    ) internal view returns (uint256) {
        if (cacheTs == 0) return CONFIDENCE_ZERO;
        if (staleness > 0 && block.timestamp - cacheTs > staleness) return CONFIDENCE_MICRO;
        if (extTVL < 100_000e6)      return CONFIDENCE_ZERO;
        if (extTVL < 500_000e6)      return CONFIDENCE_MICRO;
        if (extTVL < 2_000_000e6)    return CONFIDENCE_SMALL;
        if (extTVL < 10_000_000e6)   return CONFIDENCE_LOW;
        if (extTVL < 50_000_000e6)   return CONFIDENCE_MED;
        if (extTVL < 250_000_000e6)  return CONFIDENCE_HIGH;
        return CONFIDENCE_VHIGH;
    }

    // ── Cap-engine overlays ──────────────────────────────────────────────────
    // Single source of truth for the four-layer cap engine's overlay
    // multipliers (docs/TIER_MODEL.md §4). Previously hand-duplicated,
    // byte-for-byte, between StrategyScoringModule and StrategyAllocCalcModule
    // -- exactly the class of divergence that caused AUDIT-FINDING-13 and the
    // F-SCORING-INV2 regression (a fix landing in only one copy). Parametrized
    // (not storage-reading) so every caller shares one logic path regardless
    // of how it sources the raw values.

    /// @dev S3 RISK_OVERLAY -- reduces cap by riskScoreBps/2, max 50% reduction.
    ///      Stale scores (past `staleness`, if set) are treated as 0 (no penalty).
    function riskOverlay(uint256 score, uint32 staleness, uint64 updatedAt) internal view returns (uint16) {
        if (score == 0) return 10000;
        if (staleness > 0 && updatedAt > 0 && block.timestamp - updatedAt > staleness) return 10000;
        uint256 penalty = score / 2;
        return penalty >= 10000 ? 0 : uint16(10000 - penalty);
    }

    /// @dev S3 FAILURE_OVERLAY -- reduces cap by 15% per consecutive failure, floors at 0.
    function failureOverlay(uint256 failures) internal pure returns (uint16) {
        if (failures == 0) return 10000;
        uint256 penalty = failures * 1500;
        return penalty >= 10000 ? 0 : uint16(10000 - penalty);
    }

    /// @dev S5 LIQUIDITY_OVERLAY -- tiered cap reduction based on withdrawable liquidity ratio.
    function liquidityOverlay(uint256 liqBps) internal pure returns (uint16) {
        if (liqBps >= 8000) return 10000;
        if (liqBps >= 5000) return 9000;
        if (liqBps >= 2500) return 7500;
        return 6000;
    }

    /// @dev Cached liquidity ratio with staleness fallback to DEFAULT_LIQ_BPS.
    ///      `cached == 0` means "never cached" (distinct from a measured-zero
    ///      liquidity observation, which callers store as 1 -- see
    ///      StrategyParamsModule._pokeLiquidity).
    function cachedLiq(uint16 cached, uint32 staleness, uint64 cachedTs) internal view returns (uint256) {
        if (cached == 0) return DEFAULT_LIQ_BPS;
        if (staleness > 0 && cachedTs > 0 && block.timestamp - cachedTs > staleness) return DEFAULT_LIQ_BPS;
        return uint256(cached);
    }
}
