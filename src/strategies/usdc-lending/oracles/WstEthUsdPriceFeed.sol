// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

// ─── Minimal wstETH interface ─────────────────────────────────────────────────
// Source: https://docs.lido.fi/contracts/wsteth/
// stETH() returns the underlying rebasing token address.
// getStETHByWstETH(uint256) returns the amount of stETH for a given wstETH amount.
// The wstETH balance is non-rebasing; all staking value accrues through the
// increasing conversion rate, not through balance changes.
interface IWstETH {
    function decimals() external view returns (uint8);
    function stETH() external view returns (address);
    function getStETHByWstETH(uint256 wstEthAmount) external view returns (uint256);
}

// ─── Minimal stETH interface (for decimal validation only) ───────────────────
interface IStETH {
    function decimals() external view returns (uint8);
}

// ─── Chainlink AggregatorV3Interface (subset used) ───────────────────────────
// The stETH/USD feed (0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8) exposes
// latestRoundData with 8 decimals and the description "STETH / USD".
// Trust for feed address selection is an explicit immutable manifest input;
// callers must supply the correct stETH/USD feed, not ETH/USD or an unrelated feed.
interface IChainlinkFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
    function getRoundData(uint80 _roundId) external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// WstEthUsdPriceFeed
// ─────────────────────────────────────────────────────────────────────────────
//
// Strategy-owned price feed that computes wstETH/USD from:
//   1. The on-chain wstETH redemption rate:  wstETH.getStETHByWstETH(1e18)
//   2. The Chainlink stETH/USD spot price:   stEthFeed.latestRoundData().answer
//
// Formula (no peg assumption, no staking-APR double-count):
//   price = stEthPerWstEth × stEthUsdPrice / 1e18
//
// where stEthPerWstEth is the current on-chain conversion (18-decimal rate),
// stEthUsdPrice is the Chainlink answer in feedDecimals, and the result is
// expressed in the same feedDecimals.  Math.mulDiv prevents intermediate
// overflow.
//
// Design constraints:
//   • latest-only interface — getRoundData reverts; historical wstETH prices
//     cannot be reconstructed from historical stETH rounds alone.
//   • Freshness / max-age / round-continuity guards belong to the Core caller;
//     this contract forwards updatedAt and answeredInRound unchanged so callers
//     can apply those checks themselves.
//   • No mutable state, roles, or price overrides after deployment.
// ─────────────────────────────────────────────────────────────────────────────
contract WstEthUsdPriceFeed {
    using Math for uint256;

    // ── Immutables ────────────────────────────────────────────────────────────

    IWstETH  public immutable wrappedToken;
    IChainlinkFeed public immutable stEthUsdFeed;

    // decimals of the underlying stETH/USD Chainlink feed, cached at construction
    uint8 private immutable _feedDecimals;

    // ── Constructor ───────────────────────────────────────────────────────────

    // @param wrappedToken_  wstETH token (must be 18 decimals; stETH() must be 18 decimals)
    // @param stEthUsdFeed_  Chainlink stETH/USD aggregator — caller is responsible for
    //                       binding the correct feed; this contract trusts it unconditionally.
    constructor(address wrappedToken_, address stEthUsdFeed_) {
        require(wrappedToken_ != address(0), "WstEthUsdPriceFeed: zero wstETH");
        require(stEthUsdFeed_ != address(0), "WstEthUsdPriceFeed: zero feed");

        // Reject EOAs / undeployed addresses
        require(_hasCode(wrappedToken_), "WstEthUsdPriceFeed: wstETH not a contract");
        require(_hasCode(stEthUsdFeed_), "WstEthUsdPriceFeed: feed not a contract");

        IWstETH token = IWstETH(wrappedToken_);

        // wstETH must be 18 decimals
        require(token.decimals() == 18, "WstEthUsdPriceFeed: wstETH not 18 decimals");

        // Underlying stETH must also be 18 decimals
        address stEthAddr = token.stETH();
        require(stEthAddr != address(0), "WstEthUsdPriceFeed: stETH zero");
        require(_hasCode(stEthAddr), "WstEthUsdPriceFeed: stETH not a contract");
        require(IStETH(stEthAddr).decimals() == 18, "WstEthUsdPriceFeed: stETH not 18 decimals");

        // Validate conversion is positive at construction time
        uint256 rate = token.getStETHByWstETH(1e18);
        require(rate > 0, "WstEthUsdPriceFeed: zero conversion rate");

        // Feed decimal bounds: Chainlink USD feeds are consistently 8 decimals,
        // but we accept 6–18 to tolerate future configurations without reverting.
        IChainlinkFeed feed = IChainlinkFeed(stEthUsdFeed_);
        uint8 fd = feed.decimals();
        require(fd >= 6 && fd <= 18, "WstEthUsdPriceFeed: feed decimals out of range");

        wrappedToken  = token;
        stEthUsdFeed  = feed;
        _feedDecimals = fd;
    }

    // ── Chainlink-compatible latest-data surface ─────────────────────────────

    // Returns the same decimals as the underlying stETH/USD feed so that
    // callers can substitute this feed without rescaling.
    function decimals() external view returns (uint8) {
        return _feedDecimals;
    }

    // Explicit latest-only interface.  Historical wstETH prices cannot be
    // derived from historical stETH rounds because the conversion rate is
    // a live on-chain value, not an archived one.
    function getRoundData(uint80 /*_roundId*/) external pure returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        revert("WstEthUsdPriceFeed: historical rounds not supported");
    }

    // Computes wstETH/USD and forwards the underlying round metadata unchanged.
    // Freshness (max-age), round-continuity, and future-timestamp guards are
    // the responsibility of the Core caller.
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        // Fetch stETH/USD from Chainlink — metadata forwarded verbatim
        (roundId, answer, startedAt, updatedAt, answeredInRound) =
            stEthUsdFeed.latestRoundData();

        require(answer > 0, "WstEthUsdPriceFeed: non-positive stETH/USD answer");

        // Fetch current on-chain redemption rate: stETH per 1 wstETH (18-dec)
        uint256 stEthPerWstEth = wrappedToken.getStETHByWstETH(1e18);
        require(stEthPerWstEth > 0, "WstEthUsdPriceFeed: non-positive conversion rate");

        // price = stEthPerWstEth × answer / 1e18
        // stEthPerWstEth is 18-decimal; dividing by 1e18 keeps answer's scale.
        // Math.mulDiv guards against intermediate overflow.
        uint256 uAnswer = uint256(answer);
        uint256 rawPrice = Math.mulDiv(stEthPerWstEth, uAnswer, 1e18);

        require(rawPrice > 0, "WstEthUsdPriceFeed: zero wstETH/USD price");
        require(rawPrice <= uint256(type(int256).max), "WstEthUsdPriceFeed: price overflow int256");

        answer = int256(rawPrice);
        // roundId / startedAt / updatedAt / answeredInRound already set above
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    function _hasCode(address addr) private view returns (bool ok) {
        assembly { ok := gt(extcodesize(addr), 0) }
    }
}
