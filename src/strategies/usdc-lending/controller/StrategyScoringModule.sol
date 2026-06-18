// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ═══════════════════════════════════════════════════════════════════════════════
// StrategyScoringModule — delegatecall module for scoring & allocation logic
// ═══════════════════════════════════════════════════════════════════════════════
// Extracted from UsdcLendingStrategy.sol. All functions operate on the
// strategy's storage via delegatecall. Direct calls are forbidden.
// ═══════════════════════════════════════════════════════════════════════════════

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    StrategyStorageLayout,
    AdapterScore,
    RebalanceCooldown,
    InsufficientAdapters,
    MoveTooSmall,
    GateNotMet,
    AdapterFlaggedIncrement,
    NoCashInvariant,
    DepositsDisabled,
    DeployIdleCooldown,
    Overflow,
    QueryFailed,
    DepositModeNotSet,
    PlanAlreadyActive,
    NoPlanActive,
    PlanExpired,
    PlanInvalidated,
    TooManyAdapters,
    DegradedViews
} from "./StrategyStorageLayout.sol";
import { ILendingAdapter } from "../interfaces/ILendingAdapter.sol";

// FIX P0.L3 (quant audit): interfaccia opzionale per adapter multi-market
// che espongono TVL-weighted APY. Single-market adapter (Aave V3, Fluid, Venus)
// non implementano questo selector → try/catch in scorer fa fallback a currentAPYBps.
interface IAdapterAPYExt {
    function effectiveAPYBps() external view returns (uint16);
}

