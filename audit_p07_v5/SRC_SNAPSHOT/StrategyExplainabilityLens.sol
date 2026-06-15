// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ILendingAdapter } from "../interfaces/ILendingAdapter.sol";

/// @title StrategyExplainabilityLens — Read-only external explainability for UsdcLendingStrategy
/// @notice Standalone periphery contract. Reads strategy state via public getters and adapter
///         interfaces to reconstruct scoring and allocation logic for frontend/debug consumers.
/// @dev    IMPORTANT: This is best-effort explainability, NOT the canonical economic logic source.
///         If this lens diverges from the core ScoringModule, the worst case is incorrect debug
///         output — not incorrect allocation. The protocol's economic behavior is determined
///         exclusively by StrategyScoringModule via delegatecall inside the strategy.
///         This separation is intentional for audit cleanliness.
contract StrategyExplainabilityLens {

    // ═══════════════════════════════════════════════════════════════════
    // CONSTANTS (mirrored from StrategyStorageLayout)
    // ═══════════════════════════════════════════════════════════════════

    uint256 constant DEFAULT_STABILITY_BPS = 7000;
    uint256 constant DEFAULT_RISK_BPS = 7000;
    uint256 constant DEFAULT_LIQ_BPS = 5000;

    uint256 constant CONFIDENCE_ZERO  = 0;
    uint256 constant CONFIDENCE_MICRO = 3000;
    uint256 constant CONFIDENCE_SMALL = 5000;
    uint256 constant CONFIDENCE_LOW   = 7000;
    uint256 constant CONFIDENCE_MED   = 8500;
    uint256 constant CONFIDENCE_HIGH  = 9500;
    uint256 constant CONFIDENCE_VHIGH = 10000;

    // ═══════════════════════════════════════════════════════════════════
    // IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════

    IStrategyView public immutable strategy;

    constructor(address strategy_) {
        require(strategy_ != address(0), "strategy=0");
        require(strategy_.code.length > 0, "strategy !contract");
        strategy = IStrategyView(strategy_);
    }

    // ═══════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════

    struct AdapterAllocationInfo {
        address adapter;
        SkipReason skipReason;
        uint256 score;
        uint256 headroom;
        uint256 targetAlloc;
        uint256 currentPos;
        uint256 maxExposure;
        uint256 relCap;
        uint256 confidence;
    }

    enum SkipReason {
        None,
        Flagged,
        LowConfidence,
        OverMaxCap,
        OverRelCap,
        ZeroHeadroom,
        QueryFailed_,
        NotSelected
    }

    /// @dev Context struct to reduce stack depth in explainAllocation (Yul viaIR).
    struct _AllocContext {
        uint16 adapterMaxExposureBps;
        uint16 relExpBpsOverride;
        uint256 tvl;
        uint16 effectiveMaxAdapters;
    }

    /// @dev Return bundle for _runPhase1Selection — single ptr vs 4 separate return slots (Yul viaIR).
    struct _Phase1Result {
        address[] selected;
        uint256[] selectedScores;
        uint256[] headrooms;
        uint256 selCount;
    }

    // ═══════════════════════════════════════════════════════════════════
    // EXPLAINABILITY VIEWS
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Scoring components for a single adapter (mirrors old ParamsModule.explainScore)
    function explainScore(address adapter)
        external
        view
        returns (
            uint16 apyBps,
            uint256 liqBps,
            uint256 riskBps,
            uint256 confidenceBps,
            uint256 stabilityBps,
            uint16 incentiveBps,
            uint256 scoreRaw,
            uint256 currentPos,
            uint256 maxExposure,
            uint256 cachedExtTVL
        )
    {
        try ILendingAdapter(adapter).currentAPYBps() returns (uint16 a) {
            apyBps = a;
        } catch { apyBps = 0; }

        liqBps = _clampLiq(adapter);

        uint256 riskScore = strategy.riskScoreBps(adapter);
        uint256 baseRisk = riskScore > 0 ? (10000 - riskScore) : DEFAULT_RISK_BPS;
        confidenceBps = _tvlConfidence(adapter);
        riskBps = (baseRisk * confidenceBps) / 1e4;

        stabilityBps = strategy.stabilityEMA(adapter);
        if (stabilityBps < 1) stabilityBps = DEFAULT_STABILITY_BPS;

        // FIX P1.L6: _decayedIncentive deleted; P0.L1A forces wIncentive=0 in scoring.
        // Lens reflects actual scoring contribution which is 0 until P0.L1B reward pipeline.
        incentiveBps = 0;

        scoreRaw = uint256(strategy.wAPY()) * apyBps
            + uint256(strategy.wLiq()) * liqBps
            + uint256(strategy.wRisk()) * riskBps
            + uint256(strategy.wStability()) * stabilityBps
            + uint256(strategy.wIncentive()) * incentiveBps;

        currentPos = strategy.positionAssets(adapter);
        uint256 tvl = strategy.totalAssets();
        maxExposure = (uint256(strategy.adapterMaxExposureBps()) * tvl) / 1e4;
        cachedExtTVL = strategy.cachedExternalTVL(adapter);
    }

    /// @notice Full allocation explainability (mirrors old ParamsModule.explainAllocation)
    function explainAllocation(uint256 amountToAllocate)
        external
        view
        returns (AdapterAllocationInfo[] memory infos, uint256 tvl, uint16 effectiveMaxAdapters)
    {
        address[] memory enabledList = _enabledAdapters();
        tvl = strategy.totalAssets();
        effectiveMaxAdapters = _effectiveMaxAdapters(tvl);
        _AllocContext memory ctx = _AllocContext({
            adapterMaxExposureBps: strategy.adapterMaxExposureBps(),
            relExpBpsOverride: strategy.maxRelativeExposureBps(),
            tvl: tvl,
            effectiveMaxAdapters: effectiveMaxAdapters
        });
        uint256 n = enabledList.length;
        (uint256[] memory normScores, uint256[] memory order) = _fetchNormScoresAndOrder(enabledList, n);
        infos = new AdapterAllocationInfo[](n);

        _Phase1Result memory p1 = _runPhase1Selection(enabledList, normScores, order, ctx, infos);

        _runPhase2Alloc(amountToAllocate, p1.selCount, p1.selectedScores, p1.headrooms, infos, p1.selected, n);
    }

    /// @dev Phase 1: score-ranked selection into infos[]. Extracted to reduce Yul stack depth.
    function _runPhase1Selection(
        address[] memory enabledList,
        uint256[] memory normScores,
        uint256[] memory order,
        _AllocContext memory ctx,
        AdapterAllocationInfo[] memory infos
    ) internal view returns (_Phase1Result memory r) {
        uint256 n = enabledList.length;
        r.selected = new address[](n);
        r.selectedScores = new uint256[](n);
        r.headrooms = new uint256[](n);
        r.selCount = 0;
        for (uint256 i = 0; i < n; ++i) {
            uint256 idx = order[i];
            address adapter = enabledList[idx];
            (infos[i], ) = _evaluateAdapter(
                adapter, normScores[idx], ctx.tvl, ctx.adapterMaxExposureBps, ctx.relExpBpsOverride, r.selCount, ctx.effectiveMaxAdapters
            );
            if (infos[i].skipReason == SkipReason.None) {
                r.selected[r.selCount] = adapter;
                r.selectedScores[r.selCount] = normScores[idx];
                r.headrooms[r.selCount] = infos[i].headroom;
                r.selCount++;
            }
        }
    }

    /// @dev Phase 2: write targets into infos[].targetAlloc. Extracted to reduce Yul stack depth.
    function _runPhase2Alloc(
        uint256 amountToAllocate,
        uint256 selCount,
        uint256[] memory selectedScores,
        uint256[] memory headrooms,
        AdapterAllocationInfo[] memory infos,
        address[] memory selected,
        uint256 n
    ) internal view {
        if (selCount == 0 || amountToAllocate == 0) return;
        uint256[] memory targets = _computeTargets(amountToAllocate, selCount, selectedScores, headrooms);
        uint256 selIdx = 0;
        for (uint256 i = 0; i < n && selIdx < selCount; ++i) {
            if (infos[i].skipReason == SkipReason.None && infos[i].adapter == selected[selIdx]) {
                infos[i].targetAlloc = targets[selIdx];
                selIdx++;
            }
        }
    }

    /// @dev 3-pass proportional cap allocation. Extracted to reduce _runPhase2Alloc Yul stack depth.
    function _computeTargets(
        uint256 amountToAllocate,
        uint256 selCount,
        uint256[] memory selectedScores,
        uint256[] memory headrooms
    ) internal view returns (uint256[] memory targets) {
        targets = new uint256[](selCount);
        uint256 remaining = amountToAllocate;
        bool[] memory clamped = new bool[](selCount);
        uint256 _dust = strategy.dustTolerance();

        for (uint256 pass = 0; pass < 3 && remaining > _dust; ++pass) {
            uint256 sSum = 0;
            for (uint256 j = 0; j < selCount; ++j) {
                if (!clamped[j]) sSum += selectedScores[j];
            }
            if (sSum < 1) break;
            uint256 distributed = 0;
            for (uint256 j = 0; j < selCount; ++j) {
                if (clamped[j]) continue;
                uint256 target = (remaining * selectedScores[j]) / sSum;
                if (target > headrooms[j]) {
                    target = headrooms[j];
                    clamped[j] = true;
                }
                targets[j] += target;
                distributed += target;
            }
            remaining -= distributed;
        }
    }

    /// @notice Stability EMA details for an adapter
    function explainStability(address adapter)
        external
        view
        returns (
            uint16 lastAPY,
            uint256 currentEMA,
            uint64 lastUpdateTs,
            uint16 apyFloor,
            uint32 minInterval,
            uint16 period
        )
    {
        lastAPY = strategy.lastPokedAPY(adapter);
        currentEMA = strategy.stabilityEMA(adapter);
        lastUpdateTs = strategy.lastStabilityUpdateTs(adapter);
        apyFloor = strategy.apyFloorBps();
        minInterval = strategy.minStabilityUpdateInterval();
        period = strategy.stabilityEMAPeriod();
    }

    // ═══════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS (lens-local, NOT delegatecall shared)
    // ═══════════════════════════════════════════════════════════════════

    function _evaluateAdapter(
        address adapter,
        uint256 score,
        uint256 tvl,
        uint16 _adapterMaxExposureBps,
        uint16 _relExpBpsOverride,
        uint256 selCount,
        uint16 maxAdapters
    ) internal view returns (AdapterAllocationInfo memory info, bool selected_) {
        uint256 current = strategy.positionAssets(adapter);
        uint256 maxExp = (uint256(_adapterMaxExposureBps) * tvl) / 1e4;
        uint256 conf = _tvlConfidence(adapter);
        uint256 extTVL = strategy.cachedExternalTVL(adapter);
        uint256 relCapVal = 0;
        if (extTVL > 0) {
            uint16 dynamicRelCap = _effectiveRelativeCapBps(extTVL);
            uint16 effRelCap = (_relExpBpsOverride > 0 && _relExpBpsOverride < dynamicRelCap)
                ? _relExpBpsOverride : dynamicRelCap;
            relCapVal = (extTVL * effRelCap) / 1e4;
        }

        info.adapter = adapter;
        info.score = score;
        info.currentPos = current;
        info.maxExposure = maxExp;
        info.relCap = relCapVal;
        info.confidence = conf;

        if (selCount >= maxAdapters) { info.skipReason = SkipReason.NotSelected; return (info, false); }
        if (strategy.flagged(adapter)) { info.skipReason = SkipReason.Flagged; return (info, false); }
        if (conf == CONFIDENCE_ZERO) { info.skipReason = SkipReason.LowConfidence; return (info, false); }
        if (current >= maxExp) { info.skipReason = SkipReason.OverMaxCap; return (info, false); }

        uint256 headroom = maxExp - current;
        if (extTVL > 0 && current >= relCapVal) { info.skipReason = SkipReason.OverRelCap; return (info, false); }
        if (extTVL > 0) {
            uint256 rh = relCapVal - current;
            if (rh < headroom) headroom = rh;
        }

        // Ramp for new adapters
        bool _isBootstrap = strategy.bootstrapEndsAt() > 0 && block.timestamp < strategy.bootstrapEndsAt();
        if (!_isBootstrap) {
            uint64 actAt = strategy.adapterActivatedAt(adapter);
            bool inRamp = block.timestamp < actAt + strategy.newAdapterRampDuration();
            bool isNew = (inRamp && current < _effectiveMinNewAdapterSeed(tvl)) || current <= strategy.dustTolerance();
            if (isNew) {
                uint256 rawLimit = (uint256(strategy.newAdapterRampBps()) * tvl) / 1e4;
                if (rawLimit < headroom) headroom = rawLimit;
            }
        }

        try ILendingAdapter(adapter).maxCapacity() returns (uint256 cap) {
            if (cap > 0 && current + headroom > cap) headroom = cap > current ? cap - current : 0;
        } catch { info.skipReason = SkipReason.QueryFailed_; return (info, false); }

        if (headroom < 1) { info.skipReason = SkipReason.ZeroHeadroom; return (info, false); }

        info.skipReason = SkipReason.None;
        info.headroom = headroom;
        return (info, true);
    }

    function _enabledAdapters() internal view returns (address[] memory) {
        uint256 total = strategy.adapterCount();
        address[] memory tmp = new address[](total);
        uint256 k = 0;
        for (uint256 i = 0; i < total; ++i) {
            address a = strategy.adapters(i);
            if (strategy.enabled(a) && !strategy.quarantined(a)) {
                tmp[k++] = a;
            }
        }
        assembly { mstore(tmp, k) }
        return tmp;
    }

    function _clampLiq(address adapter) internal view returns (uint256) {
        uint256 tot;
        try ILendingAdapter(adapter).totalAssets() returns (uint256 t) { tot = t; }
        catch { return DEFAULT_LIQ_BPS; }
        if (tot <= strategy.dustTolerance()) return 10000;
        uint256 wa;
        try ILendingAdapter(adapter).withdrawableAssets() returns (uint256 w) { wa = w; }
        catch { return DEFAULT_LIQ_BPS; }
        uint256 liq = (wa * 1e4) / tot;
        return liq > 10000 ? 10000 : liq;
    }

    function _tvlConfidence(address adapter) internal view returns (uint256) {
        uint256 extTVL = strategy.cachedExternalTVL(adapter);
        uint32 staleness = strategy.externalTVLStalenessSeconds();
        if (staleness > 0 && strategy.cachedExternalTVLTs(adapter) > 0) {
            if (block.timestamp - strategy.cachedExternalTVLTs(adapter) > staleness) {
                return CONFIDENCE_MICRO;
            }
        }
        if (extTVL < 1) return CONFIDENCE_MICRO;
        if (extTVL < 100_000e6) return CONFIDENCE_ZERO;
        if (extTVL < 500_000e6) return CONFIDENCE_MICRO;
        if (extTVL < 2_000_000e6) return CONFIDENCE_SMALL;
        if (extTVL < 10_000_000e6) return CONFIDENCE_LOW;
        if (extTVL < 50_000_000e6) return CONFIDENCE_MED;
        if (extTVL < 250_000_000e6) return CONFIDENCE_HIGH;
        return CONFIDENCE_VHIGH;
    }

    function _effectiveRelativeCapBps(uint256 extTVL) internal pure returns (uint16) {
        if (extTVL < 100_000e6) return 0;
        if (extTVL < 500_000e6) return 200;
        if (extTVL < 1_000_000e6) return 500;
        if (extTVL < 2_000_000e6) return 800;
        if (extTVL < 3_000_000e6) return 1000;
        if (extTVL < 10_000_000e6) return 1200;
        if (extTVL < 25_000_000e6) return 1500;
        if (extTVL < 50_000_000e6) return 1800;
        if (extTVL < 250_000_000e6) return 2000;
        return 2500;
    }

    // FIX P1.L6: _decayedIncentive deleted (P0.L1A forces wIncentive=0).

    function _effectiveMaxAdapters(uint256 tvl) internal view returns (uint16) {
        uint16 staticMax = strategy.maxAdaptersPerAllocation();
        uint16 dynamicMax;
        if (tvl < 150_000e6) dynamicMax = 2;
        else if (tvl < 650_000e6) dynamicMax = 3;
        else if (tvl < 3_000_000e6) dynamicMax = 4;
        else dynamicMax = 5;
        return (staticMax > 0 && staticMax < dynamicMax) ? staticMax : dynamicMax;
    }

    function _effectiveMinNewAdapterSeed(uint256 tvl) internal view returns (uint256) {
        uint256 staticSeed = strategy.minNewAdapterSeed();
        uint256 dynamicSeed;
        if (tvl < 1_000_000e6) dynamicSeed = 10_000e6;
        else if (tvl < 10_000_000e6) dynamicSeed = 50_000e6;
        else dynamicSeed = (tvl * 200) / 1e4;
        return staticSeed > dynamicSeed ? staticSeed : dynamicSeed;
    }

    function _computeNormScores(
        address[] memory enabledList,
        uint16[] memory rawAPYs,
        uint16 maxAPY
    ) internal view returns (uint256[] memory) {
        uint256 n = enabledList.length;
        uint256[] memory rawScores = new uint256[](n);
        uint16 wA = strategy.wAPY();
        uint16 wL = strategy.wLiq();
        uint16 wR = strategy.wRisk();
        uint16 wS = strategy.wStability();
        uint16 wI = strategy.wIncentive();

        for (uint256 i = 0; i < n; ++i) {
            address adapter = enabledList[i];
            uint256 apyNorm = maxAPY > 0 ? (uint256(rawAPYs[i]) * 1e4) / maxAPY : 0;
            uint256 liq = _clampLiq(adapter);
            uint256 riskScore = strategy.riskScoreBps(adapter);
            uint256 risk = riskScore > 0 ? (10000 - riskScore) : DEFAULT_RISK_BPS;
            uint256 conf = _tvlConfidence(adapter);
            risk = (risk * conf) / 1e4;
            uint256 stab = strategy.stabilityEMA(adapter);
            if (stab < 1) stab = DEFAULT_STABILITY_BPS;
            // FIX P1.L6: _decayedIncentive deleted post-P0.L1A.
            uint16 inc = 0;
            rawScores[i] = uint256(wA) * apyNorm + uint256(wL) * liq + uint256(wR) * risk
                + uint256(wS) * stab + uint256(wI) * inc;
        }

        // Normalize
        uint256 sumScores = 0;
        for (uint256 i = 0; i < n; ++i) sumScores += rawScores[i];
        uint256[] memory norm = new uint256[](n);
        if (sumScores > 0) {
            for (uint256 i = 0; i < n; ++i) norm[i] = (rawScores[i] * 1e4) / sumScores;
        } else {
            uint256 eq = n > 0 ? 1e4 / n : 0;
            for (uint256 i = 0; i < n; ++i) norm[i] = eq;
        }
        return norm;
    }

    /// @dev Fetches raw APYs, computes norm scores, and sort order.
    ///      Extracted to reduce explainAllocation Yul stack depth (viaIR minimum).
    function _fetchNormScoresAndOrder(address[] memory enabledList, uint256 n)
        internal view
        returns (uint256[] memory normScores, uint256[] memory order)
    {
        uint16[] memory rawAPYs = new uint16[](n);
        uint16 maxAPY = 0;
        for (uint256 i = 0; i < n; ++i) {
            try ILendingAdapter(enabledList[i]).currentAPYBps() returns (uint16 a) {
                rawAPYs[i] = a;
            } catch { rawAPYs[i] = 0; }
            if (rawAPYs[i] > maxAPY) maxAPY = rawAPYs[i];
        }
        normScores = _computeNormScores(enabledList, rawAPYs, maxAPY);
        order = _sortDescending(normScores, n);
    }

    function _sortDescending(uint256[] memory scores, uint256 n)
        internal pure returns (uint256[] memory)
    {
        uint256[] memory order = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) order[i] = i;
        for (uint256 i = 1; i < n; ++i) {
            uint256 key = order[i];
            uint256 keyScore = scores[key];
            uint256 j = i;
            while (j > 0 && scores[order[j - 1]] < keyScore) {
                order[j] = order[j - 1];
                j--;
            }
            order[j] = key;
        }
        return order;
    }
}

