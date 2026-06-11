// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ═══════════════════════════════════════════════════════════════════════════════
// StrategyAllocCalcModule — delegatecall module for allocation calculation
// ═══════════════════════════════════════════════════════════════════════════════
// Extracted from StrategyScoringModule.sol (REFACTOR-B, 2026-05-04).
// Pure computation cluster: scoring pipeline, normalization, sorting,
// target allocation, cap/headroom checks. No deposits — ScoringModule
// executes deposits after receiving the allocation plan from this module.
// All functions operate on the strategy's storage via delegatecall.
// Direct calls are forbidden.
// ═══════════════════════════════════════════════════════════════════════════════

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    StrategyStorageLayout,
    AdapterScore,
    QueryFailed
} from "./StrategyStorageLayout.sol";
import { ILendingAdapter } from "../interfaces/ILendingAdapter.sol";

interface IAdapterAPYExt {
    function effectiveAPYBps() external view returns (uint16);
}

contract StrategyAllocCalcModule is StrategyStorageLayout {
    using SafeERC20 for IERC20Metadata;

    // ── Delegatecall-only guard ──────────────────────────────────────────────

    address private immutable _self;

    constructor(address asset_, address _core)
        StrategyStorageLayout(asset_, _core, address(0), address(0), address(0))
    {
        _self = address(this);
    }

    modifier onlyDelegateCall() {
        require(address(this) != _self, "DIRECT_CALL_FORBIDDEN");
        _;
    }

    // ── External entry points (called by ScoringModule via delegatecall) ────

    /// @notice Compute adapter scores. Returns unsorted, unnormalized.
    function execComputeScores(address[] memory enabledAdapters)
        external
        view
        onlyDelegateCall
        returns (AdapterScore[] memory)
    {
        return _computeAdapterScores(enabledAdapters);
    }

    /// @notice Normalize scores in-place.
    function execNormalizeScores(AdapterScore[] memory scores)
        external
        view
        onlyDelegateCall
        returns (AdapterScore[] memory)
    {
        _normalizeScores(scores);
        return scores;
    }

    /// @notice Compute target allocations per adapter given normalized scores and TVL.
    function execTargetAllocations(AdapterScore[] memory scores, uint256 tvl)
        external
        view
        onlyDelegateCall
        returns (uint256[] memory)
    {
        return _targetAllocations(scores, tvl);
    }

    /// @notice Aggregate plan inputs: apys, normScores, moved delta.
    function execAggregatePlanInputs(
        AdapterScore[] memory scores,
        address[] memory enabledList,
        uint256[] memory targetAllocs
    ) external view onlyDelegateCall returns (
        uint16[]  memory apys,
        uint256[] memory normScores,
        uint256 moved
    ) {
        uint256 len = enabledList.length;
        apys = new uint16[](len);
        normScores = new uint256[](len);
        for (uint256 i; i < len;) {
            AdapterScore memory s = scores[i];
            apys[i] = uint16(s.apyBps);
            normScores[i] = s.score;
            uint256 curr = positionAssets[enabledList[i]];
            uint256 tgt = targetAllocs[i];
            moved += curr > tgt ? curr - tgt : tgt - curr;
            unchecked { ++i; }
        }
    }

    /// @notice Compute the deployment allocation plan for idle cash.
    /// @dev    Returns selected adapters and per-adapter target deposit amounts.
    ///         ScoringModule executes the actual deposits after receiving this plan.
    function execSelectAllocation(uint256 amount, bool bestEffort)
        external
        view
        onlyDelegateCall
        returns (address[] memory selected, uint256[] memory targets, uint256 selCount)
    {
        if (amount < 1) return (new address[](0), new uint256[](0), 0);

        address[] memory enabledList = _enabledAdapters();
        if (enabledList.length < 1) return (new address[](0), new uint256[](0), 0);

        AdapterScore[] memory scores = _computeAdapterScores(enabledList);
        _normalizeScores(scores);
        _sortAdapterScores(scores);

        return _buildAllocationPlan(scores, amount, bestEffort);
    }

    // ── Internal scoring helpers ─────────────────────────────────────────────

    function _computeAdapterScores(address[] memory enabledAdapters)
        internal
        view
        returns (AdapterScore[] memory)
    {
        uint256 n = enabledAdapters.length;
        AdapterScore[] memory scores = new AdapterScore[](n);

        uint16 wA = wAPY;
        uint16 wL = wLiq;
        uint16 wR = wRisk;
        uint16 wS = wStability;
        uint16 wI = wIncentive;

        uint16[] memory rawAPYs = new uint16[](n);
        uint16 maxAPY = 0;
        for (uint256 i = 0; i < n;) {
            uint16 effective = 0;
            try IAdapterAPYExt(enabledAdapters[i]).effectiveAPYBps() returns (uint16 a) {
                effective = a;
            } catch {}
            if (effective > 0) {
                rawAPYs[i] = effective;
            } else {
                try ILendingAdapter(enabledAdapters[i]).currentAPYBps() returns (uint16 a) {
                    rawAPYs[i] = a;
                } catch {
                    rawAPYs[i] = 0;
                }
            }
            if (rawAPYs[i] > maxAPY) maxAPY = rawAPYs[i];
            unchecked { ++i; }
        }

        for (uint256 i = 0; i < n;) {
            scores[i] = _scoreOneAdapter(enabledAdapters[i], rawAPYs[i], maxAPY, wA, wL, wR, wS, wI);
            unchecked { ++i; }
        }
        return scores;
    }

    function _scoreOneAdapter(
        address adapter,
        uint16 rawAPY,
        uint16 maxAPY,
        uint16 wA, uint16 wL, uint16 wR, uint16 wS, uint16 wI
    ) internal view returns (AdapterScore memory) {
        uint256 apyNorm = maxAPY > 0 ? (uint256(rawAPY) * 1e4) / maxAPY : 0;
        uint16 incentive = 0;
        uint256 liq = _cachedLiq(adapter);

        uint256 riskScore = riskScoreBps[adapter];
        {
            uint32 _riskStale = riskScoreStalenessSeconds;
            uint64 _riskUpdatedTs = lastRiskScoreUpdateTs[adapter];
            if (_riskStale > 0 && _riskUpdatedTs > 0
                && block.timestamp - _riskUpdatedTs > _riskStale) {
                riskScore = 0;
            }
        }
        uint256 risk = riskScore > 0 ? (10000 - riskScore) : DEFAULT_RISK_BPS;
        uint256 confidence = _tvlConfidence(adapter);
        risk = (risk * confidence) / 1e4;

        uint256 stability = stabilityEMA[adapter];
        {
            uint32 _stabStale = stabilityEMAStalenessSeconds;
            uint64 _stabUpdatedTs = lastStabilityUpdateTs[adapter];
            if (_stabStale > 0 && _stabUpdatedTs > 0
                && block.timestamp - _stabUpdatedTs > _stabStale) {
                stability = 0;
            }
        }
        if (stability < 1) stability = DEFAULT_STABILITY_BPS;

        uint256 score = uint256(wA) * (apyNorm > 10000 ? 10000 : apyNorm)
            + uint256(wL) * (liq > 10000 ? 10000 : liq)
            + uint256(wR) * (risk > 10000 ? 10000 : risk)
            + uint256(wS) * (stability > 10000 ? 10000 : stability)
            + uint256(wI) * (incentive > 10000 ? 10000 : uint256(incentive));
        return AdapterScore(adapter, score, rawAPY, incentive, liq, risk, stability);
    }

    function _normalizeScores(AdapterScore[] memory scores) internal pure {
        uint256 len = scores.length;
        if (len < 1) return;
        uint256 sum = 0;
        for (uint256 i = 0; i < len;) {
            sum += scores[i].score;
            unchecked { ++i; }
        }
        if (sum < 1) {
            uint256 equalShare = 1e4 / len;
            for (uint256 i = 0; i < len;) {
                scores[i].score = equalShare;
                unchecked { ++i; }
            }
            return;
        }
        for (uint256 i = 0; i < len;) {
            scores[i].score = (scores[i].score * 1e4) / sum;
            unchecked { ++i; }
        }
    }

    function _sortAdapterScores(AdapterScore[] memory scores) internal pure {
        uint256 n = scores.length;
        for (uint256 i = 0; i < n;) {
            uint256 maxIdx = i;
            for (uint256 j = i + 1; j < n;) {
                if (scores[j].score > scores[maxIdx].score) maxIdx = j;
                unchecked { ++j; }
            }
            if (maxIdx != i) {
                AdapterScore memory tmp = scores[i];
                scores[i] = scores[maxIdx];
                scores[maxIdx] = tmp;
            }
            unchecked { ++i; }
        }
    }

    function _targetAllocations(AdapterScore[] memory scores, uint256 tvl)
        internal
        view
        returns (uint256[] memory)
    {
        uint256 n = scores.length;
        uint256[] memory allocs = new uint256[](n);
        uint256 totalScore = 0;
        for (uint256 i = 0; i < n;) {
            totalScore += scores[i].score;
            unchecked { ++i; }
        }
        if (totalScore < 1) return allocs;
        uint16 maxRelGov = maxRelativeExposureBps;

        // P0.7 (2026-06-11) — conditional safety margin applied ONLY when a cap
        // binds. Prevents the post-rebalance position from sitting exactly at
        // the cap, which would re-trigger the mandate as soon as the external
        // TVL fluctuated. See docs/SAFETY_ADAPTER_TIER.md.
        uint256 marginBps = uint256(targetSafetyMarginBps);
        uint256 safetyMult = 10_000 - marginBps;

        for (uint256 i = 0; i < n;) {
            address adapter = scores[i].adapter;
            // Scoring path always uses NORMAL caps. The fallback caps are
            // intentionally NOT honoured here — opportunistic allocation must
            // not target above the regular cap; only the safety-overflow path
            // can push above it.
            uint256 maxExp = (_effectiveAbsCapBps(adapter) * tvl) / 1e4;
            uint256 raw = (scores[i].score * tvl) / totalScore;
            uint256 capped = raw > maxExp ? (maxExp * safetyMult) / 10_000 : raw;

            uint256 extTVL = cachedExternalTVL[adapter];
            if (extTVL > 0) {
                uint16 dynRel = _effectiveRelativeCapBps(extTVL);
                uint16 effRel = (maxRelGov > 0 && maxRelGov < dynRel)
                    ? maxRelGov : dynRel;
                uint256 relCap = (uint256(effRel) * extTVL) / 1e4;
                if (capped > relCap) capped = (relCap * safetyMult) / 10_000;
            }

            // === PRESERVE SAFETY TRANCHE (P0.7 — the critical architectural rule)
            // For safety adapters, if the current position is between the
            // normal scoring target and the fallback ceiling, HOLD the
            // position. The overflow path is the ONLY mechanism that grows
            // the safety tranche above the normal target; the rebalance plan
            // must never unwind that legitimate tranche, otherwise the gain
            // from routing overflow to the safety adapter is immediately
            // given back at the next rebalance.
            SafetyFallback memory sf = safetyFallback[adapter];
            if (sf.absCapBps != 0) {
                uint256 current = positionAssets[adapter];
                if (current > capped) {
                    uint256 fbCeiling = (uint256(sf.absCapBps) * tvl) / 1e4;
                    if (extTVL > 0 && sf.relCapBps > 0) {
                        uint256 fbRelCeiling = (uint256(sf.relCapBps) * extTVL) / 1e4;
                        if (fbRelCeiling < fbCeiling) fbCeiling = fbRelCeiling;
                    }
                    if (current <= fbCeiling) {
                        capped = current;
                    }
                }
            }

            allocs[i] = capped;
            unchecked { ++i; }
        }
        return allocs;
    }

    // ── Allocation plan builder (no state writes, bestEffort is advisory) ────

    function _buildAllocationPlan(
        AdapterScore[] memory scores,
        uint256 amount,
        bool bestEffort
    ) internal view returns (
        address[] memory selected,
        uint256[] memory targets,
        uint256 selCount
    ) {
        uint256 tvl = _tvl();
        uint256 n = scores.length;
        uint256 _dust = dustTolerance;
        uint16 maxAdapters = _effectiveMaxAdapters();

        selected = new address[](n);
        uint256[] memory selScores = new uint256[](n);
        uint256[] memory headrooms = new uint256[](n);

        for (uint256 i = 0; i < n && selCount < maxAdapters; ++i) {
            (bool eligible, uint256 headroom) = _checkAdapterEligibility(
                scores[i].adapter, tvl, _dust, bestEffort
            );
            if (!eligible) continue;
            selected[selCount] = scores[i].adapter;
            selScores[selCount] = scores[i].score;
            headrooms[selCount] = headroom;
            selCount++;
        }

        if (selCount < 1) {
            return (selected, new uint256[](0), 0);
        }

        targets = _computeTargets(selected, selScores, headrooms, selCount, amount, _dust);
    }

    function _checkAdapterEligibility(address adapter, uint256 tvl, uint256 _dust, bool bestEffort)
        internal view returns (bool, uint256)
    {
        if (flagged[adapter]) return (false, 0);
        // P0.7 (2026-06-11) — non-safety adapters in mandate cooldown are
        // skipped for opportunistic redeploy. Safety adapters NEVER enter
        // cooldown (the mandate path doesn't set lastRelCapMandateTs for them).
        if (safetyFallback[adapter].absCapBps == 0) {
            uint32 cd = mandateRedeployCooldownSeconds;
            uint64 lastTs = lastRelCapMandateTs[adapter];
            if (cd > 0 && lastTs > 0 && block.timestamp < lastTs + cd) {
                return (false, 0);
            }
        }
        uint256 conf = _tvlConfidence(adapter);
        if (conf == CONFIDENCE_ZERO) return (false, 0);
        uint256 current = positionAssets[adapter];
        uint256 maxExp = (_effectiveAbsCapBps(adapter) * tvl) / 1e4;
        if (current >= maxExp) return (false, 0);
        uint256 headroom = maxExp - current;
        {
            uint256 extTVL = cachedExternalTVL[adapter];
            if (extTVL > 0) {
                uint16 dynRelCap = _effectiveRelativeCapBps(extTVL);
                uint16 effRelCap = (maxRelativeExposureBps > 0 && maxRelativeExposureBps < dynRelCap)
                    ? maxRelativeExposureBps : dynRelCap;
                uint256 relCap = (extTVL * effRelCap) / 1e4;
                if (current >= relCap) return (false, 0);
                uint256 rh = relCap - current;
                if (rh < headroom) headroom = rh;
            }
        }
        if (!isBootstrapActive()) {
            bool inRamp = block.timestamp < adapterActivatedAt[adapter] + newAdapterRampDuration;
            bool seasoned = isSeasoned[adapter];
            bool rampForDustNeeded = (current <= _dust) && !seasoned;
            bool isNew = (inRamp && current < _effectiveMinSeed()) || rampForDustNeeded;
            if (isNew) {
                uint256 rawLimit = (uint256(newAdapterRampBps) * tvl) / 1e4;
                if (rawLimit < headroom) headroom = rawLimit;
            }
        }
        try ILendingAdapter(adapter).maxCapacity() returns (uint256 cap) {
            if (cap == 0) { headroom = 0; }
            else if (current + headroom > cap) { headroom = cap > current ? cap - current : 0; }
            if (cap < current) { headroom = 0; }
            else if (cachedAdapterCapacity[adapter] > 0 && cap > 0
                && cachedAdapterCapacity[adapter] < type(uint256).max / MAX_EXTERNAL_TVL_JUMP_BPS) {
                uint256 maxJump = (cachedAdapterCapacity[adapter] * MAX_EXTERNAL_TVL_JUMP_BPS) / 10_000;
                if (cap > maxJump) headroom = headroom / 2;
            }
        } catch {
            if (!bestEffort) revert QueryFailed();
            return (false, 0);
        }
        if (headroom < 1) return (false, 0);
        return (true, headroom);
    }

    function _computeTargets(
        address[] memory selected,
        uint256[] memory selScores,
        uint256[] memory headrooms,
        uint256 selCount,
        uint256 amount,
        uint256 _dust
    ) internal pure returns (uint256[] memory targets) {
        targets = new uint256[](selCount);
        uint256 remaining = amount;
        bool[] memory clamped = new bool[](selCount);

        for (uint256 pass = 0; pass < 3 && remaining > _dust; ++pass) {
            uint256 sSum = 0;
            for (uint256 j = 0; j < selCount; ++j) {
                if (!clamped[j]) sSum += selScores[j];
            }
            if (sSum < 1) break;
            uint256 distributed = 0;
            for (uint256 j = 0; j < selCount; ++j) {
                if (clamped[j]) continue;
                uint256 used = targets[j];
                uint256 remainingHeadroom = headrooms[j] > used ? headrooms[j] - used : 0;
                if (remainingHeadroom == 0) { clamped[j] = true; continue; }
                uint256 target = (remaining * selScores[j]) / sSum;
                if (target > remainingHeadroom) { target = remainingHeadroom; clamped[j] = true; }
                targets[j] += target;
                distributed += target;
            }
            remaining -= distributed;
        }
    }

    // ── Inlined cap/seed helpers (mirrors ScoringModule — same storage context) ─

    function _effectiveMaxAdapters() internal view returns (uint16) {
        uint256 tvl = _tvl();
        uint16 staticMax = maxAdaptersPerAllocation;
        uint16 dynamicMax;
        if (tvl < 25_000e6) dynamicMax = 1;
        else if (tvl < 250_000e6) dynamicMax = 2;
        else if (tvl < 1_000_000e6) dynamicMax = 3;
        else if (tvl < 5_000_000e6) dynamicMax = 4;
        else dynamicMax = 5;
        return (staticMax > 0 && staticMax < dynamicMax) ? staticMax : dynamicMax;
    }

    function _effectiveAbsCapBps(address adapter) internal view returns (uint256) {
        uint16 dMax = _effectiveMaxAdapters();
        if (dMax == 0) return 0;
        if (dMax == 1) return 10000;
        uint256 cap = (11000 + uint256(dMax) - 1) / uint256(dMax);
        if (cap > 10000) cap = 10000;
        if (cap < 2500) cap = 2500;
        uint16 globalCeiling = adapterMaxExposureBps;
        if (globalCeiling > 0 && globalCeiling < cap) cap = uint256(globalCeiling);
        cap = (cap * _riskOverlay(adapter)) / 10000;
        cap = (cap * _failureOverlay(adapter)) / 10000;
        cap = (cap * _liquidityOverlay(adapter)) / 10000;
        uint16 floor = adapterAbsCapOverrideBps[adapter];
        if (floor > 0 && cap < uint256(floor)) cap = uint256(floor);
        return cap;
    }

    // S4: RISK_OVERLAY — reduces cap by riskScoreBps/2, max 50% reduction.
    // TIER_MODEL.md §4.2: multiplier = max(0, 10000 - riskScoreBps/2)
    // Stale scores (past riskScoreStalenessSeconds) treated as 0 (no penalty).
    function _riskOverlay(address adapter) internal view returns (uint16) {
        uint256 score = riskScoreBps[adapter];
        if (score == 0) return 10000;
        uint32 staleness = riskScoreStalenessSeconds;
        uint64 updatedAt = lastRiskScoreUpdateTs[adapter];
        if (staleness > 0 && updatedAt > 0 && block.timestamp - updatedAt > staleness) return 10000;
        uint256 penalty = score / 2;
        return penalty >= 10000 ? 0 : uint16(10000 - penalty);
    }

    // S3: FAILURE_OVERLAY — reduces cap by 15% per consecutive failure, floors at 0.
    // Uses adapterConsecutiveFailures (auto-reset by AdapterOpsModule after failureDecaySeconds).
    // TIER_MODEL.md §4.3: multiplier = max(0, 10000 - failures × 1500)
    function _failureOverlay(address adapter) internal view returns (uint16) {
        uint256 failures = adapterConsecutiveFailures[adapter];
        if (failures == 0) return 10000;
        uint256 penalty = failures * 1500;
        return penalty >= 10000 ? 0 : uint16(10000 - penalty);
    }

    // S5: LIQUIDITY_OVERLAY — tiered cap reduction based on withdrawable liquidity ratio.
    // TIER_MODEL.md §4.4: ≥8000→10000, 5000-7999→9000, 2500-4999→7500, <2500→6000
    function _liquidityOverlay(address adapter) internal view returns (uint16) {
        uint256 liq = _cachedLiq(adapter);
        if (liq >= 8000) return 10000;
        if (liq >= 5000) return 9000;
        if (liq >= 2500) return 7500;
        return 6000;
    }

    function _effectiveMinSeed() internal view returns (uint256) {
        uint256 tvl = _tvl();
        uint256 staticSeed = minNewAdapterSeed;
        uint256 dynamicSeed;
        if (tvl < 250_000e6) dynamicSeed = 100e6;
        else if (tvl < 1_000_000e6) dynamicSeed = 1_000e6;
        else if (tvl < 5_000_000e6) dynamicSeed = 5_000e6;
        else if (tvl < 25_000_000e6) dynamicSeed = 25_000e6;
        else dynamicSeed = (tvl * 200) / 1e4;
        return staticSeed > dynamicSeed ? staticSeed : dynamicSeed;
    }

    // ── Liquidity cache helper ───────────────────────────────────────────────

    function _cachedLiq(address adapter) internal view returns (uint256) {
        uint16 cached = cachedLiquidityBps[adapter];
        if (cached == 0) return DEFAULT_LIQ_BPS;
        uint32 _staleness = liquidityStalenessSeconds;
        if (_staleness > 0 && cachedLiquidityTs[adapter] > 0
            && block.timestamp - cachedLiquidityTs[adapter] > _staleness) {
            return DEFAULT_LIQ_BPS;
        }
        return uint256(cached);
    }

    function isBootstrapActive() public view returns (bool) {
        return bootstrapEndsAt > 0 && block.timestamp < bootstrapEndsAt;
    }

    function idleCash() public view returns (uint256) {
        return ASSET.balanceOf(address(this));
    }
}
