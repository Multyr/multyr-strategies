// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {LendingAssetConfig} from "../../../../src/strategies/usdc-lending/config/LendingAssetConfig.sol";
import {AaveV3USDCAdapter} from "../../../../src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol";
import {OPStackFeeInfo, IOPGasPriceOracle} from "../../../../src/strategies/usdc-lending/gas/OPStackFeeInfo.sol";
import {ReadOnlyGasEstimator as E, IFeed} from "../../../../src/strategies/usdc-lending/gas/ReadOnlyGasEstimator.sol";

interface IAaveMarketIdentity {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
    function POOL() external view returns (address);
}

/// @dev Explicit integration job: no conditional success/skip when an RPC is unavailable.
contract LendingAssetMatrixForkTest is Test {
    function test_arbitrumUsdc() public { _roundTrip(42161, false); }
    function test_arbitrumWeth() public { _roundTrip(42161, true); }
    function test_baseUsdc() public { _roundTrip(8453, false); }
    function test_baseWeth() public { _roundTrip(8453, true); }

    function test_baseGasQuoteUsesActualOpOracleAndNativeFeed() public {
        vm.createSelectFork("https://mainnet.base.org", 53345555);
        IOPGasPriceOracle oracle = IOPGasPriceOracle(0x420000000000000000000000000000000000000F);
        OPStackFeeInfo source = new OPStackFeeInfo(oracle, 4096, 1 gwei);
        (uint256 fixedWei, uint256 byteWei,,,, uint256 gasWei) = source.getPricesInWei();
        assertEq(fixedWei, oracle.getL1FeeUpperBound(4352) + oracle.getOperatorFee(0));
        assertGt(fixedWei, 0);
        assertEq(byteWei, 1);
        assertGe(gasWei, block.basefee + 1 gwei);
        E.Config memory c = E.Config(100000, 100000, 100000, 300000, 300000,
            21000, 512, 3000, 3600, 0, 3600, 1e6);
        E estimator = new E(source,
            IFeed(0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70), IFeed(address(0)),
            IFeed(0xBCF85224fc0756B9Fa45aA7892530B47e10b6433), c);
        (bool valid, uint256 nativePrice, uint256 usdUnit) = estimator.validatedPrices();
        assertTrue(valid);
        assertGt(nativePrice, 0);
        assertEq(usdUnit, 1e18);
        E.Action[] memory actions = new E.Action[](1);
        actions[0] = E.Action(LendingAssetConfig.get(8453, true).aToken, 1e18, true);
        E.Quote memory quote = estimator.estimate(address(this), actions, 1, true);
        assertTrue(quote.reliable);
        assertGt(quote.posterWei, 0);
        assertGt(quote.executionWei, 0);
        assertGt(quote.costUSDC, 0);
        assertTrue(quote.usedDefaults); // No fabricated strategy gas measurements.
    }

    function _roundTrip(uint256 chainId, bool weth) internal {
        if (chainId == 42161) vm.createSelectFork(vm.envOr("LENDING_ARBITRUM_RPC", string("https://arbitrum-one.public.blastapi.io")), 520094008);
        else vm.createSelectFork("https://mainnet.base.org", 53345555);
        assertEq(block.chainid, chainId);
        LendingAssetConfig.Market memory m = LendingAssetConfig.get(chainId, weth);
        IERC20Metadata token = IERC20Metadata(m.asset);
        assertEq(token.decimals(), m.decimals);
        assertEq(IAaveMarketIdentity(m.aToken).UNDERLYING_ASSET_ADDRESS(), m.asset);
        assertEq(IAaveMarketIdentity(m.aToken).POOL(), m.aavePool);
        AaveV3USDCAdapter adapter = new AaveV3USDCAdapter();
        adapter.initialize(m.asset, m.aavePool, m.aToken, address(this), address(this), 1000 * 10 ** m.decimals);
        uint256 amount = (weth ? 1 : 100) * 10 ** m.decimals;
        deal(m.asset, address(this), amount);
        token.approve(address(adapter), amount);
        uint256 marketBefore = adapter.externalMarketTVL();
        assertGt(marketBefore, amount);
        adapter.deposit(amount);
        assertApproxEqAbs(adapter.totalAssets(), amount, 2);
        assertGt(adapter.externalMarketTVL(), marketBefore);
        assertGt(adapter.withdrawableAssets(), 0);
        address receiver = address(0xBEEF);
        uint256 receiverBefore = token.balanceOf(receiver);
        uint256 vaultBefore = token.balanceOf(address(this));
        uint256 withdrawn = adapter.withdraw(amount, receiver);
        assertApproxEqAbs(withdrawn, amount, 2);
        // Adapter policy deliberately forces proceeds back to its authorized vault.
        assertEq(token.balanceOf(address(this)) - vaultBefore, withdrawn);
        assertEq(token.balanceOf(receiver), receiverBefore);
        assertLe(adapter.totalAssets(), 2);
    }
}
