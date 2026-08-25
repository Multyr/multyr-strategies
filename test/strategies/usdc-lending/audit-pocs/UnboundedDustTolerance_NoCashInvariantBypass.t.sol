// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * FINDING: `StrategySettingsModule.setDustTolerance()` has no upper bound,
 *          letting PARAM_ROLE permanently neutralize the "NoCashInvariant"
 *          (I-ADAPTER-01, docs/invariants.md) once locked in via
 *          `finalizeParameters()`.
 * SEVERITY: MEDIUM (requires PARAM_ROLE — a trusted governance role — but
 *           every other governance setter in the same file enforces a
 *           sanity range via `ParamOutOfRange`; this one silently doesn't,
 *           and it directly neutralizes a documented CRITICAL-adjacent
 *           invariant with no on-chain guardrail and no way to undo it
 *           post-finalization).
 *
 * `dustTolerance` is the sole threshold used by `deposit()`/`withdraw()`/
 * `harvest()` to decide whether idle USDC must be deployed
 * (UsdcLendingStrategy.sol: `maxIdle = max(bps * tvl, dustTolerance)`,
 * `if (idle > maxIdle) revert NoCashInvariant();`). Every *other* bps/seconds
 * setter in StrategySettingsModule.sol enforces an explicit range via
 * `ParamOutOfRange` (see setSyncInterval, setGasEmaParams, setCapDriftTolerance,
 * etc.) — `setDustTolerance` does not:
 *
 *     function setDustTolerance(uint256 _dustTolerance)
 *         external onlyRoleOrRevert(PARAM_ROLE) paramsNotFinalized
 *     { dustTolerance = _dustTolerance; ... }
 *
 * `finalizeParameters()` (StrategySettingsModule.sol:50-52) also performs no
 * validation — it only flips `paramsFinalized = true`, after which
 * `dustTolerance` can never be changed again (guarded by
 * `paramsNotFinalized`). docs/invariants.md:103 claims I-STORAGE-05
 * ("dustTolerance > 0 after bootstrap") is "Verified by: ...
 * StrategySettingsModule.finalizeParameters()" — but the function itself
 * enforces nothing; the real guarantee is purely an off-chain deploy-script
 * convention, not a contract-level guarantee.
 */

import { Test, console2 } from "forge-std/Test.sol";
import {
    UsdcMultiLendingVaultTestBase,
    MockUSDC,
    MockLendingAdapter
} from "../UsdcMultiLendingVault.t.sol";

contract UnboundedDustTolerance_PoC is UsdcMultiLendingVaultTestBase {
    function setUp() public override {
        super.setUp();
        _addAndEnableAdapter(adapter1);
        // Starve the only adapter of headroom so nothing can be deployed —
        // simulates the realistic case that legitimately leaves capital idle
        // (adapter at/near cap, all adapters flagged, scoring misconfigured,
        // etc.) which NoCashInvariant exists specifically to catch and revert.
        adapter1.setMaxCap(0);
    }

    function test_POC_paramRole_sets_unbounded_dustTolerance_then_locks_it_forever() public {
        // PARAM_ROLE (paramSetter, granted in the shared test harness) can set
        // dustTolerance to an absurd value with zero on-chain pushback.
        vm.prank(paramSetter);
        (bool ok, ) = address(vault).call(
            abi.encodeWithSignature("setDustTolerance(uint256)", type(uint256).max)
        );
        require(ok, "setDustTolerance call unexpectedly failed");
        assertEq(vault.dustTolerance(), type(uint256).max, "sanity: dustTolerance accepted with no bound");

        // Lock it in permanently.
        vm.prank(paramSetter);
        (bool okFinalize, ) = address(vault).call(abi.encodeWithSignature("finalizeParameters()"));
        require(okFinalize, "finalizeParameters call unexpectedly failed");
        assertTrue(vault.paramsFinalized());

        // dustTolerance can never be changed again.
        vm.prank(paramSetter);
        (bool okSecondSet, ) = address(vault).call(
            abi.encodeWithSignature("setDustTolerance(uint256)", 3e6)
        );
        assertFalse(okSecondSet, "sanity: dustTolerance is now permanently locked at type(uint256).max");
    }

    function test_POC_massive_idle_cash_never_triggers_NoCashInvariant() public {
        vm.prank(paramSetter);
        (bool ok, ) = address(vault).call(
            abi.encodeWithSignature("setDustTolerance(uint256)", type(uint256).max)
        );
        require(ok, "setDustTolerance call unexpectedly failed");

        uint256 depositAmt = 1_000_000e6; // 1M USDC
        usdc.mint(core, depositAmt);
        vm.prank(core);
        usdc.transfer(address(vault), depositAmt);

        // adapter1 has zero headroom (maxCap == 0), so nothing can be
        // deployed — under the documented invariant this SHOULD revert with
        // NoCashInvariant() once idle exceeds a *meaningful* dust threshold.
        vm.prank(core);
        vault.deposit(depositAmt);

        // VULNERABLE: 100% of the deposit sits idle, permanently, and the
        // call succeeded silently — the invariant that idle capital must
        // either deploy or loudly revert is fully neutralized.
        assertEq(vault.idleCash(), depositAmt, "entire deposit sits idle with zero on-chain protest");
        assertEq(vault.positionAssets(address(adapter1)), 0, "nothing was deployed to the adapter");
    }
}
