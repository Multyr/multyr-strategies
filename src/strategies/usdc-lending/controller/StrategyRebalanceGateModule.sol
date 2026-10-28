// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    StrategyStorageLayout,
    Overflow,
    GateNotMet
} from "./StrategyStorageLayout.sol";
import {ReadOnlyGasEstimator as GasEstimator} from "../gas/ReadOnlyGasEstimator.sol";
import {ILendingAdapter} from "../interfaces/ILendingAdapter.sol";
import { StrategyConfigLib } from "../lib/StrategyConfigLib.sol";

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title StrategyRebalanceGateModule — Rebalance policy/gating logic
/// @notice Delegatecall module. Decides IF a rebalance should proceed based on:
///         P0: Dynamic execution cost (EMA-based)
///         P1: Hysteresis (benefit/cost ratio, entry/exit drift, min move)
///         P2: Coordination (recent rebalance penalty, liquidity readiness)
///         P3: Regime (STABLE/VOLATILE/STRESS horizon+confidence adjustments)
/// @dev    Calls ScoringModule.computeRebalanceInputs() via delegatecall to
///         scoringModule address (NOT via fallback — direct module call).
///         All functions require onlyDelegateCall guard.
contract StrategyRebalanceGateModule is StrategyStorageLayout {

    // ── Delegatecall-only guard ──────────────────────────────────────────
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

    // ── Selector for ScoringModule.computeRebalanceInputs() ─────────────
    bytes4 private constant COMPUTE_INPUTS_SEL =
        bytes4(keccak256("computeRebalanceInputs()"));

    // ── External functions ──────────────────────────────────────────────

    /// @notice Check if rebalance is warranted. NOT view (uses delegatecall to ScoringModule).
    /// @dev    Replaces the old ScoringModule.canRebalance().
    ///         Called by LendingStrategyUpkeep via strategy fallback routing.
    function canRebalance()
        external
        onlyDelegateCall
        returns (bool ok, uint256 movedEstimateUSDC, int256 netBenefitBps)
    {
        // Pre-checks (same as old canRebalance)
        if (rebalancePlanPhase != 0) return (false, 0, 0);
        uint256 cooldown = minSecondsBetweenRebalances;
        if (rebalancePlanBackoffThreshold > 0 && rebalancePlanConsecutiveFailures > rebalancePlanBackoffThreshold)
            cooldown *= rebalancePlanConsecutiveFailures - rebalancePlanBackoffThreshold >= 2 ? 4 : 2;
        if (block.timestamp - lastRebalanceTs < cooldown) {
            return (false, 0, 0);
        }

        // Get scoring data via delegatecall to ScoringModule
        (bool dcOk, bytes memory dcRes) = scoringModule.delegatecall(
            abi.encodeWithSelector(COMPUTE_INPUTS_SEL)
        );
        if (!dcOk) return (false, 0, 0);

        (
            uint16[] memory apyBpsArray,
            address[] memory enabledAdapters,
            uint256[] memory targetAllocs,
            uint256 tvl,
            uint256 moved,
            uint256[] memory scores
        ) = abi.decode(dcRes, (uint16[], address[], uint256[], uint256, uint256, uint256[]));

        if (enabledAdapters.length == 0) return (false, 0, 0);

        // canRebalance is called via STATICCALL by LendingStrategyUpkeep.checkUpkeep
        // (view). Passing `emitOnMandate=false` guarantees no LOG* opcode executes
        // on this path, so the staticcall succeeds even when the mandate fires.
        // The CapDriftMandate event is still emitted when the plan is actually
        // prepared (checkGate path, see below).
        GasEstimator.Action[] memory actions = _candidateActions(enabledAdapters, targetAllocs, scores, tvl);
        (ok, netBenefitBps) = _fullGateCheck(
            apyBpsArray, enabledAdapters, targetAllocs, tvl, moved, false, actions
        );
        if (rebalanceGasEstimator == address(0)) movedEstimateUSDC = moved;
        else for (uint256 i; i < actions.length; ++i) movedEstimateUSDC += actions[i].amount;
    }

    /// @notice Gate check called by ScoringModule._prepareRebalanceInternal() via delegatecall.
    /// @dev    Receives pre-computed scoring data. Runs all P0-P3 checks.
    ///         `emitOnMandate=true` because this is the action path (non-view).
    ///         KEEPER_ROLE only — the sole legitimate caller is
    ///         prepareRebalance() (KEEPER-gated). Unlike canRebalance() (a
    ///         read-only STATICCALL path with emitOnMandate=false), this path
    ///         can WRITE `lastRelCapMandateTs`, so caller-supplied `tvl`/
    ///         `enabledAdapters` must not be reachable unauthenticated.
    function checkGate(
        uint16[] calldata apyBpsArray,
        address[] calldata enabledAdapters,
        uint256[] calldata targetAllocs,
        uint256 tvl,
        uint256 moved
    ) external onlyDelegateCall onlyRoleOrRevert(KEEPER_ROLE) returns (bool ok, int256 netBenefitBps) {
        return _fullGateCheck(apyBpsArray, enabledAdapters, targetAllocs, tvl, moved, true,
            _candidateActions(enabledAdapters, targetAllocs, new uint256[](enabledAdapters.length), tvl));
    }

    /// @notice True read-only preview; uses the same scoring and candidate builder as preparation.
    /// @dev Scoring's false-update path is STATICCALL-safe. No quotes are stored.
    function previewRebalanceGas() external view onlyDelegateCall
        returns (GasEstimator.Action[] memory actions, GasEstimator.Quote memory quote)
    {
        (bool ok, bytes memory data) = address(this).staticcall(abi.encodeWithSelector(COMPUTE_INPUTS_SEL));
        require(ok, "scoring-preview");
        (, address[] memory list, uint256[] memory targets, uint256 tvl,, uint256[] memory scores) =
            abi.decode(data, (uint16[], address[], uint256[], uint256, uint256, uint256[]));
        if (list.length == 0) return (new GasEstimator.Action[](0), quote);
        actions = _candidateActions(list, targets, scores, tvl);
        if (actions.length > 0 && rebalanceGasEstimator != address(0)) quote = _quote(actions, true);
    }

    /// @notice Preparation evaluates the same canonical ordered actions as execution.
    function checkCandidateGate(uint16[] calldata apys, address[] calldata list, uint256[] calldata targets,
        uint256[] calldata scores, uint256 tvl, uint256 moved)
        external onlyDelegateCall onlyRoleOrRevert(KEEPER_ROLE) returns (bool pass, int256 benefit, bool safety)
    {
        if (capDriftToleranceBps > 0 && adapterMaxExposureBps > 0 && tvl > 0)
            (safety,,,) = _checkCapDriftMandate(list, tvl);
        (pass, benefit) = _fullGateCheck(apys, list, targets, tvl, moved, true, _candidateActions(list, targets, scores, tvl));
    }

    function _quote(GasEstimator.Action[] memory actions, bool prepare) internal view returns (GasEstimator.Quote memory q) {
        uint8 batch = maxRebalanceActionsPerTx == 0 ? 2 : maxRebalanceActionsPerTx;
        try GasEstimator(rebalanceGasEstimator).estimate(address(this), actions, batch, prepare)
            returns (GasEstimator.Quote memory result) { return result; } catch { return q; }
    }

    /// @dev Validate executable funding and construct the resulting allocation.
    ///      Short liquidity, disabled venues and changed deposit flags invalidate the plan.
    function _actionTargets(address[] memory list, GasEstimator.Action[] memory actions, uint256 tvl)
        internal returns (bool valid, uint256[] memory targets, uint256 moved)
    {
        targets = new uint256[](list.length);
        for (uint256 j; j < list.length; ++j) targets[j] = positionAssets[list[j]];
        uint256 cash = ASSET.balanceOf(address(this));
        for (uint256 i; i < actions.length; ++i) {
            GasEstimator.Action memory action = actions[i];
            bool found;
            for (uint256 j; j < list.length; ++j) {
                if (list[j] != action.adapter) continue;
                found = true;
                if (action.deposit) {
                    if (!enabled[action.adapter] || quarantined[action.adapter] || depositsDisabled || flagged[action.adapter] || action.amount > cash) return (false, targets, moved);
                    uint256 projected = targets[j] + action.amount;
                    (bool success, bytes memory response) = allocCalcModule_addr.delegatecall(
                        abi.encodeWithSignature("validateRebalanceDeposit(address,uint256,uint256)", action.adapter, projected, tvl)
                    );
                    if (!success || response.length < 32 || !abi.decode(response, (bool))) return (false, targets, moved);
                    cash -= action.amount;
                    targets[j] = projected;
                } else {
                    if (action.amount > targets[j]) return (false, targets, moved);
                    try ILendingAdapter(action.adapter).withdrawableAssets() returns (uint256 liquid) {
                        if (action.amount > liquid) return (false, targets, moved);
                    } catch { return (false, targets, moved); }
                    targets[j] -= action.amount;
                    cash += action.amount;
                }
                moved += action.amount;
                break;
            }
            if (!found) return (false, targets, moved);
        }
        valid = actions.length > 0 && cash >= tvl * targetIdleBufferBps / 10000;
    }

    /// @notice Reprice the unexecuted suffix; sunk preparation/step costs are excluded.
    function checkRemainingPlan() external onlyDelegateCall onlyRoleOrRevert(KEEPER_ROLE) returns (bool) {
        if (rebalanceGasEstimator == address(0) || _gasPlanSafety) return true;
        (bool success, bytes memory data) = scoringModule.delegatecall(abi.encodeWithSelector(COMPUTE_INPUTS_SEL));
        if (!success) return false;
        (uint16[] memory apys, address[] memory list, uint256[] memory currentTargets, uint256 tvl,,) =
            abi.decode(data, (uint16[], address[], uint256[], uint256, uint256, uint256[]));
        uint256 count = rebalancePlanTotalActions - rebalancePlanNextAction;
        GasEstimator.Action[] memory actions = new GasEstimator.Action[](count);
        for (uint256 i; i < count; ++i) {
            uint256 at = rebalancePlanNextAction + i;
            uint256 raw = rebalancePlanAmounts[at];
            actions[i] = GasEstimator.Action(rebalancePlanAdapters[at], raw & ((1 << 255)-1), raw >> 255 == 1);
        }
        // Scores/TVL can change the selected set after preparation. Never deposit
        // into a venue excluded by the freshly recomputed target policy.
        for (uint256 i; i < actions.length; ++i) {
            if (!actions[i].deposit) continue;
            bool selected;
            for (uint256 j; j < list.length; ++j) {
                if (list[j] == actions[i].adapter && currentTargets[j] > 0) { selected = true; break; }
            }
            if (!selected) return false;
        }
        (bool valid, uint256[] memory targets, uint256 moved) = _actionTargets(list, actions, tvl);
        if (!valid) return false;
        GasEstimator.Quote memory q = _quote(actions, false);
        emit RebalanceGasEvaluated(q.actionsHash, q.costUSDC, q.l2Gas, q.posterWei, q.reliable);
        if (!q.reliable) return false;
        (bool pass, uint256 gross, int256 net) = _gateBenefitCost(apys, list, targets, tvl, moved, q.costUSDC);
        emit RebalanceEconomicsEvaluated(moved, gross, q.costUSDC, net, pass);
        return pass;
    }

    // ── Internal gate logic ─────────────────────────────────────────────

    function _fullGateCheck(
        uint16[] memory apyBpsArray,
        address[] memory enabledAdapters,
        uint256[] memory targetAllocs,
        uint256 tvl,
        uint256 moved,
        bool emitOnMandate,
        GasEstimator.Action[] memory actions
    ) internal returns (bool ok, int256 netBenefitBps) {
        if (rebalanceGasEstimator != address(0) && actions.length == 0) return (false, 0);
        // ─────────────────────────────────────────────────────────────────
        // P0.4 (2026-04-24) — Cap drift mandate bypass.
        //
        // If any enabled adapter's position exceeds the hard ceiling
        //   hardCeiling = adapterMaxExposureBps * tvl * (1e4 + capDriftToleranceBps) / 1e8
        // the gate MUST accept the rebalance plan regardless of benefit-vs-cost.
        //
        // Rationale: yield accrues continuously on-chain while TVL can shrink
        // (user withdrawals). Strict `current <= maxExp` is therefore physically
        // impossible to maintain. The protocol must auto-heal over-cap positions
        // beyond a bounded tolerance even when the move is not economically
        // justified by APY uplift alone. Below `hardCeiling` but above `maxExp`,
        // the existing `overCapRiskPremiumBps` soft-incentive continues to tilt
        // the benefit/cost calculation (see _computeOverCapProtectionBenefit).
        //
        // Trigger: any adapter over ceiling → mandate. Cheaper and more
        // conservative than an aggregated drift metric.
        //
        // `tvl` here is the total strategy TVL (idle + all positions) — same
        // denominator used by `_checkAdapterForDeploy` when computing maxExp,
        // so the ceiling is consistent with the deploy-time gate.
        //
        // `emitOnMandate` is false when this is reached via `canRebalance`,
        // which is called via STATICCALL by the Chainlink upkeep's view-only
        // `checkUpkeep`. Emitting LOG* under staticcall reverts. The event is
        // emitted only on the action path (`checkGate` → prepareRebalance).
        if (capDriftToleranceBps > 0 && adapterMaxExposureBps > 0 && tvl > 0) {
            (bool fired, address hitAdapter, uint256 hitCurr, uint256 hardCeiling) =
                _checkCapDriftMandate(enabledAdapters, tvl);
            if (fired) {
                if (emitOnMandate) {
                    emit CapDriftMandate(hitAdapter, hitCurr, hardCeiling);
                    // P0.7 (2026-06-11) — Per-adapter mandate cooldown.
                    // ONLY for non-safety adapters: safety adapters are exempt
                    // from cooldown by design (their mandate ceiling is the
                    // fallback cap, not the normal cap; if they hit it, the
                    // overflow path will naturally back off via the
                    // fbCeiling - current check).
                    if (safetyFallback[hitAdapter].absCapBps == 0) {
                        uint32 cd = mandateRedeployCooldownSeconds;
                        if (cd > 0) {
                            lastRelCapMandateTs[hitAdapter] = uint64(block.timestamp);
                            emit RelCapMandateCooldownStarted(
                                hitAdapter, uint64(block.timestamp), cd
                            );
                        }
                    }
                }
                // Mandate fired: accept plan unconditionally. netBenefitBps = 0
                // because the economic justification is protection, not yield.
                return (true, 0);
            }
        }
        // ─────────────────────────────────────────────────────────────────

        uint256 cost = gasCostUSDC;
        if (rebalanceGasEstimator != address(0)) {
            bool valid;
            (valid, targetAllocs, moved) = _actionTargets(enabledAdapters, actions, tvl);
            if (!valid) return (false, 0);
            GasEstimator.Quote memory q = _quote(actions, true);
            if (emitOnMandate) emit RebalanceGasEvaluated(q.actionsHash, q.costUSDC, q.l2Gas, q.posterWei, q.reliable);
            if (!q.reliable) return (false, 0);
            cost = q.costUSDC;
        }

        // P0.3 (remediation sprint 2026-04-22): drift denominator must use the
        // re-allocatable TVL (idle + enabled positions), NOT the total TVL that
        // includes quarantined positions. Otherwise quarantine inflates the
        // denominator and a legitimate rebalance on the healthy subset gets
        // artificially blocked.
        uint256 tvlEnabled = _tvlEnabled(enabledAdapters);

        // P1: Min move BPS check — against the re-allocatable TVL, not total.
        if (moved < (uint256(rebalanceMinMoveBps) * tvlEnabled) / 1e4) return (false, 0);

        // P1: Entry hysteresis — same denominator correction.
        if (entryDriftBps > 0 && tvlEnabled > 0) {
            uint256 driftBps = (moved * 1e4) / tvlEnabled;
            if (driftBps < entryDriftBps) return (false, 0);
        }

        // P1: Absolute minimum move floor
        if (minMoveUsd > 0 && moved < minMoveUsd) return (false, 0);

        // Run benefit/cost analysis (note: the benefit/cost formula itself still
        // uses `tvl` only indirectly via weighted APY; we pass `tvlEnabled` so
        // the net-benefit-bps normalisation is consistent with the pre-check).
        uint256 grossBenefit;
        (ok, grossBenefit, netBenefitBps) = _gateBenefitCost(
            apyBpsArray, enabledAdapters, targetAllocs, tvl, moved, cost
        );
        if (emitOnMandate && rebalanceGasEstimator != address(0))
            emit RebalanceEconomicsEvaluated(moved, grossBenefit, cost, netBenefitBps, ok);
    }

    /// @dev P0.4 (2026-04-24) — scan enabled adapters for cap drift mandate.
    ///      P0.5 (2026-04-25) — extended to cover the relative cap (symmetric
    ///        with the new clamp in `_targetAllocations`).
    ///      Pure view: returns on the FIRST adapter whose `positionAssets`
    ///      exceeds either hard ceiling. The caller decides whether to emit
    ///      the `CapDriftMandate` event (keeps `canRebalance`'s STATICCALL
    ///      path safe — no LOG* opcodes under staticcall).
    ///
    ///      Conservative by design:
    ///        - Any single over-ceiling adapter fires the mandate.
    ///        - Absolute ceiling uses total `tvl` (includes quarantined) to
    ///          match `_checkAdapterForDeploy`'s maxExp computation.
    ///        - Relative ceiling uses cached external TVL (same source as
    ///          the deploy gate and `_targetAllocations` clamp).
    ///        - On rel cap hit, `hardCeiling` returned is the rel hard
    ///          ceiling for the offending adapter — useful for the event.
    function _checkCapDriftMandate(
        address[] memory enabledAdapters,
        uint256 tvl
    ) internal view returns (
        bool fired,
        address hitAdapter,
        uint256 hitCurrent,
        uint256 hardCeiling
    ) {
        // P0.7 (iter-3b 2026-06-11) — Fallback-aware mandate.
        //
        // For safety-fallback adapters, the ceiling becomes the (governance-
        // approved, elevated) fallback cap instead of the normal abs/rel cap.
        // Without this, the safety overflow path would push e.g. Aave above
        // 30% and the mandate would immediately yank it back — exactly the
        // doomed-rotation loop diagnosed in iter-3 of the backtest sweep.
        //
        // Each adapter is now scored against its OWN ceiling tier:
        //   - non-safety: absHard  = (adapterMaxExposureBps * tvl) × (1+tol)
        //                 relHard  = (dynRel * extTVL)              × (1+tol)
        //   - safety:     absHard  = (fbAbsCapBps     * tvl)        × (1+tol)
        //                 relHard  = (fbRelCapBps     * extTVL)     × (1+tol)
        //                 (rel uses fallback ONLY when fbRelCapBps > 0;
        //                  otherwise falls back to the dynamic rel band.)
        //
        // The default-return hardCeiling (when no adapter fires) is the
        // legacy NORMAL absolute hard ceiling — preserved for callers that
        // read the field on the false-path (none today, but defensive).
        uint16 normalAbsCapBps = adapterMaxExposureBps;
        uint256 normalMaxExp   = (uint256(normalAbsCapBps) * tvl) / 1e4;
        hardCeiling = (normalMaxExp * (1e4 + uint256(capDriftToleranceBps))) / 1e4;

        uint16 maxRelGov = maxRelativeExposureBps;
        uint16 tolBps    = capDriftToleranceBps;
        uint256 n = enabledAdapters.length;

        for (uint256 i = 0; i < n;) {
            address a = enabledAdapters[i];
            uint256 curr = positionAssets[a];

            // === Resolve the per-adapter ceiling tier ===
            SafetyFallback memory sf = safetyFallback[a];
            bool isSafety = (sf.absCapBps != 0);

            // (1) Absolute cap drift — fallback abs cap for safety adapters.
            uint256 absCapBpsEff = isSafety ? uint256(sf.absCapBps) : uint256(normalAbsCapBps);
            if (normalAbsCapBps > 0 && absCapBpsEff > normalAbsCapBps) absCapBpsEff = normalAbsCapBps;
            uint256 absMaxExp   = (absCapBpsEff * tvl) / 1e4;
            uint256 absHard     = (absMaxExp * (1e4 + uint256(tolBps))) / 1e4;
            if (curr > absHard) {
                return (true, a, curr, absHard);
            }

            // (2) Relative cap drift (P0.5).
            // Safety adapter with explicit fbRelCapBps > 0 uses fallback rel.
            // Safety adapter with fbRelCapBps == 0 falls back to dynamic rel
            // (the "abs-only safety" mode — uncommon but supported).
            uint256 extTVL = cachedExternalTVL[a];
            if (extTVL > 0 && curr > 0) {
                uint16 effRel;
                if (isSafety && sf.relCapBps > 0) {
                    effRel = sf.relCapBps;
                } else {
                    uint16 dynRel = _gateRelativeCapBps(extTVL);
                    effRel = (maxRelGov > 0 && maxRelGov < dynRel)
                        ? maxRelGov : dynRel;
                }
                if (effRel > 0) {
                    uint256 relCap = (uint256(effRel) * extTVL) / 1e4;
                    uint256 relHard =
                        (relCap * (1e4 + uint256(tolBps))) / 1e4;
                    if (curr > relHard) {
                        return (true, a, curr, relHard);
                    }
                }
            }

            unchecked { ++i; }
        }
        return (false, address(0), 0, hardCeiling);
    }

    /// @dev Remediation sprint P0.3 — reallocatable TVL (excludes quarantined).
    ///      Uses ASSET.balanceOf(this) for idle since idleCash() lives in a
    ///      sibling module; the storage layout is shared so the immutable
    ///      ASSET address is the same strategy-scoped USDC.
    function _tvlEnabled(address[] memory enabledAdapters) internal view returns (uint256 sum) {
        sum = ASSET.balanceOf(address(this));
        uint256 n = enabledAdapters.length;
        for (uint256 i = 0; i < n;) {
            sum += positionAssets[enabledAdapters[i]];
            unchecked { ++i; }
        }
    }

    /// @dev Benefit/cost gate with P0-P3 enhancements.
    function _gateBenefitCost(
        uint16[] memory apyBpsArray,
        address[] memory enabledAdapters,
        uint256[] memory targetAllocs,
        uint256 tvl,
        uint256 moved,
        uint256 gasCost
    ) internal view returns (bool ok, uint256 grossBenefit, int256 netBenefitBps) {
        // Calculate deltaAPY = weightedAPY(target) - weightedAPY(current)
        uint256 currWeightedAPY = 0;
        uint256 tgtWeightedAPY = 0;
        uint256 sumCurr = 0;
        uint256 sumTgt = 0;
        for (uint256 i = 0; i < enabledAdapters.length; ++i) {
            uint256 curr = positionAssets[enabledAdapters[i]];
            uint256 tgt = targetAllocs[i];
            uint256 apy = apyBpsArray[i];
            currWeightedAPY += curr * apy;
            tgtWeightedAPY += tgt * apy;
            sumCurr += curr;
            sumTgt += tgt;
        }
        if (sumCurr > 0) currWeightedAPY /= sumCurr;
        if (sumTgt > 0) tgtWeightedAPY /= sumTgt;
        if (tgtWeightedAPY > uint256(type(int256).max)) revert Overflow();
        if (currWeightedAPY > uint256(type(int256).max)) revert Overflow();

        int256 deltaAPY = int256(tgtWeightedAPY) - int256(currWeightedAPY);
        // Dynamic mode uses the executable allocation's annual USDC yield delta.
        int256 annualDelta;
        if (rebalanceGasEstimator != address(0)) {
            for (uint256 i; i < enabledAdapters.length; ++i) {
                uint256 beforeYield = positionAssets[enabledAdapters[i]] * apyBpsArray[i];
                uint256 afterYield = targetAllocs[i] * apyBpsArray[i];
                if (beforeYield > uint256(type(int256).max) || afterYield > uint256(type(int256).max)) revert Overflow();
                annualDelta += int256(afterYield) - int256(beforeYield);
            }
        }


        // P3: Regime-aware horizon (0 = use default)
        uint256 _horizon = regimeHorizonDays > 0 ? regimeHorizonDays : gateHorizonDays;

        // Gross benefit = moved × deltaAPY × horizon / (10000 × 365)
        if (rebalanceGasEstimator != address(0)) {
            if (annualDelta > 0) grossBenefit = uint256(annualDelta) * _horizon / (10000 * 365);
        } else if (deltaAPY > 0) {
            grossBenefit = (moved * uint256(deltaAPY) * _horizon) / (10000 * 365);
        }

        // === P0.1 (remediation sprint 2026-04-22) — over-cap protection benefit ===
        // When an adapter's current position is above its effective relative cap,
        // reducing that position is economically valuable even when deltaAPY <= 0,
        // because every extra day spent over-cap is a day of concentration risk.
        //
        // We model this risk cost as an annualised premium (overCapRiskPremiumBps):
        //   protection_benefit += overcap_reduction × premiumBps × horizon / (1e4 × 365)
        // where overcap_reduction is the portion of the move that actually brings
        // the position closer to the rel cap (not exceeding the remaining overcap).
        //
        // 0 = feature disabled (legacy behaviour).
        if (overCapRiskPremiumBps > 0) {
            uint256 protBenefit = _computeOverCapProtectionBenefit(
                enabledAdapters, targetAllocs, _horizon
            );
            grossBenefit += protBenefit;
        }

        if (rebalanceGasEstimator != address(0) && annualDelta < 0) {
            uint256 yieldLoss = uint256(-annualDelta) * _horizon / (10000 * 365);
            grossBenefit = grossBenefit > yieldLoss ? grossBenefit - yieldLoss : 0;
        }

        // P3: Confidence multiplier (10000 = 1x, 0 = no override)
        if (regimeConfidenceMultBps > 0 && regimeConfidenceMultBps < 10000) {
            grossBenefit = (grossBenefit * regimeConfidenceMultBps) / 10000;
        }

        // P2: Coordination penalty — reduce benefit if recently rebalanced
        if (recentRebalancePenaltyBps > 0 && recentRebalanceWindowSeconds > 0) {
            if (lastRebalanceTs > 0 && block.timestamp - lastRebalanceTs < recentRebalanceWindowSeconds) {
                grossBenefit = (grossBenefit * (10000 - recentRebalancePenaltyBps)) / 10000;
            }
        }

        // P0: Dynamic gas cost (EMA-based if available, else fixed fallback)
        uint256 _gasCost = gasCost;
        uint256 moveCost = _gasCost + (moved * (slippageBpsEstimate + withdrawalSpreadBpsEstimate)) / 1e4;

        if (grossBenefit > uint256(type(int256).max)) revert Overflow();
        if (moveCost > uint256(type(int256).max)) revert Overflow();
        if (moved > uint256(type(int256).max)) revert Overflow();

        int256 netBenefit = int256(grossBenefit) - int256(moveCost);
        if (rebalanceGasEstimator != address(0) && netBenefit <= 0) return (false, grossBenefit, 0);
        if (moved < 1) return (false, grossBenefit, 0);
        netBenefitBps = (netBenefit * 1e4) / int256(moved);

        // P1: Benefit/cost ratio minimum (0 = disabled)
        if (minBenefitCostRatioBps > 0 && moveCost > 0) {
            if (grossBenefit * 10000 < moveCost * uint256(minBenefitCostRatioBps)) {
                return (false, grossBenefit, netBenefitBps);
            }
        }

        ok = netBenefitBps >= int256(uint256(gateMinNetBenefitBps));
    }

    /// @dev Remediation sprint P0.1 — over-cap protection benefit.
    ///      For each enabled adapter where `current > relCap`, if the target
    ///      reduces the position (target < current), credit the gross benefit
    ///      with `overcap_reduction × premiumBps × horizon / (1e4 × 365)`.
    ///      `overcap_reduction` is bounded by min(current - target, current - relCap)
    ///      so maintenance moves above rel cap are NOT rewarded — only genuine
    ///      divestiture toward or beyond the cap.
    function _computeOverCapProtectionBenefit(
        address[] memory enabledAdapters,
        uint256[] memory targetAllocs,
        uint256 horizonDays
    ) internal view returns (uint256 totalBenefit) {
        uint16 premium = overCapRiskPremiumBps;
        if (premium == 0) return 0;

        uint16 maxRel = maxRelativeExposureBps;
        uint256 n = enabledAdapters.length;
        for (uint256 i = 0; i < n;) {
            address a = enabledAdapters[i];
            uint256 curr = positionAssets[a];
            uint256 tgt = targetAllocs[i];
            uint256 extTVL = cachedExternalTVL[a];
            if (extTVL == 0 || curr == 0 || tgt >= curr) {
                unchecked { ++i; }
                continue;
            }

            // Effective rel cap (governance override if tighter).
            uint16 dynRel = _gateRelativeCapBps(extTVL);
            uint16 effRel = (maxRel > 0 && maxRel < dynRel) ? maxRel : dynRel;
            if (effRel == 0) {
                // Zero-cap band → any positive current is over-cap; reduction reward
                // is bounded by the full (curr - tgt) move.
                uint256 reduction = curr - tgt;
                totalBenefit += (reduction * uint256(premium) * horizonDays) / (10000 * 365);
                unchecked { ++i; }
                continue;
            }

            uint256 relCap = (uint256(effRel) * extTVL) / 1e4;
            if (curr <= relCap) {
                unchecked { ++i; }
                continue; // not over-cap → no protection benefit
            }

            uint256 overcap = curr - relCap;
            uint256 move = curr - tgt;
            uint256 reduction = move < overcap ? move : overcap;
            if (reduction > 0) {
                totalBenefit += (reduction * uint256(premium) * horizonDays) / (10000 * 365);
            }
            unchecked { ++i; }
        }
    }

    /// @dev Delegates to StrategyConfigLib (single source of truth, shared
    ///      with StrategyStorageLayout._effectiveRelativeCapBps). Previously
    ///      an independent hand-copy of the same band table -- StrategyConfigLib
    ///      functions are `internal` (compiler-inlined, no deployed library
    ///      address), so there was never actually a delegatecall to avoid.
    function _gateRelativeCapBps(uint256 extTVL) internal pure returns (uint16) {
        return StrategyConfigLib.effectiveRelativeCapBps(extTVL);
    }
}
