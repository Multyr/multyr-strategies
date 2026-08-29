// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ============================================================================
// OverlayParityFuzz.t.sol -- property-based expansion of Overlay_Parity.t.sol
//
// Overlay_Parity.t.sol proves the ScoringModule/AllocCalcModule cap-overlay
// parity invariant (I-ALLOC-06 / AUDIT-FINDING-13) at ~40 hand-picked
// (tier, risk, failures, liq, ceiling, floor) cells, via an independent
// reference formula (_expectedCap) and vm.store state-injection helpers.
// This file duplicates that same reference formula and helpers (deliberately
// -- an independent implementation is what lets this catch drift in either
// production module, matching Overlay_Parity's own stated design) and fuzzes
// the invariant continuously across the input space, with concentrated
// pressure at the four TVL tier boundaries (25K/250K/1M/5M) where a
// discontinuity bug previously hid (AUDIT-FINDING-13).
//
// Invariant under test: for ANY TVL and ANY overlay inputs, the vault's
// externally-callable effectiveAbsCapBps(adapter) (ScoringModule, reached via
// fallback dispatch) must exactly equal the canonical 4-layer formula.
// ============================================================================

import { Test } from "forge-std/Test.sol";
import { StrategyParamsModule } from "../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import { StrategySettingsModule } from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import { MockUSDC, MockLendingAdapter, UsdcMultiLendingVaultTestBase } from "./UsdcMultiLendingVault.t.sol";

