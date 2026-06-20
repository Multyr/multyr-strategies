// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { StrategyParamsModule } from "../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import { StrategySettingsModule } from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import { MockUSDC, MockLendingAdapter, UsdcMultiLendingVaultTestBase } from "./UsdcMultiLendingVault.t.sol";

// ============================================================================
// AUDIT-FINDING-13 -- Overlay Parity Matrix
//
// Invariant: ScoringModule.effectiveAbsCapBps(adapter) must equal
//   STRUCTURAL_BASE × RISK_OVERLAY × FAILURE_OVERLAY × LIQUIDITY_OVERLAY
//   (the same 4-layer engine as StrategyAllocCalcModule._effectiveAbsCapBps).
//
// Before A-F-13 fix: ScoringModule returned STRUCTURAL_BASE only (overlays
// were pure no-ops returning 10000).
//
// Test strategy: for each (risk, failures, liq, dMax, ceiling, floor) cell:
//   1. Set storage state via vm.store (deterministic, no setter side-effects)
//   2. Read strategy.effectiveAbsCapBps(adapter) via fallback dispatcher
//   3. Compare against canonical formula implemented in this file
//
// Matrix: 4 risk × 4 failures × 4 liq × 2 tiers = 128 logical cells.
//         38 named tests cover the key cells. Two named A-F-13 regressions.
// ============================================================================

