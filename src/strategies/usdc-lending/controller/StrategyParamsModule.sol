// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title StrategyParamsModule
 * @notice Operational param functions for UsdcMultiLendingVault, called via delegatecall.
 * @dev    Governance setters (DEFAULT_ADMIN_ROLE + PARAM_ROLE) were extracted to
 *         StrategySettingsModule (REFACTOR-A, 2026-05-04) to stay under EIP-170.
 *
 *         This module retains: position sync, external TVL/liquidity poking,
 *         stability EMA, and operational view helpers.
 */

// FIX P0.L5: AccessControl/Pausable/ReentrancyGuard inherited transitively
// via StrategyStorageLayout — direct imports removed to prevent shadowing.
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ILendingAdapter, IAdapterEmergency } from "../interfaces/ILendingAdapter.sol";
// FIX P0.L5: import full file → brings in StrategyStorageLayout (parent) +
// all file-scope errors (Unauthorized, Frozen, ParamOutOfRange, ZeroAmount,
// InsufficientBalance, ZeroAddress, etc.) used by setter logic.
import {
    StrategyStorageLayout,
    SkipReason,
    Unauthorized, Frozen, InvalidAdapter, WeightsSumInvalid,
    MinAdaptersTooLow, RiskScoreTooHigh, DurationTooLong, BackfillTooLarge,
    BootstrapInactive, InvalidInput, ParamOutOfRange, ZeroAmount,
    InsufficientBalance, ZeroAddress
} from "./StrategyStorageLayout.sol";

/**
 * @dev CRITICAL: Storage layout must be IDENTICAL to UsdcMultiLendingVault.
 *      We inherit AccessControl + Pausable + ReentrancyGuard in the same order
 *      to guarantee the same slot offsets for inherited state, then declare
 *      all strategy storage variables in the exact same order.
 */
