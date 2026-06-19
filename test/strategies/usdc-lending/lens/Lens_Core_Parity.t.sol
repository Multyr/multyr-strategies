// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ═══════════════════════════════════════════════════════════════════════════════
// Lens_Core_Parity.t.sol -- HIGH-LENS-01/02/03 (Wave 1, item 14/15)
// ───────────────────────────────────────────────────────────────────────────────
// Verifies that StrategyConfigLib (canonical single source of truth) matches the
// public constants declared in StrategyStorageLayout (used by the core) and that
// the library's pure/view helpers produce identical results to the previously
// duplicated Lens implementations.
//
// HIGH-LENS-01: constants parity (10 constants: 3 defaults + 7 confidence bands)
// HIGH-LENS-02: effectiveRelativeCapBps boundary table + fuzz monotonicity
// HIGH-LENS-03: tvlConfidence 3-state model + divergence regressions + fuzz
//
// Run with: forge test --match-path "test/strategies/usdc-lending/lens/**" -vv
// ═══════════════════════════════════════════════════════════════════════════════

import { Test } from "forge-std/Test.sol";
import { StrategyConfigLib } from "../../../../src/strategies/usdc-lending/lib/StrategyConfigLib.sol";
import { StrategyStorageLayout } from "../../../../src/strategies/usdc-lending/controller/StrategyStorageLayout.sol";

// ── Harness: exposes library internals as external for the fuzzer ─────────────
contract StrategyConfigLibHarness {
    function effectiveRelativeCapBps(uint256 extTVL) external pure returns (uint16) {
        return StrategyConfigLib.effectiveRelativeCapBps(extTVL);
    }

    function tvlConfidence(
        uint256 extTVL,
        uint64  cacheTs,
        uint32  staleness
    ) external view returns (uint256) {
        return StrategyConfigLib.tvlConfidence(extTVL, cacheTs, staleness);
    }
}

// ── Minimal StorageLayout deployment for constants access ─────────────────────
// StrategyStorageLayout is a concrete contract (not abstract). We deploy it with
// dummy addresses so Solidity's type system exposes the public constant getters.
// None of the dummy addresses are called during construction.
contract StorageLayoutConsts is StrategyStorageLayout {
    // solhint-disable-next-line no-empty-blocks
    constructor()
        StrategyStorageLayout(address(1), address(0), address(0), address(0), address(0))
    {}
}

// ════════════════════════════════════════════════════════════════════════════
// HIGH-LENS-01 -- Constants parity
// ════════════════════════════════════════════════════════════════════════════

contract Lens_Core_Parity_Constants is Test {

    StorageLayoutConsts core;

    function setUp() public {
        core = new StorageLayoutConsts();
    }

    function test_CL01a_default_bps_match_core() public view {
        assertEq(
            StrategyConfigLib.DEFAULT_STABILITY_BPS,
            core.DEFAULT_STABILITY_BPS(),
            "DEFAULT_STABILITY_BPS mismatch"
        );
        assertEq(
            StrategyConfigLib.DEFAULT_RISK_BPS,
            core.DEFAULT_RISK_BPS(),
            "DEFAULT_RISK_BPS mismatch"
        );
        assertEq(
            StrategyConfigLib.DEFAULT_LIQ_BPS,
            core.DEFAULT_LIQ_BPS(),
            "DEFAULT_LIQ_BPS mismatch"
        );
    }

    function test_CL01b_confidence_bands_match_core() public view {
        assertEq(StrategyConfigLib.CONFIDENCE_ZERO,  core.CONFIDENCE_ZERO(),  "CONFIDENCE_ZERO");
        assertEq(StrategyConfigLib.CONFIDENCE_MICRO, core.CONFIDENCE_MICRO(), "CONFIDENCE_MICRO");
        assertEq(StrategyConfigLib.CONFIDENCE_SMALL, core.CONFIDENCE_SMALL(), "CONFIDENCE_SMALL");
        assertEq(StrategyConfigLib.CONFIDENCE_LOW,   core.CONFIDENCE_LOW(),   "CONFIDENCE_LOW");
        assertEq(StrategyConfigLib.CONFIDENCE_MED,   core.CONFIDENCE_MED(),   "CONFIDENCE_MED");
        assertEq(StrategyConfigLib.CONFIDENCE_HIGH,  core.CONFIDENCE_HIGH(),  "CONFIDENCE_HIGH");
        assertEq(StrategyConfigLib.CONFIDENCE_VHIGH, core.CONFIDENCE_VHIGH(), "CONFIDENCE_VHIGH");
    }
}

// ════════════════════════════════════════════════════════════════════════════
// HIGH-LENS-02 -- effectiveRelativeCapBps boundary table + fuzz
// ════════════════════════════════════════════════════════════════════════════

