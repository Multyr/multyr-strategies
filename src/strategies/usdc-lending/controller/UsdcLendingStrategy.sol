// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title UsdcMultiLendingVault
 * @notice Non-custodial, multi-adapter USDC lending strategy for Arbitrum One.
 *         Designed for exclusive use by a CoreAggregatorVault. All investor-facing logic is external.
 *         Implements strict "no cash" invariant, role-based access, pausable escape hatch, and secure adapter registry.
 * @dev    No direct user interaction. No fees, no ETH, no upgradeability. OpenZeppelin v5+ dependencies.
 *         Scoring/allocation logic delegated to StrategyScoringModule via delegatecall.
 */

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ILendingAdapter, IAdapterEmergency } from "../interfaces/ILendingAdapter.sol";
import { StrategyStorageLayout, Unauthorized, Frozen, InvalidAdapter, ZeroAddress, InvalidAsset, AssetMismatch, AdapterFlaggedIncrement, InvalidInput, RebalanceCooldown, InsufficientAdapters, MoveTooSmall, GateNotMet, NoCashInvariant, Overflow, DepositsDisabled, DeployIdleCooldown, BootstrapIdleTooHigh, DurationTooLong, BackfillTooLarge, QueryFailed, DepositModeNotSet, WeightsSumInvalid, MinAdaptersTooLow, RiskScoreTooHigh, BootstrapInactive, ZeroAmount, InsufficientBalance, ScoringDelegateFailed, DegradedViews, InvalidModule } from "./StrategyStorageLayout.sol";

// -----------------------------
//         CONTRACT
// -----------------------------

