// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CometUsdcMultiMarketAdapter} from "../../../src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol";
import {DolomiteUsdcMultiMarketAdapter} from "../../../src/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol";
import {MockComet} from "./adapters/CometUsdcMultiMarketAdapter.t.sol";
import {MockUSDCDolo, MockDoloPoolLike, MockDoloRegistry, MockDoloERC4626} from "./adapters/DolomiteUsdcMultiMarketAdapter.t.sol";
import {SimpleProtocolRegistry} from "../../helpers/SimpleProtocolRegistry.sol";

contract RateTestAsset is ERC20 {
    uint8 immutable precision;
    constructor(uint8 d) ERC20("Asset", "ASSET") { precision = d; }
    function decimals() public view override returns (uint8) { return precision; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract PerMarketRateProvider {
    mapping(address => uint256) public rates;
    mapping(address => bool) public broken;
    function set(address m, uint256 r) external { rates[m] = r; }
    function setBroken(address m) external { broken[m] = true; }
    function getSupplyRatePerSecond(address m) external view returns (uint256) {
        require(!broken[m], "unavailable rate");
        return rates[m];
    }
}

contract AdapterRateRemediationTest is Test {
    function test_cometLiquidityScoreSixDecimals() public { _comet(6, 1000); }
    function test_cometLiquidityScoreEighteenDecimals() public { _comet(18, 1000); }
    function test_cometLiquidityScoreEquivalentHighPriceAsset() public { _comet(18, 1); }

    function _comet(uint8 d, uint256 quantity) internal {
        RateTestAsset token = new RateTestAsset(d);
        MockComet from = new MockComet(address(token));
        MockComet to = new MockComet(address(token));
        SimpleProtocolRegistry r = new SimpleProtocolRegistry();
        r.addVault(SimpleProtocolRegistry.ProtocolType.COMPOUND_V3, address(from), "from", 10000, type(uint256).max);
        CometUsdcMultiMarketAdapter a = new CometUsdcMultiMarketAdapter();
        a.initialize(address(token), address(this), address(this), type(uint256).max, address(r));
        a.addMarket(address(to));
        uint256 amount = quantity * 10 ** d;
        token.mint(address(this), amount);
        token.approve(address(a), amount);
        from.setSupplyRate(2_000_000_000);
        to.setSupplyRate(1_000_000_000);
        a.deposit(amount);
        // Both markets can fill the entire position. Excess cash must not drown out APY.
        token.mint(address(from), amount * 1_000_000);
        token.mint(address(to), amount);
        to.setSupplyRate(4_000_000_000);
        a.setCostsEstimates(0, 0, 0);
        a.setOptimizeParams(0, 50, 2);
        (uint256 moved, address source, address target) = a.optimize();
        assertEq(moved, amount);
        assertEq(source, address(from));
        assertEq(target, address(to));
        assertEq(from.balanceOf(address(a)), 0);
        assertEq(to.balanceOf(address(a)), amount);
        assertEq(token.allowance(address(a), address(to)), 0);
    }

    function test_dolomiteOptimizesUsingDistinctLiveMarketRates() public { _dolomite(false); }
    function test_dolomiteUnavailableSourceRateDoesNotBrickHealthyTarget() public { _dolomite(true); }

    function test_dolomiteOptimizesUsingDistinctObservedPpsRates() public {
        vm.warp(1 days);
        MockUSDCDolo token = new MockUSDCDolo();
        MockDoloPoolLike unused = new MockDoloPoolLike(address(token));
        MockDoloERC4626 from = new MockDoloERC4626(address(token));
        MockDoloERC4626 to = new MockDoloERC4626(address(token));
        DolomiteUsdcMultiMarketAdapter a = new DolomiteUsdcMultiMarketAdapter();
        a.initialize(address(token), address(this), address(this), type(uint256).max, address(new MockDoloRegistry(address(unused))));
        a.addMarket(address(from), DolomiteUsdcMultiMarketAdapter.MarketType.ERC4626);
        a.addMarket(address(to), DolomiteUsdcMultiMarketAdapter.MarketType.ERC4626);
        a.toggleMarket(0, false);
        a.validateDolomiteConfig();
        token.mint(address(this), 3000e6);
        token.approve(address(from), 1000e6);
        token.approve(address(to), 1000e6);
        from.deposit(1000e6, address(this));
        to.deposit(1000e6, address(this));
        token.approve(address(a), 1000e6);
        a.deposit(1000e6);
        assertEq(from.balanceOf(address(a)), 1000e6);
        a.pokeAPYSnapshots();
        vm.warp(block.timestamp + 1 days);
        from.simulateInterest(1e6);
        to.simulateInterest(1e6);
        token.mint(address(from), 1e6);
        token.mint(address(to), 1e6);
        // Same absolute interest: target's smaller asset base earns twice the rate.
        a.setCostsEstimates(0, 0, 0);
        a.setOptimizeParams(0, 500, 2, 80);
        (uint256 moved, address source, address target) = a.optimize();
        assertGt(moved, 50e6);
        assertEq(source, address(from));
        assertEq(target, address(to));
        assertGt(to.balanceOf(address(a)), 0);
        assertGt(a.currentAPYBps(), 3000);
    }

    function _dolomite(bool unavailable) internal {
        MockUSDCDolo token = new MockUSDCDolo();
        MockDoloPoolLike from = new MockDoloPoolLike(address(token));
        MockDoloPoolLike to = new MockDoloPoolLike(address(token));
        from.setLiquidBalance(1_000_000e6);
        to.setLiquidBalance(1_000_000e6);
        MockDoloRegistry r = new MockDoloRegistry(address(from));
        DolomiteUsdcMultiMarketAdapter a = new DolomiteUsdcMultiMarketAdapter();
        a.initialize(address(token), address(this), address(this), type(uint256).max, address(r));
        a.addMarket(address(to), DolomiteUsdcMultiMarketAdapter.MarketType.PoolLike);
        a.validateDolomiteConfig();
        PerMarketRateProvider rates = new PerMarketRateProvider();
        a.setRateProvider(address(rates));
        rates.set(address(from), 2_000_000_000);
        rates.set(address(to), 1_000_000_000);
        token.mint(address(this), 1000e6);
        token.approve(address(a), 1000e6);
        a.deposit(1000e6);
        assertEq(from.balanceOf(address(a)), 1000e6);
        rates.set(address(to), 4_000_000_000);
        if (unavailable) rates.setBroken(address(from));
        a.setCostsEstimates(0, 0, 0);
        a.setOptimizeParams(0, 500, 2, 80);
        (uint256 moved, address source, address target) = a.optimize();
        assertEq(moved, 50e6);
        assertEq(source, address(from));
        assertEq(target, address(to));
        assertEq(from.balanceOf(address(a)), 950e6);
        assertEq(to.balanceOf(address(a)), 50e6);
        assertGt(a.currentAPYBps(), 1000);
        assertEq(token.allowance(address(a), address(to)), 0);
    }
}