contract Lens_Core_Parity_RelCap is Test {

    StrategyConfigLibHarness h;

    function setUp() public {
        h = new StrategyConfigLibHarness();
    }

    function test_CL02_effectiveRelativeCapBps_boundary_table() public view {
        assertEq(h.effectiveRelativeCapBps(0),               0,    "0 -> 0");
        assertEq(h.effectiveRelativeCapBps(99_999e6),         0,    "<100K -> 0");
        assertEq(h.effectiveRelativeCapBps(100_000e6),        200,  "100K -> 200");
        assertEq(h.effectiveRelativeCapBps(499_999e6),        200,  "<500K -> 200");
        assertEq(h.effectiveRelativeCapBps(500_000e6),        500,  "500K -> 500");
        assertEq(h.effectiveRelativeCapBps(999_999e6),        500,  "<1M -> 500");
        assertEq(h.effectiveRelativeCapBps(1_000_000e6),      800,  "1M -> 800");
        assertEq(h.effectiveRelativeCapBps(1_999_999e6),      800,  "<2M -> 800");
        assertEq(h.effectiveRelativeCapBps(2_000_000e6),      1000, "2M -> 1000");
        assertEq(h.effectiveRelativeCapBps(2_999_999e6),      1000, "<3M -> 1000");
        assertEq(h.effectiveRelativeCapBps(3_000_000e6),      1200, "3M -> 1200");
        assertEq(h.effectiveRelativeCapBps(9_999_999e6),      1200, "<10M -> 1200");
        assertEq(h.effectiveRelativeCapBps(10_000_000e6),     1500, "10M -> 1500");
        assertEq(h.effectiveRelativeCapBps(24_999_999e6),     1500, "<25M -> 1500");
        assertEq(h.effectiveRelativeCapBps(25_000_000e6),     1800, "25M -> 1800");
        assertEq(h.effectiveRelativeCapBps(49_999_999e6),     1800, "<50M -> 1800");
        assertEq(h.effectiveRelativeCapBps(50_000_000e6),     2000, "50M -> 2000");
        assertEq(h.effectiveRelativeCapBps(249_999_999e6),    2000, "<250M -> 2000");
        assertEq(h.effectiveRelativeCapBps(250_000_000e6),    2500, "250M -> 2500");
        assertEq(h.effectiveRelativeCapBps(type(uint256).max),2500, "max -> 2500");
    }

    /// @dev Fuzz: result is always a valid step value; function is weakly monotone-non-decreasing.
    function testFuzz_CL03_effectiveRelativeCapBps_monotone(uint256 extTVL) public view {
        uint16 cap = h.effectiveRelativeCapBps(extTVL);
        bool valid = (cap == 0 || cap == 200 || cap == 500 || cap == 800 || cap == 1000
                   || cap == 1200 || cap == 1500 || cap == 1800 || cap == 2000 || cap == 2500);
        assertTrue(valid, "result not a valid step value");
        if (extTVL < type(uint256).max) {
            uint16 capPlus = h.effectiveRelativeCapBps(extTVL + 1);
            assertTrue(capPlus >= cap, "cap decreased on increment");
        }
    }
}

// ════════════════════════════════════════════════════════════════════════════
// HIGH-LENS-03 -- tvlConfidence 3-state model + divergence regressions
// ════════════════════════════════════════════════════════════════════════════

