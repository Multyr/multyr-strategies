// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UsdcMultiLendingVaultTestBase} from "./UsdcMultiLendingVault.t.sol";
import {StrategySettingsModule} from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {QueryFailed, ParamOutOfRange} from "../../../src/strategies/usdc-lending/controller/StrategyStorageLayout.sol";

contract EmptyRevertOps {
    fallback() external { assembly { revert(0, 0) } }
}

contract NonEmptyRevertOps {
    error Sentinel();
    fallback() external { revert Sentinel(); }
}

/// @dev Unit fault injection, separate from the real protocol end-to-end acceptance.
contract ReviewAvailabilityRemediationTest is UsdcMultiLendingVaultTestBase {
    function _breakOps() internal {
        vm.etch(vault.adapterOpsModule(), address(new EmptyRevertOps()).code);
    }

    function test_emptyModuleRevertCannotReportSuccessfulKeeperRealization() public {
        _breakOps();
        vm.prank(keeper);
        vm.expectRevert(QueryFailed.selector);
        vault.realizeLiquidity(100e6);
    }

    function test_nonemptyModuleRevertPreservesOriginalReason() public {
        vm.etch(vault.adapterOpsModule(), address(new NonEmptyRevertOps()).code);
        vm.prank(keeper);
        vm.expectRevert(NonEmptyRevertOps.Sentinel.selector);
        vault.realizeLiquidity(100e6);
    }

    function test_emptyModuleRevertCannotReportSuccessfulTwoArgumentWithdrawal() public {
        _breakOps();
        vm.prank(core);
        vm.expectRevert(QueryFailed.selector);
        vault.withdraw(100e6, user);
        assertEq(usdc.balanceOf(user), 0);
    }

    function test_emptyModuleRevertCannotReportSuccessfulOptionalShortfallWithdrawal() public {
        _breakOps();
        vm.prank(core);
        vm.expectRevert(QueryFailed.selector);
        vault.withdraw(100e6, user, false);
        assertEq(usdc.balanceOf(user), 0);
    }

    function test_advisoryLockAcceptsLargestSafeDegradedMultiplier() public {
        uint64 bound = type(uint64).max / 7;
        vm.prank(paramSetter);
        StrategySettingsModule(address(vault)).setWithdrawalLockSeconds(bound);
        assertEq(vault.withdrawalLockSeconds(), bound);
    }

    function test_missingRiskModuleCannotAcceptDepositAsHealthy() public {
        vm.etch(vault.safetyOverflowModule_addr(), hex"");
        usdc.mint(address(vault), 100e6);
        vm.prank(core);
        vm.expectRevert(QueryFailed.selector);
        vault.deposit(100e6);
    }

    function test_failedRiskModuleCannotAcceptHarvestAsHealthy() public {
        vm.etch(vault.safetyOverflowModule_addr(), address(new EmptyRevertOps()).code);
        vm.prank(keeper);
        vm.expectRevert(QueryFailed.selector);
        vault.harvest();
    }

    function test_missingRiskModuleDoesNotBlockIdleWithdrawal() public {
        vm.etch(vault.safetyOverflowModule_addr(), hex"");
        usdc.mint(address(vault), 100e6);
        vm.prank(core);
        assertEq(vault.withdraw(100e6, user), 100e6);
        assertEq(usdc.balanceOf(user), 100e6);
    }

    function test_advisoryLockRejectsDegradedMultiplierOverflow() public {
        vm.prank(paramSetter);
        vm.expectRevert(ParamOutOfRange.selector);
        StrategySettingsModule(address(vault)).setWithdrawalLockSeconds(type(uint64).max / 7 + 1);
        assertEq(vault.withdrawalLockSeconds(), 0);
    }
}