contract StrategyParamsModule is StrategyStorageLayout {
    using SafeERC20 for IERC20Metadata;

    // ── Constants UNIQUE to ParamsModule ────────────────────────────────
    uint256 public constant MAX_EXTERNAL_TVL = 50_000_000_000e6; // 50B USDC

    // ── Events UNIQUE to ParamsModule (not in StorageLayout) ────────────
    event ExternalTVLRejected(address indexed adapter, uint256 previousTvl, uint256 reportedTvl);

    // ── Constructor ─────────────────────────────────────────────────────
    constructor(address asset_, address _core)
        StrategyStorageLayout(asset_, _core, address(0), address(0), address(0))
    {}

    // ══════════════════════════════════════════════════════════════════════
    //  VIEW: ADAPTER REGISTRY
    // ══════════════════════════════════════════════════════════════════════

    function adapterCount() external view returns (uint256) {
        return adapters.length;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  DELEGATED FUNCTIONS (moved from UsdcLendingStrategy for size limit)
    // ══════════════════════════════════════════════════════════════════════

    // FIX P0.L5: DEFAULT_*/CONFIDENCE_* constants inherited from StorageLayout.
    // ExternalTVLPoked event also inherited.
    event ScoringComputed(
        address indexed adapter, uint256 scoreRaw, uint256 scoreNorm,
        uint256 targetAlloc, uint256 currentPos, uint16 apyBps,
        uint256 liqBps, uint256 riskBps, uint256 stabilityBps, uint16 incentiveBps
    );

    // ══════════════════════════════════════════════════════════════════════
    //  POSITION SYNC (PARAM_ROLE)
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Manual full sync — PARAM_ROLE only. Same guards as internal.
    function syncPositionAssets() external onlyRoleOrRevert(PARAM_ROLE) {
        uint256 n = adapters.length;
        uint256 totalDrift = 0;
        bool hasNegative = false;
        uint256 _dust = dustTolerance;
        for (uint256 i = 0; i < n;) {
            address adapter = adapters[i];
            if (enabled[adapter] || positionAssets[adapter] > 0) {
                uint256 oldPos = positionAssets[adapter];
                uint256 actual = _safeTotalAssets(adapter);
                if (actual == 0 && oldPos > 0) {
                    emit PositionSyncSkippedSuspicious(adapter, oldPos, actual);
                    unchecked { ++i; } continue;
                }
                if (oldPos > 0 && actual > oldPos * 3) {
                    emit PositionSyncSkippedSuspicious(adapter, oldPos, actual);
                    unchecked { ++i; } continue;
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
    }

    /// @notice Per-adapter sync (granular) — PARAM_ROLE only.
    function syncPositionAsset(address adapter) external onlyRoleOrRevert(PARAM_ROLE) {
        if (!isAdapter[adapter]) revert InvalidAdapter();
        if (!enabled[adapter] && positionAssets[adapter] == 0) return;
        uint256 oldPos = positionAssets[adapter];
        uint256 actual = _safeTotalAssets(adapter);
        if (actual == 0 && oldPos > 0) { emit PositionSyncSkippedSuspicious(adapter, oldPos, actual); return; }
        if (oldPos > 0 && actual > oldPos * 3) { emit PositionSyncSkippedSuspicious(adapter, oldPos, actual); return; }
        uint256 diff = actual > oldPos ? actual - oldPos : oldPos - actual;
        if (diff >= dustTolerance) {
            positionAssets[adapter] = actual;
            emit PositionAssetsSynced(adapter, oldPos, actual);
        }
    }

    /// @notice View: total bookkeeping drift (monitoring ONLY — expensive off-chain call).
    function drift() external view returns (uint256 totalDrift, bool hasNegative) {
        uint256 n = adapters.length;
        for (uint256 i = 0; i < n;) {
            address adapter = adapters[i];
            if (enabled[adapter] || positionAssets[adapter] > 0) {
                uint256 actual = _safeTotalAssets(adapter);
                uint256 pos = positionAssets[adapter];
                if (actual > pos) { unchecked { totalDrift += actual - pos; } }
                else if (pos > actual) { unchecked { totalDrift += pos - actual; } hasNegative = true; }
            }
            unchecked { ++i; }
        }
    }

    /// @notice View: should sync run? Cheap cooldown check for off-chain callers.
    function shouldSyncPositionAssets() external view returns (bool) {
        if (lastSyncTs != 0 && block.timestamp < uint256(lastSyncTs) + minSecondsBetweenSync) return false;
        return true;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  EXTERNAL TVL CACHE
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Refresh external TVL cache ONLY (no liquidity). KEEPER_ROLE.
    /// @dev    Cheap (~1M gas for 7 adapters). Call pokeLiquidityBatch separately.
    function pokeExternalTVL() external onlyRoleOrRevert(KEEPER_ROLE) {
        address[] memory enabledList = _enabledAdapters();
        uint256 n = enabledList.length;
        for (uint256 i = 0; i < n;) {
            address adapter = enabledList[i];
            try ILendingAdapter(adapter).externalMarketTVL() returns (uint256 tvl) {
                uint256 prev = cachedExternalTVL[adapter];
                bool valid = true;

                // Layer 1: absolute sanity bound
                if (tvl > MAX_EXTERNAL_TVL) valid = false;

                // Layer 2: delta limiter — reject jumps > 10x previous value
                if (valid && prev > 0) {
                    uint256 maxJump = (prev * MAX_EXTERNAL_TVL_JUMP_BPS) / 10_000;
                    if (tvl > maxJump) valid = false;
                }

                if (valid) {
                    // Phase 1.5: snapshot OLD value before overwrite, but only once per window.
                    // Skip first-time (cachedExternalTVL==0) — no baseline to compare against.
                    uint64 snapshotAge = uint64(block.timestamp) - lastExtTVLSnapshotTs[adapter];
                    if (prev > 0 && snapshotAge >= EXT_TVL_PANIC_WINDOW_SEC) {
                        lastExtTVLSnapshot[adapter]   = prev;
                        lastExtTVLSnapshotTs[adapter] = uint64(block.timestamp);
                    }
                    cachedExternalTVL[adapter] = tvl;
                    cachedExternalTVLTs[adapter] = uint64(block.timestamp);
                    emit ExternalTVLPoked(adapter, tvl);
                } else {
                    emit ExternalTVLRejected(adapter, prev, tvl);
                }
            } catch {}

            // Audit HIGH 1.6 fix: populate cachedAdapterCapacity so the delta
            // jump limiter in StrategyAllocCalcModule._checkAdapterEligibility()
            // (which reads this mapping) is no longer permanently inert. Same
            // keeper cadence and try/catch-safe pattern as the externalMarketTVL
            // poke above -- a bricked/reverting maxCapacity() simply leaves the
            // cache at its last known-good value.
            try ILendingAdapter(adapter).maxCapacity() returns (uint256 cap) {
                uint256 prevCap = cachedAdapterCapacity[adapter];
                if (prevCap > 0 && cap > prevCap) {
                    uint256 maxCapJump = (prevCap * MAX_EXTERNAL_TVL_JUMP_BPS) / 10_000;
                    if (cap > maxCapJump) {
                        emit AdapterCapacityJump(adapter, prevCap, cap);
                    }
                } else if (prevCap > 0 && cap < prevCap) {
                    emit AdapterCapacityDecreased(adapter, cap, prevCap);
                }
                cachedAdapterCapacity[adapter] = cap;
            } catch {}
            unchecked { ++i; }
        }
    }

    /// @notice Refresh liquidity cache for adapters [start, end). KEEPER_ROLE.
    /// @dev    Morpho alone costs ~3.15M gas. Split into small batches.
    function pokeLiquidityBatch(uint256 start, uint256 end) external onlyRoleOrRevert(KEEPER_ROLE) {
        address[] memory enabledList = _enabledAdapters();
        if (end > enabledList.length) end = enabledList.length;
        if (start >= end) return;
        for (uint256 i = start; i < end;) {
            _pokeLiquidity(enabledList[i]);
            unchecked { ++i; }
        }
    }

    function _pokeLiquidity(address adapter) internal {
        uint256 tot = _safeTotalAssets(adapter);
        if (tot <= dustTolerance) {
            cachedLiquidityBps[adapter] = 10000; // empty adapter = fully liquid
            cachedLiquidityTs[adapter] = uint64(block.timestamp);
            return;
        }
        uint256 wa = _safeWithdrawableAssets(adapter);
        uint256 liq = (wa * 1e4) / tot;
        if (liq > 10000) liq = 10000;
        // Store 1 instead of 0 to distinguish "measured zero" from "never cached".
        // _cachedLiq() treats cached==0 as "never cached" → DEFAULT_LIQ_BPS.
        // cached==1 means "measured, near-zero liquidity" → score penalty applied.
        cachedLiquidityBps[adapter] = liq < 1 ? 1 : uint16(liq);
        cachedLiquidityTs[adapter] = uint64(block.timestamp);

        // V9.2 CTO: Update stability EMA in the same observation pass
        try ILendingAdapter(adapter).currentAPYBps() returns (uint16 currApy) {
            _updateStabilityEMA(adapter, currApy);
        } catch {
            // APY query failed — don't penalize stability for query failure
        }
    }

    /// @dev Stability EMA update — measures APY volatility over time (CTO-approved formula).
    ///      denom = max(prevAPY, apyFloorBps)
    ///      deltaRatioBps = min(|curr - prev| * 10000 / denom, 10000)
    ///      rawStability = 10000 - deltaRatioBps
    ///      stabilityEMA = α * rawStability + (1 - α) * oldEMA,  α = 2/(period+1)
    function _updateStabilityEMA(address adapter, uint16 currApyBps) internal {
        uint64 nowTs = uint64(block.timestamp);
        uint64 lastTs = lastStabilityUpdateTs[adapter];

        // Skip overly frequent updates to avoid noisy signal
        uint32 minInterval = minStabilityUpdateInterval;
        if (minInterval == 0) minInterval = 6 hours;
        if (lastTs != 0 && nowTs < lastTs + minInterval) return;

        uint16 prevApyBps = lastPokedAPY[adapter];

        // First observation: seed with neutral default, don't compute delta
        if (prevApyBps == 0 && lastTs == 0) {
            lastPokedAPY[adapter] = currApyBps;
            lastStabilityUpdateTs[adapter] = nowTs;
            if (stabilityEMA[adapter] == 0) {
                stabilityEMA[adapter] = DEFAULT_STABILITY_BPS;
            }
            return;
        }

        // Delta ratio with floor protection
        uint256 floor = apyFloorBps;
        if (floor == 0) floor = 50;
        uint256 denom = prevApyBps > floor ? prevApyBps : floor;
        uint256 diff = currApyBps > prevApyBps
            ? uint256(currApyBps - prevApyBps)
            : uint256(prevApyBps - currApyBps);
        uint256 deltaRatioBps = (diff * 10000) / denom;
        if (deltaRatioBps > 10000) deltaRatioBps = 10000;

        uint16 rawStability = uint16(10000 - deltaRatioBps);

        // EMA smoothing
        uint256 period = stabilityEMAPeriod;
        if (period == 0) period = 7;
        uint256 alphaBps = (2 * 10000) / (period + 1);
        uint256 prevEma = stabilityEMA[adapter];
        if (prevEma == 0) prevEma = DEFAULT_STABILITY_BPS;

        stabilityEMA[adapter] = uint16(
            (alphaBps * uint256(rawStability) + (10000 - alphaBps) * prevEma) / 10000
        );
        lastPokedAPY[adapter] = currApyBps;
        lastStabilityUpdateTs[adapter] = nowTs;
    }

    // NOTE: explainScore() and explainAllocation() moved to StrategyExplainabilityLens
    // (external read-only contract, NOT a delegatecall module). The lens reads strategy
    // public state via getters and reconstructs scoring logic independently.
    // This is best-effort explainability — NOT the canonical economic logic source.
    // See: src/strategies/usdc-lending/lens/StrategyExplainabilityLens.sol

    // NOTE (cleanup): _effectiveMaxAdapters(uint256) and
    // effectiveMinNewAdapterSeed()/_effectiveMinNewAdapterSeed(uint256) were
    // removed from this module. Both were unreachable dead code: the vault's
    // fallback() dispatches to StrategyScoringModule (mods[0]) before
    // StrategyParamsModule (mods[4]), and StrategyScoringModule already
    // implements effectiveMinNewAdapterSeed() with the identical selector, so
    // it always wins the dispatch -- this module's copy could never execute
    // via the vault. Worse, _effectiveMaxAdapters(uint256) had STALE tier
    // thresholds (150K/650K/3M) predating the AUDIT-FINDING-1 fix that
    // corrected them to 25K/250K/1M/5M in StrategyScoringModule/
    // StrategyAllocCalcModule -- leaving it in place risked a future edit
    // mistakenly wiring up the stale copy. See test/strategies/usdc-lending/
    // Dynamic_Seed.t.sol and Scoring_Model.t.sol, which exercise the live
    // StrategyScoringModule implementation via `StrategyParamsModule(address(vault))
    // .effectiveMinNewAdapterSeed()` -- the cast is only for ABI encoding;
    // dispatch still resolves to ScoringModule.

    /// @dev Internal mirror of UsdcLendingStrategy.isBootstrapActive() — used inside delegatecall.
    function _isBootstrapActive() internal view returns (bool) {
        return bootstrapEndsAt > 0 && block.timestamp < bootstrapEndsAt;
    }

    // _tvl (ASSET.balanceOf variant), _enabledAdapters, _clampLiq, _tvlConfidence,
    // _effectiveRelativeCapBps, _safeTotalAssets, _safeWithdrawableAssets — inherited from StrategyStorageLayout.

}
