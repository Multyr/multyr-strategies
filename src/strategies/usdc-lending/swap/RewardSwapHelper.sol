// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
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
/// @notice On-chain reward token → configured strategy asset swap with MEV resistance.
/// @dev Pattern: caller transferFroms reward token to this helper; helper executes
///      Chainlink-anchored swap with multi-DEX fallback, returns the configured asset.
///
///      MEV defenses:
///        - Chainlink price as anchor (not pool spot) for minOut calculation
///        - Configurable slippage cap per reward token (max 500 bps = 5%)
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
    /// @notice Callers permitted to execute reward swaps (adapters + keeper bots).
    ///         Granted by admin post-deploy to each adapter via grantRole(KEEPER_ROLE, adapter).
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    // ─── Immutable Storage ──────────────────────────────────────────────
    // --- V10 Storage (was immutable in V9.x; logically immutable post-initialize) ---
    address public usdc; // legacy storage slot: configured output asset
    address public uniswapV3Router;
    address public camelotV3Router; // optional (address(0) if not configured)

    // ─── L2 Sequencer Uptime Feed (Step 4.7 RA-10 defense) ──────────────
    /// @notice Arbitrum sequencer uptime feed. address(0) = check disabled.
    /// @dev    Reference Arbitrum mainnet: 0xFdB631F5EE196F0ed6FAa767959853A9F217697D
    ///         When non-zero, reward swaps + canSwap require: sequencer up
    ///         AND > SEQUENCER_GRACE_PERIOD_SEC since last restart.
    ///         Set via `setSequencerUptimeFeed`. Should be configured pre-deploy
    ///         on Arbitrum/Optimism/Base/etc; left zero only on chains without L2
    ///         sequencer or in unit-test environments.
    address public sequencerUptimeFeed;

    event SequencerUptimeFeedUpdated(address feed);
    event OutputAssetOracleUpdated(address indexed feed, uint8 feedDecimals, uint8 assetDecimals, uint32 maxAge);

    // ─── Reward Token Config ────────────────────────────────────────────
    struct RewardConfig {
        address chainlinkFeed;       // <rewardToken>/USD feed
        uint8   feedDecimals;        // Chainlink feed decimals (typically 8)
        uint8   tokenDecimals;       // reward token ERC20 decimals
        uint32  maxFeedAgeSec;       // staleness threshold
        bytes   uniswapV3Path;       // ABI-encoded path: rewardToken → ... → output asset
        bytes   camelotV3Path;       // fallback path (empty bytes = disabled)
        uint16  slippageBps;         // 100 = 1%; max 500 (5%)
        bool    enabled;
    }
    mapping(address => RewardConfig) public configs;

    // Appended after V10 storage. One helper instance is scoped to one strategy asset.
    address public outputAssetPriceFeed;
    uint8 public outputAssetDecimals;
    uint8 public outputAssetFeedDecimals;
    uint32 public outputAssetMaxFeedAgeSec;
    bool public legacyUsdcMode;

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
    error FutureOracleTimestamp(uint256 updatedAt);
    error LegacyUsdcSelectorDisabled();

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

    /// @notice One-shot initialization called atomically by AdapterFactory.
    function initialize(
        address usdc_,
        address admin_,
        address uniswapV3Router_,
        address camelotV3Router_
    ) external initializer {
        legacyUsdcMode = true;
        _initializeAsset(usdc_, admin_, uniswapV3Router_, camelotV3Router_);
    }

    /// @notice Initialize an arbitrary output asset; the legacy USDC selector is disabled.
    function initializeAsset(address asset_, address admin_, address uniRouter_, address camelotRouter_)
        external initializer
    {
        _initializeAsset(asset_, admin_, uniRouter_, camelotRouter_);
    }

    function _initializeAsset(address usdc_, address admin_, address uniswapV3Router_, address camelotV3Router_)
        internal
    {
        if (usdc_ == address(0) || admin_ == address(0) || uniswapV3Router_ == address(0)) {
            revert ZeroAddress();
        }
        usdc = usdc_;
        uint8 assetDecimals_ = IERC20Metadata(usdc_).decimals();
        if (assetDecimals_ > 18) revert InvalidConfig();
        outputAssetDecimals = assetDecimals_;
        uniswapV3Router = uniswapV3Router_;
        camelotV3Router = camelotV3Router_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(PARAM_ROLE, admin_);
    }

    /// @notice Set the configured strategy asset's USD feed and freshness bound.
    function setOutputAssetOracle(address feed, uint32 maxFeedAgeSec) external onlyRole(PARAM_ROLE) {
        if (feed == address(0)) revert ZeroAddress();
        if (maxFeedAgeSec < MIN_MAX_FEED_AGE_SEC || maxFeedAgeSec > MAX_MAX_FEED_AGE_SEC) {
            revert MaxFeedAgeOutOfRange(maxFeedAgeSec);
        }
        uint8 feedDecimals_ = IChainlinkFeed(feed).decimals();
        if (feedDecimals_ > 18) revert InvalidConfig();
        outputAssetPriceFeed = feed;
        outputAssetFeedDecimals = feedDecimals_;
        outputAssetMaxFeedAgeSec = maxFeedAgeSec;
        emit OutputAssetOracleUpdated(feed, feedDecimals_, outputAssetDecimals, maxFeedAgeSec);
    }

    /// @notice Output token for this helper; `usdc()` remains for ABI compatibility.
    function outputAsset() external view returns (address) {
        return usdc;
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
        if (slippageBps > 500) revert SlippageTooHigh(slippageBps); // hard cap 5% (sandwich mitigation)
        if (uniswapV3Path.length == 0) revert InvalidConfig();
        if (feedDecimals > 18 || tokenDecimals > 18) revert InvalidConfig();
        if (maxFeedAgeSec < MIN_MAX_FEED_AGE_SEC || maxFeedAgeSec > MAX_MAX_FEED_AGE_SEC) {
            revert MaxFeedAgeOutOfRange(maxFeedAgeSec);
        }
        if (IChainlinkFeed(chainlinkFeed).decimals() != feedDecimals) revert InvalidConfig();
        if (IERC20Metadata(rewardToken).decimals() != tokenDecimals) revert InvalidConfig();
        if (!_validPath(uniswapV3Path, rewardToken, false)) revert InvalidConfig();
        if (camelotV3Path.length > 0 && !_validPath(camelotV3Path, rewardToken, true)) revert InvalidConfig();
        if (outputAssetPriceFeed == address(0)) revert InvalidConfig();

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

    // ─── Core: reward token to configured strategy asset ────────────────

    /// @notice Pull rewardToken from caller, swap to the configured asset,
    ///         and transfer that asset to receiver.
    /// @dev Caller must have approved this helper for `amountIn` of rewardToken.
    /// @return amountOut configured strategy asset delivered to receiver.
    function swapToAsset(
        address rewardToken,
        uint256 amountIn,
        address receiver
    ) external nonReentrant onlyRole(KEEPER_ROLE) returns (uint256 amountOut) {
        return _swapToAsset(rewardToken, amountIn, receiver);
    }

    /// @notice Legacy USDC integrations only. Generic asset instances reject this selector.
    function swapToUSDC(
        address rewardToken,
        uint256 amountIn,
        address receiver
    ) external nonReentrant onlyRole(KEEPER_ROLE) returns (uint256 amountOut) {
        if (!legacyUsdcMode) revert LegacyUsdcSelectorDisabled();
        return _swapToAsset(rewardToken, amountIn, receiver);
    }

    function _swapToAsset(address rewardToken, uint256 amountIn, address receiver)
        internal
        returns (uint256 amountOut)
    {
        RewardConfig memory cfg = configs[rewardToken];
        if (!cfg.enabled) revert NotEnabled(rewardToken);
        if (receiver == address(0)) revert ZeroAddress();
        if (amountIn == 0) return 0;

        // RA-10: L2 sequencer health gate (defends against post-outage stale feeds)
        _requireSequencerOk();

        // 1. Pull reward tokens from caller
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amountIn);

        // 2. Compute oracle-anchored minOut
        uint256 expectedOut = _oracleExpectedAssetOut(amountIn, cfg);
        uint256 minOut = Math.mulDiv(expectedOut, 10_000 - cfg.slippageBps, 10_000);

        // 3. Try Uniswap V3 (primary)
        amountOut = _tryUniV3(rewardToken, amountIn, minOut, cfg.uniswapV3Path);
        uint8 dexUsed = 1;

        // 4. Fallback: Camelot V3 if Uniswap failed
        if (amountOut == 0 && cfg.camelotV3Path.length > 0 && camelotV3Router != address(0)) {
            amountOut = _tryCamelotV3(rewardToken, amountIn, minOut, cfg.camelotV3Path);
            dexUsed = 2;
        }

        if (amountOut == 0) revert AllRoutesFailed();

        // 5. Forward the configured output asset to receiver
        IERC20(usdc).safeTransfer(receiver, amountOut);
        emit Swapped(msg.sender, rewardToken, amountIn, amountOut, receiver, dexUsed);
    }

    // ─── Internal: oracle expected output-asset amount ──────────────────

    function _oracleExpectedAssetOut(uint256 amountIn, RewardConfig memory cfg)
        internal
        view
        returns (uint256)
    {
        uint256 rewardPriceWad = _freshPriceWad(
            IChainlinkFeed(cfg.chainlinkFeed), cfg.feedDecimals, cfg.maxFeedAgeSec, false
        );
        uint256 assetPriceWad = _freshPriceWad(
            IChainlinkFeed(outputAssetPriceFeed), outputAssetFeedDecimals, outputAssetMaxFeedAgeSec, true
        );
        uint256 rewardValueWad = Math.mulDiv(amountIn, rewardPriceWad, 10 ** uint256(cfg.tokenDecimals));
        return Math.mulDiv(rewardValueWad, 10 ** uint256(outputAssetDecimals), assetPriceWad);
    }

    function _freshPriceWad(IChainlinkFeed feed, uint8 feedDecimals, uint32 maxAge, bool roundUp)
        internal
        view
        returns (uint256 priceWad)
    {
        (, int256 answer, , uint256 updatedAt, ) = feed.latestRoundData();
        if (updatedAt == 0) revert StaleOracle(updatedAt, maxAge);
        if (block.timestamp < updatedAt) revert FutureOracleTimestamp(updatedAt);
        if (block.timestamp - updatedAt > maxAge) revert StaleOracle(updatedAt, maxAge);
        if (answer <= 0) revert InvalidOraclePrice(answer);
        uint256 scale = 10 ** uint256(feedDecimals);
        priceWad = Math.mulDiv(uint256(answer), 1e18, scale);
        if (roundUp && mulmod(uint256(answer), 1e18, scale) != 0) ++priceWad;
        if (priceWad == 0) revert InvalidOraclePrice(answer);
    }

    /// @dev Uniswap uses token/fee/token; Camelot Algebra V1 uses token/token.
    ///      A different Algebra router version requires a separately reviewed integration.
    function _validPath(bytes calldata path, address rewardToken, bool algebraV1) internal view returns (bool) {
        uint256 step = algebraV1 ? 20 : 23;
        if (path.length < 20 + step || (path.length - 20) % step != 0) return false;
        address first;
        address last;
        assembly {
            first := shr(96, calldataload(path.offset))
            last := shr(96, calldataload(add(path.offset, sub(path.length, 20))))
        }
        return first == rewardToken && last == usdc;
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
        return _feedUsable(cfg.chainlinkFeed, cfg.maxFeedAgeSec)
            && _feedUsable(outputAssetPriceFeed, outputAssetMaxFeedAgeSec);
    }

    function _feedUsable(address feed, uint32 maxAge) internal view returns (bool) {
        if (feed == address(0)) return false;
        try IChainlinkFeed(feed).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            return answer > 0 && updatedAt > 0 && block.timestamp >= updatedAt
                && block.timestamp - updatedAt <= maxAge;
        } catch {
            return false;
        }
    }

    /// @notice Preview expectedOut for a given input — useful for off-chain monitoring.
    ///         Not authoritative; actual swap may differ.
    /// @dev Returns raw units of `outputAsset()`.
    function previewExpectedOut(address rewardToken, uint256 amountIn)
        external view returns (uint256)
    {
        RewardConfig memory cfg = configs[rewardToken];
        if (!cfg.enabled) return 0;
        return _oracleExpectedAssetOut(amountIn, cfg);
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
