// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * FINDING: The F-SCORING-INV2 governance-ceiling fix for the T1 (single-
 *          adapter, dMax==1) tier was applied to
 *          `StrategyAllocCalcModule._effectiveAbsCapBps()` (the engine that
 *          actually computes allocation targets) but NOT to the parallel,
 *          supposedly-identical copy in
 *          `StrategyScoringModule.effectiveAbsCapBps()` (the public getter
 *          reachable through the vault). This is a live regression of
 *          exactly the invariant `docs/invariants.md` I-ALLOC-06 exists to
 *          protect ("Overlay parity ... AllocCalcModule._effectiveAbsCapBps
 *          ≡ ScoringModule.effectiveAbsCapBps for all inputs"), and it was
 *          originally fixed once already as AUDIT-FINDING-13.
 * SEVERITY: HIGH (observability/integrity, not direct fund loss). Any
 *           consumer that trusts `ScoringModule.effectiveAbsCapBps()` as
 *           ground truth for "what cap is this adapter actually under" — a
 *           monitoring dashboard, `StrategyExplainabilityLens`, a risk
 *           system, another on-chain contract — will be told an adapter is
 *           allowed 100% concentration when the REAL allocation engine is
 *           actually enforcing a tighter governance-set emergency ceiling.
 *           This exact divergence class caused AUDIT-FINDING-13 (see
 *           docs/threat-model.md §9) and evidently was reintroduced here.
 *
 * StrategyAllocCalcModule.sol:486-489 (current, fixed):
 *     if (dMax == 1) {
 *         uint16 globalCeiling = adapterMaxExposureBps;
 *         return globalCeiling > 0 ? uint256(globalCeiling) : 10000;
 *     }
 *
 * StrategyScoringModule.sol:254-256 (current, STALE / pre-fix):
 *     // T1: single-adapter mode = intentional 100% concentration by design.
 *     // Global ceiling does not apply ...
 *     if (dMax == 1) return 10000;
 *
 * The existing regression test (Overlay_Parity.t.sol, "T1 ignores global
 * ceiling", expects 10000) still passes because it asserts the STALE
 * behavior as correct, so this divergence currently ships silently.
 */

import { Test, console2 } from "forge-std/Test.sol";
import {
    UsdcMultiLendingVaultTestBase,
    MockUSDC,
    MockLendingAdapter
} from "../UsdcMultiLendingVault.t.sol";

contract OverlayParityRegression_PoC is UsdcMultiLendingVaultTestBase {
    function setUp() public override {
        super.setUp();
        _addAndEnableAdapter(adapter1);

        // Emergency governance ceiling: cap any single adapter at 30% of TVL,
        // even in T1 (single-adapter, <$25K TVL) mode.
        vm.prank(paramSetter);
        (bool ok, ) = address(vault).call(
            abi.encodeWithSignature("setRebalanceParams(uint16,uint16,uint16,uint32,uint16,uint16,uint16)",
                uint16(3), uint16(2), uint16(50), uint32(21600), uint16(80),
                uint16(3000),  // adapterMaxExposureBps = 30%
                uint16(5000)   // newAdapterRampBps
            )
        );
        require(ok, "setRebalanceParams failed");
        assertEq(vault.adapterMaxExposureBps(), 3000, "sanity: 30% emergency ceiling is active");
    }

    function test_POC_scoring_getter_diverges_from_actual_enforced_T1_cap() public {
        // Stay in T1 tier (TVL < $25,000). Deploy via deployIdleToAdapters()
        // directly (bestEffort=true) rather than the full deposit() flow, so
        // the (unrelated) post-deposit idle-threshold checks in deposit()
        // don't interfere with observing the cap engine itself -- with only
        // one adapter capped at 30%, 70% of any deposit is *expected* to stay
        // idle by design, which deposit()'s own NoCashInvariant/BootstrapIdleTooHigh
        // checks would otherwise (correctly, for their own purpose) reject.
        uint256 depositAmt = 10_000e6;
        usdc.mint(address(vault), depositAmt);
        vm.prank(keeper);
        (bool okDeploy, ) = address(vault).call(
            abi.encodeWithSignature("deployIdleToAdapters(uint256,bool)", depositAmt, true)
        );
        require(okDeploy, "deployIdleToAdapters call failed");

        // The public getter (reachable through the vault, used by external
        // consumers as "the cap this adapter is under") reports 10000 (100%,
        // unconstrained) -- the STALE, pre-governance-ceiling value.
        (bool ok, bytes memory ret) = address(vault).call(
            abi.encodeWithSignature("effectiveAbsCapBps(address)", address(adapter1))
        );
        require(ok, "effectiveAbsCapBps call failed");
        uint16 reportedCapBps = abi.decode(ret, (uint16));
        assertEq(reportedCapBps, 10000, "sanity: the getter claims 100% (unconstrained), ignoring the 30% governance ceiling");

        // But the REAL allocation engine (AllocCalcModule, exercised through
        // the actual deposit path above) enforced the 30% ceiling for real:
        // the single T1 adapter received at most 30% of TVL, not 100%.
        uint256 actualPosition = vault.positionAssets(address(adapter1));
        uint256 impliedCapBps = (actualPosition * 10_000) / depositAmt;

        assertLe(
            impliedCapBps, 3000,
            "sanity: the real engine really did enforce the 30% ceiling on this single T1 adapter"
        );

        assertTrue(
            reportedCapBps != impliedCapBps,
            "VULNERABLE: ScoringModule.effectiveAbsCapBps() (10000) diverges from what StrategyAllocCalcModule actually enforced (<=3000) -- overlay parity (I-ALLOC-06) is broken for the T1 + governance-ceiling case"
        );
    }
}
