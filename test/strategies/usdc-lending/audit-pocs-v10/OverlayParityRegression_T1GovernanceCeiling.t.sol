// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * FINDING (FIXED): The F-SCORING-INV2 governance-ceiling fix for the T1
 *          (single-adapter, dMax==1) tier had been applied to
 *          `StrategyAllocCalcModule._effectiveAbsCapBps()` (the engine that
 *          actually computes allocation targets) but NOT to the parallel,
 *          supposedly-identical copy in
 *          `StrategyScoringModule.effectiveAbsCapBps()` (the public getter
 *          reachable through the vault) -- a live regression of exactly the
 *          invariant `docs/invariants.md` I-ALLOC-06 exists to protect,
 *          previously fixed once already as AUDIT-FINDING-13.
 * SEVERITY: HIGH (observability/integrity, not direct fund loss) (was).
 *
 * FIX: `StrategyScoringModule.effectiveAbsCapBps()`'s T1 branch now mirrors
 * `StrategyAllocCalcModule._effectiveAbsCapBps()` exactly:
 *     if (dMax == 1) {
 *         uint16 t1Ceiling = adapterMaxExposureBps;
 *         return t1Ceiling > 0 ? t1Ceiling : 10000;
 *     }
 *
 * NOTE: `test/strategies/usdc-lending/Overlay_Parity.t.sol`'s "T1 ignores
 * global ceiling" case still asserts the old (10000, unconstrained) value
 * for the *ceiling-unset* case -- which remains correct (globalCeiling==0 is
 * the documented sentinel for "no constraint"). It just never covered the
 * ceiling-SET case this PoC exercises, which is why the regression shipped
 * silently.
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

    function test_POC_scoring_getter_now_matches_actual_enforced_T1_cap() public {
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

        // The public getter now correctly reflects the 30% governance
        // ceiling instead of the stale, unconstrained 10000.
        (bool ok, bytes memory ret) = address(vault).call(
            abi.encodeWithSignature("effectiveAbsCapBps(address)", address(adapter1))
        );
        require(ok, "effectiveAbsCapBps call failed");
        uint16 reportedCapBps = abi.decode(ret, (uint16));
        assertEq(reportedCapBps, 3000, "FIXED: the getter now reports the real 30% governance ceiling");

        // The real allocation engine (AllocCalcModule, exercised through the
        // actual deposit path above) enforces the same 30% ceiling.
        uint256 actualPosition = vault.positionAssets(address(adapter1));
        uint256 impliedCapBps = (actualPosition * 10_000) / depositAmt;

        assertLe(impliedCapBps, 3000, "sanity: the engine really did enforce the 30% ceiling on this single T1 adapter");

        assertEq(
            reportedCapBps, uint16(3000),
            "FIXED: ScoringModule.effectiveAbsCapBps() now matches what StrategyAllocCalcModule actually enforces -- overlay parity (I-ALLOC-06) restored"
        );
    }
}
