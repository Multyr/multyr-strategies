// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ═══════════════════════════════════════════════════════════════════════════════
// DO NOT CHANGE ORDER — STORAGE LAYOUT CRITICAL
// ═══════════════════════════════════════════════════════════════════════════════
// This contract defines the SINGLE SOURCE OF TRUTH for storage layout.
// UsdcLendingStrategy, StrategyParamsModule, and StrategyScoringModule
// all inherit from this contract to guarantee identical slot alignment.
//
// The delegatecall pattern requires EXACT storage layout match between
// the strategy and its modules. Any mismatch silently corrupts state.
//
// NOTE: The onlyDelegateCall guard (_self pattern) is NOT proxy-compatible.
//       This is intentional — the system does not use proxy upgrades.
// ═══════════════════════════════════════════════════════════════════════════════

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Pausable } from "@openzeppelin/contracts/security/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ILendingAdapter } from "../interfaces/ILendingAdapter.sol";

// ── Structs ──────────────────────────────────────────────────────────────────

/// @notice Scoring result for one adapter — shared between ScoringModule and AllocCalcModule.
struct AdapterScore {
    address adapter;
    uint256 score;        // normalized [0, 1e4]
    uint256 apyBps;
    uint256 incentiveBps;
    uint256 liqBps;
    uint256 riskBps;
    uint256 stabilityBps;
}

// ── Enums ───────────────────────────────────────────────────────────────────

/// @notice Reason an adapter was skipped during allocation.
enum SkipReason {
    None,           // 0 — adapter was selected (not skipped)
    Flagged,        // 1 — adapter is flagged by admin
    LowConfidence,  // 2 — external TVL confidence = ZERO
    OverMaxCap,     // 3 — position >= adapterMaxExposureBps cap
    OverRelCap,     // 4 — position >= relative exposure cap
    ZeroHeadroom,   // 5 — headroom narrowed to zero after all caps
    QueryFailed_,   // 6 — maxCapacity() call reverted
    NotSelected     // 7 — adapter scored too low (exceeded maxAdapters limit)
}

// ── Shared errors ───────────────────────────────────────────────────────────
error Unauthorized();
error Frozen();
error InvalidAdapter();
error ZeroAddress();
error InvalidAsset();
error AssetMismatch();
error AdapterFlaggedIncrement();
error InvalidInput();
error RebalanceCooldown();
error InsufficientAdapters();
error MoveTooSmall();
error GateNotMet();
error NoCashInvariant();
error Overflow();
error DepositsDisabled();
error DeployIdleCooldown();
error BootstrapIdleTooHigh();
error DegradedViews();
error InvalidModule();
error DurationTooLong();
error BackfillTooLarge();
error QueryFailed();
error DepositModeNotSet();
error WeightsSumInvalid();
error MinAdaptersTooLow();
error RiskScoreTooHigh();
error BootstrapInactive();
error ZeroAmount();
error InsufficientBalance();
error ScoringDelegateFailed();
error PlanAlreadyActive();
error NoPlanActive();
error PlanExpired();
error PlanInvalidated();
error TooManyAdapters();
// === EIP-170 refactor (2026-04-22) — setter validation error (ParamsModule) ===
error ParamOutOfRange();
// === P0.7 — Safety Adapter Cap Tier (2026-06-11) — setter validation errors ===
error AlreadySafetyFallback();
error NotSafetyFallback();
error InvalidFallbackCap();
error AdapterNotEnabled();