contract Lens_Core_Parity_TvlConf is Test {

    StrategyConfigLibHarness h;

    uint32 constant STALENESS = 3600; // 1 hour
    uint64 constant BASE_TS   = uint64(365 days) + 100_000; // large enough for `BASE_TS - 365 days > 0`

    function setUp() public {
        h = new StrategyConfigLibHarness();
        vm.warp(BASE_TS);
    }

    // ── State 1: cacheTs == 0 -> CONFIDENCE_ZERO (no cache ever) ─────────

    function test_CL04a_cacheTs_zero_returns_CONFIDENCE_ZERO() public view {
        assertEq(
            h.tvlConfidence(1_000_000e6, 0, STALENESS),
            StrategyConfigLib.CONFIDENCE_ZERO,
            "cacheTs=0, extTVL=1M: must return ZERO"
        );
        assertEq(
            h.tvlConfidence(0, 0, STALENESS),
            StrategyConfigLib.CONFIDENCE_ZERO,
            "cacheTs=0, extTVL=0: must return ZERO (regression: old lens returned MICRO)"
        );
    }

    // ── State 2: stale cache -> CONFIDENCE_MICRO ──────────────────────────

    function test_CL04b_stale_cache_returns_CONFIDENCE_MICRO() public view {
        uint64 staleTs = uint64(BASE_TS - STALENESS - 1);
        assertEq(
            h.tvlConfidence(50_000_000e6, staleTs, STALENESS),
            StrategyConfigLib.CONFIDENCE_MICRO,
            "stale cache must return MICRO"
        );
    }

    function test_CL04c_staleness_zero_skips_stale_check() public view {
        uint64 oldTs = 1; // a timestamp well in the past; avoids underflow with small BASE_TS
        // Use 25M: clearly in [10M, 50M) band -> CONFIDENCE_MED.
        // (50M hits the >= 50M threshold exactly -> CONFIDENCE_HIGH, not MED.)
        assertEq(
            h.tvlConfidence(25_000_000e6, oldTs, 0),
            StrategyConfigLib.CONFIDENCE_MED,
            "staleness=0 must use TVL band (25M -> MED)"
        );
    }

    // ── State 3: fresh cache, 7 TVL bands ────────────────────────────────

    function test_CL04d_fresh_tvl_bands() public view {
        uint64 freshTs = uint64(BASE_TS - 60);

        assertEq(h.tvlConfidence(99_999e6,     freshTs, STALENESS), StrategyConfigLib.CONFIDENCE_ZERO,  "<100K");
        assertEq(h.tvlConfidence(100_000e6,    freshTs, STALENESS), StrategyConfigLib.CONFIDENCE_MICRO, ">=100K");
        assertEq(h.tvlConfidence(499_999e6,    freshTs, STALENESS), StrategyConfigLib.CONFIDENCE_MICRO, "<500K");
        assertEq(h.tvlConfidence(500_000e6,    freshTs, STALENESS), StrategyConfigLib.CONFIDENCE_SMALL, ">=500K");
        assertEq(h.tvlConfidence(1_999_999e6,  freshTs, STALENESS), StrategyConfigLib.CONFIDENCE_SMALL, "<2M");
        assertEq(h.tvlConfidence(2_000_000e6,  freshTs, STALENESS), StrategyConfigLib.CONFIDENCE_LOW,   ">=2M");
        assertEq(h.tvlConfidence(9_999_999e6,  freshTs, STALENESS), StrategyConfigLib.CONFIDENCE_LOW,   "<10M");
        assertEq(h.tvlConfidence(10_000_000e6, freshTs, STALENESS), StrategyConfigLib.CONFIDENCE_MED,   ">=10M");
        assertEq(h.tvlConfidence(49_999_999e6, freshTs, STALENESS), StrategyConfigLib.CONFIDENCE_MED,   "<50M");
        assertEq(h.tvlConfidence(50_000_000e6, freshTs, STALENESS), StrategyConfigLib.CONFIDENCE_HIGH,  ">=50M");
        assertEq(h.tvlConfidence(249_999_999e6,freshTs, STALENESS), StrategyConfigLib.CONFIDENCE_HIGH,  "<250M");
        assertEq(h.tvlConfidence(250_000_000e6,freshTs, STALENESS), StrategyConfigLib.CONFIDENCE_VHIGH, ">=250M");
    }

    // ── HIGH-LENS-03 divergence regressions ──────────────────────────────
    // Old lens divergences from the core:
    //   (A) cacheTs==0 -> old lens: MICRO (via extTVL<1 branch), core/lib: ZERO
    //   (B) fresh + extTVL==0 -> old lens: MICRO (via extTVL<1 branch), core/lib: ZERO

    function test_CL05a_regression_cacheTs0_extTVL0_returns_ZERO() public view {
        assertEq(
            h.tvlConfidence(0, 0, STALENESS),
            StrategyConfigLib.CONFIDENCE_ZERO,
            "HIGH-LENS-03A: cacheTs=0, extTVL=0 must be ZERO (not MICRO)"
        );
    }

    function test_CL05b_regression_fresh_extTVL0_returns_ZERO() public view {
        uint64 freshTs = uint64(BASE_TS - 60);
        assertEq(
            h.tvlConfidence(0, freshTs, STALENESS),
            StrategyConfigLib.CONFIDENCE_ZERO,
            "HIGH-LENS-03B: fresh cacheTs, extTVL=0 must be ZERO (not MICRO)"
        );
    }

    // ── Fuzz ─────────────────────────────────────────────────────────────

    function testFuzz_CL06_tvlConfidence_returns_valid_band(
        uint256 extTVL,
        uint64  cacheTs,
        uint32  staleness,
        uint64  blockOffset
    ) public {
        blockOffset = uint64(bound(blockOffset, 0, 365 days * 10));
        vm.warp(BASE_TS + blockOffset);
        // Production invariant: cacheTs is always set by `block.timestamp` at poke time.
        // cacheTs > block.timestamp is an impossible state; constrain to valid domain.
        vm.assume(uint256(cacheTs) <= block.timestamp);

        uint256 conf = h.tvlConfidence(extTVL, cacheTs, staleness);
        bool valid = (conf == StrategyConfigLib.CONFIDENCE_ZERO
                   || conf == StrategyConfigLib.CONFIDENCE_MICRO
                   || conf == StrategyConfigLib.CONFIDENCE_SMALL
                   || conf == StrategyConfigLib.CONFIDENCE_LOW
                   || conf == StrategyConfigLib.CONFIDENCE_MED
                   || conf == StrategyConfigLib.CONFIDENCE_HIGH
                   || conf == StrategyConfigLib.CONFIDENCE_VHIGH);
        assertTrue(valid, "result not a valid confidence band");
        if (cacheTs == 0) {
            assertEq(conf, StrategyConfigLib.CONFIDENCE_ZERO, "cacheTs=0 must always be ZERO");
        }
    }
}