contract UsdcMultiLendingVault is StrategyStorageLayout {
    using SafeERC20 for IERC20Metadata;

    // -----------------------------
    //         STRUCTS
    // -----------------------------

    struct StrategyInitParams {
        // Allocation
        uint16 maxAdaptersPerAllocation;
        uint16 minAdaptersActive;
        // Rebalance
        uint16 rebalanceMinMoveBps;
        uint32 minSecondsBetweenRebalances;
        uint16 driftToleranceBps;
        // Weights
        uint16 wAPY;
        uint16 wLiq;
        uint16 wRisk;
        uint16 wStability;
        uint16 wIncentive;
        // Decay
        uint32 incentiveDecayHalfLife;
        // Exposure
        uint16 adapterMaxExposureBps;
        uint16 newAdapterRampBps;
        // Gate
        uint16 gateHorizonDays;
        uint16 gateMinNetBenefitBps;
        uint16 slippageBpsEstimate;
        uint16 withdrawalSpreadBpsEstimate;
        uint256 gasCostUSDC;
        // Harvest
        uint16 harvestThresholdBps;
        uint32 minSecondsBetweenHarvests;
        // Dust
        uint256 dustTolerance;
        // Stability EMA period
        uint16 stabilityEMAPeriod;
        // CTO Hardening params
        uint256 minNewAdapterSeed;
        uint64 newAdapterRampDuration;
        uint16 maxIdleAfterDepositBps;
        uint16 maxIdleBootstrapBps;
        uint16 degradedViewThresholdBps;
        uint32 failureDecaySeconds;
        uint32 minSecondsBetweenDeployIdle;
        uint64 bootstrapDuration;
        // V9.1 CTO: External TVL confidence
        uint16 maxRelativeExposureBps; // e.g., 1000 (10% of external market TVL)
        uint32 externalTVLStalenessSeconds; // e.g., 43200 (12h)
    }

    // -----------------------------
    //         ADDITIONAL MODIFIERS (strategy-only)
    // -----------------------------

    /// @notice Modifier for adapter management - accepts DEFAULT_ADMIN_ROLE or BOOTSTRAP_ROLE
    /// @dev BOOTSTRAP_ROLE is one-shot and renounced after bootstrapper.bootstrap()
    modifier onlyAdminOrBootstrap() {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(BOOTSTRAP_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        _;
    }

    modifier onlyKeeperOrCore() {
        if (!hasRole(KEEPER_ROLE, msg.sender) && !hasRole(CORE_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        _;
    }

    modifier noCashInvariant() {
        _;
        uint256 idle = idleCash();
        if (idle > dustTolerance) revert NoCashInvariant();
    }

    // -----------------------------
    //         CONSTRUCTOR
    // -----------------------------

    /**
     * @notice Deploys the vault with NO privileged deployer.
     * @param asset_ USDC token address (IERC20Metadata, Arbitrum One native)
     * @param _core CoreAggregatorVault address (granted CORE_ROLE)
     * @param _router StrategyRouter address (granted CORE_ROLE for deposit/withdraw)
     * @param _rootTimelock ROOT_TIMELOCK address (granted DEFAULT_ADMIN_ROLE + PARAM_ROLE)
     * @param _guardian SAFE_GUARDIAN address (granted KEEPER_ROLE for backup)
     * @param _bootstrapper StrategyBootstrapper address (granted BOOTSTRAP_ROLE for adapter registration)
     * @param _paramsModule StrategyParamsModule address (delegatecall target)
     * @param _scoringModule StrategyScoringModule address (delegatecall target)
     * @param params Initial strategy parameters (see struct below)
     * @dev SECURITY: Deployer receives NO roles. All admin roles go directly to ROOT_TIMELOCK.
     *      Bootstrapper receives BOOTSTRAP_ROLE only (not admin) for one-shot adapter registration.
     *      After bootstrapper.bootstrap() is called, BOOTSTRAP_ROLE is renounced permanently.
     */
    constructor(
        address asset_,
        address _core,
        address _router,
        address _rootTimelock,
        address _guardian,
        address _bootstrapper,
        address _paramsModule,
        address _scoringModule,
        address _adapterOpsModule,
        address _rebalanceGateModule,
        StrategyInitParams memory params
    ) StrategyStorageLayout(asset_, _core, _paramsModule, _scoringModule, _adapterOpsModule) {
        if (asset_ == address(0) || _core == address(0)) revert ZeroAddress();
        if (_router == address(0)) revert ZeroAddress();
        if (_rootTimelock == address(0)) revert ZeroAddress();
        if (_paramsModule == address(0)) revert ZeroAddress();
        if (_rebalanceGateModule == address(0)) revert ZeroAddress();
        if (_rebalanceGateModule.code.length == 0) revert InvalidModule();
        // V10: Set-once gate module address (no public setter)
        rebalanceGateModule_addr = _rebalanceGateModule;
        emit RebalanceGateModuleSet(_rebalanceGateModule);
        // Enforce Arbitrum native USDC
        if (asset_ != 0xaf88d065e77c8cC2239327C5EDb3A432268e5831) revert InvalidAsset();

        // SECURITY: All admin roles go DIRECTLY to ROOT_TIMELOCK
        // Deployer (msg.sender) receives NOTHING - eliminates "privileged deployer" finding
        _grantRole(DEFAULT_ADMIN_ROLE, _rootTimelock);
        _grantRole(PARAM_ROLE, _rootTimelock);
        _grantRole(CORE_ROLE, _core);
        _grantRole(CORE_ROLE, _router); // StrategyRouter needs CORE_ROLE for deposit/withdraw

        // Guardian gets KEEPER_ROLE for emergency backup operations
        if (_guardian != address(0)) {
            _grantRole(KEEPER_ROLE, _guardian);
        }

        // Bootstrapper gets BOOTSTRAP_ROLE for one-shot adapter registration
        // After bootstrap() is called, this role is renounced permanently
        if (_bootstrapper != address(0)) {
            _grantRole(BOOTSTRAP_ROLE, _bootstrapper);
        }

        // Range guards
        if (params.bootstrapDuration > MAX_BOOTSTRAP_DURATION) revert DurationTooLong();
        if (params.newAdapterRampDuration > MAX_RAMP_DURATION) revert DurationTooLong();

        // P1.1 coherence check: if idle cap > ramp can cover AND no bootstrap relief,
        // deposit-idle-deploy will brick (cant find target adapter).
        // Formula: maxIdleAfterDepositBps must NOT exceed newAdapterRampBps * maxAdaptersPerAllocation,
        // unless bootstrap mode is active (gives gov manual escape).
        {
            uint256 rampCoverageBps = uint256(params.newAdapterRampBps) * uint256(params.maxAdaptersPerAllocation);
            bool noBootstrap = (params.bootstrapDuration == 0 && params.maxIdleBootstrapBps == 0);
            if (noBootstrap && uint256(params.maxIdleAfterDepositBps) > rampCoverageBps) {
                revert InvalidInput();
            }
        }
        // Set initial parameters
        _setStrategyParams(params);

        // Bootstrap mode
        if (params.bootstrapDuration > 0) {
            bootstrapEndsAt = uint64(block.timestamp) + params.bootstrapDuration;
        }

        // Quarantine defaults
        adapterQuarantineThreshold = 10; // V9.1 CTO: raised for retry tolerance

        // No adapters at deployment - will be registered via bootstrapper
    }

    // -----------------------------
    //         ROLE ADMIN OVERRIDES
    // -----------------------------

    function grantRole(bytes32 role, address account) public override rolesNotFrozen {
        super.grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) public override rolesNotFrozen {
        super.revokeRole(role, account);
    }

    function renounceRole(bytes32 role, address account) public override rolesNotFrozen {
        super.renounceRole(role, account);
    }

    // -----------------------------
    //         PARAMETER SETTERS (PARAM_ROLE) — internal only, used by constructor
    // -----------------------------

    function _setStrategyParams(StrategyInitParams memory params) internal {
        // Allocation
        maxAdaptersPerAllocation = params.maxAdaptersPerAllocation;
        minAdaptersActive = params.minAdaptersActive;
        // Rebalance
        rebalanceMinMoveBps = params.rebalanceMinMoveBps;
        minSecondsBetweenRebalances = params.minSecondsBetweenRebalances;
        driftToleranceBps = params.driftToleranceBps;
        // Weights
        wAPY = params.wAPY;
        wLiq = params.wLiq;
        wRisk = params.wRisk;
        wStability = params.wStability;
        wIncentive = params.wIncentive;
        // Decay
        incentiveDecayHalfLife = params.incentiveDecayHalfLife;
        // Exposure
        adapterMaxExposureBps = params.adapterMaxExposureBps;
        newAdapterRampBps = params.newAdapterRampBps;
        // Gate
        gateHorizonDays = params.gateHorizonDays;
        gateMinNetBenefitBps = params.gateMinNetBenefitBps;
        slippageBpsEstimate = params.slippageBpsEstimate;
        withdrawalSpreadBpsEstimate = params.withdrawalSpreadBpsEstimate;
        gasCostUSDC = params.gasCostUSDC;
        // Harvest
        harvestThresholdBps = params.harvestThresholdBps;
        minSecondsBetweenHarvests = params.minSecondsBetweenHarvests;
        // Dust
        dustTolerance = params.dustTolerance;
        // Stability EMA
        stabilityEMAPeriod = params.stabilityEMAPeriod;
        // V9.2 CTO: Stability EMA live tracking defaults
        apyFloorBps = 50;                        // denominator floor
        minStabilityUpdateInterval = 6 hours;    // min interval between updates
        // CTO Hardening
        minNewAdapterSeed = params.minNewAdapterSeed;
        newAdapterRampDuration = params.newAdapterRampDuration;
        maxIdleAfterDepositBps = params.maxIdleAfterDepositBps;
        maxIdleBootstrapBps = params.maxIdleBootstrapBps;
        degradedViewThresholdBps = params.degradedViewThresholdBps;
        failureDecaySeconds = params.failureDecaySeconds;
        minSecondsBetweenDeployIdle = params.minSecondsBetweenDeployIdle;
        // V9.1 CTO: External TVL confidence
        maxRelativeExposureBps = params.maxRelativeExposureBps;
        externalTVLStalenessSeconds = params.externalTVLStalenessSeconds;
    }

    // -- Delegatecall relay selectors (F-SIZE-02)
    bytes4 private constant CHECK_EMIT_DEGRADED_SEL = bytes4(keccak256("checkAndEmitDegradedViews()"));
    bytes4 private constant CHECK_DEGRADED_LOCAL_SEL = bytes4(keccak256("checkDegradedModeLocally()"));
    bytes4 private constant REALIZE_LIQUIDITY_SEL    = bytes4(keccak256("executeRealizeLiquidity(uint256)"));

    /// @notice Set the StrategyRebalancePlanModule address (write-once).
    /// @dev    Architectural completion: planModule has prepareRebalance/
    ///         executeRebalanceStep/cancelRebalancePlan that vault routes via fallback.
    ///         Must be called BEFORE finalizeParameters. Set-once via require.
    function setRebalancePlanModule(address _planModule) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (rebalancePlanModule_addr != address(0) || _planModule == address(0)) revert InvalidModule();
        rebalancePlanModule_addr = _planModule;
        emit RebalancePlanModuleSet(_planModule);
    }

    function setSettingsModule(address _settingsModule) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (settingsModule_addr != address(0) || _settingsModule == address(0)) revert InvalidModule();
        settingsModule_addr = _settingsModule;
        emit SettingsModuleSet(_settingsModule);
    }

    function setAllocCalcModule(address _allocCalcModule) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (allocCalcModule_addr != address(0) || _allocCalcModule == address(0)) revert InvalidModule();
        allocCalcModule_addr = _allocCalcModule;
        emit AllocCalcModuleSet(_allocCalcModule);
    }

    function isBootstrapActive() public view returns (bool) {
        return bootstrapEndsAt > 0 && block.timestamp < bootstrapEndsAt;
    }

    // -----------------------------
    //         ADAPTER REGISTRY (ADMIN)
    // -----------------------------

    /**
     * @notice Add a new lending adapter. Only DEFAULT_ADMIN_ROLE.
     * @param adapter Adapter address
     * @dev Requirements:
     *      - Adapter must be configured with `vault` equal to this strategy address.
     *        Otherwise adapter calls guarded by `onlyVault` will revert and/or funds
     *        on withdraw will not be returned to this strategy.
     *      - Adapter `underlying()` must equal `ASSET` (USDC native on Arbitrum).
     *      - Adapter must implement isPushMode() to auto-configure deposit mode.
     */
    function addAdapter(address adapter) external onlyAdminOrBootstrap {
        if (adapter == address(0)) revert ZeroAddress();
        if (isAdapter[adapter]) revert InvalidAdapter();
        // Audit HIGH 2.3 — explicit whitelist enforcement (underlying check alone
        // cannot prevent a malicious adapter from matching asset type).
        if (!whitelistedAdapters[adapter]) revert InvalidAdapter();
        if (adapter.code.length == 0) revert InvalidAdapter();
        if (ILendingAdapter(adapter).underlying() != address(ASSET)) revert AssetMismatch();

        adapters.push(adapter);
        isAdapter[adapter] = true;
        enabled[adapter] = false; // must be enabled separately
        positionAssets[adapter] = 0;

        // Initialize scoring mappings with safe defaults
        // V9.2: stabilityEMA is a stability score [0-10000], NOT an APY value.
        // Initialize to DEFAULT_STABILITY_BPS (neutral). The live EMA update in
        // _pokeLiquidity() will adjust it based on observed APY volatility.
        stabilityEMA[adapter] = DEFAULT_STABILITY_BPS;
        // riskScoreBps: 0 = lowest risk (neutral default)
        riskScoreBps[adapter] = 0;

        // AUTO-CONFIGURE DEPOSIT MODE from adapter's isPushMode()
        // Per CTO directive: deposit mode must be deterministic at deploy-time
        // Euler adapters return true (PUSH), all others return false (PULL)
        pushDepositMode[adapter] = ILendingAdapter(adapter).isPushMode();
        depositModeKnown[adapter] = true;

        emit AdapterAdded(adapter);
        emit AdapterDepositModeSet(adapter, pushDepositMode[adapter]);
    }

    /**
     * @notice Enable or disable an adapter. Only DEFAULT_ADMIN_ROLE.
     * @param adapter Adapter address
     * @param on      True to enable, false to disable
     */
    function toggleAdapter(address adapter, bool on) external onlyAdminOrBootstrap {
        if (!isAdapter[adapter]) revert InvalidAdapter();
        enabled[adapter] = on;
        if (on && adapterActivatedAt[adapter] == 0) {
            uint64 ts = uint64(block.timestamp);
            adapterActivatedAt[adapter] = ts;
            emit AdapterActivated(adapter, ts);
        }
        emit AdapterToggled(adapter, on);
    }

    // -----------------------------
    //         PAUSABLE
    // -----------------------------

    /**
     * @notice Pause vault (escape hatch). Only DEFAULT_ADMIN_ROLE.
     *         Only withdrawToCore and emergencyRecallAll remain enabled.
     */
    function pause() external onlyRoleOrRevert(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause vault. Only DEFAULT_ADMIN_ROLE.
     */
    function unpause() external onlyRoleOrRevert(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // -----------------------------
    //         SCORING MODULE DELEGATECALL HELPER
    // -----------------------------

    function _delegateToScoring(bytes memory data) internal returns (bytes memory) {
        (bool ok, bytes memory result) = scoringModule.delegatecall(data);
        if (!ok) {
            if (result.length > 0) {
                assembly { revert(add(result, 32), mload(result)) }
            }
            revert ScoringDelegateFailed();
        }
        return result;
    }

    // -----------------------------
    //         CORE ⇄ STRATEGY (CORE_ROLE)
    // -----------------------------

    /**
     * @notice Deposit USDC from Core. Allocates immediately to adapters.
     * @param assets Amount of USDC (must be > 0)
     * @dev    Only callable by Core. "No cash": idle ≤ dustTolerance after.
     */
    function deposit(uint256 assets)
        external
        nonReentrant
        onlyCore
        whenNotPaused
        returns (uint256)
    {
        if (depositsDisabled) revert DepositsDisabled();

        (bool degraded, uint16 fallbackBps) = _checkAndEmitDegradedViews();
        if (degraded) revert DegradedViews();

        if (assets < 1) revert InvalidInput(); // slither: incorrect-equality - use < 1 instead of == 0

        if (isBootstrapActive()) {
            _delegateToScoring(abi.encodeWithSelector(bytes4(keccak256("deployIdleToAdapters(uint256,bool)")), assets, true));
            uint256 idle = idleCash();
            if (idle > dustTolerance) {
                emit IdleCashRemaining(idle, dustTolerance);
            }
            uint256 tvlAfter = totalAssets();
            uint256 maxIdle = (uint256(maxIdleBootstrapBps) * tvlAfter) / 1e4;
            if (maxIdle < dustTolerance) maxIdle = dustTolerance;
            if (idle > maxIdle) revert BootstrapIdleTooHigh();
        } else {
            uint256 tvlBefore = totalAssets();
            // DegradedMode auto-update: if majority of adapters ineligible or failure velocity hit,
            // accept deposit but skip auto-deployIdle (capital preserved in idle reserve).
            // See docs/TIER_MODEL.md Section 6. Cleared by governance via clearDegradedMode().
            if (!degradedModeActive) {
                string memory degradedReason = _checkDegradedModeLocally();
                if (bytes(degradedReason).length > 0) {
                    degradedModeActive = true;
                    degradedModeEnteredAt = uint64(block.timestamp);
                    emit DegradedModeEntered(degradedReason, uint64(block.timestamp));
                }
            }
            if (degradedModeActive) {
                return assets; // capital stays idle — NoCashInvariant intentionally skipped
            }
            _delegateToScoring(abi.encodeWithSelector(bytes4(keccak256("deployIdleToAdapters(uint256,bool)")), assets, false));
            uint256 idle = idleCash();
            uint256 tvlTarget = tvlBefore + assets;
            uint256 maxIdle = (uint256(maxIdleAfterDepositBps) * tvlTarget) / 1e4;
            if (maxIdle < dustTolerance) maxIdle = dustTolerance;
            if (idle > maxIdle) revert NoCashInvariant();
        }

        return assets;
    }

    /**
     * @notice Withdraw USDC to Core (or receiver). Realizes liquidity pro-rata if needed.
     * @param assets   Amount of USDC (must be > 0)
     * @param receiver Receiver address (must not be zero)
     * @dev    Only callable by Core. Leaves at most dust idle.
     */
    function withdraw(uint256 assets, address receiver)
        external
        nonReentrant
        onlyCore
        whenNotPaused
        returns (uint256 withdrawn)
    {
        if (assets < 1 || receiver == address(0)) revert InvalidInput(); // slither: incorrect-equality - use < 1 instead of == 0

        uint256 idle = idleCash();
        if (idle < assets) {
            // Realize liquidity pro-rata from adapters
            _realizeLiquidity(assets - idle);
            idle = idleCash();
        }
        if (idle < assets) assets = idle; // in case adapters couldn't provide full amount

        ASSET.safeTransfer(receiver, assets);
        withdrawn = assets;

        // Best-effort re-deploy: user path must not revert for broken adapter.
        // idle - assets (not another idleCash() call): USDC has no transfer
        // fee/rebase, so the post-transfer balance is exactly derivable from
        // the pre-transfer `idle` local, saving 2 redundant external
        // ASSET.balanceOf calls on every withdrawal that leaves idle > dust.
        uint256 idleAfter = idle - assets;
        if (idleAfter > dustTolerance) {
            _delegateToScoring(abi.encodeWithSelector(bytes4(keccak256("deployIdleToAdapters(uint256,bool)")), idleAfter, true));
        }
    }

    /**
     * @notice Withdraw with explicit shortfall semantics.
     * @param assets             USDC to withdraw
     * @param receiver           Recipient
     * @param revertOnShortfall  If true, reverts when adapters can't deliver `assets`.
     *                           If false, behaves like the 2-arg overload (returns realized amount).
     * @dev Cascade fix P1.5 — supports tests expecting strict-failure semantics.
     */
    function withdraw(uint256 assets, address receiver, bool revertOnShortfall)
        external
        nonReentrant
        onlyCore
        whenNotPaused
        returns (uint256 withdrawn)
    {
        if (assets < 1 || receiver == address(0)) revert InvalidInput();

        uint256 idle = idleCash();
        if (idle < assets) {
            _realizeLiquidity(assets - idle);
            idle = idleCash();
        }
        if (idle < assets) {
            if (revertOnShortfall) revert InsufficientBalance();
            assets = idle;
        }

        ASSET.safeTransfer(receiver, assets);
        withdrawn = assets;

        // See the 2-arg withdraw() above for why this avoids a second
        // idleCash() external call.
        uint256 idleAfter = idle - assets;
        if (idleAfter > dustTolerance) {
            _delegateToScoring(abi.encodeWithSelector(bytes4(keccak256("deployIdleToAdapters(uint256,bool)")), idleAfter, true));
        }
    }

    // -----------------------------
    //         REALIZE LIQUIDITY (KEEPER_ROLE or CORE_ROLE)
    // -----------------------------

    /**
     * @notice Realize liquidity pro-rata from enabled adapters.
     * @param amountNeeded Amount of USDC to realize
     * @dev    Only KEEPER_ROLE or CORE_ROLE. Funds stay in vault (not sent to third parties).
     */
    function realizeLiquidity(uint256 amountNeeded)
        external
        nonReentrant
        onlyKeeperOrCore
        whenNotPaused
    {
        _realizeLiquidity(amountNeeded);
    }

    function _realizeLiquidity(uint256 amountNeeded) internal {
        (bool ok, bytes memory ret) = adapterOpsModule.delegatecall(
            abi.encodeWithSelector(REALIZE_LIQUIDITY_SEL, amountNeeded)
        );
        if (!ok && ret.length > 0) assembly { revert(add(ret, 0x20), mload(ret)) }
    }

    // -----------------------------
    //         HARVEST (KEEPER_ROLE)
    // -----------------------------

    /**
     * @notice Harvest yield from adapters, auto-deploys idle.
     * @dev    Only KEEPER_ROLE. "No cash": idle ≤ dustTolerance after.
     */
    function harvest() external nonReentrant onlyRoleOrRevert(KEEPER_ROLE) whenNotPaused {
        (bool degraded,) = _checkAndEmitDegradedViews();
        if (degraded) revert DegradedViews();

        uint256 adaptersTouched = 0;
        uint256 totalRealized = 0;
        uint256 n = adapters.length;

        for (uint256 i = 0; i < n; ++i) {
            address adapter = adapters[i];
            if (!enabled[adapter]) continue;
            try ILendingAdapter(adapter).harvestableProfit() returns (uint256 profit) {
                if (profit > 0) {
                    try ILendingAdapter(adapter).harvest(address(this)) returns (uint256 realized) {
                        totalRealized += realized;
                        adaptersTouched++;
                        _recordAdapterSuccess(adapter);
                    } catch (bytes memory reason) {
                        emit AdapterHarvestFailed(adapter, reason);
                        _recordAdapterFailure(adapter);
                    }
                }
            } catch (bytes memory reason) {
                emit AdapterHarvestFailed(adapter, reason);
                _recordAdapterFailure(adapter);
            }
        }
        lastHarvestTs = uint64(block.timestamp);

        // Auto-deploy idle (best-effort: don't block harvest if adapter deposit fails)
        uint256 idle = idleCash();
        if (idle > dustTolerance) {
            _delegateToScoring(abi.encodeWithSelector(bytes4(keccak256("deployIdleToAdapters(uint256,bool)")), idle, true));
        }
        // Explicit degraded-state signal (replaces noCashInvariant)
        uint256 remainingIdle = idleCash();
        if (remainingIdle > dustTolerance) {
            emit IdleCashRemaining(remainingIdle, dustTolerance);
        }
        emit Harvest(totalRealized, adaptersTouched);
    }

    // pokeExternalTVL() → delegated to StrategyParamsModule via fallback
    // deployIdle() → delegated to StrategyScoringModule via fallback
    // rebalance() → delegated to StrategyScoringModule via fallback

    /**
     * @notice Harvest yield from adapters and send directly to receiver (Core). IStrategyVault-compatible.
     * @param receiver Target address to receive realized USDC (e.g., Core vault)
     * @return realized Total USDC sent to receiver across adapters
     * @dev    Only Core. Does not redeploy idle; funds are transferred out to receiver.
     */
    function harvest(address receiver)
        external
        nonReentrant
        onlyCore
        whenNotPaused
        returns (uint256 realized)
    {
        if (receiver == address(0)) revert ZeroAddress();
        realized = 0; // Initialize return variable (slither: uninitialized-local)
        uint256 adaptersTouched = 0;
        uint256 n = adapters.length;

        for (uint256 i = 0; i < n; ++i) {
            address adapter = adapters[i];
            if (!enabled[adapter]) continue;
            try ILendingAdapter(adapter).harvestableProfit() returns (uint256 profit) {
                if (profit > 0) {
                    try ILendingAdapter(adapter).harvest(receiver) returns (uint256 got) {
                        realized += got;
                        adaptersTouched++;
                        _recordAdapterSuccess(adapter);
                    } catch (bytes memory reason) {
                        emit AdapterHarvestFailed(adapter, reason);
                        _recordAdapterFailure(adapter);
                    }
                }
            } catch (bytes memory reason) {
                emit AdapterHarvestFailed(adapter, reason);
                _recordAdapterFailure(adapter);
            }
        }
        lastHarvestTs = uint64(block.timestamp);

        emit Harvest(realized, adaptersTouched);
    }

    // -----------------------------
    //         EMERGENCY
    // -----------------------------

    /**
     * @notice Emergency recall: withdraw all from all adapters (even flagged/disabled).
     * @dev    Only DEFAULT_ADMIN_ROLE or CORE_ROLE. Idle may exceed dustTolerance after.
     */
    function emergencyRecallAll() external nonReentrant {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(CORE_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        uint256 totalRecalled = 0;
        uint256 n = adapters.length;
        unchecked {
            for (uint256 i = 0; i < n; ++i) {
                address adapter = adapters[i];
                uint256 pos = positionAssets[adapter];
                if (pos < 1) continue; // slither: incorrect-equality - use < 1 instead of == 0
                try ILendingAdapter(adapter).withdraw(pos, address(this)) returns (
                    uint256 withdrawn
                ) {
                    positionAssets[adapter] -= withdrawn;
                    totalRecalled += withdrawn;
                } catch (bytes memory reason) {
                    emit AdapterWithdrawFailed(adapter, pos, reason);
                    // No auto-quarantine in emergency path — just continue
                }
            }
        }
        emit EmergencyRecalled(totalRecalled);
    }

    /**
     * @notice Selective recall: withdraw from a subset of adapters by address.
     * @dev    Only DEFAULT_ADMIN_ROLE. Per-adapter try/catch: failures don't block others.
     *         Each target must be a registered adapter (else InvalidAdapter).
     *         Emits SelectiveRecallExecuted with total realized USDC.
     */
    function selectiveRecall(address[] calldata targets) external nonReentrant {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert Unauthorized();
        // Reject empty array: avoids no-op gas waste + matches test invariant
        if (targets.length == 0) revert InvalidInput();
        uint256 totalRecalled = 0;
        uint256 n = targets.length;
        for (uint256 i = 0; i < n; ++i) {
            address adapter = targets[i];
            if (!isAdapter[adapter]) revert InvalidAdapter();
            uint256 pos = positionAssets[adapter];
            if (pos < 1) continue; // slither: incorrect-equality - use < 1 instead of == 0
            try ILendingAdapter(adapter).withdraw(pos, address(this)) returns (
                uint256 withdrawn
            ) {
                positionAssets[adapter] -= withdrawn;
                totalRecalled += withdrawn;
            } catch (bytes memory reason) {
                emit AdapterWithdrawFailed(adapter, pos, reason);
                // No auto-quarantine: this is a manual recall path. Caller
                // sets quarantine explicitly if needed.
            }
        }
        emit SelectiveRecallExecuted(targets, totalRecalled);
    }

    // -----------------------------
    //         INTERNAL: Adapter Failure Recording
    // -----------------------------

    /// @dev Increment failure counter with temporal decay; auto-quarantine if threshold reached.
    ///      V9.1: NO depositsDisabled cascade. Skip if already quarantined.
    function _recordAdapterFailure(address adapter) internal {
        if (quarantined[adapter]) return;
        uint64 lastFailTs = adapterLastFailureTs[adapter];
        if (
            failureDecaySeconds > 0 && lastFailTs > 0
                && block.timestamp - lastFailTs > failureDecaySeconds
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
        if (threshold > 0 && failures >= threshold && !quarantined[adapter]) {
            quarantined[adapter] = true;
            emit AdapterAutoQuarantined(adapter, failures);
            // V9.1 CTO: NO depositsDisabled cascade — admin only
        }
    }

    /// @dev Immediate quarantine for PUSH mode stranded funds.
    ///      V9.1: NO automatic depositsDisabled.
    // coverage-ignore: dead code — no in-tree caller; kept as defensive reserve
    function _recordAdapterFailureImmediate(address adapter) internal {
        if (quarantined[adapter]) return;
        quarantined[adapter] = true;
        emit AdapterAutoQuarantined(adapter, adapterConsecutiveFailures[adapter]);
        // V9.1 CTO: NO depositsDisabled cascade — admin only
    }

    /// @dev Reset failure counter on success.
    /// @dev Gradual success: decrement failure counter (not reset to 0).
    function _recordAdapterSuccess(address adapter) internal {
        if (adapterConsecutiveFailures[adapter] > 0) {
            adapterConsecutiveFailures[adapter]--;
        }
    }

    // -----------------------------
    //         INTERNAL: Safe Views
    // -----------------------------

    /// @dev Safe view: fallback to positionAssets (bookkeeping) if adapter reverts or returns malformed data.
    ///      Low-level staticcall + data.length >= 32 guard eliminates entire class of brick
    ///      from ABI return-data mismatch (e.g. adapter returns < 32 bytes → try/catch bypassed).
    // _safeTotalAssets, _safeWithdrawableAssets — inherited from StrategyStorageLayout.

    /// @dev Relay to StrategySafetyOverflowModule via delegatecall (F-SIZE-02).
    function _checkAndEmitDegradedViews() internal returns (bool degraded, uint16 bps) {
        (bool ok, bytes memory ret) = safetyOverflowModule_addr.delegatecall(
            abi.encodeWithSelector(CHECK_EMIT_DEGRADED_SEL)
        );
        if (!ok || ret.length == 0) return (false, 0);
        (degraded, bps) = abi.decode(ret, (bool, uint16));
    }

    // -----------------------------
    //     INTERNAL: DegradedMode detection (inline — accesses storage directly)
    // -----------------------------

    /// @dev Relay to StrategySafetyOverflowModule via delegatecall (F-SIZE-02).
    function _checkDegradedModeLocally() internal returns (string memory reason) {
        (bool ok, bytes memory ret) = safetyOverflowModule_addr.delegatecall(
            abi.encodeWithSelector(CHECK_DEGRADED_LOCAL_SEL)
        );
        if (!ok || ret.length == 0) return "";
        reason = abi.decode(ret, (string));
    }

    // -----------------------------
    //         INTERNAL: Enabled Adapters
    // -----------------------------

    // _enabledAdapters — inherited from StrategyStorageLayout.

    // -----------------------------
    //         VIEWS & DIAGNOSTICS
    // -----------------------------

    /// @notice Returns the USDC asset address.
    function asset() external view returns (address) {
        return address(ASSET);
    }

    /// @notice Returns total assets (idle + adapters). Never reverts — uses positionAssets fallback.
    function totalAssets() public view returns (uint256) {
        uint256 sum = ASSET.balanceOf(address(this));
        uint256 n = adapters.length;
        for (uint256 i = 0; i < n;) {
            sum += _safeTotalAssets(adapters[i]);
            unchecked {
                ++i;
            }
        }
        return sum;
    }

    /// @notice Returns withdrawable assets (idle + adapters' withdrawable). Never reverts.
    function withdrawableAssets() external view returns (uint256) {
        uint256 sum = ASSET.balanceOf(address(this));
        uint256 n = adapters.length;
        for (uint256 i = 0; i < n;) {
            sum += _safeWithdrawableAssets(adapters[i]);
            unchecked {
                ++i;
            }
        }
        return sum;
    }

    /// @notice Returns current internal positions.
    function positions() external view returns (address[] memory addrs, uint256[] memory assets) {
        uint256 n = adapters.length;
        addrs = new address[](n);
        assets = new uint256[](n);
        for (uint256 i = 0; i < n;) {
            address adapter = adapters[i];
            addrs[i] = adapter;
            assets[i] = positionAssets[adapter];
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Returns current idle USDC (not deployed).
    function idleCash() public view returns (uint256) {
        return ASSET.balanceOf(address(this));
    }

    /// @notice Returns true if idle USDC > dustTolerance.
    function hasIdleCash() external view returns (bool) {
        return idleCash() > dustTolerance;
    }

    /// @notice Returns true if harvest is possible (threshold or time).
    function canHarvest() external returns (bool, uint256, uint64) {
        address _mod = adapterOpsModule;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), _mod, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch success
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    // canRebalance() → delegated to StrategyScoringModule via fallback
    // effectiveMinNewAdapterSeed() → delegated to StrategyScoringModule via fallback
    // explainScore() / explainAllocation() → moved to StrategyExplainabilityLens (external read-only)

    // ── Coordination Hooks (preparatory, for future router-level integration) ──

    /// @notice Timestamp of last internal rebalance completion
    function lastInternalRebalanceTs() external view returns (uint64) {
        return lastRebalanceTs;
    }

    /// @notice True if multi-step rebalance plan is actively executing
    function isInternallyRebalancing() external view returns (bool) {
        return rebalancePlanPhase > 0;
    }

    /// @notice Weighted average liquidity across enabled adapters (10000 = fully liquid)
    function liquidityReadinessBps() external returns (uint16) {
        address _mod = adapterOpsModule;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), _mod, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch success
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    /// @notice Penalty signal: higher = "don't move capital now"
    function rebalancePenaltyBps() external returns (uint16) {
        address _mod = adapterOpsModule;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), _mod, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch success
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    // ── adapterCount (needed by StrategyExplainabilityLens) ──

    /// @notice Number of registered adapters (needed by external lens)
    function adapterCount() external view returns (uint256) {
        return adapters.length;
    }

    // -----------------------------
    //         INTERNAL: TVL
    // -----------------------------

    function _tvl() internal view override returns (uint256) {
        uint256 sum = idleCash();
        uint256 n = adapters.length;
        for (uint256 i = 0; i < n;) {
            sum += positionAssets[adapters[i]];
            unchecked {
                ++i;
            }
        }
        return sum;
    }

    // -----------------------------
    //         RECEIVE / FALLBACK (delegatecall router)
    // -----------------------------

    // coverage-ignore: ETH guard — identical pattern covered in all adapter tests
    receive() external payable {
        revert InvalidInput();
    }

    /// @notice Routes unrecognized selectors to modules via delegatecall.
    /// @dev    Order: scoring → gate → plan → adapterOps → params → settings (LAST).
    // AUDIT-FINDING-9 (HIGH): dispatcher must distinguish "selector not in this module"
    // (empty returndata → continue chain) from "semantic revert" (non-empty returndata →
    // propagate immediately). Previous pattern swallowed all semantic errors → InvalidInput().
    fallback() external payable {
        bool ok; bytes memory ret;
        address[6] memory mods = [
            address(scoringModule),
            rebalanceGateModule_addr,
            rebalancePlanModule_addr,
            adapterOpsModule,
            address(paramsModule),
            settingsModule_addr
        ];
        for (uint256 i = 0; i < 6; ++i) {
            if (mods[i] == address(0)) continue;
            (ok, ret) = mods[i].delegatecall(msg.data);
            if (ok) { assembly { return(add(ret, 32), mload(ret)) } }
            // Non-empty returndata = semantic revert → propagate immediately
            if (ret.length > 0) { assembly { revert(add(ret, 32), mload(ret)) } }
            // Empty returndata = selector not in this module → continue chain
        }
        revert InvalidInput();
    }
}
