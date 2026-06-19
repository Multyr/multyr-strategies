// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title StrategySettingsModule
 * @notice Governance setter functions for UsdcMultiLendingVault, called via delegatecall.
 * @dev    Extracted from StrategyParamsModule to stay under EIP-170 bytecode limit.
 *         Contains all DEFAULT_ADMIN_ROLE and PARAM_ROLE setters (45 functions).
 *         Must be LAST in the fallback dispatch chain — lowest call frequency.
 *
 *         Like all modules: never called directly. All storage reads/writes operate
 *         on the strategy's own storage context via delegatecall.
 */

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ILendingAdapter, IAdapterEmergency } from "../interfaces/ILendingAdapter.sol";
import {
    StrategyStorageLayout,
    SkipReason,
    Unauthorized, Frozen, InvalidAdapter, WeightsSumInvalid,
    MinAdaptersTooLow, RiskScoreTooHigh, DurationTooLong, BackfillTooLarge,
    BootstrapInactive, InvalidInput, ParamOutOfRange, ZeroAmount,
    InsufficientBalance, ZeroAddress,
    // P0.7 — Safety Adapter Cap Tier setter errors.
    AlreadySafetyFallback, NotSafetyFallback, InvalidFallbackCap, AdapterNotEnabled
} from "./StrategyStorageLayout.sol";

error InvalidQuarantineThreshold();