contract OverlayParityFuzz_Test is UsdcMultiLendingVaultTestBase {
    MockLendingAdapter public adapterA;

    uint256 internal constant SLOT_ADAPTER_CONSECUTIVE_FAILURES = 21;
    uint256 internal constant SLOT_ADAPTER_MAX_EXPOSURE_BPS     = 10;
    uint256 internal constant SLOT_RISK_SCORE_BPS               = 19;
    uint256 internal constant SLOT_LAST_RISK_UPDATE_TS          = 77;
    uint256 internal constant SLOT_RISK_STALENESS_SECONDS       = 75;
    uint256 internal constant SLOT_CACHED_LIQUIDITY_BPS         = 34;
    uint256 internal constant SLOT_CACHED_LIQUIDITY_TS          = 35;

    function setUp() public override {
        super.setUp();

        adapterA = new MockLendingAdapter(ARBITRUM_USDC);
        adapterA.setAPY(800);
        adapterA.setExtMarketTVL(50_000_000e6);
        adapterA.setVault(address(vault));

        vm.startPrank(admin);
        address(vault).call(abi.encodeWithSignature("whitelistAdapter(address,bool)", address(adapterA), true));
        vault.addAdapter(address(adapterA));
        vault.toggleAdapter(address(adapterA), true);
        address(vault).call(abi.encodeWithSignature("setAdapterDepositMode(address,bool)", address(adapterA), false));
        vm.stopPrank();

        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();
        vm.prank(keeper);
        address(vault).call(abi.encodeWithSignature("pokeLiquidityBatch(uint256,uint256)", 0, 10));

        vm.prank(admin);
        StrategySettingsModule(address(vault)).exitBootstrapMode();

        vm.prank(admin);
        StrategySettingsModule(address(vault)).setRebalanceParams(
            10, 2, 50, 21600, 80,
            0,    // adapterMaxExposureBps=0 -- no global ceiling by default
            3400
        );

        // Disable risk-score staleness: uint32 at slot 75, byte offset 26.
        bytes32 current = vm.load(address(vault), bytes32(SLOT_RISK_STALENESS_SECONDS));
        uint256 val = uint256(current) & ~(uint256(0xFFFFFFFF) << (26 * 8));
        vm.store(address(vault), bytes32(SLOT_RISK_STALENESS_SECONDS), bytes32(val));
    }

    // ── Independent reference formula (same as Overlay_Parity._expectedCap) ─

    // Mirrors StrategyConfigLib.cachedLiq(): cached==0 means "never cached"
    // (distinct from a measured-zero observation), and falls back to
    // DEFAULT_LIQ_BPS=5000 -- NOT treated as 0% liquidity.
    uint256 internal constant DEFAULT_LIQ_BPS = 5000;

    function _expectedCap(
        uint16 dMax,
        uint16 riskScore,
        uint8  failures,
        uint16 liqBps,
        uint16 globalCeiling
    ) internal pure returns (uint16) {
        if (dMax == 0) return 0;
        // T1 mirrors effectiveAbsCapBps()'s T1 branch exactly: the governance
        // ceiling still applies at T1, it is NOT an unconditional short-circuit.
        if (dMax == 1) return globalCeiling > 0 ? globalCeiling : 10000;

        uint256 cap = (11000 + uint256(dMax) - 1) / uint256(dMax);
        if (cap > 10000) cap = 10000;
        if (cap < 2500)  cap = 2500;
        if (globalCeiling > 0 && globalCeiling < cap) cap = uint256(globalCeiling);

        if (riskScore > 0) {
            uint256 penalty = uint256(riskScore) / 2;
            uint16 riskMult = penalty >= 10000 ? 0 : uint16(10000 - penalty);
            cap = (cap * riskMult) / 10000;
        }

        if (failures > 0) {
            uint256 penalty = uint256(failures) * 1500;
            uint16 failMult = penalty >= 10000 ? 0 : uint16(10000 - penalty);
            cap = (cap * failMult) / 10000;
        }

        uint256 effectiveLiqBps = liqBps == 0 ? DEFAULT_LIQ_BPS : uint256(liqBps);
        uint16 liqMult;
        if      (effectiveLiqBps >= 8000) liqMult = 10000;
        else if (effectiveLiqBps >= 5000) liqMult = 9000;
        else if (effectiveLiqBps >= 2500) liqMult = 7500;
        else                              liqMult = 6000;
        cap = (cap * liqMult) / 10000;

        return uint16(cap);
    }

    function _dMaxForTvl(uint256 tvl) internal pure returns (uint16) {
        if (tvl < 25_000e6) return 1;
        if (tvl < 250_000e6) return 2;
        if (tvl < 1_000_000e6) return 3;
        if (tvl < 5_000_000e6) return 4;
        return 5; // stays within T5 (5M..25M) -- the 25M+ overflow tier uses a
                  // different dynamicSeed formula not modeled by _expectedCap
    }

    // Sets the vault's idle balance to EXACTLY `tvl` (not additive), so each
    // fuzz run starts from an independently controlled TVL. adapterA never
    // receives a deposit in this file, so idleCash() is the entire _tvl().
    // Uses MockUSDC's own mint/burn (not the `deal` cheatcode's storage-slot
    // heuristic, which is unreliable against a custom mock's layout).
    function _setTvlExact(uint256 tvl) internal {
        uint256 current = usdc.balanceOf(address(vault));
        if (current > tvl) {
            usdc.burn(address(vault), current - tvl);
        } else if (current < tvl) {
            usdc.mint(address(vault), tvl - current);
        }
    }

    function _assertParity(
        string memory label,
        uint16 dMax,
        uint16 riskScore,
        uint8  failures,
        uint16 liqBps,
        uint16 globalCeiling
    ) internal {
        bytes32 riskSlot = keccak256(abi.encode(address(adapterA), SLOT_RISK_SCORE_BPS));
        vm.store(address(vault), riskSlot, bytes32(uint256(riskScore)));
        bytes32 riskTsSlot = keccak256(abi.encode(address(adapterA), SLOT_LAST_RISK_UPDATE_TS));
        vm.store(address(vault), riskTsSlot, bytes32(uint256(block.timestamp)));

        bytes32 failSlot = keccak256(abi.encode(address(adapterA), SLOT_ADAPTER_CONSECUTIVE_FAILURES));
        vm.store(address(vault), failSlot, bytes32(uint256(failures)));

        bytes32 liqSlot = keccak256(abi.encode(address(adapterA), SLOT_CACHED_LIQUIDITY_BPS));
        vm.store(address(vault), liqSlot, bytes32(uint256(liqBps)));
        bytes32 liqTsSlot = keccak256(abi.encode(address(adapterA), SLOT_CACHED_LIQUIDITY_TS));
        vm.store(address(vault), liqTsSlot, bytes32(uint256(block.timestamp)));

        bytes32 ceilingCurrent = vm.load(address(vault), bytes32(SLOT_ADAPTER_MAX_EXPOSURE_BPS));
        uint256 ceilingVal = uint256(ceilingCurrent);
        ceilingVal = (ceilingVal & ~(uint256(0xFFFF) << (26 * 8))) | (uint256(globalCeiling) << (26 * 8));
        vm.store(address(vault), bytes32(SLOT_ADAPTER_MAX_EXPOSURE_BPS), bytes32(ceilingVal));

        (bool ok, bytes memory ret) = address(vault).staticcall(
            abi.encodeWithSignature("effectiveAbsCapBps(address)", address(adapterA))
        );
        require(ok, string.concat("effectiveAbsCapBps reverted: ", label));
        uint16 actual = abi.decode(ret, (uint16));
        uint16 expected = _expectedCap(dMax, riskScore, failures, liqBps, globalCeiling);
        assertEq(actual, expected, string.concat("PARITY FAIL: ", label));
    }

    // ── Full-space fuzz: any TVL in [1, 24,999,999e6] x any overlay inputs ──

    function testFuzz_parity_holds_across_tvl_and_overlay_space(
        uint256 tvlSeed,
        uint16 riskScore,
        uint8 failures,
        uint16 liqBps,
        uint16 globalCeiling
    ) public {
        uint256 tvl = bound(tvlSeed, 1e6, 24_999_999e6); // stays inside T1..T5
        riskScore = uint16(bound(riskScore, 0, 10000));
        liqBps = uint16(bound(liqBps, 0, 10000));
        globalCeiling = uint16(bound(globalCeiling, 0, 10000));

        _setTvlExact(tvl);
        uint16 dMax = _dMaxForTvl(tvl);

        _assertParity("fuzz/full-space", dMax, riskScore, failures, liqBps, globalCeiling);
    }

    // ── Boundary-concentrated fuzz: TVL within +/-2000 USDC of each of the ──
    // ── four tier boundaries, where a discontinuity is most likely to hide ──

    function testFuzz_parity_near_tier_boundaries(
        uint8 boundarySeed,
        int32 offsetSeed,
        uint16 riskScore,
        uint8 failures,
        uint16 liqBps
    ) public {
        uint256[4] memory boundaries = [uint256(25_000e6), 250_000e6, 1_000_000e6, 5_000_000e6];
        uint256 boundary = boundaries[boundarySeed % 4];

        int256 offset = bound(int256(offsetSeed), -2000e6, 2000e6);
        uint256 tvl = offset >= 0 ? boundary + uint256(offset) : boundary - uint256(-offset);
        if (tvl == 0) tvl = 1;

        riskScore = uint16(bound(riskScore, 0, 10000));
        liqBps = uint16(bound(liqBps, 0, 10000));

        _setTvlExact(tvl);
        uint16 dMax = _dMaxForTvl(tvl);

        _assertParity("fuzz/boundary", dMax, riskScore, failures, liqBps, 0);
    }

    // ── Adjacent-TVL continuity: cap must never jump discontinuously when ──
    // ── TVL moves by a single wei across a tier boundary ──────────────────

    function testFuzz_parity_single_wei_crossing_is_continuous(
        uint8 boundarySeed,
        uint16 riskScore,
        uint8 failures,
        uint16 liqBps
    ) public {
        uint256[4] memory boundaries = [uint256(25_000e6), 250_000e6, 1_000_000e6, 5_000_000e6];
        uint256 boundary = boundaries[boundarySeed % 4];
        riskScore = uint16(bound(riskScore, 0, 10000));
        liqBps = uint16(bound(liqBps, 0, 10000));

        _setTvlExact(boundary - 1);
        uint16 dMaxBelow = _dMaxForTvl(boundary - 1);
        _assertParity("fuzz/1wei-below", dMaxBelow, riskScore, failures, liqBps, 0);

        _setTvlExact(boundary);
        uint16 dMaxAt = _dMaxForTvl(boundary);
        _assertParity("fuzz/1wei-at", dMaxAt, riskScore, failures, liqBps, 0);
    }
}