contract StrategyScoringModule is StrategyStorageLayout {
    using SafeERC20 for IERC20Metadata;

    // ── Delegatecall-only guard ──────────────────────────────────────────────

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

    // Degraded-views guard for keeper-callable ops (audit HIGH 2.2 — promote from
    // deposit-only to all operating paths: harvest, prepareRebalance, deployIdle).
    // When fallback totals (adapters whose totalAssets() reverts) exceed the
    // configured threshold, block the op to avoid allocating on stale accounting.
    function _degradedGuard() internal view {
        uint256 n = adapters.length;
        uint256 healthyAssets;
        uint256 fallbackAssets;
        for (uint256 i = 0; i < n; ++i) {
            address a = adapters[i];
            if (!enabled[a] || quarantined[a]) continue;
            try ILendingAdapter(a).totalAssets() returns (uint256 val) {
                healthyAssets += val;
            } catch {
                fallbackAssets += positionAssets[a];
            }
        }
        uint256 total = healthyAssets + fallbackAssets;
        if (total == 0) return;
        uint256 bps = (fallbackAssets * 1e4) / total;
        if (bps > degradedViewThresholdBps) revert DegradedViews();
    }

    // ── External functions ───────────────────────────────────────────────────

    // ─────────────────────────────────────────────────────────────────────────
    // Rebalance plan lifecycle EXTRACTED (2026-04-22) to StrategyRebalancePlanModule
    // for EIP-170 compliance. The plan module calls back into this module via
    // `computeInputsForPlan()` + `deployIdleToAdapters(...)` externals.
    // See StrategyRebalancePlanModule.sol for the full implementation.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Single-call rebalance plan inputs producer.
    /// @dev    Called by StrategyRebalancePlanModule via delegatecall. Performs:
    ///           1. degraded-views guard (reverts if threshold exceeded)
    ///           2. forced position sync
    ///           3. enabled adapters list
    ///           4. scoring pipeline: compute → normalize → target allocs
    ///           5. aggregate APYs + normalized scores + moved
    ///         The plan module consumes these, runs gate check and builds actions.
    function computeInputsForPlan() external onlyDelegateCall returns (
        address[] memory enabledList,
        uint256[] memory targetAllocs,
        uint256[] memory normScores,
        uint16[]  memory apys,
        uint256 tvl,
        uint256 moved
    ) {
        _degradedGuard();
        _syncPositionAssets(true);

        enabledList = _enabledAdapters();
        if (enabledList.length == 0) {
            return (enabledList, new uint256[](0), new uint256[](0), new uint16[](0), 0, 0);
        }
        tvl = _tvl();
        AdapterScore[] memory scores = _computeAdapterScores(enabledList);
        _normalizeScores(scores);
        targetAllocs = _targetAllocations(scores, tvl);

        // Stack relief: the apys / normScores / moved aggregation is split into
        // an internal helper so the Yul stack frame of computeInputsForPlan stays
        // shallow enough for solc. (EIP-170 refactor 2026-04-22.)
        (apys, normScores, moved) =
            _aggregatePlanInputs(scores, enabledList, targetAllocs);
    }

    /// @notice Deploy idle USDC to adapters (keeper-callable, short cooldown).
    /// @dev    Skips if idle < idleDeployThreshold (max(dustTolerance, TVL * 5 bps)).
    function deployIdle() external nonReentrant onlyRoleOrRevert(KEEPER_ROLE) whenNotPaused onlyDelegateCall {
        if (depositsDisabled) revert DepositsDisabled();
        _degradedGuard();
        if (block.timestamp - lastDeployIdleTs < minSecondsBetweenDeployIdle) {
            revert DeployIdleCooldown();
        }
        uint256 idle = idleCash();
        uint256 threshold = _idleDeployThreshold(); // snapshot — not recalculated after sync
        if (idle <= threshold) return;
        // V9.1 CTO: conditional sync before allocation (respects cooldown)
        _syncPositionAssets(false);
        _deployIdleToAdapters(idle, true);
        lastDeployIdleTs = uint64(block.timestamp);
        uint256 remainingIdle = idleCash();

        // V9.1 CTO: self-healing retry — if caps were stale, sync + retry once.
        // Audit MEDIUM 1.2 — emit RetryModeSet observability events on each edge.
        if (remainingIdle > threshold && remainingIdle > 1e6 && gasleft() > 500_000) {
            emit IdleCapExhausted(remainingIdle, threshold);
            _syncPositionAssets(true);
            _retryMode = true;
            emit RetryModeSet(true);
            _deployIdleToAdapters(remainingIdle, true);
            _retryMode = false;
            emit RetryModeSet(false);
            remainingIdle = idleCash();
        }

        if (remainingIdle > threshold) {
            emit IdleCashRemaining(remainingIdle, threshold);
        }
        emit DeployIdleExecuted(idle - remainingIdle, remainingIdle);
        _retryMode = false; // defensive reset — always clean at end
    }

    /// @notice Deploy idle to adapters — external entry point for delegatecall from strategy.
    /// @dev    Was _deployIdleToAdapters(uint256, bool) internal in UsdcLendingStrategy.
    ///         Made external with onlyDelegateCall for module extraction.
    function deployIdleToAdapters(uint256 amount, bool bestEffort) external onlyDelegateCall {
        _deployIdleToAdapters(amount, bestEffort);
    }

    // canRebalance() moved to StrategyRebalanceGateModule (V10 extraction)

    /// @notice Compute rebalance scoring inputs for the GateModule.
    /// @dev    Called by GateModule via delegatecall. Returns packed data for gate decision.
    function computeRebalanceInputs()
        external
        onlyDelegateCall
        returns (
            uint16[] memory apyBpsArray,
            address[] memory enabledAdapters,
            uint256[] memory targetAllocs,
            uint256 tvl,
            uint256 moved
        )
    {
        enabledAdapters = _enabledAdapters();
        if (enabledAdapters.length < minAdaptersActive) {
            return (new uint16[](0), enabledAdapters, new uint256[](0), 0, 0);
        }
        tvl = _tvl();
        AdapterScore[] memory scores = _computeAdapterScores(enabledAdapters);
        _normalizeScores(scores);
        targetAllocs = _targetAllocations(scores, tvl);

        uint256 len = enabledAdapters.length;
        apyBpsArray = new uint16[](len);
        for (uint256 i; i < len;) {
            apyBpsArray[i] = uint16(scores[i].apyBps);
            uint256 curr = positionAssets[enabledAdapters[i]];
            uint256 tgt = targetAllocs[i];
            moved += curr > tgt ? curr - tgt : tgt - curr;
            unchecked { ++i; }
        }
    }

    /// @notice Dynamic seed: scales with TVL to prevent starvation at low TVL and over-seeding at high TVL.
    /// @dev Uses discrete bands per CTO directive. Falls back to static minNewAdapterSeed if set.
    // DESIGN: QUANT MODEL — see docs/TIER_MODEL.md Section 5.
    // WHY: old seeds (10K-50K) were > min deposit cap (100 USDC) at T1/T2, making
    //      always-deploy impossible at low TVL (AUDIT-FINDING-2). New T1+T2 = 100 USDC.
    function effectiveMinNewAdapterSeed() external view onlyDelegateCall returns (uint256) {
        return _minSeedInternal();
    }

    function _minSeedInternal() internal view returns (uint256) {
        uint256 tvl = _tvl();
        uint256 staticSeed = minNewAdapterSeed;
        uint256 dynamicSeed;
        if (tvl < 250_000e6) dynamicSeed = 100e6;           // T1+T2: 100 USDC (= min deposit)
        else if (tvl < 1_000_000e6) dynamicSeed = 1_000e6;  // T3: 1K USDC
        else if (tvl < 5_000_000e6) dynamicSeed = 5_000e6;  // T4: 5K USDC
        else if (tvl < 25_000_000e6) dynamicSeed = 25_000e6; // T5: 25K USDC
        else dynamicSeed = (tvl * 200) / 1e4;                // T_overflow: 2% TVL
        return staticSeed > dynamicSeed ? staticSeed : dynamicSeed;
    }

    /// @notice Dynamic max adapters per allocation — scales with TVL.
    /// @dev Low TVL = fewer adapters (capital efficiency), high TVL = more (diversification).
    ///      staticMax (maxAdaptersPerAllocation) acts as manual override if set lower.
    // DESIGN: QUANT MODEL — see docs/TIER_MODEL.md Section 3.
    // WHAT: tier bands updated to ensure T3 (3 adapters) triggers at 250K, not 650K.
    // WHY: at 100K-250K TVL, dynamicMax=2 structurally excludes a 3rd adapter (AUDIT-FINDING-1).
    // WHAT COULD BREAK: tests asserting old thresholds (150K→2, 650K→3). PROMPT 3 fixes cascade.
    // VERIFY: sum(effectiveAbsCapBps) >= 110% TVL at each tier (STRUCTURAL_BASE invariant).
    function effectiveMaxAdaptersPerAllocation() public view onlyDelegateCall returns (uint16) {
        uint256 tvl = _tvl();
        uint16 staticMax = maxAdaptersPerAllocation;
        uint16 dynamicMax;
        if (tvl < 25_000e6) dynamicMax = 1;              // T1 single:  < 25K
        else if (tvl < 250_000e6) dynamicMax = 2;        // T2 dual:    25K - 250K
        else if (tvl < 1_000_000e6) dynamicMax = 3;      // T3 triple:  250K - 1M
        else if (tvl < 5_000_000e6) dynamicMax = 4;      // T4 quad:    1M - 5M
        else dynamicMax = 5;                              // T5 max:     5M+
        return (staticMax > 0 && staticMax < dynamicMax) ? staticMax : dynamicMax;
    }

    /// @notice Adaptive per-adapter cap (docs/TIER_MODEL.md Section 4).
    ///         Phase 1: STRUCTURAL_BASE + governance ceiling active. Overlays are no-op placeholders.
    function effectiveAbsCapBps(address adapter) public view onlyDelegateCall returns (uint16) {
        uint16 dMax = effectiveMaxAdaptersPerAllocation();
        if (dMax == 0) return 0;
        // T1: single-adapter mode = intentional 100% concentration by design.
        // Global ceiling does not apply — there is no diversification choice to constrain.
        if (dMax == 1) return 10000;
        // Layer 1: STRUCTURAL_BASE — ceil(11000 / dMax), floor 2500, ceiling 10000
        uint256 cap = (11000 + uint256(dMax) - 1) / uint256(dMax);
        if (cap > 10000) cap = 10000;
        if (cap < 2500) cap = 2500;
        // AUDIT-FINDING-6 fix: adapterMaxExposureBps is a GLOBAL GOVERNANCE CEILING.
        // It can only tighten caps below structural (emergency conservatism lever).
        // A value of 0 means unconstrained (use structural only).
        uint16 globalCeiling = adapterMaxExposureBps;
        if (globalCeiling > 0 && globalCeiling < cap) cap = uint256(globalCeiling);
        // Layers 2-4: Phase 1 no-op (returns 10000 each)
        cap = (cap * _riskOverlay(adapter)) / 10000;
        cap = (cap * _failureOverlay(adapter)) / 10000;
        cap = (cap * _liquidityOverlay(adapter)) / 10000;
        // Per-adapter floor override — can raise above structural for specific partnerships.
        // If floor > ceiling, floor wins (per-adapter override takes precedence).
        uint16 floor = adapterAbsCapOverrideBps[adapter];
        if (floor > 0 && cap < uint256(floor)) cap = uint256(floor);
        return uint16(cap);
    }

    // A-F-13 fix: activate overlays — mirrors StrategyAllocCalcModule._riskOverlay/
    // _failureOverlay/_liquidityOverlay exactly. Parity enforced by Overlay_Parity.t.sol.
    function _riskOverlay(address adapter) internal view returns (uint16) {
        uint256 score = riskScoreBps[adapter];
        if (score == 0) return 10000;
        uint32 staleness = riskScoreStalenessSeconds;
        uint64 updatedAt = lastRiskScoreUpdateTs[adapter];
        if (staleness > 0 && updatedAt > 0 && block.timestamp - updatedAt > staleness) return 10000;
        uint256 penalty = score / 2;
        return penalty >= 10000 ? 0 : uint16(10000 - penalty);
    }

    function _failureOverlay(address adapter) internal view returns (uint16) {
        uint256 failures = adapterConsecutiveFailures[adapter];
        if (failures == 0) return 10000;
        uint256 penalty = failures * 1500;
        return penalty >= 10000 ? 0 : uint16(10000 - penalty);
    }

    function _liquidityOverlay(address adapter) internal view returns (uint16) {
        uint256 liq = _cachedLiq(adapter);
        if (liq >= 8000) return 10000;
        if (liq >= 5000) return 9000;
        if (liq >= 2500) return 7500;
        return 6000;
    }

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

    // ── DegradedMode detection (Phase 1 — MAJORITY_INELIGIBLE + FAILURE_VELOCITY) ─

    uint16 internal constant MIN_LIQ_BPS_FOR_ELIGIBILITY = 100;
    uint64 internal constant FAILURE_VELOCITY_WINDOW = 1 hours;
    uint16 internal constant FAILURE_VELOCITY_THRESHOLD = 2;

    /// @notice Count adapters that are enabled, not quarantined, and minimally liquid.
    /// @dev    Uses cachedLiquidityBps (poked by keeper) — stale = conservative (under-counts eligible).
    function _countEligibleAdapters() internal view returns (uint16 count) {
        address[] memory enabledList = _enabledAdapters();
        for (uint256 i = 0; i < enabledList.length; ) {
            address a = enabledList[i];
            if (!quarantined[a] && cachedLiquidityBps[a] >= MIN_LIQ_BPS_FOR_ELIGIBILITY) {
                unchecked { ++count; }
            }
            unchecked { ++i; }
        }
    }

    /// @notice Three-trigger degraded mode check per docs/TIER_MODEL.md Section 7.
    /// @dev    Triggers: MAJORITY_INELIGIBLE, FAILURE_VELOCITY, EXT_TVL_PANIC (Phase 1.5).
    function _isDegradedMode() internal view returns (bool, string memory) {
        address[] memory enabledList = _enabledAdapters();
        uint16 enabledCount = uint16(enabledList.length);
        if (enabledCount == 0) return (false, "");

        uint16 eligibleCount = _countEligibleAdapters();
        if (eligibleCount * 2 < enabledCount) {
            return (true, "MAJORITY_INELIGIBLE");
        }

        uint16 recentFailures = 0;
        for (uint256 i = 0; i < enabledList.length; ) {
                uint64 lastFail = adapterLastFailureTs[enabledList[i]];
            if (lastFail > 0 && block.timestamp - lastFail < FAILURE_VELOCITY_WINDOW) {
                unchecked { ++recentFailures; }
            }
            unchecked { ++i; }
        }
        if (recentFailures >= FAILURE_VELOCITY_THRESHOLD) {
            return (true, "FAILURE_VELOCITY");
        }
        // Trigger 3: EXT_TVL_PANIC — 30% drop in external TVL within 1-hour window.
        for (uint256 i = 0; i < enabledList.length; ) {
                address a = enabledList[i];
                uint256 snapshot = lastExtTVLSnapshot[a];
            uint256 current  = cachedExternalTVL[a];
            if (snapshot > 0 && current < snapshot) {
                uint256 dropBps = ((snapshot - current) * 10_000) / snapshot;
                if (dropBps >= EXT_TVL_PANIC_DROP_BPS) {
                    return (true, "EXT_TVL_PANIC");
                }
            }
            unchecked { ++i; }
        }
        return (false, "");
    }

    // ── Public view functions ────────────────────────────────────────────────

    /// @notice Exposes _isDegradedMode for keepers and tests. Called via delegatecall from vault.
    function checkDegradedMode() external view onlyDelegateCall returns (bool, string memory) {
        return _isDegradedMode();
    }

    function isBootstrapActive() public view returns (bool) {
        return bootstrapEndsAt > 0 && block.timestamp < bootstrapEndsAt;
    }

    /// @notice Advisory lock period: 7× base when degraded mode active.
    /// @dev    Does NOT enforce CoreVault lockPeriod automatically — governance must act on signal.
    ///         Returns withdrawalLockSeconds * 7 in degraded mode, withdrawalLockSeconds otherwise.
    ///         If withdrawalLockSeconds == 0 (not yet set), returns 0 (advisory only).
    function effectiveWithdrawalLockSeconds() public view onlyDelegateCall returns (uint64) {
        uint64 base = withdrawalLockSeconds;
        if (degradedModeActive) return base * 7;
        return base;
    }

    /// @notice Threshold below which deployIdle skips (not worth the gas).
    function idleDeployThreshold() public view returns (uint256) {
        return _idleDeployThreshold();
    }

    /// @notice Returns current idle USDC (not deployed).
    function idleCash() public view returns (uint256) {
        return ASSET.balanceOf(address(this));
    }

    // ── Internal functions ───────────────────────────────────────────────────

    // ── AllocCalc delegatecall selectors ────────────────────────────────────

    bytes4 private constant EXEC_SELECT_ALLOC_SEL =
        bytes4(keccak256("execSelectAllocation(uint256,bool)"));
    bytes4 private constant EXEC_COMPUTE_SCORES_SEL =
        bytes4(keccak256("execComputeScores(address[])"));
    bytes4 private constant EXEC_NORMALIZE_SEL =
        bytes4(keccak256("execNormalizeScores((address,uint256,uint256,uint256,uint256,uint256,uint256)[])"));
    bytes4 private constant EXEC_TARGET_ALLOCS_SEL =
        bytes4(keccak256("execTargetAllocations((address,uint256,uint256,uint256,uint256,uint256,uint256)[],uint256)"));
    bytes4 private constant EXEC_AGGREGATE_SEL =
        bytes4(keccak256("execAggregatePlanInputs((address,uint256,uint256,uint256,uint256,uint256,uint256)[],address[],uint256[])"));

    // ── AdapterOps delegatecall selectors ──────────────────────────────────

    bytes4 private constant SAFE_DEPOSIT_SEL = bytes4(keccak256("safeAdapterDeposit(address,uint256)"));
    bytes4 private constant ADAPTER_DEPOSIT_SEL = bytes4(keccak256("adapterDeposit(address,uint256)"));
    bytes4 private constant RECORD_FAILURE_SEL = bytes4(keccak256("recordAdapterFailure(address)"));
    bytes4 private constant RECORD_SUCCESS_SEL = bytes4(keccak256("recordAdapterSuccess(address)"));

    function _deployIdleToAdapters(uint256 amount, bool bestEffort) internal {
        if (amount < 1) return;
        address ac = allocCalcModule_addr;
        require(ac != address(0), "alloc-calc-not-set");
        (bool ok, bytes memory res) = ac.delegatecall(
            abi.encodeWithSelector(EXEC_SELECT_ALLOC_SEL, amount, bestEffort)
        );
        if (!ok) {
            if (res.length > 0) { assembly { revert(add(res, 32), mload(res)) } }
            revert();
        }
        (address[] memory selected, uint256[] memory targets, uint256 selCount) =
            abi.decode(res, (address[], uint256[], uint256));

        // Emit observability events for adapters skipped due to low confidence.
        // AllocCalcModule is view-only; ScoringModule emits on its behalf.
        _emitLowConfidenceSkips(selected, selCount);

        uint256 _minSeed = _minSeedInternal();
        for (uint256 j = 0; j < selCount; ++j) {
            if (targets[j] == 0) continue;
            address a = selected[j];
            if (bestEffort) {
                uint256 idleBefore = ASSET.balanceOf(address(this));
                bool deposited = _safeAdapterDeposit(a, targets[j]);
                if (deposited) {
                    uint256 actualDeposited = idleBefore - ASSET.balanceOf(address(this));
                    positionAssets[a] += actualDeposited;
                    if (actualDeposited < targets[j]) {
                        emit DeployIdleDepositPartial(a, targets[j], actualDeposited);
                    }
                }
            } else {
                uint256 idleBefore = ASSET.balanceOf(address(this));
                _adapterDeposit(a, targets[j]);
                uint256 actualDeposited = idleBefore - ASSET.balanceOf(address(this));
                positionAssets[a] += actualDeposited;
                if (actualDeposited < targets[j]) {
                    emit DeployIdleDepositPartial(a, targets[j], actualDeposited);
                }
            }
            if (!isSeasoned[a] && positionAssets[a] > _minSeed) {
                isSeasoned[a] = true;
                emit AdapterSeasoned(a, positionAssets[a]);
            }
        }

        // === SAFETY OVERFLOW (P0.7 — 2026-06-11) ===========================
        // After the normal allocator plan completes, if idle still exceeds
        // maxIdleBps × tvl, route the excess to the governance-approved
        // safety adapters using their elevated fallback caps. This is the
        // ONLY path that can push a safety adapter above its normal cap.
        // No-op when maxIdleBps == 0 OR safetyFallbackAdapters is empty.
        _executeSafetyOverflow();
    }

    /// @notice Route excess idle into ordered safety-fallback adapters.
    /// @dev    Best-effort: each deposit goes through _safeAdapterDeposit
    ///         (catches adapter failures, does not revert the deploy). The
    ///         overflow respects fallbackAbsCap and fallbackRelCap PER ADAPTER
    ///         — never the normal abs/rel cap, which would defeat the purpose.
    ///         Skips safety adapters that are disabled, flagged, quarantined,
    ///         or whose extTVL is below 500K (MICRO band). Safety adapters do
    ///         NOT honour mandate cooldown because by construction they are
    ///         exempt from the cooldown set.
    function _executeSafetyOverflow() internal {
        uint16 maxIdleBpsLocal = maxIdleBps;
        if (maxIdleBpsLocal == 0) return;
        uint256 nSafety = safetyFallbackAdapters.length;
        if (nSafety == 0) return;

        uint256 tvl = _tvl();
        if (tvl < 1) return;
        uint256 maxIdleAmt = (tvl * uint256(maxIdleBpsLocal)) / 1e4;
        uint256 idleBalance = ASSET.balanceOf(address(this));
        if (idleBalance <= maxIdleAmt) return;
        uint256 remaining = idleBalance - maxIdleAmt;
        uint256 _dust = dustTolerance;

        for (uint256 i = 0; i < nSafety && remaining > _dust;) {
            address a = safetyFallbackAdapters[i];
            unchecked { ++i; }

            // Eligibility gates — order chosen for cheapest-first short-circuit.
            if (!enabled[a]) continue;
            if (flagged[a]) continue;
            if (quarantined[a]) continue;

            // Pool depth gate — refuse to park into adapters below MICRO band
            // (500K USDC extTVL), where a $1M deposit would distort the rate
            // and breach the "safety venue must be deep" precondition.
            uint256 extTVL = cachedExternalTVL[a];
            if (extTVL < 500_000e6) continue;

            // Fallback caps (governance-approved second tier).
            SafetyFallback memory sf = safetyFallback[a];
            if (sf.absCapBps == 0) continue; // belt-and-braces: not a safety adapter
            uint256 fbCeiling = (uint256(sf.absCapBps) * tvl) / 1e4;
            if (sf.relCapBps > 0) {
                uint256 fbRelCeiling = (uint256(sf.relCapBps) * extTVL) / 1e4;
                if (fbRelCeiling < fbCeiling) fbCeiling = fbRelCeiling;
            }

            uint256 current = positionAssets[a];
            if (current >= fbCeiling) continue;
            uint256 room = fbCeiling - current;
            uint256 toDeposit = remaining < room ? remaining : room;
            if (toDeposit < _dust) continue;

            uint256 idleBefore = ASSET.balanceOf(address(this));
            bool ok = _safeAdapterDeposit(a, toDeposit);
            if (!ok) continue;
            uint256 idleAfter = ASSET.balanceOf(address(this));
            uint256 actualDeposited = idleBefore - idleAfter;
            positionAssets[a] = current + actualDeposited;
            remaining -= actualDeposited;
            emit SafetyOverflowDeployed(a, toDeposit, idleBefore, idleAfter);
        }
    }

    // Emits AdapterSkippedLowConfidence for enabled adapters excluded from the plan
    // due to CONFIDENCE_ZERO. AllocCalcModule is view-only and cannot emit events.
    function _emitLowConfidenceSkips(address[] memory selected, uint256 selCount) internal {
        address[] memory enabledList = _enabledAdapters();
        for (uint256 i = 0; i < enabledList.length;) {
            address a = enabledList[i];
            bool inPlan = false;
            for (uint256 j = 0; j < selCount;) {
                if (selected[j] == a) { inPlan = true; break; }
                unchecked { ++j; }
            }
            if (!inPlan && _tvlConfidence(a) == CONFIDENCE_ZERO) {
                uint256 extTVL = cachedExternalTVL[a];
                emit AdapterSkippedLowConfidence(a, extTVL, CONFIDENCE_ZERO);
            }
            unchecked { ++i; }
        }
    }

    function _computeAdapterScores(address[] memory enabledAdapters)
        internal
        returns (AdapterScore[] memory)
    {
        address ac = allocCalcModule_addr;
        require(ac != address(0), "alloc-calc-not-set");
        (bool ok, bytes memory res) = ac.delegatecall(
            abi.encodeWithSelector(EXEC_COMPUTE_SCORES_SEL, enabledAdapters)
        );
        require(ok, "AllocCalc: computeScores");
        return abi.decode(res, (AdapterScore[]));
    }

    function _normalizeScores(AdapterScore[] memory scores) internal {
        address ac = allocCalcModule_addr;
        require(ac != address(0), "alloc-calc-not-set");
        (bool ok, bytes memory res) = ac.delegatecall(
            abi.encodeWithSelector(EXEC_NORMALIZE_SEL, scores)
        );
        require(ok, "AllocCalc: normalize");
        AdapterScore[] memory normalized = abi.decode(res, (AdapterScore[]));
        uint256 len = scores.length;
        for (uint256 i = 0; i < len;) {
            scores[i].score = normalized[i].score;
            unchecked { ++i; }
        }
    }

    function _targetAllocations(AdapterScore[] memory scores, uint256 tvl)
        internal
        returns (uint256[] memory)
    {
        address ac = allocCalcModule_addr;
        require(ac != address(0), "alloc-calc-not-set");
        (bool ok, bytes memory res) = ac.delegatecall(
            abi.encodeWithSelector(EXEC_TARGET_ALLOCS_SEL, scores, tvl)
        );
        require(ok, "AllocCalc: targetAllocs");
        return abi.decode(res, (uint256[]));
    }

    function _aggregatePlanInputs(
        AdapterScore[] memory scores,
        address[] memory enabledList,
        uint256[] memory targetAllocs
    ) internal returns (
        uint16[]  memory apys,
        uint256[] memory normScores,
        uint256 moved
    ) {
        address ac = allocCalcModule_addr;
        require(ac != address(0), "alloc-calc-not-set");
        (bool ok, bytes memory res) = ac.delegatecall(
            abi.encodeWithSelector(EXEC_AGGREGATE_SEL, scores, enabledList, targetAllocs)
        );
        require(ok, "AllocCalc: aggregate");
        return abi.decode(res, (uint16[], uint256[], uint256));
    }

    function _safeAdapterDeposit(address adapter, uint256 amount) internal returns (bool) {
        if (amount == 0) return true;
        (bool ok, bytes memory res) = adapterOpsModule.delegatecall(
            abi.encodeWithSelector(SAFE_DEPOSIT_SEL, adapter, amount)
        );
        if (!ok) return false;
        if (res.length == 0) return ok;
        return abi.decode(res, (bool));
    }

    function _adapterDeposit(address adapter, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory res) = adapterOpsModule.delegatecall(
            abi.encodeWithSelector(ADAPTER_DEPOSIT_SEL, adapter, amount)
        );
        if (!ok) {
            if (res.length > 0) { assembly { revert(add(res, 32), mload(res)) } }
            revert DepositModeNotSet();
        }
    }

    function _recordAdapterFailure(address adapter) internal {
        (bool ok,) = adapterOpsModule.delegatecall(
            abi.encodeWithSelector(RECORD_FAILURE_SEL, adapter)
        );
        require(ok, "AdapterOps call failed");
    }

    function _recordAdapterSuccess(address adapter) internal {
        (bool ok,) = adapterOpsModule.delegatecall(
            abi.encodeWithSelector(RECORD_SUCCESS_SEL, adapter)
        );
        require(ok, "AdapterOps call failed");
    }

    /// @dev Idle deploy threshold: max(dustTolerance, TVL * 5 bps). Cap at 50K USDC.
    function _idleDeployThreshold() internal view returns (uint256) {
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
        uint256 tvlBased = (_tvl() * 5) / 1e4;
        uint256 maxCap = 50_000e6;
        if (tvlBased > maxCap) tvlBased = maxCap;
        return tvlBased > _dust ? tvlBased : _dust;
    }

    /// @dev Sync positionAssets from live adapter balances. Co-located with capital operations.
    ///      force=true: bypass cooldown (rebalance). force=false: respect cooldown (deployIdle).
    ///      Guards: skip zero-on-nonzero, skip >3x jump, skip if drift < dust.
    ///      DOS-safe: _safeTotalAssets uses staticcall + fallback → bricked adapter = no change.
    function _syncPositionAssets(bool force) internal {
        // FAST PATH: cooldown check (single SLOAD, no external calls)
        if (!force && lastSyncTs != 0
            && block.timestamp < uint256(lastSyncTs) + minSecondsBetweenSync) return;

        address[] storage _adapters = adapters;
        uint256 n = _adapters.length;
        uint256 totalDrift = 0;
        bool hasNegative = false;
        uint256 _dust = dustTolerance;

        for (uint256 i = 0; i < n;) {
            address adapter = _adapters[i];
            // Sync enabled OR disabled-with-funds (drift can hide in disabled adapters)
            if (enabled[adapter] || positionAssets[adapter] > 0) {
                uint256 oldPos = positionAssets[adapter];
                uint256 actual = _safeTotalAssets(adapter);

                // Guard: skip if adapter returns 0 but had funds (bricked/reverted fallback)
                if (actual == 0 && oldPos > 0) {
                    emit PositionSyncSkippedSuspicious(adapter, oldPos, actual);
                    unchecked { ++i; }
                    continue;
                }
                // Guard: skip if >3x jump (suspicious manipulation)
                if (oldPos > 0 && actual > oldPos * 3) {
                    emit PositionSyncSkippedSuspicious(adapter, oldPos, actual);
                    unchecked { ++i; }
                    continue;
                }

                uint256 diff = actual > oldPos ? actual - oldPos : oldPos - actual;
                if (actual < oldPos) hasNegative = true;
                unchecked { totalDrift += diff; }

                // Skip SSTORE if drift < dustTolerance
                if (diff >= _dust) {
                    positionAssets[adapter] = actual;
                    emit PositionAssetsSynced(adapter, oldPos, actual);
                }
            }
            unchecked { ++i; }
        }

        lastSyncTs = uint64(block.timestamp);
        if (totalDrift > 0) emit DriftMeasured(totalDrift, hasNegative);

        // V9.1 CTO: check liquidity cache staleness — emit events for monitoring
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

    // _enabledAdapters, _tvl — inherited from StrategyStorageLayout.

}