contract StrategySettingsModule is StrategyStorageLayout {
    using SafeERC20 for IERC20Metadata;

    event EmergencyTransferToCore(address indexed caller, address indexed asset, uint256 amount, address indexed destination);
    event GasEmaParamsUpdated(uint16 smoothingBps);

    constructor(address asset_, address _core)
        StrategyStorageLayout(asset_, _core, address(0), address(0), address(0))
    {}

    // ══════════════════════════════════════════════════════════════════════
    //  FREEZE / FINALIZE
    // ══════════════════════════════════════════════════════════════════════

    function freezeRoles() external onlyRoleOrRevert(DEFAULT_ADMIN_ROLE) rolesNotFrozen {
        rolesFrozen = true;
        emit RolesFrozen();
    }

    function finalizeParameters() external onlyRoleOrRevert(PARAM_ROLE) paramsNotFinalized {
        paramsFinalized = true;
        emit ParametersFinalized();
    }

    // ── Module address setters (F-SIZE-01 2026-06-20) ───────────────────────

    /// @notice Set StrategySafetyOverflowModule address (set-once, DEFAULT_ADMIN_ROLE).
    function setSafetyOverflowModule(address _overflowModule)
        external onlyRoleOrRevert(DEFAULT_ADMIN_ROLE)
    {
        require(safetyOverflowModule_addr == address(0) && _overflowModule != address(0), "overflow-module");
        safetyOverflowModule_addr = _overflowModule;
        emit SafetyOverflowModuleSet(_overflowModule);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  ROLE ADMIN
    // ══════════════════════════════════════════════════════════════════════

    function setRoleAdmin(bytes32 role, bytes32 adminRole)
        external
        onlyRoleOrRevert(DEFAULT_ADMIN_ROLE)
        rolesNotFrozen
    {
        _setRoleAdmin(role, adminRole);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  PARAMETER SETTERS (PARAM_ROLE)
    // ══════════════════════════════════════════════════════════════════════

    function setRiskWeights(
        uint16 _wAPY,
        uint16 _wLiq,
        uint16 _wRisk,
        uint16 _wStability,
        uint16 _wIncentive
    ) external onlyRoleOrRevert(PARAM_ROLE) paramsNotFinalized {
        if (_wIncentive != 0) revert WeightsSumInvalid();
        if (_wAPY + _wLiq + _wRisk + _wStability + _wIncentive != 10000) {
            revert WeightsSumInvalid();
        }
        wAPY = _wAPY;
        wLiq = _wLiq;
        wRisk = _wRisk;
        wStability = _wStability;
        wIncentive = _wIncentive;
        emit RiskWeightsUpdated(_wAPY, _wLiq, _wRisk, _wStability, _wIncentive);
    }

    function setGateParams(
        uint16 _gateHorizonDays,
        uint16 _gateMinNetBenefitBps,
        uint16 _slippageBpsEstimate,
        uint16 _withdrawalSpreadBpsEstimate,
        uint256 _gasCostUSDC
    ) external onlyRoleOrRevert(PARAM_ROLE) paramsNotFinalized {
        gateHorizonDays = _gateHorizonDays;
        gateMinNetBenefitBps = _gateMinNetBenefitBps;
        slippageBpsEstimate = _slippageBpsEstimate;
        withdrawalSpreadBpsEstimate = _withdrawalSpreadBpsEstimate;
        gasCostUSDC = _gasCostUSDC;
        emit GateParamsUpdated(
            _gateHorizonDays,
            _gateMinNetBenefitBps,
            _slippageBpsEstimate,
            _withdrawalSpreadBpsEstimate,
            _gasCostUSDC
        );
    }

    function setRebalanceParams(
        uint16 _maxAdaptersPerAllocation,
        uint16 _minAdaptersActive,
        uint16 _rebalanceMinMoveBps,
        uint32 _minSecondsBetweenRebalances,
        uint16 _driftToleranceBps,
        uint16 _adapterMaxExposureBps,
        uint16 _newAdapterRampBps
    ) external onlyRoleOrRevert(PARAM_ROLE) {
        if (_maxAdaptersPerAllocation < 2) revert MinAdaptersTooLow();
        if (_minAdaptersActive < 2) revert MinAdaptersTooLow();
        if (!(_minSecondsBetweenRebalances >= 3600 && _minSecondsBetweenRebalances <= 604800)) revert ParamOutOfRange(); // "range: 1h-7d"
        // C-03: bounds on previously-unbounded params (P0.7 mandate-gate integrity).
        if (_driftToleranceBps > 2000) revert ParamOutOfRange();                                       // max 20%
        if (_adapterMaxExposureBps > 5000) revert ParamOutOfRange();                                     // max 50% (0 = disabled/no ceiling)
        if (_newAdapterRampBps > 5000) revert ParamOutOfRange();                                       // max 50%
        if (_rebalanceMinMoveBps > 5000) revert ParamOutOfRange();                                     // max 50%
        maxAdaptersPerAllocation = _maxAdaptersPerAllocation;
        minAdaptersActive = _minAdaptersActive;
        rebalanceMinMoveBps = _rebalanceMinMoveBps;
        minSecondsBetweenRebalances = _minSecondsBetweenRebalances;
        driftToleranceBps = _driftToleranceBps;
        adapterMaxExposureBps = _adapterMaxExposureBps;
        newAdapterRampBps = _newAdapterRampBps;
        emit RebalanceParamsUpdated(
            _maxAdaptersPerAllocation,
            _minAdaptersActive,
            _rebalanceMinMoveBps,
            _minSecondsBetweenRebalances,
            _driftToleranceBps,
            _adapterMaxExposureBps,
            _newAdapterRampBps
        );
    }

    function setHarvestParams(uint16 _harvestThresholdBps, uint32 _minSecondsBetweenHarvests)
        external
        onlyRoleOrRevert(PARAM_ROLE)
    {
        if (!(_minSecondsBetweenHarvests >= 3600 && _minSecondsBetweenHarvests <= 604800)) revert ParamOutOfRange(); // "range: 1h-7d"
        harvestThresholdBps = _harvestThresholdBps;
        minSecondsBetweenHarvests = _minSecondsBetweenHarvests;
        emit HarvestParamsUpdated(_harvestThresholdBps, _minSecondsBetweenHarvests);
    }

    function setDustTolerance(uint256 _dustTolerance)
        external
        onlyRoleOrRevert(PARAM_ROLE)
        paramsNotFinalized
    {
        dustTolerance = _dustTolerance;
        emit DustToleranceUpdated(_dustTolerance);
    }

    function setNewAdapterRampParams(uint256 _minNewAdapterSeed, uint64 _newAdapterRampDuration)
        external
        onlyRoleOrRevert(PARAM_ROLE)
        paramsNotFinalized
    {
        if (_newAdapterRampDuration > MAX_RAMP_DURATION) revert DurationTooLong();
        minNewAdapterSeed = _minNewAdapterSeed;
        newAdapterRampDuration = _newAdapterRampDuration;
        emit NewAdapterRampParamsUpdated(_minNewAdapterSeed, _newAdapterRampDuration);
    }

    function setMaxIdleAfterDepositBps(uint16 _maxIdleAfterDepositBps)
        external
        onlyRoleOrRevert(PARAM_ROLE)
        paramsNotFinalized
    {
        maxIdleAfterDepositBps = _maxIdleAfterDepositBps;
        emit MaxIdleAfterDepositBpsUpdated(_maxIdleAfterDepositBps);
    }

    function setMaxIdleBootstrapBps(uint16 _maxIdleBootstrapBps)
        external
        onlyRoleOrRevert(PARAM_ROLE)
        paramsNotFinalized
    {
        maxIdleBootstrapBps = _maxIdleBootstrapBps;
        emit BootstrapIdleParamsUpdated(_maxIdleBootstrapBps);
    }

    function setDegradedViewThresholdBps(uint16 _degradedViewThresholdBps)
        external
        onlyRoleOrRevert(PARAM_ROLE)
        paramsNotFinalized
    {
        degradedViewThresholdBps = _degradedViewThresholdBps;
        emit DegradedViewThresholdBpsUpdated(_degradedViewThresholdBps);
    }

    function setFailureDecaySeconds(uint32 _failureDecaySeconds)
        external
        onlyRoleOrRevert(PARAM_ROLE)
        paramsNotFinalized
    {
        failureDecaySeconds = _failureDecaySeconds;
        emit FailureDecaySecondsUpdated(_failureDecaySeconds);
    }

    function setDeployIdleCooldown(uint32 _minSecondsBetweenDeployIdle)
        external
        onlyRoleOrRevert(PARAM_ROLE)
    {
        if (!(_minSecondsBetweenDeployIdle >= 60 && _minSecondsBetweenDeployIdle <= 7200)) revert ParamOutOfRange(); // "range: 1min-2h"
        minSecondsBetweenDeployIdle = _minSecondsBetweenDeployIdle;
        emit DeployIdleParamsUpdated(_minSecondsBetweenDeployIdle);
    }

    function backfillAdapterActivatedAt(address[] calldata list)
        external
        onlyRoleOrRevert(PARAM_ROLE)
        paramsNotFinalized
    {
        if (list.length > MAX_BACKFILL) revert BackfillTooLarge();
        for (uint256 i = 0; i < list.length; ++i) {
            address a = list[i];
            if (enabled[a] && adapterActivatedAt[a] == 0 && positionAssets[a] <= dustTolerance) {
                adapterActivatedAt[a] = uint64(block.timestamp);
            }
        }
    }

    function setSyncInterval(uint32 _interval) external onlyRoleOrRevert(PARAM_ROLE) {
        if (!(_interval >= 300 && _interval <= 7200)) revert ParamOutOfRange(); // "range: 5min-2h"
        minSecondsBetweenSync = _interval;
        emit SyncIntervalUpdated(_interval);
    }

    function setLiquidityStalenessSeconds(uint32 _seconds) external onlyRoleOrRevert(PARAM_ROLE) {
        if (!(_seconds >= 3600 && _seconds <= 259200)) revert ParamOutOfRange(); // "range: 1h-3d"
        uint32 old = liquidityStalenessSeconds;
        liquidityStalenessSeconds = _seconds;
        emit LiquidityStalenessUpdated(old, _seconds);
    }

    function setMaxRebalanceActionsPerTx(uint8 _max) external onlyRoleOrRevert(PARAM_ROLE) {
        if (!(_max >= 1 && _max <= 3)) revert ParamOutOfRange(); // "range: 1-3"
        uint8 old = maxRebalanceActionsPerTx;
        maxRebalanceActionsPerTx = _max;
        emit MaxRebalanceActionsUpdated(old, _max);
    }

    function setRebalancePlanMaxAge(uint32 _maxAge) external onlyRoleOrRevert(PARAM_ROLE) {
        if (!(_maxAge >= 3600 && _maxAge <= 259200)) revert ParamOutOfRange(); // "range: 1h-3d"
        uint32 old = rebalancePlanMaxAge;
        rebalancePlanMaxAge = _maxAge;
        emit RebalancePlanMaxAgeUpdated(old, _maxAge);
    }

    function setRebalancePlanMinDrift(uint256 _minDrift) external onlyRoleOrRevert(PARAM_ROLE) {
        if (!(_minDrift >= 1000e6 && _minDrift <= 100_000e6)) revert ParamOutOfRange(); // "range: 1K-100K"
        uint256 old = rebalancePlanMinDrift;
        rebalancePlanMinDrift = _minDrift;
        emit RebalancePlanMinDriftUpdated(old, _minDrift);
    }

    function setExternalTVLStalenessSeconds(uint32 _seconds) external onlyRoleOrRevert(PARAM_ROLE) {
        if (!(_seconds >= 3600 && _seconds <= 259200)) revert ParamOutOfRange(); // "range: 1h-3d"
        uint32 old = externalTVLStalenessSeconds;
        externalTVLStalenessSeconds = _seconds;
        emit ExternalTVLStalenessUpdated(old, _seconds);
    }

    function setStabilityParams(uint16 _apyFloorBps, uint32 _minInterval, uint16 _period)
        external onlyRoleOrRevert(PARAM_ROLE)
    {
        if (!(_apyFloorBps >= 10 && _apyFloorBps <= 500)) revert ParamOutOfRange(); // "floor: 10-500"
        if (!(_minInterval >= 3600 && _minInterval <= 86400)) revert ParamOutOfRange(); // "interval: 1h-24h"
        if (!(_period >= 3 && _period <= 30)) revert ParamOutOfRange(); // "period: 3-30"
        apyFloorBps = _apyFloorBps;
        minStabilityUpdateInterval = _minInterval;
        stabilityEMAPeriod = _period;
        emit StabilityParamsUpdated(_apyFloorBps, _minInterval, _period);
    }

    function setGasEmaParams(uint16 _smoothingBps) external onlyRoleOrRevert(PARAM_ROLE) {
        if (!(_smoothingBps >= 500 && _smoothingBps <= 5000)) revert ParamOutOfRange(); // "range: 5-50%"
        gasEmaSmoothingBps = _smoothingBps;
        emit GasEmaParamsUpdated(_smoothingBps);
    }

    function setHysteresisParams(
        uint16 _minBCR, uint16 _entryDrift, uint16 _exitDrift, uint256 _minMoveUsd
    ) external onlyRoleOrRevert(PARAM_ROLE) {
        if (!(_minBCR <= 50000)) revert ParamOutOfRange(); // "BCR max 5x"
        if (!(_entryDrift >= _exitDrift)) revert ParamOutOfRange(); // "entry >= exit"
        if (!(_entryDrift <= 2000)) revert ParamOutOfRange(); // "entry max 20%"
        minBenefitCostRatioBps = _minBCR;
        entryDriftBps = _entryDrift;
        exitDriftBps = _exitDrift;
        minMoveUsd = _minMoveUsd;
        emit HysteresisParamsUpdated(_minBCR, _entryDrift, _exitDrift, _minMoveUsd);
    }

    function setCoordinationParams(
        uint16 _penalty, uint32 _window, uint16 _minLiqReadiness
    ) external onlyRoleOrRevert(PARAM_ROLE) {
        if (!(_penalty <= 5000)) revert ParamOutOfRange(); // "penalty max 50%"
        if (!(_window <= 604800)) revert ParamOutOfRange(); // "window max 7d"
        if (!(_minLiqReadiness <= 10000)) revert ParamOutOfRange(); // "readiness max 100%"
        recentRebalancePenaltyBps = _penalty;
        recentRebalanceWindowSeconds = _window;
        minLiquidityReadinessBps = _minLiqReadiness;
        emit CoordinationParamsUpdated(_penalty, _window, _minLiqReadiness);
    }

    function setRegimeParams(
        uint8 _regime,
        uint16 _hysteresisMult,
        uint16 _budgetMult,
        uint16 _horizonDays,
        uint16 _confidenceMult
    ) external onlyRoleOrRevert(PARAM_ROLE) {
        if (!(_regime <= 2)) revert ParamOutOfRange(); // "invalid regime"
        if (!(_hysteresisMult <= 30000)) revert ParamOutOfRange(); // "hysteresis max 3x"
        if (!(_budgetMult <= 30000)) revert ParamOutOfRange(); // "budget max 3x"
        if (!(_horizonDays <= 365)) revert ParamOutOfRange(); // "horizon max 1y"
        if (!(_confidenceMult <= 10000)) revert ParamOutOfRange(); // "confidence max 1x"
        if (!(_confidenceMult > 0)) revert ParamOutOfRange(); // "confidence=0"
        if (!(_horizonDays > 0)) revert ParamOutOfRange(); // "horizon=0"
        if (!(_hysteresisMult <= _budgetMult)) revert ParamOutOfRange(); // "hyst>budget"
        if (_regime == currentRegime) {
            regimeHysteresisMultBps = _hysteresisMult;
            regimeBudgetMultBps = _budgetMult;
            regimeHorizonDays = _horizonDays;
            regimeConfidenceMultBps = _confidenceMult;
        }
        emit RegimeParamsUpdated(_regime, _hysteresisMult, _budgetMult, _horizonDays, _confidenceMult);
    }

    function setOverCapRiskPremium(uint16 _bps) external onlyRoleOrRevert(PARAM_ROLE) {
        if (!(_bps <= 5000)) revert ParamOutOfRange(); // "range: 0-5000 bps"
        overCapRiskPremiumBps = _bps;
        emit OverCapRiskPremiumUpdated(_bps);
    }

    function setScoringStalenessParams(uint32 _stabilityStaleness, uint32 _riskStaleness)
        external onlyRoleOrRevert(PARAM_ROLE)
    {
        if (!(_stabilityStaleness == 0 || _stabilityStaleness >= 3600)) revert ParamOutOfRange(); // "stab: 0 or >=1h"
        if (!(_riskStaleness == 0 || _riskStaleness >= 86400)) revert ParamOutOfRange(); // "risk: 0 or >=1d"
        stabilityEMAStalenessSeconds = _stabilityStaleness;
        riskScoreStalenessSeconds = _riskStaleness;
        emit ScoringStalenessUpdated(_stabilityStaleness, _riskStaleness);
    }

    function setRebalancePlanBackoffThreshold(uint8 _threshold)
        external onlyRoleOrRevert(PARAM_ROLE)
    {
        if (!(_threshold <= 20)) revert ParamOutOfRange(); // "threshold max 20"
        rebalancePlanBackoffThreshold = _threshold;
        emit RebalancePlanBackoffThresholdUpdated(_threshold);
    }

    function setRiskScore(address adapter, uint16 bps) external onlyRoleOrRevert(PARAM_ROLE) {
        if (!isAdapter[adapter]) revert InvalidAdapter();
        if (bps > 10000) revert RiskScoreTooHigh();
        riskScoreBps[adapter] = bps;
        lastRiskScoreUpdateTs[adapter] = uint64(block.timestamp);
        emit RiskScoreUpdated(adapter, bps);
    }

    function setCapDriftTolerance(uint16 _bps) external onlyRoleOrRevert(PARAM_ROLE) {
        if (!(_bps <= 2000)) revert ParamOutOfRange(); // "capDrift max 2000bps (20%)"
        uint16 old = capDriftToleranceBps;
        capDriftToleranceBps = _bps;
        emit CapDriftToleranceUpdated(old, _bps);
    }

    function setAdapterAbsCapOverride(address adapter, uint16 floorBps)
        external onlyRoleOrRevert(PARAM_ROLE)
    {
        if (adapter == address(0)) revert ZeroAddress();
        if (floorBps > 10000) revert ParamOutOfRange();
        adapterAbsCapOverrideBps[adapter] = floorBps;
        emit AdapterAbsCapOverrideUpdated(adapter, floorBps);
    }

    function setWithdrawalLockSeconds(uint64 seconds_) external onlyRoleOrRevert(PARAM_ROLE) {
        withdrawalLockSeconds = seconds_;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  ADAPTER ADMIN (DEFAULT_ADMIN_ROLE)
    // ══════════════════════════════════════════════════════════════════════

    function exitBootstrapMode() external onlyRoleOrRevert(DEFAULT_ADMIN_ROLE) {
        if (!_isBootstrapActive()) revert BootstrapInactive();
        bootstrapEndsAt = 0;
        emit BootstrapModeExited();
    }

    function setFlaggedAdapter(address adapter, bool isFlagged)
        external
        onlyRoleOrRevert(DEFAULT_ADMIN_ROLE)
    {
        if (!isAdapter[adapter]) revert InvalidAdapter();
        flagged[adapter] = isFlagged;
        emit AdapterFlagged(adapter, isFlagged);
    }

    function whitelistAdapter(address adapter, bool allowed)
        external
    {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(BOOTSTRAP_ROLE, msg.sender))
            revert Unauthorized();
        if (adapter == address(0)) revert ZeroAddress();
        whitelistedAdapters[adapter] = allowed;
        emit AdapterWhitelisted(adapter, allowed);
    }

    function setQuarantineThreshold(uint8 threshold)
        external
        onlyRoleOrRevert(PARAM_ROLE)
    {
        if (threshold == 0) revert InvalidQuarantineThreshold();
        if (threshold > MAX_ADAPTERS) revert InvalidQuarantineThreshold();
        adapterQuarantineThreshold = threshold;
        emit QuarantineThresholdUpdated(threshold);
    }

    function setMaxRelativeExposureBps(uint16 _maxRelativeExposureBps)
        external
        onlyRoleOrRevert(PARAM_ROLE)
        paramsNotFinalized
    {
        if (!(_maxRelativeExposureBps <= 5000)) revert ParamOutOfRange(); // "Max 50%"
        uint16 old = maxRelativeExposureBps;
        maxRelativeExposureBps = _maxRelativeExposureBps;
        emit MaxRelativeExposureBpsUpdated(old, _maxRelativeExposureBps);
    }

    function setQuarantined(address adapter, bool _quarantined)
        external
        onlyRoleOrRevert(DEFAULT_ADMIN_ROLE)
    {
        if (!isAdapter[adapter]) revert InvalidAdapter();
        quarantined[adapter] = _quarantined;
        adapterConsecutiveFailures[adapter] = 0;
    }

    function setDepositsDisabled(bool disabled) external onlyRoleOrRevert(DEFAULT_ADMIN_ROLE) {
        depositsDisabled = disabled;
        emit DepositsDisabledChanged(disabled);
    }

    function setAdapterDepositMode(address adapter, bool pushMode_)
        external
        onlyRoleOrRevert(DEFAULT_ADMIN_ROLE)
    {
        if (!isAdapter[adapter]) revert InvalidAdapter();
        pushDepositMode[adapter] = pushMode_;
        depositModeKnown[adapter] = true;
        emit AdapterDepositModeSet(adapter, pushMode_);
    }

    function callAdapterEmergencySweep(address adapter)
        external
        onlyRoleOrRevert(DEFAULT_ADMIN_ROLE)
    {
        if (!isAdapter[adapter]) revert InvalidAdapter();
        IAdapterEmergency(adapter).sweepIdleAssetToVault();
    }

    function callAdapterEmergencyPull(address adapter)
        external
        onlyRoleOrRevert(DEFAULT_ADMIN_ROLE)
    {
        if (!isAdapter[adapter]) revert InvalidAdapter();
        IAdapterEmergency(adapter).emergencyPullAllToVault();
    }

    function emergencyTransferToCore(uint256 amount)
        external
        onlyRoleOrRevert(DEFAULT_ADMIN_ROLE)
    {
        if (amount == 0) revert ZeroAmount();
        uint256 balance = ASSET.balanceOf(address(this));
        if (amount > balance) revert InsufficientBalance();
        ASSET.safeTransfer(core, amount);
        emit EmergencyTransferToCore(msg.sender, address(ASSET), amount, core);
    }

    function clearDegradedMode() external onlyRoleOrRevert(DEFAULT_ADMIN_ROLE) {
        if (!degradedModeActive) revert ParamOutOfRange(); // not degraded
        degradedModeActive = false;
        emit DegradedModeCleared(msg.sender, uint64(block.timestamp));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  KEEPER SETTERS
    // ══════════════════════════════════════════════════════════════════════

    function setRegime(uint8 _regime) external onlyRoleOrRevert(KEEPER_ROLE) {
        if (!(_regime <= 2)) revert ParamOutOfRange(); // "invalid regime"
        currentRegime = _regime;
        emit RegimeChanged(_regime);
    }

    // ══════════════════════════════════════════════════════════════════════
    //  P0.7 — SAFETY ADAPTER CAP TIER (2026-06-11)
    //  Governance setters + helper view.
    //  Ref: docs/SAFETY_ADAPTER_TIER.md, memory.md sessione 13.
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Set the max-idle threshold above which the safety overflow path activates.
    /// @param _bps bps of TVL. 0 disables overflow. Max 2000 (20%).
    function setMaxIdleBps(uint16 _bps)
        external
        onlyRoleOrRevert(DEFAULT_ADMIN_ROLE)
    {
        if (_bps > 2000) revert ParamOutOfRange();
        emit MaxIdleBpsUpdated(maxIdleBps, _bps);
        maxIdleBps = _bps;
    }

    /// @notice Set the target safety margin applied when abs/rel cap binds in target_allocations.
    /// @param _bps bps. 0 disables margin (legacy). Max 2000 (20%).
    function setTargetSafetyMargin(uint16 _bps)
        external
        onlyRoleOrRevert(DEFAULT_ADMIN_ROLE)
    {
        if (_bps > 2000) revert ParamOutOfRange();
        emit TargetSafetyMarginUpdated(targetSafetyMarginBps, _bps);
        targetSafetyMarginBps = _bps;
    }

    /// @notice Set the per-adapter cooldown after a rel-cap mandate fires.
    /// @param _seconds seconds. 0 disables cooldown. Max 30 days.
    function setMandateRedeployCooldown(uint32 _seconds)
        external
        onlyRoleOrRevert(DEFAULT_ADMIN_ROLE)
    {
        if (_seconds > 30 days) revert ParamOutOfRange();
        emit MandateRedeployCooldownUpdated(mandateRedeployCooldownSeconds, _seconds);
        mandateRedeployCooldownSeconds = _seconds;
    }

    /// @notice Add an adapter to the ordered safety-fallback list with its dedicated caps.
    /// @dev Reverts if adapter is already in the list. Requires absCapBps > 0 (the
    ///      canonical "is safety adapter" predicate). relCapBps may be 0, which means
    ///      "safety adapter without explicit rel cap override — use dynamic rel cap".
    /// @param adapter Adapter address. Must be registered and currently enabled.
    /// @param absCapBps Fallback absolute cap, 1..8000 (0.01%..80% of strategy TVL).
    /// @param relCapBps Fallback relative cap, 0..10000 (0%..100% of adapter extTVL).
    function addSafetyFallbackAdapter(
        address adapter,
        uint16 absCapBps,
        uint16 relCapBps
    ) external onlyRoleOrRevert(DEFAULT_ADMIN_ROLE) {
        if (adapter == address(0)) revert ZeroAddress();
        if (!isAdapter[adapter]) revert InvalidAdapter();
        if (!enabled[adapter]) revert AdapterNotEnabled();
        // P0.7 (post-audit L-01 fix 2026-06-12) -- Quarantined adapters must not be
        // promoted to safety. Quarantine is the protocol's circuit breaker for
        // adapters with consecutive operational failures; bypassing it via safety
        // promotion would defeat the failure-isolation purpose.
        if (quarantined[adapter]) revert InvalidAdapter();
        if (absCapBps == 0 || absCapBps > 8000) revert InvalidFallbackCap();
        if (relCapBps > 10000) revert InvalidFallbackCap();
        if (safetyFallback[adapter].absCapBps != 0) revert AlreadySafetyFallback();

        // P0.7 (post-audit H-03 fix 2026-06-12) — Clear any active mandate cooldown
        // on promotion. Governance-trusted override: the promotion signal supersedes
        // accumulated mandate state. Without this, a recently-mandated adapter would
        // retain its dormant cooldown timestamp; if later demoted via
        // removeSafetyFallbackAdapter, the cooldown would reactivate retroactively.
        uint64 priorMandateTs = lastRelCapMandateTs[adapter];
        if (priorMandateTs != 0) {
            delete lastRelCapMandateTs[adapter];
            emit RelCapMandateCooldownCleared(adapter, msg.sender, priorMandateTs);
        }

        safetyFallback[adapter] = SafetyFallback({
            absCapBps: absCapBps,
            relCapBps: relCapBps
        });
        safetyFallbackAdapters.push(adapter);
        emit SafetyFallbackAdapterAdded(adapter, absCapBps, relCapBps);
    }

    /// @notice Update the fallback caps of an already-registered safety adapter.
    /// @param adapter Adapter address. Must already be a safety fallback.
    /// @param absCapBps New absolute fallback cap, 1..8000.
    /// @param relCapBps New relative fallback cap, 0..10000.
    function updateSafetyFallbackCaps(
        address adapter,
        uint16 absCapBps,
        uint16 relCapBps
    ) external onlyRoleOrRevert(DEFAULT_ADMIN_ROLE) {
        SafetyFallback storage sf = safetyFallback[adapter];
        if (sf.absCapBps == 0) revert NotSafetyFallback();
        if (absCapBps == 0 || absCapBps > 8000) revert InvalidFallbackCap();
        if (relCapBps > 10000) revert InvalidFallbackCap();

        emit SafetyFallbackCapsUpdated(
            adapter, sf.absCapBps, absCapBps, sf.relCapBps, relCapBps
        );
        sf.absCapBps = absCapBps;
        sf.relCapBps = relCapBps;
    }

    /// @notice Remove an adapter from the safety-fallback list. Position is preserved
    ///         on-chain — only the cap tier override is dropped, after which normal
    ///         caps apply again.
    function removeSafetyFallbackAdapter(address adapter)
        external
        onlyRoleOrRevert(DEFAULT_ADMIN_ROLE)
    {
        if (safetyFallback[adapter].absCapBps == 0) revert NotSafetyFallback();

        // Compact-remove from array (swap-pop pattern).
        uint256 len = safetyFallbackAdapters.length;
        for (uint256 i = 0; i < len; i++) {
            if (safetyFallbackAdapters[i] == adapter) {
                if (i != len - 1) {
                    safetyFallbackAdapters[i] = safetyFallbackAdapters[len - 1];
                }
                safetyFallbackAdapters.pop();
                break;
            }
        }
        delete safetyFallback[adapter];
        emit SafetyFallbackAdapterRemoved(adapter);
    }

    /// @notice Canonical predicate: is this adapter currently a safety fallback?
    /// @dev safetyFallback[a].absCapBps != 0 is the on-chain marker; relCapBps == 0
    ///      is a valid configuration (rel cap defaults to dynamic).
    function isSafetyFallbackAdapter(address adapter) public view returns (bool) {
        return safetyFallback[adapter].absCapBps != 0;
    }

    /// @notice Length of the ordered safety-fallback list. Useful for off-chain
    ///         iteration without manual storage probing.
    function safetyFallbackAdaptersLength() external view returns (uint256) {
        return safetyFallbackAdapters.length;
    }

    // ══════════════════════════════════════════════════════════════════════
    //  INTERNAL HELPERS
    // ══════════════════════════════════════════════════════════════════════

    function _isBootstrapActive() internal view returns (bool) {
        return bootstrapEndsAt > 0 && block.timestamp < bootstrapEndsAt;
    }
}
