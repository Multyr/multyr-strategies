// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    StrategyStorageLayout,
    DepositModeNotSet
} from "./StrategyStorageLayout.sol";
import { ILendingAdapter } from "../interfaces/ILendingAdapter.sol";

/// @title StrategyAdapterOpsModule — Adapter deposit/failure operations
/// @notice Delegatecall module extracted from StrategyScoringModule for size limit.
///         All functions operate on strategy storage via delegatecall.
contract StrategyAdapterOpsModule is StrategyStorageLayout {
    using SafeERC20 for IERC20Metadata;

    address private immutable _self;

    constructor(address asset_, address _core, address _paramsModule, address _scoringModule, address _adapterOpsModule)
        StrategyStorageLayout(asset_, _core, _paramsModule, _scoringModule, _adapterOpsModule)
    {
        _self = address(this);
    }

    modifier onlyDelegateCall() {
        require(address(this) != _self, "DIRECT_CALL_FORBIDDEN");
        _;
    }

    /// @notice Safe adapter deposit with failure handling + gas EMA recording.
    function safeAdapterDeposit(address adapter, uint256 amount)
        external onlyDelegateCall returns (bool)
    {
        if (amount == 0) return true;
        if (!depositModeKnown[adapter]) revert DepositModeNotSet();

        bool countFailure = !_retryMode;
        uint256 gasBefore = gasleft();

        if (pushDepositMode[adapter]) {
            ASSET.safeTransfer(adapter, amount);
            try ILendingAdapter(adapter).deposit(amount) {
                _recordAdapterSuccess(adapter);
                _updateGasEma(adapter, gasBefore - gasleft(), true);
                return true;
            } catch (bytes memory reason) {
                emit AdapterDepositFailed(adapter, amount, reason);
                emit AdapterFundsStranded(adapter, amount);
                // Audit HIGH 1.3 — unify failure handling: gradual decay on BOTH
                // push and pull deposit paths (was immediate-quarantine on push).
                if (countFailure) _recordAdapterFailure(adapter);
                else emit RetryFailureIgnored(adapter, amount);
                return false;
            }
        } else {
            ASSET.forceApprove(adapter, amount);
            try ILendingAdapter(adapter).deposit(amount) {
                ASSET.forceApprove(adapter, 0);
                _recordAdapterSuccess(adapter);
                _updateGasEma(adapter, gasBefore - gasleft(), true);
                return true;
            } catch (bytes memory reason) {
                ASSET.forceApprove(adapter, 0);
                emit AdapterDepositFailed(adapter, amount, reason);
                if (countFailure) _recordAdapterFailure(adapter);
                else emit RetryFailureIgnored(adapter, amount);
                return false;
            }
        }
    }

    /// @notice Strict deposit (reverts on failure). Called via delegatecall.
    function adapterDeposit(address adapter, uint256 amount) external onlyDelegateCall {
        if (amount == 0) return;
        if (!depositModeKnown[adapter]) revert DepositModeNotSet();

        if (pushDepositMode[adapter]) {
            ASSET.safeTransfer(adapter, amount);
            ILendingAdapter(adapter).deposit(amount);
        } else {
            ASSET.forceApprove(adapter, amount);
            ILendingAdapter(adapter).deposit(amount);
            ASSET.forceApprove(adapter, 0);
        }
    }

    /// @notice Record adapter failure with temporal decay. Called via delegatecall.
    function recordAdapterFailure(address adapter) external onlyDelegateCall {
        _recordAdapterFailure(adapter);
    }

    /// @notice Record adapter success (gradual decrement). Called via delegatecall.
    function recordAdapterSuccess(address adapter) external onlyDelegateCall {
        _recordAdapterSuccess(adapter);
    }

    // ── Internal ────────────────────────────────────────────────────────────

    function _recordAdapterFailure(address adapter) internal {
        if (quarantined[adapter]) return;
        if (
            failureDecaySeconds > 0 && adapterLastFailureTs[adapter] > 0
                && block.timestamp - adapterLastFailureTs[adapter] > failureDecaySeconds
        ) {
            adapterConsecutiveFailures[adapter] = 0;
        }
        adapterLastFailureTs[adapter] = uint64(block.timestamp);

        uint8 failures;
        unchecked {
            failures = adapterConsecutiveFailures[adapter] + 1;
        }
        adapterConsecutiveFailures[adapter] = failures;
        uint8 threshold = adapterQuarantineThreshold;
        if (threshold > 0 && failures >= threshold) {
            quarantined[adapter] = true;
            emit AdapterAutoQuarantined(adapter, failures);
        }
    }

    // coverage-ignore: dead code — no in-tree caller; kept as defensive reserve
    function _recordAdapterFailureImmediate(address adapter) internal {
        if (quarantined[adapter]) return;
        quarantined[adapter] = true;
        emit AdapterAutoQuarantined(adapter, adapterConsecutiveFailures[adapter]);
    }

    function _recordAdapterSuccess(address adapter) internal {
        if (adapterConsecutiveFailures[adapter] > 0) {
            adapterConsecutiveFailures[adapter]--;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // V10 P0: Execution Gas EMA
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Record withdraw gas for EMA (called by ScoringModule after withdraw)
    function recordWithdrawGas(address adapter, uint256 gasUsed) external onlyDelegateCall {
        _updateGasEma(adapter, gasUsed, false);
    }

    /// @dev Update per-adapter gas EMA. alpha = gasEmaSmoothingBps / 10000.
    function _updateGasEma(address adapter, uint256 gasUsed, bool isDeposit) internal {
        if (gasUsed == 0) return;
        uint256 alpha = gasEmaSmoothingBps;
        if (alpha == 0) alpha = 2000; // default 0.2

        uint64 old = isDeposit ? emaDepositGas[adapter] : emaWithdrawGas[adapter];
        uint64 updated;
        if (old == 0) {
            updated = uint64(gasUsed); // first observation
        } else {
            updated = uint64((uint256(old) * (10000 - alpha) + gasUsed * alpha) / 10000);
        }

        if (isDeposit) {
            emaDepositGas[adapter] = updated;
        } else {
            emaWithdrawGas[adapter] = updated;
        }
        emit GasEmaUpdated(adapter, updated, isDeposit);
    }
}
