// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { WstEthUsdPriceFeed } from "../../../src/strategies/usdc-lending/oracles/WstEthUsdPriceFeed.sol";

// ═════════════════════════════════════════════════════════════════════════════
// Controlled mock contracts — no fork / no network / no credentials
// ═════════════════════════════════════════════════════════════════════════════

contract MockStETH {
    uint8 public decimals = 18;
}

contract MockWstETH {
    uint8 public decimals = 18;
    address public stETH;
    uint256 public stEthPerToken;

    constructor(address stEth_, uint256 rate_) {
        stETH = stEth_;
        stEthPerToken = rate_;
    }

    function getStETHByWstETH(uint256 wstEthAmount) external view returns (uint256) {
        return Math.mulDiv(wstEthAmount, stEthPerToken, 1e18);
    }

    function setRate(uint256 rate_) external { stEthPerToken = rate_; }
    function setDecimals(uint8 d) external { decimals = d; }
}

contract MockFeed {
    uint8 public decimals = 8;
    int256 public price;
    uint80 public roundId_ = 42;
    uint256 public startedAt_ = 1_000_000;
    uint256 public updatedAt_ = 1_100_000;
    uint80 public answeredInRound_ = 42;

    constructor(int256 price_) { price = price_; }

    function latestRoundData() external view returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        return (roundId_, price, startedAt_, updatedAt_, answeredInRound_);
    }

    // This mock also exposes getRoundData to satisfy the interface check during
    // constructor calls on WstEthUsdPriceFeed (which calls feed.decimals() only).
    function getRoundData(uint80) external pure returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        revert("not supported");
    }

    function setPrice(int256 p) external { price = p; }
    function setDecimals(uint8 d) external { decimals = d; }
    function setRound(uint80 r, uint256 sa, uint256 ua, uint80 ar) external {
        roundId_ = r; startedAt_ = sa; updatedAt_ = ua; answeredInRound_ = ar;
    }
}

// Mock that reverts on getStETHByWstETH
contract MockWstETH_RevertingRate {
    uint8 public decimals = 18;
    address public stETH;
    bool public unavailable;
    constructor(address stEth_) { stETH = stEth_; }
    function setUnavailable() external { unavailable = true; }
    function getStETHByWstETH(uint256 amount) external view returns (uint256) {
        require(!unavailable, "rate unavailable");
        return amount;
    }
}

// Mock wstETH where stETH is an EOA (no code)
contract MockWstETH_EOAStETH {
    uint8 public decimals = 18;
    address public stETH = address(0xdead);
    uint256 public stEthPerToken = 1.1e18;
    function getStETHByWstETH(uint256 wstEthAmount) external view returns (uint256) {
        return Math.mulDiv(wstEthAmount, stEthPerToken, 1e18);
    }
}

// Mock stETH with wrong decimals
contract MockStETH_BadDecimals {
    uint8 public decimals = 6;
}

// Mock wstETH with wrong decimals
contract MockWstETH_BadDecimals {
    uint8 public decimals = 6;
    address public stETH;
    uint256 public stEthPerToken = 1.1e18;
    constructor(address stEth_) { stETH = stEth_; }
    function getStETHByWstETH(uint256 wstEthAmount) external view returns (uint256) {
        return Math.mulDiv(wstEthAmount, stEthPerToken, 1e18);
    }
}

// Mock feed with decimals out of range
contract MockFeed_BadDecimals {
    uint8 public decimals = 3;
    function latestRoundData() external pure returns (uint80,int256,uint256,uint256,uint80) {
        return (1, 1e3, 0, 0, 1);
    }
    function getRoundData(uint80) external pure returns (uint80,int256,uint256,uint256,uint80) {
        revert();
    }
}

