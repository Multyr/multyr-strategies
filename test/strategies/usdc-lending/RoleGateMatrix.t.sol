// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * Role-matrix regression suite for the 10 delegatecall-module entry points
 * that were previously reachable unauthenticated through the vault's
 * fallback dispatcher (see audit-pocs-v10/AccessControlBypass_* and
 * UnauthenticatedCheckGate_AdapterLockout.t.sol for the original findings).
 *
 * Where those PoCs each proved "one attacker, one function, now blocked",
 * this suite is systematic: every gated function is exercised against every
 * role the strategy actually grants (PARAM_ROLE, BOOTSTRAP_ROLE, KEEPER_ROLE,
 * CORE_ROLE, DEFAULT_ADMIN_ROLE) plus a random unrelated address, asserting
 * the exact pass/fail outcome the modifier documents -- including the
 * non-obvious case that DEFAULT_ADMIN_ROLE alone does NOT satisfy a
 * KEEPER_ROLE/CORE_ROLE gate (least-privilege: admin must explicitly hold
 * the operational role, not just the top-level admin role).
 */

import { Test, console2 } from "forge-std/Test.sol";
import { Unauthorized } from "../../../src/strategies/usdc-lending/controller/StrategyStorageLayout.sol";
import {
    UsdcMultiLendingVaultTestBase,
    MockUSDC,
    MockLendingAdapter
} from "./UsdcMultiLendingVault.t.sol";

