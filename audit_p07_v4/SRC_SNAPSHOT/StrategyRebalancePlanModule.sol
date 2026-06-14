// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ═══════════════════════════════════════════════════════════════════════════════
// StrategyRebalancePlanModule — rebalance plan lifecycle (extracted 2026-04-22)
// ───────────────────────────────────────────────────────────────────────────────
// EIP-170 refactor (2026-04-22):
//
//   StrategyScoringModule exceeded the 24,576-byte runtime cap by 870 bytes
//   after the remediation sprint. This module extracts the rebalance plan
//   lifecycle (prepareRebalance, executeRebalanceStep, cancelRebalancePlan and
//   their internals, including the P2.1 backoff counter) into a dedicated
//   delegatecall module so both contracts stay under the EIP-170 limit with a
//   healthy margin and both remain deployable.
//
// Invariants preserved vs the pre-extraction code:
//   * Storage layout is untouched (inherits StrategyStorageLayout; no mirror).
//   * Same plan-phase state machine (0→1→2→0) and same silent-invalidation
//     semantics (expiry + TVL drift).
//   * Same P2.1 backoff contract: bump on silent invalidation, reset on
//     successful finalise, base × {2x, 4x} escalation above threshold.
//   * Same gate delegation (to rebalanceGateModule_addr.checkGate).
//   * Same auto-finalise-and-deploy-idle flow.
//
// External cross-module calls (as before, except scoring now does most of the
// prepare heavy lifting via computeInputsForPlan):
//   * scoringModule.delegatecall(computeInputsForPlan())  — sync + scoring
//   * scoringModule.delegatecall(deployIdleToAdapters(,))  — post-finalise idle
//   * adapterOpsModule.delegatecall(safeAdapterDeposit / recordAdapterX)
//   * rebalanceGateModule_addr.delegatecall(checkGate(...))
//
// Access control: KEEPER_ROLE for external entry points (same as before).
// Deployment: deployed once, address stored in rebalancePlanModule_addr (set
// once in UsdcLendingStrategy constructor, no setter).
// ═══════════════════════════════════════════════════════════════════════════════

import { ILendingAdapter } from "../interfaces/ILendingAdapter.sol";
import {
    StrategyStorageLayout,
    RebalanceCooldown,
    InsufficientAdapters,
    GateNotMet,
    PlanAlreadyActive,
    NoPlanActive,
    TooManyAdapters
} from "./StrategyStorageLayout.sol";