contract StrategyStorageLayout is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20Metadata;

    // ── Constants (do NOT occupy storage slots) ─────────────────────────────

    bytes32 public constant PARAM_ROLE = keccak256("PARAM_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant CORE_ROLE = keccak256("CORE_ROLE");
    bytes32 public constant BOOTSTRAP_ROLE = keccak256("BOOTSTRAP_ROLE");

    string public constant name = "USDC Multi-Lending Strategy";
    string public constant description =
        "Maximizes USDC yield through automated multi-protocol lending. "
        "Funds are dynamically allocated across the most trusted protocols on Arbitrum "
        "with optimized exposure caps and automated rebalancing for max return.";

    uint64 public constant MAX_BOOTSTRAP_DURATION = uint64(30 days);
    uint64 public constant MAX_RAMP_DURATION = uint64(30 days);
    uint256 public constant MAX_BACKFILL = 64;

    // CTO decision (strategy hardening): hard cap on total active adapters.
    // Not raised to 20 — keeps gas bounded on iterating loops (pokeAPY, scoring,
    // prepareRebalance) and keeps quarantine threshold meaningful.
    uint8 public constant MAX_ADAPTERS = 10;

    // Audit HIGH 1.5/1.6 — delta limiter for external TVL and adapter capacity.
    uint32 public constant MAX_EXTERNAL_TVL_JUMP_BPS = 100000; // 10x per poke

    // V9.1 CTO: Safe defaults for unset scoring components
    uint256 public constant DEFAULT_STABILITY_BPS = 7000;
    uint256 public constant DEFAULT_RISK_BPS = 7000;
    uint256 public constant DEFAULT_LIQ_BPS = 5000; // safe fallback: 50% liquid

    // V9.1 CFO: External TVL confidence bands (market-level USDC TVL, risk multipliers, 10000 = 1.0x)
    // Bands calibrated on real Arbitrum USDC market depths — measures how protected
    // our capital is from liquidity risk in the external market.
    uint256 public constant CONFIDENCE_ZERO  = 0;     // < 100K — NO ALLOCATION (market too small)
    uint256 public constant CONFIDENCE_MICRO = 3000;  // 100K - 500K (micro-cap, dust only)
    uint256 public constant CONFIDENCE_SMALL = 5000;  // 500K - 2M (small-cap, cautious)
    uint256 public constant CONFIDENCE_LOW   = 7000;  // 2M - 10M (mid-cap, operational)
    uint256 public constant CONFIDENCE_MED   = 8500;  // 10M - 50M (established)
    uint256 public constant CONFIDENCE_HIGH  = 9500;  // 50M - 250M (major market)
    uint256 public constant CONFIDENCE_VHIGH = 10000; // > 250M (institutional)

    // Phase 1.5: EXT_TVL_PANIC — drop threshold and observation window
    uint16 internal constant EXT_TVL_PANIC_DROP_BPS   = 3000; // 30% drop triggers panic
    uint64 internal constant EXT_TVL_PANIC_WINDOW_SEC = 3600; // 1-hour observation window

    // V9.1 CTO: Allocation observability events
    event AdapterSkippedLowConfidence(address indexed adapter, uint256 cachedTVL, uint256 confidence);
    event AdapterSkippedOverCap(address indexed adapter, uint256 current, uint256 cap);
    event AdapterUsingStaleExternalTVL(address indexed adapter, uint256 cachedTVL, uint256 age);

    // ── Immutables (do NOT occupy storage slots) ────────────────────────────

    IERC20Metadata public immutable ASSET;
    address public immutable core;
    address public immutable paramsModule;
    address public immutable scoringModule;
    address public immutable adapterOpsModule;

    // ── Storage: Adapter Registry ───────────────────────────────────────────

    address[] public adapters;
    mapping(address => bool) public isAdapter;
    mapping(address => bool) public enabled;
    mapping(address => bool) public flagged;
    mapping(address => uint256) public positionAssets;
    mapping(address => bool) public pushDepositMode;
    mapping(address => bool) public depositModeKnown;

    // ── Storage: Parameters ─────────────────────────────────────────────────

    uint16 public maxAdaptersPerAllocation;
    uint16 public minAdaptersActive;

    uint16 public rebalanceMinMoveBps;
    uint32 public minSecondsBetweenRebalances;
    uint16 public driftToleranceBps;

    uint16 public wAPY;
    uint16 public wLiq;
    uint16 public wRisk;
    uint16 public wStability;
    uint16 public wIncentive;

    uint32 public incentiveDecayHalfLife;

    uint16 public adapterMaxExposureBps;
    uint16 public newAdapterRampBps;

    mapping(address => uint16) public adapterAbsCapOverrideBps;

    /// @notice DegradedMode: true when system in defensive mode (auto-set by _isDegradedMode check).
    /// @dev bool + uint64 + uint64 pack into one slot (1+8+8 = 17 bytes < 32).
    bool public degradedModeActive;
    uint64 public degradedModeEnteredAt;
    /// @notice Advisory withdrawal lock in seconds. effectiveWithdrawalLockSeconds() returns this × 7 in degraded mode.
    /// @dev Does NOT enforce CoreVault lockPeriod — governance must act on signal. Default 86400 (1 day).
    uint64 public withdrawalLockSeconds;

    uint16 public gateHorizonDays;
    uint16 public gateMinNetBenefitBps;
    uint16 public slippageBpsEstimate;
    uint16 public withdrawalSpreadBpsEstimate;
    uint256 public gasCostUSDC;

    uint16 public harvestThresholdBps;
    uint32 public minSecondsBetweenHarvests;

    uint256 public dustTolerance;

    // ── Storage: State, Freeze, Timestamps ──────────────────────────────────

    bool public rolesFrozen;
    bool public paramsFinalized;

    uint64 public lastHarvestTs;
    uint64 public lastRebalanceTs;

    mapping(address => uint256) public stabilityEMA;
    uint16 public stabilityEMAPeriod;

    mapping(address => uint16) public riskScoreBps;

    mapping(address => bool) public quarantined;
    mapping(address => uint8) public adapterConsecutiveFailures;
    uint8 public adapterQuarantineThreshold;
    bool public depositsDisabled;

    mapping(address => uint64) public adapterActivatedAt;
    uint256 public minNewAdapterSeed;
    uint64 public newAdapterRampDuration;

    uint16 public maxIdleAfterDepositBps;

    uint64 public bootstrapEndsAt;
    uint16 public maxIdleBootstrapBps;

    uint16 public degradedViewThresholdBps;

    mapping(address => uint64) public adapterLastFailureTs;
    uint32 public failureDecaySeconds;

    uint64 public lastDeployIdleTs;
    uint32 public minSecondsBetweenDeployIdle;

    // === V9.1 CTO: External TVL confidence ===
    uint16 public maxRelativeExposureBps;
    mapping(address => uint256) public cachedExternalTVL;
    mapping(address => uint64) public cachedExternalTVLTs;
    uint32 public externalTVLStalenessSeconds;
    // === Phase 1.5: EXT_TVL_PANIC snapshot — value before last window refresh ===
    mapping(address => uint256) public lastExtTVLSnapshot;
    mapping(address => uint64)  public lastExtTVLSnapshotTs;

    // === V9.1 CTO: Position sync ===
    uint64 public lastSyncTs;
    uint32 public minSecondsBetweenSync;

    // === V9.1 CTO: Cached liquidity for gas-efficient scoring ===
    mapping(address => uint16) public cachedLiquidityBps;
    mapping(address => uint64) public cachedLiquidityTs;
    uint32 public liquidityStalenessSeconds;

    // === V9.1 CTO: Multi-step rebalance plan ===
    uint8 public rebalancePlanPhase;           // 0=none, 1=prepared, 2=executing
    uint64 public rebalancePlanTs;             // plan creation timestamp
    uint8 public rebalancePlanNextAction;      // next action index
    uint8 public rebalancePlanTotalActions;    // total actions in plan
    uint8 public maxRebalanceActionsPerTx;     // max actions per execute step (default 2)
    uint32 public rebalancePlanMaxAge;         // max seconds before plan expires (default 7200)
    uint256 public rebalancePlanTvl;           // TVL snapshot at prepare time
    uint256 public rebalancePlanMinDrift;      // min absolute drift to invalidate (default 5_000e6)
    address[10] public rebalancePlanAdapters;  // planned adapters (fixed size)
    uint256[10] public rebalancePlanAmounts;   // planned amounts (high bit = isDeposit)

    // === V9.1 CTO: Retry mode flag — read by AdapterOpsModule via delegatecall ===
    bool internal _retryMode;

    // === V9.2 CTO: Stability EMA — live APY volatility tracking ===
    mapping(address => uint16) public lastPokedAPY;
    mapping(address => uint64) public lastStabilityUpdateTs;
    uint16 public apyFloorBps;                   // denominator floor for delta calc (default 50)
    uint32 public minStabilityUpdateInterval;    // min seconds between updates (default 6h)

    // === V10 P0: Execution Cost EMA ===
    mapping(address => uint64) public emaDepositGas;       // per-adapter EMA of deposit gas used
    mapping(address => uint64) public emaWithdrawGas;      // per-adapter EMA of withdraw gas used
    uint16 public gasEmaSmoothingBps;                      // EMA alpha in bps (default 2000 = 0.2)
    uint256 public estimatedGasCostUSDC;                   // precomputed gas cost, updated by keeper

    // === V10 P1: Hysteresis + benefit/cost ratio ===
    uint16 public minBenefitCostRatioBps;                  // e.g., 15000 = 1.5x (in bps scaling)
    uint16 public entryDriftBps;                           // min drift to trigger rebalance
    uint16 public exitDriftBps;                            // drift below which stop (< entryDriftBps)
    uint256 public minMoveUsd;                             // absolute floor in USDC (6 decimals)

    // === V10 P2: Coordination hooks ===
    uint16 public recentRebalancePenaltyBps;               // score penalty if strategy recently rebalanced
    uint32 public recentRebalanceWindowSeconds;             // "recently" = within this many seconds
    uint16 public minLiquidityReadinessBps;                 // below this, penalize benefit estimate

    // === V10 P3: Regime controller ===
    uint8 public currentRegime;                            // 0=STABLE, 1=VOLATILE, 2=STRESS
    uint16 public regimeHysteresisMultBps;                 // multiplier on hysteresis (10000 = 1x)
    uint16 public regimeBudgetMultBps;                     // scales move budget (10000 = 1x)
    uint16 public regimeHorizonDays;                       // overrides gateHorizonDays when > 0
    uint16 public regimeConfidenceMultBps;                 // multiplied into benefit estimate (10000 = 1x)

    // === V10: Rebalance Gate Module address (set-once in constructor, NO public setter) ===
    address public rebalanceGateModule_addr;

    // === Strategy hardening (audit 2026-04) ================================
    // Audit HIGH 2.3 — explicit adapter whitelist (not just underlying() check).
    mapping(address => bool) public whitelistedAdapters;
    // Audit HIGH 1.6 — cached adapter capacity for delta sanity checks.
    mapping(address => uint256) public cachedAdapterCapacity;
    // =======================================================================

    // === EIP-170 refactor (2026-04-22) =====================================
    // StrategyRebalancePlanModule address — holds prepareRebalance,
    // executeRebalanceStep, cancelRebalancePlan and their internals (extracted
    // from StrategyScoringModule to keep both within EIP-170 runtime size).
    // Set-once in UsdcMultiLendingVault constructor. No public setter.
    /// @dev SLOT RESERVED — DO NOT REMOVE. Preserves P0.L5 storage layout for all
    ///      modules inheriting StrategyStorageLayout via delegatecall pattern.
    ///      Currently unused (no setter, no reader) but slot allocation MUST remain.
    /// @notice rebalancePlanModule_addr placeholder (1 slot, EIP-170 refactor reserved)
    address public rebalancePlanModule_addr;

    /// @notice settingsModule_addr — StrategySettingsModule (governance setters, last in fallback chain)
    address public settingsModule_addr;

    /// @notice allocCalcModule_addr — StrategyAllocCalcModule (allocation calculation cluster)
    address public allocCalcModule_addr;

    // === Backtest remediation sprint (2026-04-22) =========================
    // S1 / P0.1 — over-cap risk premium: the gate adds a protection benefit
    //   term when reducing a position that is above the effective relative cap,
    //   so the gate can pass a protective divestiture even without APY uplift.
    //   Units: bps of annualised "risk APY". 0 = disabled.
    //   Packed with the following three uints in one 256-bit slot.
    uint16 public overCapRiskPremiumBps;
    // S8 / P1.4 — staleness windows for scoring signals: after this many seconds
    //   without a keeper update, the scoring falls back to DEFAULT_STABILITY_BPS /
    //   DEFAULT_RISK_BPS instead of using the last cached value. 0 = no expiry.
    uint32 public stabilityEMAStalenessSeconds;
    uint32 public riskScoreStalenessSeconds;
    // S11 / P2.1 — consecutive plan-timeout counter used for backoff.
    //   Incremented on each silent plan invalidation; decremented on a
    //   successful finalisation. Triggers effective-cooldown doubling above
    //   `rebalancePlanBackoffThreshold`.
    uint8 public rebalancePlanConsecutiveFailures;
    uint8 public rebalancePlanBackoffThreshold;

    // S4 / P1.3 — seasoned-adapter flag. Set true the first time positionAssets
    //   crosses the effective new-adapter seed. Once seasoned, the newAdapterRamp
    //   is NOT re-applied on subsequent drainage back to dust (post-emergency).
    mapping(address => bool) public isSeasoned;
    // S8 / P1.4 — per-adapter last governance-update timestamp for risk score.
    mapping(address => uint64) public lastRiskScoreUpdateTs;
    // =======================================================================

    // === Cap drift mandate (2026-04-24) =====================================
    // P0.4 — tolerance band around `adapterMaxExposureBps`. Between two
    //   rebalances, an adapter's position can drift above `maxExp` because
    //   yield accrues continuously on-chain while TVL can shrink (user
    //   withdrawals). Strict `current <= maxExp` is therefore physically
    //   impossible to maintain. We introduce a bounded tolerance:
    //
    //     softCeiling = maxExp                              (deploy-time gate)
    //     hardCeiling = maxExp * (1e4 + capDriftToleranceBps) / 1e4
    //
    //   Above `hardCeiling`, the gate MUST accept a rebalance plan
    //   (mandate bypass) regardless of benefit-vs-cost. Below `hardCeiling`
    //   but above `maxExp`, the existing `overCapRiskPremiumBps` soft-
    //   incentive continues to apply via the rel-cap protection benefit.
    //
    //   Units: bps. 0 disables the mandate (legacy behaviour).
    //   Bound: <= 2000 (20%) enforced by the setter.
    uint16 public capDriftToleranceBps;
    // =======================================================================

    // === P0.7 — Safety Adapter Cap Tier (2026-06-11) ========================
    // P0.7 safety cap tier architecture. Audit ref: docs/SAFETY_ADAPTER_TIER.md
    //
    // This is a SECOND, governance-approved cap layer for adapters explicitly
    // designated as liquidity-parking venues (e.g. Aave). NOT a cap bypass:
    // the normal scoring path still uses the regular caps; only the safety
    // overflow path and the mandate gate honour the fallback caps when an
    // adapter is in the safety list.
    //
    // Backtest validation: iter-3b (10-iteration sweep) — TWR USD 5.62% vs
    // Aave standalone 5.37% (+25 bps), Sharpe 0.729 vs Aave 0.33.
    //
    // Slot packing: capDriftToleranceBps(uint16,@0) + uint16 + uint16 + uint32 = 80 bits in slot 78.
    uint16 public maxIdleBps;                       // 0 = disabled, max 2000
    uint16 public targetSafetyMarginBps;            // 0 = disabled, max 2000
    uint32 public mandateRedeployCooldownSeconds;   // 0 = disabled, max 30 days

    /// @notice Ordered list of governance-approved safety venues (priority desc).
    /// @dev Used by the safety overflow path and the cap drift mandate.
    address[] public safetyFallbackAdapters;

    /// @notice Per-adapter safety cap configuration.
    /// @dev absCapBps == 0 means the adapter is NOT a safety fallback; this is
    ///      the canonical "is safety adapter" predicate.
    struct SafetyFallback {
        uint16 absCapBps;   // 0 = adapter not safety; max 8000 (80%)
        uint16 relCapBps;   // 0 = adapter not safety; max 10000 (100%)
    }
    mapping(address => SafetyFallback) public safetyFallback;

    /// @notice Per-adapter timestamp of last rel-cap mandate trigger.
    /// @dev Used by deploy-idle to skip non-safety adapters in cooldown.
    ///      Stored separately from generic last-failure tracking for audit clarity.
    mapping(address => uint64) public lastRelCapMandateTs;
    // =======================================================================

    // ── Storage gap for future upgrades ─────────────────────────────────────
    // === P0.Q11+Q12A monitoring (2026-04-28) — performance snapshot tuple ===
    // FIX P0.Q11/Q12A: per-rebalance snapshot persisted in storage so off-chain
    // indexers can compute realized vs predicted APY by joining LendingPerformanceSnapshot
    // events with Core's deposit/withdraw flow events. Path A (light) — keeps math
    // off-chain, no flow accounting on hot path.
    // Slot packing: 128 + 64 + 16 = 208 bits in one slot (48 bits unused padding).
    uint128 public lastSnapshotTotalAssets;     // totalAssets at last snapshot emit
    uint64  public lastSnapshotTs;              // timestamp of last snapshot emit
    uint16  public lastSnapshotPredictedAPYBps; // weighted predicted APY at last emit

    // Reduced from 7 to 6 after adding allocCalcModule_addr (REFACTOR-B, 2026-05-04).
    // Reduced from 8 to 7 after adding settingsModule_addr (REFACTOR-A, 2026-05-04).
    // Reduced from 9 to 8 after adding the snapshot tuple (one slot used).
    // Reduced from 10 to 9 (2026-04-24): capDriftToleranceBps for P0.4 mandate.
    // Reduced from 6 to 2 (2026-06-11): P0.7 Safety Adapter Cap Tier consumed
    //   4 slots:
    //     - packed (maxIdleBps + targetSafetyMarginBps + mandateRedeployCooldownSeconds)
    //     - safetyFallbackAdapters address[] head
    //     - safetyFallback mapping head
    //     - lastRelCapMandateTs mapping head
    // Earlier reductions (sprint 2026-04-22):
    //   - rebalancePlanModule_addr (1 slot, EIP-170 refactor)
    //   - packed uint16/uint32/uint32/uint8/uint8 block (1 slot)
    //   - isSeasoned mapping head (1 slot)
    //   - lastRiskScoreUpdateTs mapping head (1 slot)
    uint256[2] private __gap;

    // ── Shared events ───────────────────────────────────────────────────────

    event AdapterAdded(address indexed adapter);
    event AdapterToggled(address indexed adapter, bool enabled);
    event AdapterFlagged(address indexed adapter, bool flagged);
    event AdapterDepositModeSet(address indexed adapter, bool pushMode);
    event QuarantineThresholdUpdated(uint8 threshold);
    event RiskWeightsUpdated(uint16 wAPY, uint16 wLiq, uint16 wRisk, uint16 wStability, uint16 wIncentive);
    event GateParamsUpdated(uint16 gateHorizonDays, uint16 gateMinNetBenefitBps, uint16 slippageBpsEstimate, uint16 withdrawalSpreadBpsEstimate, uint256 gasCostUSDC);
    event RebalanceParamsUpdated(uint16 maxAdaptersPerAllocation, uint16 minAdaptersActive, uint16 rebalanceMinMoveBps, uint32 minSecondsBetweenRebalances, uint16 driftToleranceBps, uint16 adapterMaxExposureBps, uint16 newAdapterRampBps);
    event HarvestParamsUpdated(uint16 harvestThresholdBps, uint32 minSecondsBetweenHarvests);
    event DustToleranceUpdated(uint256 dustTolerance);
    event RolesFrozen();
    event ParametersFinalized();
    event Harvest(uint256 realized, uint256 adaptersTouched);
    event Rebalanced(uint256 movedAssets);
    event LiquidityRealized(uint256 requested, uint256 realized);
    event EmergencyRecalled(uint256 totalRecalled);
    event AdapterDepositFailed(address indexed adapter, uint256 amount, bytes reason);
    event AdapterWithdrawFailed(address indexed adapter, uint256 amount, bytes reason);
    event AdapterHarvestFailed(address indexed adapter, bytes reason);
    event AdapterAutoQuarantined(address indexed adapter, uint8 consecutiveFailures);
    event AdapterFundsStranded(address indexed adapter, uint256 amount);
    event IdleCashRemaining(uint256 idle, uint256 dustTolerance);
    event DepositsDisabledChanged(bool disabled);
    event NewAdapterRampParamsUpdated(uint256 minNewAdapterSeed, uint64 newAdapterRampDuration);
    event MaxIdleAfterDepositBpsUpdated(uint16 maxIdleAfterDepositBps);
    event BootstrapModeExited();
    event DegradedViewThresholdBpsUpdated(uint16 degradedViewThresholdBps);
    event FailureDecaySecondsUpdated(uint32 failureDecaySeconds);
    event DeployIdleParamsUpdated(uint32 minSecondsBetweenDeployIdle);
    event DeployIdleExecuted(uint256 deployed, uint256 remainingIdle);
    event BootstrapIdleParamsUpdated(uint16 maxIdleBootstrapBps);
    event DegradedViewsObserved(uint16 fallbackBps);
    event AdapterActivated(address indexed adapter, uint64 activatedAt);
    event ExternalTVLPoked(address indexed adapter, uint256 tvl);
    event MaxRelativeExposureBpsUpdated(uint16 oldValue, uint16 newValue);
    event PositionAssetsSynced(address indexed adapter, uint256 oldPosition, uint256 newPosition);
    event StabilityUpdated(address indexed adapter, uint16 prevApyBps, uint16 currApyBps, uint16 rawStabilityBps, uint16 emaStabilityBps);
    event StabilityParamsUpdated(uint16 apyFloorBps, uint32 minStabilityUpdateInterval, uint16 stabilityEMAPeriod);
    // V10 events
    event GasEmaUpdated(address indexed adapter, uint64 emaGas, bool isDeposit);
    event EstimatedGasCostUpdated(uint256 costUSDC);
    event HysteresisParamsUpdated(uint16 minBCR, uint16 entryDrift, uint16 exitDrift, uint256 minMoveUsd);
    event CoordinationParamsUpdated(uint16 penalty, uint32 window, uint16 minLiqReadiness);
    event RegimeChanged(uint8 regime);
    event RegimeParamsUpdated(uint8 regime, uint16 hysteresis, uint16 budget, uint16 horizon, uint16 confidence);
    event RebalanceGateModuleSet(address indexed module);
    event RebalancePlanModuleSet(address indexed module);
    event SettingsModuleSet(address indexed module);
    event AllocCalcModuleSet(address indexed module);
    event PositionSyncSkippedSuspicious(address indexed adapter, uint256 oldPos, uint256 actual);
    event DriftMeasured(uint256 totalDrift, bool hasNegativeDrift);
    event SyncIntervalUpdated(uint32 interval);
    event LiquidityCacheStale(address indexed adapter, uint256 age);
    event RebalancePlanCreated(uint8 actionCount, uint256 totalMoved, uint256 tvlSnapshot);
    event RebalanceStepExecuted(uint8 fromAction, uint8 toAction);
    event ExternalTVLStalenessUpdated(uint32 oldValue, uint32 newValue);
    event LiquidityStalenessUpdated(uint32 oldValue, uint32 newValue);
    event RebalancePlanMaxAgeUpdated(uint32 oldValue, uint32 newValue);
    event MaxRebalanceActionsUpdated(uint8 oldValue, uint8 newValue);
    event RebalancePlanMinDriftUpdated(uint256 oldValue, uint256 newValue);
    event IdleCapExhausted(uint256 remaining, uint256 threshold);
    event RetryFailureIgnored(address indexed adapter, uint256 amount);
    event RebalancePlanCancelled();
    event RebalancePlanInvalidated(uint256 planTvl, uint256 currentTvl);
    event RebalancePlanExpired(uint256 age, uint256 maxAge);
    event RebalancePlanInvalidatedDueToDrift(uint256 drift, uint256 allowed);
    event RetryModeSet(bool enabled);
    event AdapterWhitelisted(address indexed adapter, bool allowed);
    event AdapterCapacityDecreased(address indexed adapter, uint256 cap, uint256 current);
    event AdapterCapacityJump(address indexed adapter, uint256 previousCap, uint256 newCap);
    // AUDIT-FINDING-7: canonical maxCapacity()=0 means CLOSED (zero capacity, no new deposits).
    event AdapterCapacityZero(address indexed adapter, uint256 currentPosition);

    // ── Shared modifiers ────────────────────────────────────────────────────

    modifier onlyRoleOrRevert(bytes32 role) {
        if (!hasRole(role, msg.sender)) revert Unauthorized();
        _;
    }

    modifier rolesNotFrozen() {
        if (rolesFrozen) revert Frozen();
        _;
    }

    modifier paramsNotFinalized() {
        if (paramsFinalized) revert Frozen();
        _;
    }

    modifier onlyCore() {
        if (!hasRole(CORE_ROLE, msg.sender)) revert Unauthorized();
        _;
    }

    // ── Constructor (only sets immutables) ──────────────────────────────────

    constructor(address asset_, address _core, address _paramsModule, address _scoringModule, address _adapterOpsModule) {
        ASSET = IERC20Metadata(asset_);
        core = _core;
        paramsModule = _paramsModule;
        scoringModule = _scoringModule;
        adapterOpsModule = _adapterOpsModule;
    }

    // Phase 1 added events (preserved across reload)
    event WithdrawalShortfall(uint256 requested, uint256 received);
    event SelectiveRecallExecuted(address[] targets, uint256 totalRecalled);

    event OverCapRiskPremiumUpdated(uint16 bps);
    event ScoringStalenessUpdated(uint32 stabilityStaleness, uint32 riskStaleness);
    event RebalancePlanBackoffThresholdUpdated(uint8 threshold);
    event RiskScoreUpdated(address indexed adapter, uint16 bps);
    event CapDriftToleranceUpdated(uint16 oldBps, uint16 newBps);
    event AdapterAbsCapOverrideUpdated(address indexed adapter, uint16 floorBps);
    event DegradedModeEntered(string reason, uint64 timestamp);
    event DegradedModeCleared(address indexed by, uint64 timestamp);

    event CapDriftMandate(address indexed adapter, uint256 currentBps, uint256 hardCeilingBps);

    // === P0.7 — Safety Adapter Cap Tier events (2026-06-11) ===
    event MaxIdleBpsUpdated(uint16 oldBps, uint16 newBps);
    event TargetSafetyMarginUpdated(uint16 oldBps, uint16 newBps);
    event MandateRedeployCooldownUpdated(uint32 oldSeconds, uint32 newSeconds);
    event SafetyFallbackAdapterAdded(address indexed adapter, uint16 absCapBps, uint16 relCapBps);
    event SafetyFallbackAdapterRemoved(address indexed adapter);
    event SafetyFallbackCapsUpdated(address indexed adapter, uint16 oldAbs, uint16 newAbs, uint16 oldRel, uint16 newRel);
    event SafetyOverflowDeployed(address indexed adapter, uint256 amount, uint256 idleBefore, uint256 idleAfter);
    event RelCapMandateCooldownStarted(address indexed adapter, uint64 timestamp, uint32 cooldownSeconds);
    /// @notice Emitted when a safety-fallback promotion clears an active mandate cooldown.
    /// @dev Governance-trusted override — the promotion signal supersedes accumulated
    ///      mandate state. Off-chain observability for the cooldown lifecycle.
    event RelCapMandateCooldownCleared(address indexed adapter, address indexed clearedBy, uint64 priorTs);

    event AdapterSeasoned(address indexed adapter, uint256 positionAssets);

    event RebalancePlanBackoffActive(uint16 consecutiveFailures, uint64 cooldownUntil);
    event LendingPerformanceSnapshot(
        uint64 timestamp,
        uint256 totalAssets,
        uint16 idlePctBps,
        uint16 weightedAPYPredictedBps,
        uint16 prevSnapshotPredictedAPYBps,
        uint16 concentrationTopBps,
        uint16 activeCount,
        uint16 quarantinedCount,
        uint16 weightedTVLConfidenceBps,
        uint16 degradedViewsBps
    );

    // ── Shared internal helpers (used by ParamsModule + ScoringModule) ───────
    // Centralised here to eliminate bytecode duplication across modules.
    // All functions are internal — inlined by the compiler into each module
    // that inherits StorageLayout, but maintained in a single location.

    /// @dev Used by Params/Scoring modules (delegatecall context). Uses ASSET.balanceOf, NOT idleCash().
    ///      UsdcLendingStrategy overrides with idleCash() version for vault-local calls.
    function _tvl() internal view virtual returns (uint256) {
        uint256 sum = ASSET.balanceOf(address(this));
        uint256 n = adapters.length;
        for (uint256 i = 0; i < n;) {
            sum += positionAssets[adapters[i]];
            unchecked { ++i; }
        }
        return sum;
    }

    function _enabledAdapters() internal view returns (address[] memory result) {
        address[] storage _adapters = adapters;
        uint256 n = _adapters.length;
        address[] memory temp = new address[](n);
        uint256 count = 0;
        unchecked {
            for (uint256 i = 0; i < n; ++i) {
                address a = _adapters[i];
                if (enabled[a] && !quarantined[a]) {
                    temp[count++] = a;
                }
            }
        }
        result = new address[](count);
        unchecked {
            for (uint256 i = 0; i < count; ++i) {
                result[i] = temp[i];
            }
        }
    }

    function _safeTotalAssets(address adapter) internal view returns (uint256) {
        (bool ok, bytes memory data) =
            adapter.staticcall(abi.encodeWithSelector(ILendingAdapter.totalAssets.selector));
        if (ok && data.length >= 32) {
            return abi.decode(data, (uint256));
        }
        return positionAssets[adapter];
    }

    function _safeWithdrawableAssets(address adapter) internal view returns (uint256) {
        (bool ok, bytes memory data) = adapter.staticcall(
            abi.encodeWithSelector(ILendingAdapter.withdrawableAssets.selector)
        );
        if (ok && data.length >= 32) {
            return abi.decode(data, (uint256));
        }
        return positionAssets[adapter];
    }

    function _clampLiq(address adapter) internal view returns (uint256) {
        uint256 tot = _safeTotalAssets(adapter);
        if (tot <= dustTolerance) return 10000;
        uint256 wa = _safeWithdrawableAssets(adapter);
        uint256 liq = (wa * 1e4) / tot;
        if (liq > 10000) liq = 10000;
        return liq;
    }

    /// @dev TVL confidence — 3-state: UNAVAILABLE (ts==0), STALE (beyond window), FRESH.
    ///      Canonical version (aligned with ScoringModule Audit #2 P0.6 fix).
    function _tvlConfidence(address adapter) internal view returns (uint256) {
        uint64 cacheTs = cachedExternalTVLTs[adapter];
        uint256 extTVL = cachedExternalTVL[adapter];
        if (cacheTs == 0) return CONFIDENCE_ZERO;
        uint32 _staleness = externalTVLStalenessSeconds;
        if (_staleness > 0 && block.timestamp - cacheTs > _staleness) return CONFIDENCE_MICRO;
        if (extTVL < 100_000e6) return CONFIDENCE_ZERO;
        if (extTVL < 500_000e6) return CONFIDENCE_MICRO;
        if (extTVL < 2_000_000e6) return CONFIDENCE_SMALL;
        if (extTVL < 10_000_000e6) return CONFIDENCE_LOW;
        if (extTVL < 50_000_000e6) return CONFIDENCE_MED;
        if (extTVL < 250_000_000e6) return CONFIDENCE_HIGH;
        return CONFIDENCE_VHIGH;
    }

    /// @dev Dynamic relative exposure cap — scales with external market depth.
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
}
