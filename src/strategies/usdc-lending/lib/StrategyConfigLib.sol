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
}