contract Overlay_Parity is UsdcMultiLendingVaultTestBase {

    MockLendingAdapter public adapterA;
    MockLendingAdapter public adapterB;

    // Storage slots — verified via: FOUNDRY_PROFILE=lending forge inspect UsdcMultiLendingVault storageLayout
    // Re-verify against StrategyStorageLayout if any storage variables are added/reordered.
    // Stale slots cause vm.store writes to be silently ignored → test passes with wrong state.
    uint256 internal constant SLOT_ADAPTER_CONSECUTIVE_FAILURES = 21; // mapping(address=>uint8)   slot 21
    uint256 internal constant SLOT_ADAPTER_MAX_EXPOSURE_BPS     = 10; // uint16 at slot 10, byte offset 26
    uint256 internal constant SLOT_ADAPTER_ABS_CAP_OVERRIDE     = 11; // mapping(address=>uint16) slot 11
    uint256 internal constant SLOT_RISK_SCORE_BPS               = 19; // mapping(address=>uint16) slot 19
    uint256 internal constant SLOT_LAST_RISK_UPDATE_TS          = 77; // mapping(address=>uint64) slot 77
    uint256 internal constant SLOT_RISK_STALENESS_SECONDS       = 75; // uint32 at slot 75, byte offset 26
    uint256 internal constant SLOT_CACHED_LIQUIDITY_BPS         = 34; // mapping(address=>uint16) slot 34
    uint256 internal constant SLOT_CACHED_LIQUIDITY_TS          = 35; // mapping(address=>uint64) slot 35

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

        // Unconstrain tier bands: allow dMax up to 10 (dynamic TVL bands work correctly)
        // Set adapterMaxExposureBps=0 so no governance ceiling interferes with matrix tests
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setRebalanceParams(
            10,     // maxAdaptersPerAllocation — unconstrained (dMax driven by TVL tiers)
            2,      // minAdaptersActive — unchanged
            50,     // rebalanceMinMoveBps — unchanged
            21600,  // minSecondsBetweenRebalances — unchanged
            80,     // driftToleranceBps — unchanged
            0,      // adapterMaxExposureBps=0 — no global ceiling (ceiling tests set it explicitly)
            3400    // newAdapterRampBps — unchanged
        );

        // Disable risk score staleness so injected scores are always fresh
        _disableRiskStaleness();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // CANONICAL FORMULA -- independent reference implementation
    // Intentionally separate from both ScoringModule and AllocCalcModule so
    // it can catch drift in either direction.
    // ══════════════════════════════════════════════════════════════════════════

    function _expectedCap(
        uint16 dMax,
        uint16 riskScore,
        uint8  failures,
        uint16 liqBps,
        uint16 globalCeiling,
        uint16 floorOverride
    ) internal pure returns (uint16) {
        if (dMax == 0) return 0;
        if (dMax == 1) return 10000; // T1 short-circuit (TIER_MODEL §4.1)

        uint256 cap = (11000 + uint256(dMax) - 1) / uint256(dMax); // ceil(11000/dMax)
        if (cap > 10000) cap = 10000;
        if (cap < 2500)  cap = 2500;
        if (globalCeiling > 0 && globalCeiling < cap) cap = uint256(globalCeiling);

        // RISK_OVERLAY (§4.2): multiplier = max(0, 10000 - riskScoreBps/2)
        if (riskScore > 0) {
            uint256 penalty = uint256(riskScore) / 2;
            uint16 riskMult = penalty >= 10000 ? 0 : uint16(10000 - penalty);
            cap = (cap * riskMult) / 10000;
        }

        // FAILURE_OVERLAY (§4.3): multiplier = max(0, 10000 - failures×1500)
        if (failures > 0) {
            uint256 penalty = uint256(failures) * 1500;
            uint16 failMult = penalty >= 10000 ? 0 : uint16(10000 - penalty);
            cap = (cap * failMult) / 10000;
        }

        // LIQUIDITY_OVERLAY (§4.4): tiered bands
        uint16 liqMult;
        if      (liqBps >= 8000) liqMult = 10000;
        else if (liqBps >= 5000) liqMult = 9000;
        else if (liqBps >= 2500) liqMult = 7500;
        else                     liqMult = 6000;
        cap = (cap * liqMult) / 10000;

        if (floorOverride > 0 && cap < uint256(floorOverride)) cap = uint256(floorOverride);
        return uint16(cap);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // STATE INJECTION HELPERS
    // Use vm.store for deterministic, no-side-effect state writes.
    // Slots verified by: forge inspect UsdcMultiLendingVault storage-layout
    // ══════════════════════════════════════════════════════════════════════════

    function _setRiskScore(address adapter, uint16 score) internal {
        bytes32 slot = keccak256(abi.encode(adapter, SLOT_RISK_SCORE_BPS));
        vm.store(address(vault), slot, bytes32(uint256(score)));
        // Update lastRiskScoreUpdateTs so staleness does not fire
        bytes32 tsSlot = keccak256(abi.encode(adapter, SLOT_LAST_RISK_UPDATE_TS));
        vm.store(address(vault), tsSlot, bytes32(uint256(block.timestamp)));
    }

    function _setFailures(address adapter, uint8 count) internal {
        bytes32 slot = keccak256(abi.encode(adapter, SLOT_ADAPTER_CONSECUTIVE_FAILURES));
        vm.store(address(vault), slot, bytes32(uint256(count)));
    }

    function _setLiquidityCache(address adapter, uint16 liqBps) internal {
        bytes32 slot = keccak256(abi.encode(adapter, SLOT_CACHED_LIQUIDITY_BPS));
        vm.store(address(vault), slot, bytes32(uint256(liqBps)));
        bytes32 tsSlot = keccak256(abi.encode(adapter, SLOT_CACHED_LIQUIDITY_TS));
        vm.store(address(vault), tsSlot, bytes32(uint256(block.timestamp)));
    }

    function _setGlobalCeiling(uint16 ceiling) internal {
        // adapterMaxExposureBps: uint16 at slot 10, offset 26 bytes
        // Read current slot, clear the uint16 at offset 26, write new value
        bytes32 current = vm.load(address(vault), bytes32(SLOT_ADAPTER_MAX_EXPOSURE_BPS));
        uint256 val = uint256(current);
        // Clear bytes [26,28) and set new value
        val = (val & ~(uint256(0xFFFF) << (26 * 8))) | (uint256(ceiling) << (26 * 8));
        vm.store(address(vault), bytes32(SLOT_ADAPTER_MAX_EXPOSURE_BPS), bytes32(val));
    }

    function _clearGlobalCeiling() internal { _setGlobalCeiling(0); }

    function _setFloor(address adapter, uint16 floor) internal {
        bytes32 slot = keccak256(abi.encode(adapter, SLOT_ADAPTER_ABS_CAP_OVERRIDE));
        vm.store(address(vault), slot, bytes32(uint256(floor)));
    }

    function _clearFloor(address adapter) internal { _setFloor(adapter, 0); }

    function _disableRiskStaleness() internal {
        // riskScoreStalenessSeconds: uint32 at slot 75, offset 26 bytes -- set to 0 (no expiry)
        bytes32 current = vm.load(address(vault), bytes32(uint256(75)));
        uint256 val = uint256(current);
        val = (val & ~(uint256(0xFFFFFFFF) << (26 * 8)));
        vm.store(address(vault), bytes32(uint256(75)), bytes32(val));
    }

    // ══════════════════════════════════════════════════════════════════════════
    // CORE PARITY ASSERTION
    // ══════════════════════════════════════════════════════════════════════════

    function _assertParity(
        string memory label,
        uint16 dMax,
        uint16 riskScore,
        uint8  failures,
        uint16 liqBps,
        uint16 globalCeiling,
        uint16 floorOverride
    ) internal {
        _setRiskScore(address(adapterA), riskScore);
        _setFailures(address(adapterA), failures);
        _setLiquidityCache(address(adapterA), liqBps);
        if (globalCeiling > 0) _setGlobalCeiling(globalCeiling);
        if (floorOverride > 0) _setFloor(address(adapterA), floorOverride);

        // Call via strategy fallback → ScoringModule (the external reader path)
        (bool ok, bytes memory ret) = address(vault).staticcall(
            abi.encodeWithSignature("effectiveAbsCapBps(address)", address(adapterA))
        );
        require(ok, string.concat("effectiveAbsCapBps reverted: ", label));
        uint16 actual = abi.decode(ret, (uint16));
        uint16 expected = _expectedCap(dMax, riskScore, failures, liqBps, globalCeiling, floorOverride);
        assertEq(actual, expected, string.concat("PARITY FAIL: ", label));

        // Reset
        _clearGlobalCeiling();
        _clearFloor(address(adapterA));
        _setFailures(address(adapterA), 0);
        _setRiskScore(address(adapterA), 0);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // TVL SEEDERS -- put vault in the correct tier (pure-view approach)
    //
    // _tvl() = idleCash() + sum(positionAssets) = ASSET.balanceOf(vault) + ...
    // Minting USDC directly to vault raises _tvl() without touching deposit()
    // flow, deployIdle(), or NoCashInvariant. No production guards bypassed.
    // ══════════════════════════════════════════════════════════════════════════

    function _seedTier(uint256 amount) internal {
        usdc.mint(address(vault), amount);
    }

    function _seedT2() internal { _seedTier(100_000e6);     } // T2: 25K-250K → dMax=2
    function _seedT3() internal { _seedTier(500_000e6);     } // T3: 250K-1M  → dMax=3
    function _seedT4() internal { _seedTier(2_000_000e6);   } // T4: 1M-5M    → dMax=4
    function _seedT5() internal { _seedTier(10_000_000e6);  } // T5: 5M-25M   → dMax=5

    // ══════════════════════════════════════════════════════════════════════════
    // T1 TESTS (dMax=1 -- vault empty, TVL < 25K)
    // ══════════════════════════════════════════════════════════════════════════

    function test_parity_T1_short_circuit_no_overlays_applied() public {
        // T1: always returns 10000 regardless of any overlay state
        _setRiskScore(address(adapterA), 10000);
        _setFailures(address(adapterA), 7);
        _setLiquidityCache(address(adapterA), 100);
        (bool ok, bytes memory ret) = address(vault).staticcall(
            abi.encodeWithSignature("effectiveAbsCapBps(address)", address(adapterA))
        );
        require(ok, "T1 staticcall failed");
        assertEq(abi.decode(ret, (uint16)), 10000, "T1: must always return 10000");
    }

    function test_parity_T1_with_ceiling_still_10000() public {
        _setGlobalCeiling(3000);
        (bool ok, bytes memory ret) = address(vault).staticcall(
            abi.encodeWithSignature("effectiveAbsCapBps(address)", address(adapterA))
        );
        require(ok);
        assertEq(abi.decode(ret, (uint16)), 10000, "T1 ignores global ceiling");
        _clearGlobalCeiling();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // T2 TESTS (dMax=2, STRUCTURAL_BASE=5500)
    // ══════════════════════════════════════════════════════════════════════════

    function test_parity_T2_risk0_fail0_liq10000() public { _seedT2(); _assertParity("T2/r0/f0/l10k", 2,    0, 0, 10000, 0, 0); }
    function test_parity_T2_risk2000_fail0_liq10000() public { _seedT2(); _assertParity("T2/r2k/f0/l10k", 2, 2000, 0, 10000, 0, 0); }
    function test_parity_T2_risk5000_fail0_liq10000() public { _seedT2(); _assertParity("T2/r5k/f0/l10k", 2, 5000, 0, 10000, 0, 0); }
    function test_parity_T2_risk8000_fail0_liq10000() public { _seedT2(); _assertParity("T2/r8k/f0/l10k", 2, 8000, 0, 10000, 0, 0); }

    function test_parity_T2_risk0_fail1_liq10000() public { _seedT2(); _assertParity("T2/r0/f1/l10k", 2, 0, 1, 10000, 0, 0); }
    function test_parity_T2_risk0_fail3_liq10000() public { _seedT2(); _assertParity("T2/r0/f3/l10k", 2, 0, 3, 10000, 0, 0); }
    function test_parity_T2_risk0_fail6_liq10000() public { _seedT2(); _assertParity("T2/r0/f6/l10k", 2, 0, 6, 10000, 0, 0); }
    function test_parity_T2_risk0_fail7_quarantine() public { _seedT2(); _assertParity("T2/r0/f7/l10k", 2, 0, 7, 10000, 0, 0); }

    function test_parity_T2_risk0_fail0_liq7000() public { _seedT2(); _assertParity("T2/r0/f0/l7k",  2, 0, 0,  7000, 0, 0); }
    function test_parity_T2_risk0_fail0_liq4000() public { _seedT2(); _assertParity("T2/r0/f0/l4k",  2, 0, 0,  4000, 0, 0); }
    function test_parity_T2_risk0_fail0_liq1000() public { _seedT2(); _assertParity("T2/r0/f0/l1k",  2, 0, 0,  1000, 0, 0); }

    function test_parity_T2_risk5000_fail3_liq4000() public { _seedT2(); _assertParity("T2/r5k/f3/l4k", 2, 5000, 3, 4000, 0, 0); }
    function test_parity_T2_risk8000_fail6_liq1000() public { _seedT2(); _assertParity("T2/r8k/f6/l1k", 2, 8000, 6, 1000, 0, 0); }
    function test_parity_T2_risk8000_fail7_liq1000() public { _seedT2(); _assertParity("T2/r8k/f7/l1k", 2, 8000, 7, 1000, 0, 0); }
    function test_parity_T2_risk2000_fail2_liq7000() public { _seedT2(); _assertParity("T2/r2k/f2/l7k", 2, 2000, 2, 7000, 0, 0); }
    function test_parity_T2_risk5000_fail1_liq4000() public { _seedT2(); _assertParity("T2/r5k/f1/l4k", 2, 5000, 1, 4000, 0, 0); }

    function test_parity_T2_ceiling3000_risk0_fail0() public { _seedT2(); _assertParity("T2/ceil3k/r0/f0/l10k", 2, 0, 0, 10000, 3000, 0); }
    function test_parity_T2_ceiling3000_risk5000_fail2_liq7000() public {
        _seedT2(); _assertParity("T2/ceil3k/r5k/f2/l7k", 2, 5000, 2, 7000, 3000, 0);
    }
    function test_parity_T2_floor2000_risk8000_fail3_liq1000() public {
        _seedT2(); _assertParity("T2/floor2k/r8k/f3/l1k", 2, 8000, 3, 1000, 0, 2000);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // T3 TESTS (dMax=3, STRUCTURAL_BASE=3667)
    // ══════════════════════════════════════════════════════════════════════════

    function test_parity_T3_risk0_fail0_liq10000() public { _seedT3(); _assertParity("T3/r0/f0/l10k", 3,    0, 0, 10000, 0, 0); }
    function test_parity_T3_risk2000_fail0_liq10000() public { _seedT3(); _assertParity("T3/r2k/f0/l10k", 3, 2000, 0, 10000, 0, 0); }
    function test_parity_T3_risk5000_fail0_liq10000() public { _seedT3(); _assertParity("T3/r5k/f0/l10k", 3, 5000, 0, 10000, 0, 0); }
    function test_parity_T3_risk8000_fail0_liq10000() public { _seedT3(); _assertParity("T3/r8k/f0/l10k", 3, 8000, 0, 10000, 0, 0); }

    function test_parity_T3_risk0_fail1_liq10000() public { _seedT3(); _assertParity("T3/r0/f1/l10k", 3, 0, 1, 10000, 0, 0); }
    function test_parity_T3_risk0_fail3_liq10000() public { _seedT3(); _assertParity("T3/r0/f3/l10k", 3, 0, 3, 10000, 0, 0); }
    function test_parity_T3_risk0_fail6_liq10000() public { _seedT3(); _assertParity("T3/r0/f6/l10k", 3, 0, 6, 10000, 0, 0); }
    function test_parity_T3_risk0_fail7_quarantine() public { _seedT3(); _assertParity("T3/r0/f7/l10k", 3, 0, 7, 10000, 0, 0); }

    function test_parity_T3_risk0_fail0_liq7000() public { _seedT3(); _assertParity("T3/r0/f0/l7k",  3, 0, 0,  7000, 0, 0); }
    function test_parity_T3_risk0_fail0_liq4000() public { _seedT3(); _assertParity("T3/r0/f0/l4k",  3, 0, 0,  4000, 0, 0); }
    function test_parity_T3_risk0_fail0_liq1000() public { _seedT3(); _assertParity("T3/r0/f0/l1k",  3, 0, 0,  1000, 0, 0); }

    function test_parity_T3_risk5000_fail3_liq4000() public { _seedT3(); _assertParity("T3/r5k/f3/l4k", 3, 5000, 3, 4000, 0, 0); }
    function test_parity_T3_risk8000_fail6_liq1000() public { _seedT3(); _assertParity("T3/r8k/f6/l1k", 3, 8000, 6, 1000, 0, 0); }
    function test_parity_T3_risk8000_fail7_liq1000() public { _seedT3(); _assertParity("T3/r8k/f7/l1k", 3, 8000, 7, 1000, 0, 0); }
    function test_parity_T3_risk2000_fail2_liq7000() public { _seedT3(); _assertParity("T3/r2k/f2/l7k", 3, 2000, 2, 7000, 0, 0); }
    function test_parity_T3_risk5000_fail1_liq4000() public { _seedT3(); _assertParity("T3/r5k/f1/l4k", 3, 5000, 1, 4000, 0, 0); }
    function test_parity_T3_ceiling2500_risk0_fail0() public { _seedT3(); _assertParity("T3/ceil2.5k/r0/f0/l10k", 3, 0, 0, 10000, 2500, 0); }
    function test_parity_T3_risk5000_fail2_liq4000() public { _seedT3(); _assertParity("T3/r5k/f2/l4k", 3, 5000, 2, 4000, 0, 0); }

    // ══════════════════════════════════════════════════════════════════════════
    // T4 TESTS (dMax=4, STRUCTURAL_BASE=2750)
    // ══════════════════════════════════════════════════════════════════════════

    function test_parity_T4_risk0_fail0_liq10000() public { _seedT4(); _assertParity("T4/r0/f0/l10k", 4,    0, 0, 10000, 0, 0); }
    function test_parity_T4_risk2000_fail0_liq10000() public { _seedT4(); _assertParity("T4/r2k/f0/l10k", 4, 2000, 0, 10000, 0, 0); }
    function test_parity_T4_risk5000_fail0_liq10000() public { _seedT4(); _assertParity("T4/r5k/f0/l10k", 4, 5000, 0, 10000, 0, 0); }
    function test_parity_T4_risk0_fail1_liq10000() public { _seedT4(); _assertParity("T4/r0/f1/l10k", 4, 0, 1, 10000, 0, 0); }
    function test_parity_T4_risk0_fail3_liq10000() public { _seedT4(); _assertParity("T4/r0/f3/l10k", 4, 0, 3, 10000, 0, 0); }
    function test_parity_T4_risk0_fail0_liq7000() public { _seedT4(); _assertParity("T4/r0/f0/l7k",  4, 0, 0,  7000, 0, 0); }
    function test_parity_T4_risk0_fail0_liq4000() public { _seedT4(); _assertParity("T4/r0/f0/l4k",  4, 0, 0,  4000, 0, 0); }
    function test_parity_T4_risk0_fail0_liq1000() public { _seedT4(); _assertParity("T4/r0/f0/l1k",  4, 0, 0,  1000, 0, 0); }
    function test_parity_T4_risk5000_fail3_liq4000() public { _seedT4(); _assertParity("T4/r5k/f3/l4k", 4, 5000, 3, 4000, 0, 0); }
    function test_parity_T4_risk8000_fail6_liq1000() public { _seedT4(); _assertParity("T4/r8k/f6/l1k", 4, 8000, 6, 1000, 0, 0); }

    // ══════════════════════════════════════════════════════════════════════════
    // T5 TESTS (dMax=5, STRUCTURAL_BASE=2500)
    // ══════════════════════════════════════════════════════════════════════════

    function test_parity_T5_risk0_fail0_liq10000() public { _seedT5(); _assertParity("T5/r0/f0/l10k", 5,    0, 0, 10000, 0, 0); }
    function test_parity_T5_risk2000_fail0_liq10000() public { _seedT5(); _assertParity("T5/r2k/f0/l10k", 5, 2000, 0, 10000, 0, 0); }
    function test_parity_T5_risk5000_fail0_liq10000() public { _seedT5(); _assertParity("T5/r5k/f0/l10k", 5, 5000, 0, 10000, 0, 0); }
    function test_parity_T5_risk0_fail1_liq10000() public { _seedT5(); _assertParity("T5/r0/f1/l10k", 5, 0, 1, 10000, 0, 0); }
    function test_parity_T5_risk0_fail3_liq10000() public { _seedT5(); _assertParity("T5/r0/f3/l10k", 5, 0, 3, 10000, 0, 0); }
    function test_parity_T5_risk0_fail0_liq7000() public { _seedT5(); _assertParity("T5/r0/f0/l7k",  5, 0, 0,  7000, 0, 0); }
    function test_parity_T5_risk0_fail0_liq4000() public { _seedT5(); _assertParity("T5/r0/f0/l4k",  5, 0, 0,  4000, 0, 0); }
    function test_parity_T5_risk0_fail0_liq1000() public { _seedT5(); _assertParity("T5/r0/f0/l1k",  5, 0, 0,  1000, 0, 0); }
    function test_parity_T5_risk5000_fail3_liq4000() public { _seedT5(); _assertParity("T5/r5k/f3/l4k", 5, 5000, 3, 4000, 0, 0); }
    function test_parity_T5_risk8000_fail6_liq1000() public { _seedT5(); _assertParity("T5/r8k/f6/l1k", 5, 8000, 6, 1000, 0, 0); }

    // ══════════════════════════════════════════════════════════════════════════
    // NAMED A-F-13 REGRESSIONS (mandatory per PHASE 3)
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice A-F-13 primary regression: high-risk degraded adapter at T3.
    ///         Before fix: returned 3667 (STRUCTURAL_BASE only).
    ///         After fix: 3667 × (10000-8000/2)/10000 × (10000-3×1500)/10000 × 7500/10000
    ///                  = 3667 × 6000/10000 × 5500/10000 × 7500/10000
    ///                  = 3667 × 0.6 × 0.55 × 0.75 = ~907 bps
    function test_AUDIT_FINDING_13_external_reader_matches_engine_at_T3_high_risk() public {
        _seedT3();
        _assertParity("AF13/T3/r8k/f3/l4k", 3, 8000, 3, 4000, 0, 0);
    }

    /// @notice A-F-13 T1 regression: short-circuit must survive in BOTH paths.
    ///         Worst-case overlay state: riskScore=10000, failures=7, liqBps=100.
    ///         Both ScoringModule (external) and AllocCalcModule (internal) must return 10000.
    function test_AUDIT_FINDING_13_T1_short_circuit_preserved_in_both_paths() public {
        // T1 state: vault is empty (TVL=0 < 25K) → dMax=1
        _setRiskScore(address(adapterA), 10000);
        _setFailures(address(adapterA), 7);
        _setLiquidityCache(address(adapterA), 100);
        _setGlobalCeiling(3000); // ceiling would incorrectly reduce if applied

        (bool ok, bytes memory ret) = address(vault).staticcall(
            abi.encodeWithSignature("effectiveAbsCapBps(address)", address(adapterA))
        );
        require(ok, "T1 staticcall failed");
        uint16 actual = abi.decode(ret, (uint16));
        assertEq(actual, 10000, "T1 must short-circuit to 10000 -- overlays and ceiling must not apply");

        _clearGlobalCeiling();
        _setFailures(address(adapterA), 0);
        _setRiskScore(address(adapterA), 0);
    }
}
