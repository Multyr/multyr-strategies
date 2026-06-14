// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

// ─── Uniswap V3 SwapRouter02 minimal interface ───────────────────────────
interface ISwapRouterV3 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    /// @dev SwapRouter02 (canonical Arbitrum) — no `deadline` field.
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

// ─── Camelot V3 router (compatible IUniswapV3-style with different sig) ──
interface ICamelotV3SwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

// ─── Chainlink AggregatorV3Interface ─────────────────────────────────────
interface IChainlinkFeed {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
    function decimals() external view returns (uint8);
}

/// @title RewardSwapHelper
/// @notice On-chain reward token → USDC swap with MEV resistance.
/// @dev Pattern: caller transferFroms reward token to this helper; helper executes
///      Chainlink-anchored swap with multi-DEX fallback, returns USDC to receiver.
///
///      MEV defenses:
///        - Chainlink price as anchor (not pool spot) for minOut calculation
///        - Configurable slippage cap per reward token (max 1000 bps = 10%)
///        - Stale oracle check (per-token configurable maxFeedAgeSec)
///        - Multi-DEX fallback chain: Uniswap V3 → Camelot V3
///        - Single-block execution (deadline = block.timestamp on Camelot)
///        - ReentrancyGuard
///
///      OPERATIONAL NOTE — Chainlink heartbeats on Arbitrum (verified 2026-04-28):
///        Most price feeds use 24h heartbeat (86400s) with 0.05%/0.1%/0.5% deviation.
///        Set maxFeedAgeSec = heartbeat × 1.05 (e.g. 90_000s for 24h-heartbeat feeds).
///        Examples (per data.chain.link/feeds/arbitrum/mainnet/<feed>):
///          - USDC/USD: 24h hb, 0.1% dev   → recommended maxFeedAgeSec 90_000
///          - COMP/USD: 24h hb, ~1% dev    → recommended maxFeedAgeSec 90_000
///          - AAVE/USD: 24h hb, ~1% dev    → recommended maxFeedAgeSec 90_000
///          - LINK/USD: 1h  hb, 0.5% dev   → recommended maxFeedAgeSec  4_000
///          - XVS/USD:  may not exist on Arbitrum — verify before adapter deploy
///        Floor enforced: 3_600s (1h). Ceiling enforced: 7 days. Govern responsibly.
///
///      Companion view `canSwap(rewardToken)` lets callers (adapters / canHarvest)
///      pre-flight the oracle freshness so they can SKIP swap rather than revert,
///      avoiding wasted Chainlink Automation LINK on guaranteed-failure tx.
contract RewardSwapHelper is AccessControl, ReentrancyGuard, Initializable {
    using SafeERC20 for IERC20;

    // ─── Roles ──────────────────────────────────────────────────────────
    bytes32 public constant PARAM_ROLE = keccak256("PARAM_ROLE");

    // ─── Immutable Storage ──────────────────────────────────────────────
    // --- V10 Storage (was immutable in V9.x; logically immutable post-initialize) ---
    address public usdc;
    address public uniswapV3Router;
    address public camelotV3Router; // optional (address(0) if not configured)

    // ─── L2 Sequencer Uptime Feed (Step 4.7 RA-10 defense) ──────────────
    /// @notice Arbitrum sequencer uptime feed. address(0) = check disabled.
    /// @dev    Reference Arbitrum mainnet: 0xFdB631F5EE196F0ed6FAa767959853A9F217697D
    ///         When non-zero, swapToUSDC + canSwap require: sequencer up
    ///         AND > SEQUENCER_GRACE_PERIOD_SEC since last restart.
    ///         Set via `setSequencerUptimeFeed`. Should be configured pre-deploy
    ///         on Arbitrum/Optimism/Base/etc; left zero only on chains without L2
    ///         sequencer or in unit-test environments.
    address public sequencerUptimeFeed;

    event SequencerUptimeFeedUpdated(address feed);

    // ─── Reward Token Config ────────────────────────────────────────────
    struct RewardConfig {
        address chainlinkFeed;       // <rewardToken>/USD feed
        uint8   feedDecimals;        // Chainlink feed decimals (typically 8)
        uint8   tokenDecimals;       // reward token ERC20 decimals
        uint32  maxFeedAgeSec;       // staleness threshold
        bytes   uniswapV3Path;       // ABI-encoded path: rewardToken → ... → USDC
        bytes   camelotV3Path;       // fallback path (empty bytes = disabled)
        uint16  slippageBps;         // 100 = 1%; max 1000 (10%)
        bool    enabled;
    }
    mapping(address => RewardConfig) public configs;

    // ─── Events ─────────────────────────────────────────────────────────
    event RewardConfigured(
        address indexed rewardToken,
        address chainlinkFeed,
        uint16 slippageBps,
        uint32 maxFeedAgeSec
    );
    event RewardConfigDisabled(address indexed rewardToken);
    event Swapped(
        address indexed caller,
        address indexed rewardToken,
        uint256 amountIn,
        uint256 amountOut,
        address indexed receiver,
        uint8 dexUsed // 1 = Uniswap V3, 2 = Camelot V3
    );

    // ─── Errors ─────────────────────────────────────────────────────────
    error ZeroAddress();
    error NotEnabled(address rewardToken);
    error StaleOracle(uint256 updatedAt, uint32 maxAge);
    error InvalidOraclePrice(int256 price);
    error AllRoutesFailed();
    error SlippageTooHigh(uint16 slippageBps);
    error InvalidConfig();
    error MaxFeedAgeOutOfRange(uint32 secs);
    error SequencerDown();
    error SequencerGracePeriodNotElapsed(uint256 startedAt, uint256 graceUntil);

    /// @dev Operational floor for maxFeedAgeSec (matches LINK/USD heartbeat lower-bound).
    uint32 public constant MIN_MAX_FEED_AGE_SEC = 3_600;
    /// @dev Operational ceiling — beyond this we wouldn't trust the oracle anyway.
    uint32 public constant MAX_MAX_FEED_AGE_SEC = 7 days;
    /// @dev Industry standard grace period after Arbitrum sequencer restart.
    ///      During this window, Chainlink price feeds may not have updated yet
    ///      even though sequencer is technically up. Aave V3, Synthetix, OZ Defender
    ///      use 3600s (1h). Reference:
    ///      https://docs.chain.link/data-feeds/l2-sequencer-feeds
    uint32 public constant SEQUENCER_GRACE_PERIOD_SEC = 3_600;

    // ─── Constructor ────────────────────────────────────────────────────
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice One-shot initialization called atomically by AdapterFactory.
    function initialize(
        address usdc_,
        address admin_,
        address uniswapV3Router_,
        address camelotV3Router_
    ) external initializer {
        if (usdc_ == address(0) || admin_ == address(0) || uniswapV3Router_ == address(0)) {
            revert ZeroAddress();
        }
        usdc = usdc_;
        uniswapV3Router = uniswapV3Router_;
        camelotV3Router = camelotV3Router_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(PARAM_ROLE, admin_);
    }

    // ─── Admin: Configure reward token ──────────────────────────────────
    /// @notice Configure a reward token for swap.
    /// @dev camelotV3Path can be empty bytes (disable Camelot fallback).
    function setRewardConfig(
        address rewardToken,
        address chainlinkFeed,
        uint8   feedDecimals,
        uint8   tokenDecimals,
        uint32  maxFeedAgeSec,
        bytes calldata uniswapV3Path,
        bytes calldata camelotV3Path,
        uint16  slippageBps
    ) external onlyRole(PARAM_ROLE) {
        if (rewardToken == address(0) || chainlinkFeed == address(0)) revert ZeroAddress();
        if (slippageBps > 1000) revert SlippageTooHigh(slippageBps); // hard cap 10%
        if (uniswapV3Path.length == 0) revert InvalidConfig();
        if (maxFeedAgeSec < MIN_MAX_FEED_AGE_SEC || maxFeedAgeSec > MAX_MAX_FEED_AGE_SEC) {
            revert MaxFeedAgeOutOfRange(maxFeedAgeSec);
        }

        configs[rewardToken] = RewardConfig({
            chainlinkFeed: chainlinkFeed,
            feedDecimals: feedDecimals,
            tokenDecimals: tokenDecimals,
            maxFeedAgeSec: maxFeedAgeSec,
            uniswapV3Path: uniswapV3Path,
            camelotV3Path: camelotV3Path,
            slippageBps: slippageBps,
            enabled: true
        });

        emit RewardConfigured(rewardToken, chainlinkFeed, slippageBps, maxFeedAgeSec);
    }

    function disableReward(address rewardToken) external onlyRole(PARAM_ROLE) {
        configs[rewardToken].enabled = false;
        emit RewardConfigDisabled(rewardToken);
    }

    /// @notice Configure (or disable) Arbitrum/L2 sequencer uptime feed.
    /// @dev    Pass address(0) to disable check (e.g., on L1 or in unit tests).
    function setSequencerUptimeFeed(address feed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        sequencerUptimeFeed = feed;
        emit SequencerUptimeFeedUpdated(feed);
    }

    /// @dev Internal sequencer health check. Reverts if down or in grace period.
    ///      No-op if `sequencerUptimeFeed` is unconfigured (address(0)).
    function _requireSequencerOk() internal view {
        address feed = sequencerUptimeFeed;
        if (feed == address(0)) return;
        (, int256 answer, uint256 startedAt, , ) = IChainlinkFeed(feed).latestRoundData();
        // Sequencer feed convention: 0 = up, 1 = down.
        if (answer != 0) revert SequencerDown();
        // Grace period: refuse swaps for first hour after sequencer restart
        // (Chainlink price feeds may still be stale during this window).
        uint256 graceUntil = startedAt + uint256(SEQUENCER_GRACE_PERIOD_SEC);
        if (block.timestamp <= graceUntil) {
            revert SequencerGracePeriodNotElapsed(startedAt, graceUntil);
        }
    }

    /// @dev Internal sequencer health probe (returns bool, no revert).
    ///      Used by view functions (canSwap, harvestableProfit chain).
    function _sequencerOk() internal view returns (bool) {
        address feed = sequencerUptimeFeed;
        if (feed == address(0)) return true;
        try IChainlinkFeed(feed).latestRoundData() returns (
            uint80, int256 answer, uint256 startedAt, uint256, uint80
        ) {
            if (answer != 0) return false;
            if (block.timestamp <= startedAt + uint256(SEQUENCER_GRACE_PERIOD_SEC)) return false;
            return true;
        } catch {
            return false;
        }
    }

    // ─── Core: swapToUSDC ───────────────────────────────────────────────

    /// @notice Pull rewardToken from caller, swap to USDC with MEV protection,
    ///         transfer USDC to receiver.
    /// @dev Caller must have approved this helper for `amountIn` of rewardToken.
    /// @return amountOut USDC delivered to receiver.
    function swapToUSDC(
        address rewardToken,
        uint256 amountIn,
        address receiver
    ) external nonReentrant returns (uint256 amountOut) {
        RewardConfig memory cfg = configs[rewardToken];
        if (!cfg.enabled) revert NotEnabled(rewardToken);
        if (receiver == address(0)) revert ZeroAddress();
        if (amountIn == 0) return 0;

        // RA-10: L2 sequencer health gate (defends against post-outage stale feeds)
        _requireSequencerOk();

        // 1. Pull reward tokens from caller
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amountIn);

        // 2. Compute oracle-anchored minOut
        uint256 expectedOut = _oracleExpectedUsdcOut(rewardToken, amountIn, cfg);
        uint256 minOut = (expectedOut * (10_000 - cfg.slippageBps)) / 10_000;

        // 3. Try Uniswap V3 (primary)
        amountOut = _tryUniV3(rewardToken, amountIn, minOut, cfg.uniswapV3Path);
        uint8 dexUsed = 1;

        // 4. Fallback: Camelot V3 if Uniswap failed
        if (amountOut == 0 && cfg.camelotV3Path.length > 0 && camelotV3Router != address(0)) {
            amountOut = _tryCamelotV3(rewardToken, amountIn, minOut, cfg.camelotV3Path);
            dexUsed = 2;
        }

        if (amountOut == 0) revert AllRoutesFailed();

        // 5. Forward USDC to receiver
        IERC20(usdc).safeTransfer(receiver, amountOut);
        emit Swapped(msg.sender, rewardToken, amountIn, amountOut, receiver, dexUsed);
    }

    // ─── Internal: oracle expected USDC out ─────────────────────────────

    /// @dev expectedUsdc = amountIn × oraclePrice × 10^USDC_DEC / 10^(tokenDec + feedDec)
    function _oracleExpectedUsdcOut(
        address /*rewardToken*/,
        uint256 amountIn,
        RewardConfig memory cfg
    ) internal view returns (uint256) {
        IChainlinkFeed feed = IChainlinkFeed(cfg.chainlinkFeed);
        (, int256 answer, , uint256 updatedAt, ) = feed.latestRoundData();
        if (block.timestamp - updatedAt > cfg.maxFeedAgeSec) {
            revert StaleOracle(updatedAt, cfg.maxFeedAgeSec);
        }
        if (answer <= 0) revert InvalidOraclePrice(answer);

        uint256 numerator = amountIn * uint256(answer) * 1e6;
        uint256 divisor = 10 ** (uint256(cfg.tokenDecimals) + uint256(cfg.feedDecimals));
        return numerator / divisor;
    }

    // ─── Internal: Uniswap V3 attempt ───────────────────────────────────

    function _tryUniV3(
        address rewardToken,
        uint256 amountIn,
        uint256 minOut,
        bytes memory path
    ) internal returns (uint256 out) {
        IERC20(rewardToken).forceApprove(uniswapV3Router, amountIn);
        try ISwapRouterV3(uniswapV3Router).exactInput(
            ISwapRouterV3.ExactInputParams({
                path: path,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: minOut
            })
        ) returns (uint256 received) {
            out = received;
        } catch {
            out = 0;
        }
        IERC20(rewardToken).forceApprove(uniswapV3Router, 0);
    }

    // ─── Internal: Camelot V3 attempt ───────────────────────────────────

    function _tryCamelotV3(
        address rewardToken,
        uint256 amountIn,
        uint256 minOut,
        bytes memory path
    ) internal returns (uint256 out) {
        IERC20(rewardToken).forceApprove(camelotV3Router, amountIn);
        try ICamelotV3SwapRouter(camelotV3Router).exactInput(
            ICamelotV3SwapRouter.ExactInputParams({
                path: path,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minOut
            })
        ) returns (uint256 received) {
            out = received;
        } catch {
            out = 0;
        }
        IERC20(rewardToken).forceApprove(camelotV3Router, 0);
    }

    // ─── Views ──────────────────────────────────────────────────────────

    function isEnabled(address rewardToken) external view returns (bool) {
        return configs[rewardToken].enabled;
    }

    /// @notice Pre-flight check: returns true iff a swap would NOT revert on
    ///         oracle freshness / config / sequencer / price-validity grounds.
    /// @dev    Used by adapters' canHarvest pre-flight to avoid wasted keeper LINK.
    function canSwap(address rewardToken) external view returns (bool) {
        RewardConfig memory cfg = configs[rewardToken];
        if (!cfg.enabled) return false;
        // RA-10: L2 sequencer probe (no-op if feed not configured)
        if (!_sequencerOk()) return false;
        // Oracle freshness probe (must mirror _oracleExpectedUsdcOut checks)
        try IChainlinkFeed(cfg.chainlinkFeed).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer <= 0) return false;
            if (block.timestamp < updatedAt) return false; // future-dated round
            if (block.timestamp - updatedAt > cfg.maxFeedAgeSec) return false;
            return true;
        } catch {
            return false;
        }
    }

    /// @notice Preview expectedOut for a given input — useful for off-chain monitoring.
    ///         Not authoritative; actual swap may differ.
    function previewExpectedOut(address rewardToken, uint256 amountIn)
        external view returns (uint256)
    {
        RewardConfig memory cfg = configs[rewardToken];
        if (!cfg.enabled) return 0;
        return _oracleExpectedUsdcOut(rewardToken, amountIn, cfg);
    }

    // ─── Sweep protection ───────────────────────────────────────────────
    /// @notice Rescue tokens accidentally sent to the helper (NOT reward tokens
    ///         currently mid-swap — that path is atomic). Admin only.
    function rescueERC20(address token, address to, uint256 amount)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (configs[token].enabled) revert NotEnabled(token);
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    // ─── Fallbacks disabled ─────────────────────────────────────────────
    receive() external payable {
        revert("NO_RECEIVE");
    }

    fallback() external payable {
        revert("NO_FALLBACK");
    }
}