contract RoleGateMatrix_Test is UsdcMultiLendingVaultTestBase {
    bytes32 constant BOOTSTRAP_ROLE = keccak256("BOOTSTRAP_ROLE");

    address bootstrapAddr = address(0xB007);
    address randomAddr = address(0xF00D);

    function setUp() public override {
        super.setUp();
        _addAndEnableAdapter(adapter1);

        vm.prank(admin);
        vault.grantRole(BOOTSTRAP_ROLE, bootstrapAddr);

        // Give adapter1 a real position so realize/deposit-shaped calls have
        // something to act on, and fund the vault with idle cash.
        _mintAndTransferToVault(core, 200_000e6);
        vm.prank(core);
        vault.deposit(200_000e6);
        usdc.mint(address(vault), 50_000e6);
    }

    // Non-role-holding / wrong-role callers that must NEVER pass a
    // KEEPER_ROLE-or-CORE_ROLE-or-either gate: PARAM_ROLE holder, BOOTSTRAP_ROLE
    // holder, DEFAULT_ADMIN_ROLE holder, and a random address with nothing.
    function _deniedCallers() internal view returns (address[4] memory) {
        return [paramSetter, bootstrapAddr, admin, randomAddr];
    }

    function _assertAlwaysDenied(bytes memory callData) internal {
        address[4] memory denied = _deniedCallers();
        for (uint256 i = 0; i < denied.length; i++) {
            vm.prank(denied[i]);
            (bool ok, bytes memory ret) = address(vault).call(callData);
            assertFalse(ok, "denied role must revert");
            assertEq(bytes4(ret), Unauthorized.selector, "denied role must revert with Unauthorized()");
        }
    }

    function _assertFuzzedRandomDenied(bytes memory callData, address fuzzedCaller) internal {
        vm.assume(fuzzedCaller != keeper && fuzzedCaller != core && fuzzedCaller != router);
        vm.prank(fuzzedCaller);
        (bool ok, bytes memory ret) = address(vault).call(callData);
        assertFalse(ok, "fuzzed non-privileged caller must revert");
        assertEq(bytes4(ret), Unauthorized.selector);
    }

    // ── KEEPER_ROLE-only functions ──────────────────────────────────────────

    function test_matrix_recordAdapterFailure() public {
        bytes memory callData = abi.encodeWithSignature("recordAdapterFailure(address)", address(adapter1));
        _assertAlwaysDenied(callData);

        vm.prank(core);
        (bool okCore, bytes memory retCore) = address(vault).call(callData);
        assertFalse(okCore, "CORE_ROLE alone must not satisfy KEEPER-only gate");
        assertEq(bytes4(retCore), Unauthorized.selector);

        vm.prank(keeper);
        (bool okKeeper,) = address(vault).call(callData);
        assertTrue(okKeeper, "KEEPER_ROLE must be allowed");
    }

    function testFuzz_recordAdapterFailure_randomCaller(address fuzzedCaller) public {
        _assertFuzzedRandomDenied(
            abi.encodeWithSignature("recordAdapterFailure(address)", address(adapter1)), fuzzedCaller
        );
    }

    function test_matrix_recordAdapterSuccess() public {
        bytes memory callData = abi.encodeWithSignature("recordAdapterSuccess(address)", address(adapter1));
        _assertAlwaysDenied(callData);

        vm.prank(core);
        (bool okCore, bytes memory retCore) = address(vault).call(callData);
        assertFalse(okCore);
        assertEq(bytes4(retCore), Unauthorized.selector);

        vm.prank(keeper);
        (bool okKeeper,) = address(vault).call(callData);
        assertTrue(okKeeper, "KEEPER_ROLE must be allowed");
    }

    function test_matrix_recordWithdrawGas() public {
        bytes memory callData = abi.encodeWithSignature("recordWithdrawGas(address,uint256)", address(adapter1), uint256(21000));
        _assertAlwaysDenied(callData);

        vm.prank(core);
        (bool okCore, bytes memory retCore) = address(vault).call(callData);
        assertFalse(okCore);
        assertEq(bytes4(retCore), Unauthorized.selector);

        vm.prank(keeper);
        (bool okKeeper,) = address(vault).call(callData);
        assertTrue(okKeeper, "KEEPER_ROLE must be allowed");
    }

    function test_matrix_syncPositionAssets() public {
        bytes memory callData = abi.encodeWithSignature("syncPositionAssets(bool)", true);
        _assertAlwaysDenied(callData);

        vm.prank(core);
        (bool okCore, bytes memory retCore) = address(vault).call(callData);
        assertFalse(okCore, "CORE_ROLE alone must not satisfy KEEPER-only gate");
        assertEq(bytes4(retCore), Unauthorized.selector);

        vm.prank(keeper);
        (bool okKeeper,) = address(vault).call(callData);
        assertTrue(okKeeper, "KEEPER_ROLE must be allowed");
    }

    function test_matrix_computeInputsForPlan() public {
        bytes memory callData = abi.encodeWithSignature("computeInputsForPlan()");
        _assertAlwaysDenied(callData);

        vm.prank(core);
        (bool okCore, bytes memory retCore) = address(vault).call(callData);
        assertFalse(okCore, "CORE_ROLE alone must not satisfy KEEPER-only gate");
        assertEq(bytes4(retCore), Unauthorized.selector);

        vm.prank(keeper);
        (bool okKeeper,) = address(vault).call(callData);
        assertTrue(okKeeper, "KEEPER_ROLE must be allowed");
    }

    function test_matrix_checkGate() public {
        uint16[] memory apys = new uint16[](0);
        address[] memory targets = new address[](0);
        uint256[] memory targetAllocs = new uint256[](0);
        bytes memory callData = abi.encodeWithSignature(
            "checkGate(uint16[],address[],uint256[],uint256,uint256)",
            apys, targets, targetAllocs, uint256(0), uint256(0)
        );
        _assertAlwaysDenied(callData);

        vm.prank(core);
        (bool okCore, bytes memory retCore) = address(vault).call(callData);
        assertFalse(okCore, "CORE_ROLE alone must not satisfy KEEPER-only gate");
        assertEq(bytes4(retCore), Unauthorized.selector);

        vm.prank(keeper);
        (bool okKeeper,) = address(vault).call(callData);
        assertTrue(okKeeper, "KEEPER_ROLE must be allowed");
    }

    // ── KEEPER_ROLE-or-CORE_ROLE functions ──────────────────────────────────

    function test_matrix_safeAdapterDeposit() public {
        bytes memory callData = abi.encodeWithSignature("safeAdapterDeposit(address,uint256)", address(adapter1), uint256(10e6));
        _assertAlwaysDenied(callData);

        vm.prank(core);
        (bool okCore,) = address(vault).call(callData);
        assertTrue(okCore, "CORE_ROLE must be allowed");

        vm.prank(keeper);
        (bool okKeeper,) = address(vault).call(callData);
        assertTrue(okKeeper, "KEEPER_ROLE must be allowed");
    }

    function test_matrix_adapterDeposit() public {
        bytes memory callData = abi.encodeWithSignature("adapterDeposit(address,uint256)", address(adapter1), uint256(10e6));
        _assertAlwaysDenied(callData);

        vm.prank(core);
        (bool okCore,) = address(vault).call(callData);
        assertTrue(okCore, "CORE_ROLE must be allowed");

        vm.prank(keeper);
        (bool okKeeper,) = address(vault).call(callData);
        assertTrue(okKeeper, "KEEPER_ROLE must be allowed");
    }

    function test_matrix_executeRealizeLiquidity() public {
        uint256 pos = vault.positionAssets(address(adapter1));
        bytes memory callData = abi.encodeWithSignature("executeRealizeLiquidity(uint256)", pos / 4);
        _assertAlwaysDenied(callData);

        vm.prank(keeper);
        (bool okKeeper,) = address(vault).call(callData);
        assertTrue(okKeeper, "KEEPER_ROLE must be allowed");

        vm.prank(core);
        (bool okCore,) = address(vault).call(callData);
        assertTrue(okCore, "CORE_ROLE must be allowed");
    }

    function test_matrix_deployIdleToAdapters() public {
        bytes memory callData = abi.encodeWithSignature("deployIdleToAdapters(uint256,bool)", uint256(0), true);
        _assertAlwaysDenied(callData);

        vm.prank(core);
        (bool okCore,) = address(vault).call(callData);
        assertTrue(okCore, "CORE_ROLE must be allowed");

        vm.prank(keeper);
        (bool okKeeper,) = address(vault).call(callData);
        assertTrue(okKeeper, "KEEPER_ROLE must be allowed");
    }

    // ── Distinct-overload sanity: StrategyParamsModule.syncPositionAssets()
    //    (no-arg) is PARAM_ROLE-gated -- a different selector/role entirely
    //    from the KEEPER-gated syncPositionAssets(bool) above. Confirms the
    //    two overloads are not accidentally sharing a gate.
    function test_matrix_syncPositionAssets_noArg_isParamRoleGated() public {
        bytes memory callData = abi.encodeWithSignature("syncPositionAssets()");

        vm.prank(keeper);
        (bool okKeeper, bytes memory retKeeper) = address(vault).call(callData);
        assertFalse(okKeeper, "KEEPER_ROLE must not satisfy the PARAM_ROLE-gated no-arg overload");
        assertEq(bytes4(retKeeper), Unauthorized.selector);

        vm.prank(randomAddr);
        (bool okRandom, bytes memory retRandom) = address(vault).call(callData);
        assertFalse(okRandom);
        assertEq(bytes4(retRandom), Unauthorized.selector);

        vm.prank(paramSetter);
        (bool okParam,) = address(vault).call(callData);
        assertTrue(okParam, "PARAM_ROLE must be allowed");
    }
}