// Mock feed that reverts on latestRoundData
contract MockFeed_Reverting {
    uint8 public decimals = 8;
    function latestRoundData() external pure returns (uint80,int256,uint256,uint256,uint80) {
        revert("oracle down");
    }
    function getRoundData(uint80) external pure returns (uint80,int256,uint256,uint256,uint80) {
        revert();
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// Test suite
// ═════════════════════════════════════════════════════════════════════════════

contract WstEthUsdPriceFeedTest is Test {

    MockStETH   stEth;
    MockWstETH  wstEth;
    MockFeed    feed;
    WstEthUsdPriceFeed priceFeed;

    // Controlled arithmetic vectors, not historical market observations.
    uint256 constant RATE = 1.197e18;
    int256  constant STETH_USD = 3_400e8;

    function setUp() public {
        stEth  = new MockStETH();
        wstEth = new MockWstETH(address(stEth), RATE);
        feed   = new MockFeed(STETH_USD);
        priceFeed = new WstEthUsdPriceFeed(address(wstEth), address(feed));
    }

    // ── Construction ─────────────────────────────────────────────────────────

    function test_decimals_matchFeed() public view {
        assertEq(priceFeed.decimals(), feed.decimals());
    }

    function test_immutables_set() public view {
        assertEq(address(priceFeed.wrappedToken()),  address(wstEth));
        assertEq(address(priceFeed.stEthUsdFeed()),  address(feed));
    }

    // ── Positive price computation ────────────────────────────────────────────

    function test_latestRoundData_positivePrice() public view {
        (, int256 answer,,,) = priceFeed.latestRoundData();
        assertEq(answer, 4_069_80000000);
        assertGt(answer, 0);
    }

    function test_latestRoundData_18decimalConversion() public {
        // Rate = 1e18 (1:1 peg) → wstETH/USD should equal stETH/USD exactly
        wstEth.setRate(1e18);
        (, int256 answer,,,) = priceFeed.latestRoundData();
        assertEq(answer, STETH_USD);
    }

    function test_latestRoundData_rateAboveOne() public {
        // Rate = 1.5e18 → price should be 1.5× stETH/USD
        wstEth.setRate(1.5e18);
        (, int256 answer,,,) = priceFeed.latestRoundData();
        assertEq(answer, 5_100e8);
    }

    function test_fractionalConversionFloorsToPublishedFeedDecimals() public {
        wstEth.setRate(1_234_567_890_123_456_789);
        feed.setPrice(234_567_890_123);
        (, int256 answer,,,) = priceFeed.latestRoundData();
        assertEq(answer, 289_589_985_199);
    }

    function test_revert_resultOutsideSignedPriceRange() public {
        wstEth.setRate(2e18);
        feed.setPrice(type(int256).max);
        vm.expectRevert("WstEthUsdPriceFeed: price overflow int256");
        priceFeed.latestRoundData();
    }

    function test_revert_productOutsideUnsignedPriceRange() public {
        wstEth.setRate(type(uint256).max);
        feed.setPrice(2e18);
        vm.expectRevert();
        priceFeed.latestRoundData();
    }

    // ── Metadata forwarded verbatim ───────────────────────────────────────────

    function test_latestRoundData_metadataUnchanged() public {
        uint80 r = 77; uint256 sa = 9_000_000; uint256 ua = 9_100_000; uint80 ar = 77;
        feed.setRound(r, sa, ua, ar);

        (uint80 roundId,, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        assertEq(roundId,         r);
        assertEq(startedAt,       sa);
        assertEq(updatedAt,       ua);
        assertEq(answeredInRound, ar);
    }

    function test_latestRoundData_staleTimestampNotRefreshed() public {
        // updatedAt = 1 (ancient) — feed is stale; contract must NOT replace it with block.timestamp
        feed.setRound(1, 1, 1, 1);
        (,,, uint256 updatedAt,) = priceFeed.latestRoundData();
        assertEq(updatedAt, 1, "updatedAt must be forwarded unchanged");
    }

    // ── Rejection: non-positive / zero / overflow ─────────────────────────────

    function test_revert_nonPositiveAnswer() public {
        feed.setPrice(0);
        vm.expectRevert("WstEthUsdPriceFeed: non-positive stETH/USD answer");
        priceFeed.latestRoundData();
    }

    function test_revert_negativeAnswer() public {
        feed.setPrice(-1);
        vm.expectRevert("WstEthUsdPriceFeed: non-positive stETH/USD answer");
        priceFeed.latestRoundData();
    }

    function test_revert_zeroConversionRate() public {
        // Deploy with a reverting-rate mock — constructor would reject zero, so
        // we set the rate to zero after construction via a writable mock.
        wstEth.setRate(0);
        vm.expectRevert("WstEthUsdPriceFeed: non-positive conversion rate");
        priceFeed.latestRoundData();
    }

    function test_revert_roundedResultZero() public {
        // Force price = 1 (tiny) and rate = 1 (tiny) so mulDiv(1, 1, 1e18) = 0
        feed.setPrice(1);
        wstEth.setRate(1);
        vm.expectRevert("WstEthUsdPriceFeed: zero wstETH/USD price");
        priceFeed.latestRoundData();
    }

    // ── Rejection: reverting dependencies ────────────────────────────────────

    function test_revert_feedReverts() public {
        MockFeed_Reverting revertFeed = new MockFeed_Reverting();
        WstEthUsdPriceFeed pf = new WstEthUsdPriceFeed(address(wstEth), address(revertFeed));
        vm.expectRevert("oracle down");
        pf.latestRoundData();
    }

    function test_revert_wstEthRateReverts() public {
        MockWstETH_RevertingRate badWst = new MockWstETH_RevertingRate(address(stEth));
        WstEthUsdPriceFeed pf = new WstEthUsdPriceFeed(address(badWst), address(feed));
        badWst.setUnavailable();
        vm.expectRevert("rate unavailable");
        pf.latestRoundData();
    }

    // ── getRoundData reverts ──────────────────────────────────────────────────

    function test_getRoundData_alwaysReverts() public {
        vm.expectRevert("WstEthUsdPriceFeed: historical rounds not supported");
        priceFeed.getRoundData(1);
    }

    function test_getRoundData_roundZeroReverts() public {
        vm.expectRevert("WstEthUsdPriceFeed: historical rounds not supported");
        priceFeed.getRoundData(0);
    }

    // ── Constructor rejections ────────────────────────────────────────────────

    function test_constructor_revert_zeroWstETH() public {
        vm.expectRevert("WstEthUsdPriceFeed: zero wstETH");
        new WstEthUsdPriceFeed(address(0), address(feed));
    }

    function test_constructor_revert_zeroFeed() public {
        vm.expectRevert("WstEthUsdPriceFeed: zero feed");
        new WstEthUsdPriceFeed(address(wstEth), address(0));
    }

    function test_constructor_revert_wstETH_codeless() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert("WstEthUsdPriceFeed: wstETH not a contract");
        new WstEthUsdPriceFeed(eoa, address(feed));
    }

    function test_constructor_revert_feed_codeless() public {
        address eoa = makeAddr("eoa2");
        vm.expectRevert("WstEthUsdPriceFeed: feed not a contract");
        new WstEthUsdPriceFeed(address(wstEth), eoa);
    }

    function test_constructor_revert_wstETH_wrongDecimals() public {
        MockStETH stEth18 = new MockStETH(); // 18 dec
        MockWstETH_BadDecimals bad = new MockWstETH_BadDecimals(address(stEth18));
        vm.expectRevert("WstEthUsdPriceFeed: wstETH not 18 decimals");
        new WstEthUsdPriceFeed(address(bad), address(feed));
    }

    function test_constructor_revert_stETH_wrongDecimals() public {
        MockStETH_BadDecimals badStEth = new MockStETH_BadDecimals();
        MockWstETH wst6 = new MockWstETH(address(badStEth), 1.1e18);
        vm.expectRevert("WstEthUsdPriceFeed: stETH not 18 decimals");
        new WstEthUsdPriceFeed(address(wst6), address(feed));
    }

    function test_constructor_revert_stETH_codeless() public {
        MockWstETH_EOAStETH badWst = new MockWstETH_EOAStETH();
        vm.expectRevert("WstEthUsdPriceFeed: stETH not a contract");
        new WstEthUsdPriceFeed(address(badWst), address(feed));
    }

    function test_constructor_revert_feed_badDecimals() public {
        MockFeed_BadDecimals bad = new MockFeed_BadDecimals();
        vm.expectRevert("WstEthUsdPriceFeed: feed decimals out of range");
        new WstEthUsdPriceFeed(address(wstEth), address(bad));
    }

    function test_constructor_revert_zeroConversionRate() public {
        // getStETHByWstETH(1e18) returns 0 when rate = 0
        MockWstETH zeroRateWst = new MockWstETH(address(stEth), 0);
        vm.expectRevert("WstEthUsdPriceFeed: zero conversion rate");
        new WstEthUsdPriceFeed(address(zeroRateWst), address(feed));
    }

    // ── Fuzz: rate × price product stays in range ────────────────────────────

    /// @dev Covers realistic wstETH rates (1e18–2e18) and stETH prices ($1–$10k in 8-dec)
    function testFuzz_positivePrice(uint256 rate, int256 stEthUsd) public {
        rate      = bound(rate,      1e18,         2e18);       // 1× – 2× conversion
        stEthUsd  = int256(bound(uint256(stEthUsd), 1e8, 100_000e8)); // $1 – $100k

        wstEth.setRate(rate);
        feed.setPrice(stEthUsd);

        (, int256 answer,,,) = priceFeed.latestRoundData();
        // The bounded operands fit uint256; this reference does not reuse mulDiv.
        uint256 expected = rate * uint256(stEthUsd) / 1e18;
        assertEq(uint256(answer), expected);
        assertGt(answer, 0);
    }
}