contract StrategyRebalancePlanModule is StrategyStorageLayout {

    // ── Delegatecall-only guard ─────────────────────────────────────────────
    address private immutable _self;

    constructor(
        address asset_,
        address _core,
        address _paramsModule,
        address _scoringModule,
        address _adapterOpsModule
    ) StrategyStorageLayout(asset_, _core, _paramsModule, _scoringModule, _adapterOpsModule) {
        _self = address(this);
    }

    modifier onlyDelegateCall() {
        require(address(this) != _self, "DIRECT_CALL_FORBIDDEN");
        _;
    }

    // ── External selectors used in cross-module delegatecalls ───────────────
    bytes4 private constant COMPUTE_INPUTS_FOR_PLAN_SEL =
        bytes4(keccak256("computeInputsForPlan()"));
    bytes4 private constant DEPLOY_IDLE_TO_ADAPTERS_SEL =
        bytes4(keccak256("deployIdleToAdapters(uint256,bool)"));
    bytes4 private constant CHECK_GATE_SEL =
        bytes4(keccak256("checkGate(uint16[],address[],uint256[],uint256,uint256)"));
    bytes4 private constant SAFE_DEPOSIT_SEL =
        bytes4(keccak256("safeAdapterDeposit(address,uint256)"));
    bytes4 private constant RECORD_FAILURE_SEL =
        bytes4(keccak256("recordAdapterFailure(address)"));
    bytes4 private constant RECORD_SUCCESS_SEL =
        bytes4(keccak256("recordAdapterSuccess(address)"));

    // ═════════════════════════════════════════════════════════════════════════
    // External entry points (routed here via the vault fallback)
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Phase 1: build rebalance plan. Scoring + gate check, no protocol interactions.
    /// @dev    KEEPER_ROLE. Persists plan in storage for executeRebalanceStep to consume.
    function prepareRebalance()
        external
        nonReentrant
        onlyRoleOrRevert(KEEPER_ROLE)
        whenNotPaused
        onlyDelegateCall
    {
        _prepareRebalanceInternal();
    }

    /// @notice Phase 2: execute up to `maxRebalanceActionsPerTx` actions from the plan.
    /// @dev    KEEPER_ROLE. Bounded by governance. Auto-finalises when all actions done.
    function executeRebalanceStep()
        external
        nonReentrant
        onlyRoleOrRevert(KEEPER_ROLE)
        whenNotPaused
        onlyDelegateCall
    {
        _executeRebalanceStepInternal();
    }

    /// @notice Cancel an active plan without bumping the backoff counter.
    /// @dev    Operator-initiated (KEEPER_ROLE) — not treated as a silent
    ///         invalidation because it's deliberate.
    function cancelRebalancePlan()
        external
        onlyRoleOrRevert(KEEPER_ROLE)
        onlyDelegateCall
    {
        _clearPlan();
        emit RebalancePlanCancelled();
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Internal: prepare
    // ═════════════════════════════════════════════════════════════════════════

    function _prepareRebalanceInternal() internal {
        if (rebalancePlanPhase != 0) revert PlanAlreadyActive();

        // P2.1 — effective cooldown with backoff escalation.
        uint32 _cooldown = minSecondsBetweenRebalances;
        if (rebalancePlanBackoffThreshold > 0
            && rebalancePlanConsecutiveFailures > rebalancePlanBackoffThreshold) {
            uint8 over = rebalancePlanConsecutiveFailures - rebalancePlanBackoffThreshold;
            _cooldown = over >= 2 ? _cooldown * 4 : _cooldown * 2;
            emit RebalancePlanBackoffActive(rebalancePlanConsecutiveFailures, _cooldown);
        }
        if (block.timestamp - lastRebalanceTs < _cooldown) revert RebalanceCooldown();

        // Delegate all sync + scoring to ScoringModule (single cross-module call).
        // ScoringModule handles: degraded-guard revert, _syncPositionAssets(true),
        // _enabledAdapters, _tvl, _computeAdapterScores, _normalizeScores,
        // _targetAllocations, and returns apys + normalized scores + moved.
        address[] memory enabledList;
        uint256[] memory targetAllocs;
        uint256[] memory normScores;
        uint16[]  memory apys;
        uint256 tvl;
        uint256 moved;
        {
            (bool ok, bytes memory ret) = scoringModule.delegatecall(
                abi.encodeWithSelector(COMPUTE_INPUTS_FOR_PLAN_SEL)
            );
            if (!ok) { assembly { revert(add(ret, 32), mload(ret)) } }
            (enabledList, targetAllocs, normScores, apys, tvl, moved) =
                abi.decode(ret, (address[], uint256[], uint256[], uint16[], uint256, uint256));
        }

        uint256 len = enabledList.length;
        if (len < minAdaptersActive) revert InsufficientAdapters();
        if (len > 10) revert TooManyAdapters();

        // Gate check via rebalanceGateModule_addr delegatecall.
        {
            (bool gOk, bytes memory gRes) = rebalanceGateModule_addr.delegatecall(
                abi.encodeWithSelector(CHECK_GATE_SEL, apys, enabledList, targetAllocs, tvl, moved)
            );
            if (!gOk) revert GateNotMet();
            (bool pass,) = abi.decode(gRes, (bool, int256));
            if (!pass) revert GateNotMet();
        }

        // Build action plan (local storage writes).
        uint256 _dust = dustTolerance;
        uint256 _minDelta = (tvl * rebalanceMinMoveBps) / 1e4;
        if (len > 0) _minDelta = _minDelta / len;
        if (_minDelta < _dust) _minDelta = _dust;

        uint8 actionCount = 0;

        // Withdrawals in enabled order.
        for (uint256 i = 0; i < len && actionCount < 10;) {
            uint256 curr = positionAssets[enabledList[i]];
            uint256 tgt = targetAllocs[i];
            if (curr > tgt) {
                uint256 toWithdraw = curr - tgt;
                if (toWithdraw >= _minDelta) {
                    rebalancePlanAdapters[actionCount] = enabledList[i];
                    rebalancePlanAmounts[actionCount] = toWithdraw; // MSB=0 → withdraw
                    actionCount++;
                }
            }
            unchecked { ++i; }
        }

        // Deposits sorted by deficit × normalized-score (insertion sort, len ≤ 10).
        uint256[] memory deficitScores = new uint256[](len);
        uint256[] memory order = new uint256[](len);
        for (uint256 i = 0; i < len;) {
            uint256 tgt = targetAllocs[i];
            uint256 curr = positionAssets[enabledList[i]];
            uint256 deficit = tgt > curr ? tgt - curr : 0;
            deficitScores[i] = deficit * normScores[i];
            order[i] = i;
            unchecked { ++i; }
        }
        for (uint256 i = 1; i < len;) {
            uint256 key = order[i];
            uint256 keyVal = deficitScores[key];
            uint256 j = i;
            while (j > 0 && deficitScores[order[j - 1]] < keyVal) {
                order[j] = order[j - 1];
                j--;
            }
            order[j] = key;
            unchecked { ++i; }
        }
        for (uint256 k = 0; k < len && actionCount < 10;) {
            uint256 idx = order[k];
            uint256 curr = positionAssets[enabledList[idx]];
            uint256 tgt = targetAllocs[idx];
            if (tgt > curr) {
                uint256 toDeposit = tgt - curr;
                if (toDeposit >= _minDelta) {
                    rebalancePlanAdapters[actionCount] = enabledList[idx];
                    rebalancePlanAmounts[actionCount] = toDeposit | (1 << 255); // MSB=1 → deposit
                    actionCount++;
                }
            }
            unchecked { ++k; }
        }

        rebalancePlanPhase = 1;
        rebalancePlanTs = uint64(block.timestamp);
        rebalancePlanNextAction = 0;
        rebalancePlanTotalActions = actionCount;
        rebalancePlanTvl = tvl;

        emit RebalancePlanCreated(actionCount, moved, tvl);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Internal: execute
    // ═════════════════════════════════════════════════════════════════════════

    function _executeRebalanceStepInternal() internal {
        uint8 phase = rebalancePlanPhase;
        if (phase != 1 && phase != 2) revert NoPlanActive();

        // Plan staleness — silent invalidation (no lastRebalanceTs update).
        uint32 _maxAge = rebalancePlanMaxAge;
        if (_maxAge < 1) _maxAge = 7200; // default 2h
        uint256 age = block.timestamp - rebalancePlanTs;
        if (age > _maxAge) {
            _clearPlan();
            _bumpRebalanceBackoff();
            emit RebalancePlanCancelled();
            emit RebalancePlanExpired(age, _maxAge);
            return;
        }

        // TVL drift invalidation — also silent.
        {
            uint256 currentTvl = _tvlLocal();
            uint256 planTvl = rebalancePlanTvl;
            uint256 drift = currentTvl > planTvl ? currentTvl - planTvl : planTvl - currentTvl;
            uint256 allowed = (planTvl * driftToleranceBps) / 1e4;
            uint256 minAbs = rebalancePlanMinDrift;
            if (minAbs < 1) minAbs = 5_000e6;
            if (drift > allowed && drift > minAbs) {
                emit RebalancePlanInvalidated(planTvl, currentTvl);
                emit RebalancePlanInvalidatedDueToDrift(drift, allowed);
                _clearPlan();
                _bumpRebalanceBackoff();
                return;
            }
        }

        rebalancePlanPhase = 2;
        uint8 start = rebalancePlanNextAction;
        uint8 maxPerTx = maxRebalanceActionsPerTx;
        if (maxPerTx < 1) maxPerTx = 2;
        uint8 end = start + maxPerTx;
        if (end > rebalancePlanTotalActions) end = rebalancePlanTotalActions;

        for (uint8 i = start; i < end;) {
            address adapter = rebalancePlanAdapters[i];
            uint256 rawAmount = rebalancePlanAmounts[i];
            bool isDeposit = (rawAmount >> 255) == 1;
            uint256 amount = rawAmount & ((1 << 255) - 1);

            if (!enabled[adapter] || quarantined[adapter]) {
                unchecked { ++i; }
                continue;
            }

            if (isDeposit) {
                uint256 idle = ASSET.balanceOf(address(this));
                if (amount > idle) amount = idle;
                if (amount > 0) {
                    bool ok = _safeAdapterDepositViaOps(adapter, amount);
                    if (ok) positionAssets[adapter] += amount;
                }
            } else {
                try ILendingAdapter(adapter).withdraw(amount, address(this)) returns (uint256 withdrawn) {
                    positionAssets[adapter] -= withdrawn;
                    _recordAdapterSuccessViaOps(adapter);
                } catch (bytes memory reason) {
                    emit AdapterWithdrawFailed(adapter, amount, reason);
                    _recordAdapterFailureViaOps(adapter);
                }
            }
            unchecked { ++i; }
        }

        rebalancePlanNextAction = end;
        emit RebalanceStepExecuted(start, end);

        if (end >= rebalancePlanTotalActions) {
            _finalizePlan();
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Internal: plan lifecycle helpers
    // ═════════════════════════════════════════════════════════════════════════

    function _finalizePlan() internal {
        lastRebalanceTs = uint64(block.timestamp);
        _resetRebalanceBackoff();

        uint256 idle = ASSET.balanceOf(address(this));
        uint256 threshold = _idleDeployThresholdLocal();
        // Force deploy if idle is very high (2x threshold)
        if (idle > threshold * 2) {
            // Auto-redeploy via ScoringModule (preserves all cap/ramp invariants).
            (bool ok,) = scoringModule.delegatecall(
                abi.encodeWithSelector(DEPLOY_IDLE_TO_ADAPTERS_SEL, idle, true)
            );
            // Best-effort: ignore failure so finalisation still completes.
            ok; // silence unused
        } else if (idle > threshold) {
            emit IdleCashRemaining(idle, threshold);
        }
        _clearPlan();
        emit Rebalanced(0);

        // FIX P0.Q11+Q12A: emit performance snapshot for off-chain monitoring.
        // Storage updated to support realized-vs-predicted APY tracking.
        _emitPerformanceSnapshot();
    }

    function _clearPlan() internal {
        rebalancePlanPhase = 0;
        rebalancePlanNextAction = 0;
        rebalancePlanTotalActions = 0;
    }

    /// @dev P2.1 — bump consecutive-failure counter (saturating at 255).
    function _bumpRebalanceBackoff() internal {
        uint8 f = rebalancePlanConsecutiveFailures;
        if (f < type(uint8).max) {
            rebalancePlanConsecutiveFailures = f + 1;
        }
    }

    /// @dev P2.1 — reset backoff after a successful finalise.
    function _resetRebalanceBackoff() internal {
        if (rebalancePlanConsecutiveFailures != 0) {
            rebalancePlanConsecutiveFailures = 0;
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // P0.Q11+Q12A — Performance snapshot helpers (added 2026-04-28)
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Aggregated snapshot data computed in single pass over adapters[].
    struct _SnapshotAcc {
        uint256 idle;
        uint256 sumPos;          // sum of positionAssets[adapter]
        uint256 maxPos;          // max single-adapter position (concentration)
        uint256 weightedAPY;     // sum(apy_bps * pos)
        uint256 weightedConf;    // sum(pos) where adapter has fresh TVL cache
        uint256 healthyAssets;   // pos for adapters returning real totalAssets()
        uint256 fallbackAssets;  // pos for adapters using positionAssets fallback
        uint8 activeCount;
        uint8 quarantinedCount;
    }

    /// @notice Build performance snapshot in one loop over registered adapters.
    /// @dev Internal view — NO state changes. Used by _emitPerformanceSnapshot.
    ///      Each adapter's currentAPYBps + totalAssets are tried in try/catch:
    ///      failures don't revert the snapshot; they just exclude the adapter
    ///      from weighted aggregates (and increment the degradedViews bucket).
    function _buildSnapshotAcc() internal view returns (_SnapshotAcc memory acc) {
        acc.idle = ASSET.balanceOf(address(this));
        uint256 n = adapters.length;
        for (uint256 i = 0; i < n;) {
            address a = adapters[i];
            uint256 pos = positionAssets[a];
            acc.sumPos += pos;
            if (pos > acc.maxPos) acc.maxPos = pos;

            if (enabled[a]) {
                if (quarantined[a]) {
                    unchecked { ++acc.quarantinedCount; }
                } else {
                    unchecked { ++acc.activeCount; }
                }

                // Predicted APY contribution (weighted by position size)
                if (pos > 0) {
                    try ILendingAdapter(a).currentAPYBps() returns (uint16 ap) {
                        acc.weightedAPY += uint256(ap) * pos;
                    } catch {
                        // Adapter APY unavailable — exclude from average.
                    }
                }

                // External TVL confidence: adapter has fresh cache → contributes its position
                if (cachedExternalTVL[a] > 0 && cachedExternalTVLTs[a] > 0) {
                    acc.weightedConf += pos;
                }

                // Degraded-views detection: try live totalAssets() vs positionAssets
                try ILendingAdapter(a).totalAssets() returns (uint256 actualTA) {
                    if (actualTA > 0) {
                        acc.healthyAssets += pos;
                    } else {
                        acc.fallbackAssets += pos;
                    }
                } catch {
                    acc.fallbackAssets += pos;
                }
            }
            unchecked { ++i; }
        }
    }

    /// @notice Emit LendingPerformanceSnapshot + persist storage tuple.
    /// @dev Computes 10-field metric snapshot via _buildSnapshotAcc.
    ///      Storage update (lastSnapshotTotalAssets/Ts/PredictedAPYBps) gives the
    ///      indexer the previous prediction for delta computation off-chain.
    function _emitPerformanceSnapshot() internal {
        _SnapshotAcc memory acc = _buildSnapshotAcc();
        uint256 totalAssets_ = acc.idle + acc.sumPos;

        uint16 idlePctBps_ = totalAssets_ > 0
            ? uint16((acc.idle * 10_000) / totalAssets_)
            : 0;

        uint16 weightedAPYPredictedBps_ = acc.sumPos > 0
            ? uint16(_safeBps(acc.weightedAPY / acc.sumPos))
            : 0;

        uint16 concentrationTopBps_ = totalAssets_ > 0
            ? uint16((acc.maxPos * 10_000) / totalAssets_)
            : 0;

        uint16 weightedTVLConfidenceBps_ = acc.sumPos > 0
            ? uint16((acc.weightedConf * 10_000) / acc.sumPos)
            : 0;

        uint256 totalCheck = acc.healthyAssets + acc.fallbackAssets;
        uint16 degradedViewsBps_ = totalCheck > 0
            ? uint16((acc.fallbackAssets * 10_000) / totalCheck)
            : 0;

        emit LendingPerformanceSnapshot(
            uint64(block.timestamp),
            totalAssets_,
            idlePctBps_,
            weightedAPYPredictedBps_,
            lastSnapshotPredictedAPYBps,    // previous snapshot's prediction
            concentrationTopBps_,
            acc.activeCount,
            acc.quarantinedCount,
            weightedTVLConfidenceBps_,
            degradedViewsBps_
        );

        // Persist for next snapshot's "previous" reference + off-chain queries.
        // Cap to uint128 max to avoid overflow on theoretically-huge TVL.
        lastSnapshotTotalAssets = totalAssets_ > type(uint128).max
            ? type(uint128).max
            : uint128(totalAssets_);
        lastSnapshotTs = uint64(block.timestamp);
        lastSnapshotPredictedAPYBps = weightedAPYPredictedBps_;
    }

    /// @dev Cap value at uint16.max to fit event field.
    function _safeBps(uint256 v) internal pure returns (uint256) {
        return v > type(uint16).max ? uint256(type(uint16).max) : v;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Local helpers — duplicated from Scoring to avoid extra delegatecall
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Local copy of ScoringModule._tvl(). Sums idle + positionAssets of
    ///      all registered adapters. Used by the drift invalidation check only.
    function _tvlLocal() internal view returns (uint256) {
        uint256 sum = ASSET.balanceOf(address(this));
        uint256 n = adapters.length;
        for (uint256 i = 0; i < n;) {
            sum += positionAssets[adapters[i]];
            unchecked { ++i; }
        }
        return sum;
    }

    /// @dev Local copy of ScoringModule._idleDeployThreshold(). Used only in
    ///      _finalizePlan when deciding whether to trigger auto-redeploy.
    function _idleDeployThresholdLocal() internal view returns (uint256) {
        uint256 _dust = dustTolerance;
        uint32 _liqStaleness = liquidityStalenessSeconds;
        if (_liqStaleness > 0) {
            uint256 n = adapters.length;
            for (uint256 i = 0; i < n;) {
                address a = adapters[i];
                if (enabled[a] && cachedLiquidityTs[a] > 0
                    && block.timestamp - cachedLiquidityTs[a] > _liqStaleness) {
                    return _dust;
                }
                unchecked { ++i; }
            }
        }
        uint256 tvlBased = (_tvlLocal() * 5) / 1e4;
        uint256 maxCap = 50_000e6;
        if (tvlBased > maxCap) tvlBased = maxCap;
        return tvlBased > _dust ? tvlBased : _dust;
    }

    /// @dev Small delegator wrappers for adapterOpsModule calls used inside
    ///      _executeRebalanceStepInternal. Same pattern as ScoringModule.
    function _safeAdapterDepositViaOps(address adapter, uint256 amount) internal returns (bool) {
        if (amount == 0) return true;
        (bool ok, bytes memory res) = adapterOpsModule.delegatecall(
            abi.encodeWithSelector(SAFE_DEPOSIT_SEL, adapter, amount)
        );
        if (!ok) return false;
        if (res.length == 0) return ok;
        return abi.decode(res, (bool));
    }

    /// @dev Same pattern as ScoringModule's _recordAdapterFailure/_recordAdapterSuccess but in PlanModule context.
    function _recordAdapterFailureViaOps(address adapter) internal {
        (bool ok,) = adapterOpsModule.delegatecall(
            abi.encodeWithSelector(RECORD_FAILURE_SEL, adapter)
        );
        require(ok, "AdapterOps call failed");
    }

    function _recordAdapterSuccessViaOps(address adapter) internal {
        (bool ok,) = adapterOpsModule.delegatecall(
            abi.encodeWithSelector(RECORD_SUCCESS_SEL, adapter)
        );
        require(ok, "AdapterOps call failed");
    }

}