/// @dev Minimal interface for reading strategy public state. All functions map to
///      public storage variables (auto-getters) or existing external view functions.
interface IStrategyView {
    function adapters(uint256 index) external view returns (address);
    function adapterCount() external view returns (uint256);
    function enabled(address adapter) external view returns (bool);
    function flagged(address adapter) external view returns (bool);
    function quarantined(address adapter) external view returns (bool);
    function positionAssets(address adapter) external view returns (uint256);
    function totalAssets() external view returns (uint256);

    // Scoring weights
    function wAPY() external view returns (uint16);
    function wLiq() external view returns (uint16);
    function wRisk() external view returns (uint16);
    function wStability() external view returns (uint16);
    function wIncentive() external view returns (uint16);

    // Per-adapter scoring data
    function riskScoreBps(address adapter) external view returns (uint16);
    function stabilityEMA(address adapter) external view returns (uint256);
    function cachedExternalTVL(address adapter) external view returns (uint256);
    function cachedExternalTVLTs(address adapter) external view returns (uint64);
    function cachedLiquidityBps(address adapter) external view returns (uint16);
    function cachedLiquidityTs(address adapter) external view returns (uint64);
    function lastPokedAPY(address adapter) external view returns (uint16);
    function lastStabilityUpdateTs(address adapter) external view returns (uint64);

    // Config
    function adapterMaxExposureBps() external view returns (uint16);
    function maxRelativeExposureBps() external view returns (uint16);
    function maxAdaptersPerAllocation() external view returns (uint16);
    function newAdapterRampBps() external view returns (uint16);
    function newAdapterRampDuration() external view returns (uint64);
    function minNewAdapterSeed() external view returns (uint256);
    function incentiveDecayHalfLife() external view returns (uint32);
    function lastRebalanceTs() external view returns (uint64);
    function bootstrapEndsAt() external view returns (uint64);
    function dustTolerance() external view returns (uint256);
    function externalTVLStalenessSeconds() external view returns (uint32);
    function adapterActivatedAt(address adapter) external view returns (uint64);

    // Stability EMA params
    function apyFloorBps() external view returns (uint16);
    function minStabilityUpdateInterval() external view returns (uint32);
    function stabilityEMAPeriod() external view returns (uint16);
}
