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

    // ═══════════════════════════════════════════════════════════════════════
    // Position sync (extracted from StrategyScoringModule, F-SIZE-01)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Sync positionAssets from live adapter balances. Called via delegatecall.
    ///         force=true: bypass cooldown (rebalance). force=false: respect cooldown (deployIdle).
    function syncPositionAssets(bool force) external onlyDelegateCall {
        if (!force && lastSyncTs != 0
            && block.timestamp < uint256(lastSyncTs) + minSecondsBetweenSync) return;

        address[] storage _adapters = adapters;
        uint256 n = _adapters.length;
        uint256 totalDrift = 0;
        bool hasNegative = false;
        uint256 _dust = dustTolerance;

        for (uint256 i = 0; i < n;) {
            address adapter = _adapters[i];
            if (enabled[adapter] || positionAssets[adapter] > 0) {
                uint256 oldPos = positionAssets[adapter];
                uint256 actual = _safeTotalAssets(adapter);
                if (actual == 0 && oldPos > 0) {
                    emit PositionSyncSkippedSuspicious(adapter, oldPos, actual);
                    unchecked { ++i; }
                    continue;
                }
                if (oldPos > 0 && actual > oldPos * 3) {
                    emit PositionSyncSkippedSuspicious(adapter, oldPos, actual);
                    unchecked { ++i; }
                    continue;
                }
                uint256 diff = actual > oldPos ? actual - oldPos : oldPos - actual;
                if (actual < oldPos) hasNegative = true;
                unchecked { totalDrift += diff; }
                if (diff >= _dust) {
                    positionAssets[adapter] = actual;
                    emit PositionAssetsSynced(adapter, oldPos, actual);
                }
            }
            unchecked { ++i; }
        }

        lastSyncTs = uint64(block.timestamp);
        if (totalDrift > 0) emit DriftMeasured(totalDrift, hasNegative);

        uint32 _liqStaleness = liquidityStalenessSeconds;
        if (_liqStaleness > 0) {
            for (uint256 j = 0; j < n;) {
                address a = _adapters[j];
                if (enabled[a] && cachedLiquidityTs[a] > 0) {
                    uint256 age = block.timestamp - cachedLiquidityTs[a];
                    if (age > _liqStaleness) {
                        emit LiquidityCacheStale(a, age);
                    }
                }
                unchecked { ++j; }
            }
        }
    }

    // ── Liquidity realization (F-SIZE-02) ────────────────────────────────────

    /// @notice Two-pass pro-rata withdrawal from adapters. Called via delegatecall from vault.
    function executeRealizeLiquidity(uint256 amountNeeded) external onlyDelegateCall {
        uint256 tvl = _tvl();
        if (tvl < 1) return;
        uint256 totalRealized = 0;
        uint256 n = adapters.length;
        for (uint8 pass = 0; pass < 2 && totalRealized < amountNeeded; ++pass) {
            uint256 need = amountNeeded - totalRealized;
            for (uint256 i = 0; i < n && totalRealized < amountNeeded; ++i) {
                address a = adapters[i];
                if (!enabled[a]) continue;
                if (pass == 1 && quarantined[a]) continue;
                uint256 pos = positionAssets[a];
                if (pos < 1) continue;
                uint256 w = pass == 0 ? (need * pos) / tvl : need;
                if (w > pos) w = pos;
                if (w < 1) continue;
                try ILendingAdapter(a).withdraw(w, address(this)) returns (uint256 got) {
                    positionAssets[a] -= got;
                    totalRealized += got;
                    _recordAdapterSuccess(a);
                } catch (bytes memory reason) {
                    emit AdapterWithdrawFailed(a, w, reason);
                    _recordAdapterFailure(a);
                }
            }
        }
        if (totalRealized < amountNeeded) emit WithdrawalShortfall(amountNeeded, totalRealized);
        emit LiquidityRealized(amountNeeded, totalRealized);
    }

    // ── View diagnostics (F-SIZE-02) ─────────────────────────────────────────

    /// @notice Weighted average liquidity readiness across enabled adapters.
    function liquidityReadinessBps() external view onlyDelegateCall returns (uint16) {
        uint256 totalWeight = 0;
        uint256 weightedLiq = 0;
        uint256 n = adapters.length;
        for (uint256 i = 0; i < n;) {
            address a = adapters[i];
            if (enabled[a] && !quarantined[a]) {
                uint256 pos = positionAssets[a];
                uint16 liq = cachedLiquidityBps[a];
                if (liq == 0) liq = 5000;
                weightedLiq += pos * liq;
                totalWeight += pos;
            }
            unchecked { ++i; }
        }
        if (totalWeight == 0) return 10000;
        uint256 result = weightedLiq / totalWeight;
        return result > 10000 ? uint16(10000) : uint16(result);
    }

    /// @notice Rebalance penalty: higher = capital should not move.
    function rebalancePenaltyBps() external view onlyDelegateCall returns (uint16) {
        if (rebalancePlanPhase > 0) return 5000;
        if (lastRebalanceTs == 0) return 0;
        uint256 elapsed = block.timestamp - lastRebalanceTs;
        uint256 cooldown = minSecondsBetweenRebalances;
        if (cooldown == 0) return 0;
        if (elapsed >= cooldown) return 0;
        return uint16((2000 * (cooldown - elapsed)) / cooldown);
    }

    /// @notice Returns harvest readiness and harvestable sum.
    function canHarvest() external view onlyDelegateCall returns (bool ok, uint256 sumHarvestable, uint64 sinceLastHarvest) {
        uint256 n = adapters.length;
        for (uint256 i = 0; i < n;) {
            address adapter = adapters[i];
            if (enabled[adapter]) {
                try ILendingAdapter(adapter).harvestableProfit() returns (uint256 profit) {
                    sumHarvestable += profit;
                } catch { }
            }
            unchecked { ++i; }
        }
        uint256 tvl = _tvl();
        ok = (sumHarvestable > 0 && sumHarvestable >= (harvestThresholdBps * tvl) / 1e4)
            || (minSecondsBetweenHarvests > 0 && block.timestamp - lastHarvestTs >= minSecondsBetweenHarvests);
        sinceLastHarvest = uint64(block.timestamp - lastHarvestTs);
    }
}
