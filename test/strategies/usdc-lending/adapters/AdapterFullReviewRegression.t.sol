// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockUSDCMorpho, MockMorphoVault} from "./MorphoAdapter.t.sol";
import {MockUSDCVenus, MockVToken} from "./VenusUsdcMultiMarketAdapter.t.sol";
import {MockUSDCEulX, MockEulerVault, MockPermit2X} from "./EulerUsdcMultiMarketAdapter.t.sol";
import {ProtocolRegistry} from "../../../../src/strategies/usdc-lending/registry/ProtocolRegistry.sol";
import {DolomiteUsdcMultiMarketAdapter as Dolomite} from "../../../../src/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol";
import {VenusUsdcMultiMarketAdapter as Venus} from "../../../../src/strategies/usdc-lending/adapters/lending/VenusUsdcMultiMarket.sol";
import {EulerUsdcMultiMarketAdapter as Euler} from "../../../../src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol";

/// @dev Controlled fault injection, separate from no-mock real-market acceptance.
contract ReviewEulerRateMarket is MockEulerVault {
    uint256 public immutable interestRate;
    constructor(address token, uint256 rate) MockEulerVault(token) {
        interestRate = rate;
        _totalAssets = 1500e6;
        totalSupply = 1500e6;
        balanceOf[address(0xdead)] = 1500e6;
        MockUSDCEulX(token).mint(address(this), 1000e6);
    }
    function totalBorrows() external pure returns (uint256) { return 500e6; }
    function interestFee() external pure returns (uint16) { return 0; }
}

contract ReviewEulerRegistry {
    address[] internal entries;
    function set(address[] memory values) external { entries = values; }
    function getEnabledVaults(ProtocolRegistry.ProtocolType) external view returns (address[] memory) { return entries; }
}

contract AdapterFullReviewRegressionTest is Test {
    function test_dolomiteRegistryExcludesForeignUnderlying() public {
        MockUSDCMorpho token = new MockUSDCMorpho();
        MockUSDCMorpho foreign = new MockUSDCMorpho();
        MockMorphoVault good = new MockMorphoVault(address(token));
        MockMorphoVault wrong = new MockMorphoVault(address(foreign));
        ProtocolRegistry registry = ProtocolRegistry(deployCode("ProtocolRegistry.sol:ProtocolRegistry", abi.encode(address(this))));
        registry.addVault(ProtocolRegistry.ProtocolType.DOLOMITE, address(good), "matching", 1000, 1_000_000e6);
        registry.addVault(ProtocolRegistry.ProtocolType.DOLOMITE, address(wrong), "foreign", 1000, 1_000_000e6);
        Dolomite adapter = Dolomite(payable(deployCode("DolomiteUsdcMultiMarket.sol:DolomiteUsdcMultiMarketAdapter")));
        adapter.initialize(address(token), address(this), address(this), 1_000_000e6, address(registry));
        address[] memory markets = adapter.markets();
        assertEq(markets.length, 1, "foreign asset cannot enter the asset-denominated market book");
        assertEq(markets[0], address(good));
    }

    function test_venusErrorCodeStillSweepsIdleAndPreservesReceipts() public {
        MockUSDCVenus token = new MockUSDCVenus();
        MockVToken market = new MockVToken(address(token));
        Venus adapter = Venus(payable(deployCode("VenusUsdcMultiMarket.sol:VenusUsdcMultiMarketAdapter")));
        adapter.initialize(address(token), address(this), address(this), 1_000_000e6, address(market), 31_536_000);
        token.mint(address(this), 1000e6);
        token.approve(address(adapter), 1000e6);
        adapter.deposit(1000e6);
        uint256 receipts = market.balanceOf(address(adapter));
        assertGt(receipts, 0);
        token.mint(address(adapter), 30e6);
        market.setRedeemError(1);
        adapter.emergencyPullAllToVault();
        assertEq(token.balanceOf(address(this)), 30e6);
        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(market.balanceOf(address(adapter)), receipts, "failed redemption must not erase ownership");
        assertGt(adapter.investedAssets(), 0);
    }

    function _euler(bool failing) internal returns (Euler adapter, MockUSDCEulX token, ReviewEulerRateMarket good, ReviewEulerRateMarket best) {
        MockPermit2X permit = new MockPermit2X();
        vm.etch(0x000000000022D473030F116dDEE9F6B43aC78BA3, address(permit).code);
        token = new MockUSDCEulX();
        good = new ReviewEulerRateMarket(address(token), 1e18);
        best = new ReviewEulerRateMarket(address(token), 2e18);
        best.setRevertOnDeposit(failing);
        if (!failing) best.setMaxDepositCap(400e6);
        address[] memory markets = new address[](2);
        markets[0] = address(good);
        markets[1] = address(best);
        adapter = Euler(payable(deployCode("EulerUsdcMultiMarket.sol:EulerUsdcMultiMarketAdapter")));
        adapter.initialize(address(this), address(token), markets, address(0), address(this));
        token.mint(address(adapter), 1000e6);
    }

    function test_eulerFailedLastBestRetriesEarlierHealthyMarket() public {
        (Euler adapter, MockUSDCEulX token, ReviewEulerRateMarket good, ReviewEulerRateMarket best) = _euler(true);
        adapter.deposit(1000e6);
        assertEq(token.balanceOf(address(good)), 2000e6);
        assertEq(token.balanceOf(address(best)), 1000e6);
        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(adapter.totalAssets(), 1000e6);
    }

    function test_eulerCappedLastBestFillsEarlierHealthyMarket() public {
        (Euler adapter, MockUSDCEulX token, ReviewEulerRateMarket good, ReviewEulerRateMarket best) = _euler(false);
        adapter.deposit(1000e6);
        assertEq(token.balanceOf(address(best)), 1400e6);
        assertEq(token.balanceOf(address(good)), 1600e6);
        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(adapter.totalAssets(), 1000e6);
    }

    function test_eulerRegistryOverflowRevertsWithoutSilentTruncation() public {
        MockPermit2X permit = new MockPermit2X();
        vm.etch(0x000000000022D473030F116dDEE9F6B43aC78BA3, address(permit).code);
        MockUSDCEulX token = new MockUSDCEulX();
        MockEulerVault existing = new MockEulerVault(address(token));
        ReviewEulerRegistry registry = new ReviewEulerRegistry();
        address[] memory initial = new address[](1);
        initial[0] = address(existing);
        Euler adapter = Euler(payable(deployCode("EulerUsdcMultiMarket.sol:EulerUsdcMultiMarketAdapter")));
        adapter.initialize(address(this), address(token), initial, address(registry), address(this));
        address[] memory incoming = new address[](255);
        for (uint256 i; i < incoming.length; ++i) {
            incoming[i] = address(uint160(0x800000 + i));
            vm.etch(incoming[i], address(existing).code);
        }
        registry.set(incoming);
        vm.expectRevert(bytes("too many markets"));
        adapter.refreshFromRegistry();
    }
}
