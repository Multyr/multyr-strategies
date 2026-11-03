// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LendingOracleTestFixture} from "../helpers/LendingOracleTestFixture.sol";
import {LendingAssetConfig} from "../../../../src/strategies/usdc-lending/config/LendingAssetConfig.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AaveV3USDCAdapter} from "../../../../src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol";
import {UsdcMultiLendingVault} from "../../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
import {StrategyParamsModule} from "../../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import {StrategyScoringModule} from "../../../../src/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import {StrategyAdapterOpsModule} from "../../../../src/strategies/usdc-lending/controller/StrategyAdapterOpsModule.sol";
import {StrategyRebalanceGateModule} from "../../../../src/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol";
import {StrategySettingsModule} from "../../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {StrategyAllocCalcModule} from "../../../../src/strategies/usdc-lending/controller/StrategyAllocCalcModule.sol";
import {StrategyRebalancePlanModule} from "../../../../src/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol";
import {StrategySafetyOverflowModule} from "../../../../src/strategies/usdc-lending/controller/StrategySafetyOverflowModule.sol";
import {IStrategyAssetValuation} from "../../../../src/strategies/usdc-lending/interfaces/ILendingAdapter.sol";

/// @dev Live Aave markets with controlled core-oracle fixtures. This establishes
///      strategy/market integration, not deployed CoreVault or reward-route acceptance.
abstract contract LendingStrategyMatrixFixture is LendingOracleTestFixture {
    function _lifecycle(uint256 chainId, bool weth) internal {
        if (chainId == 42161) vm.createSelectFork(vm.envOr("LENDING_ARBITRUM_RPC", string("https://arbitrum-one.public.blastapi.io")), 520094008);
        else vm.createSelectFork("https://mainnet.base.org", 53345555);
        LendingAssetConfig.Market memory m = LendingAssetConfig.get(chainId, weth);
        address core = _newOracleCore(weth ? 3000e18 : 1e18);
        UsdcMultiLendingVault strategy = _deploy(m.asset, core);
        uint256 minimumDrift = IStrategyAssetValuation(address(strategy)).usd6ToAssetUnits(1000e6);
        StrategySettingsModule(address(strategy)).setRebalancePlanMinDrift(minimumDrift);
        assertEq(strategy.rebalancePlanMinDrift(), minimumDrift);
        AaveV3USDCAdapter adapter = new AaveV3USDCAdapter();
        uint256 unit = 10 ** m.decimals;
        adapter.initialize(m.asset, m.aavePool, m.aToken, address(this), address(strategy), 1000 * unit);
        StrategySettingsModule(address(strategy)).whitelistAdapter(address(adapter), true);
        strategy.addAdapter(address(adapter));
        strategy.toggleAdapter(address(adapter), true);
        StrategyParamsModule params = StrategyParamsModule(address(strategy));
        StrategySettingsModule(address(strategy)).setAdapterDepositMode(address(adapter), false);
        params.pokeExternalTVL();
        params.pokeLiquidityBatch(0, 1);
        uint256 amount = (weth ? 1 : 100) * unit;
        deal(m.asset, address(strategy), amount);
        strategy.deposit(amount);
        assertGt(adapter.totalAssets(), 0, "must invest in the actual market");
        assertApproxEqAbs(strategy.totalAssets(), amount, 2);
        strategy.harvest();

        // An unavailable core oracle must not block exit or optional idle redeployment.
        vm.mockCall(core, abi.encodeWithSignature("params()"), abi.encode(address(0)));
        deal(m.asset, address(strategy), IERC20Metadata(m.asset).balanceOf(address(strategy)) + unit);
        uint256 requested = unit / 10;
        uint256 receiverBefore = IERC20Metadata(m.asset).balanceOf(address(0xBEEF));
        uint256 received = strategy.withdraw(requested, address(0xBEEF), true);
        assertEq(received, requested);
        assertEq(IERC20Metadata(m.asset).balanceOf(address(0xBEEF)) - receiverBefore, requested);
        uint256 emergencyBefore = IERC20Metadata(m.asset).balanceOf(address(0xCAFE));
        uint256 remaining = strategy.withdrawAll(address(0xCAFE));
        assertGt(remaining, 0);
        assertEq(IERC20Metadata(m.asset).balanceOf(address(0xCAFE)) - emergencyBefore, remaining);
        assertLe(adapter.totalAssets(), 2);
        assertLe(strategy.totalAssets(), 2);
    }

    function _deploy(address asset, address core) internal returns (UsdcMultiLendingVault s) {
        return _deployForRouter(asset, core, address(this));
    }

    function _deployForRouter(address asset, address core, address router) internal returns (UsdcMultiLendingVault s) {
        StrategyParamsModule params = new StrategyParamsModule(asset, core);
        StrategyAdapterOpsModule ops = new StrategyAdapterOpsModule(asset, core, address(params), address(0), address(0));
        StrategyScoringModule scoring = new StrategyScoringModule(asset, core, address(params), address(0), address(ops));
        StrategyRebalanceGateModule gate = new StrategyRebalanceGateModule(asset, core, address(params), address(scoring), address(ops));
        UsdcMultiLendingVault.StrategyInitParams memory p;
        p.maxAdaptersPerAllocation = 5;
        p.minAdaptersActive = 1;
        p.wAPY = 5000; p.wLiq = 2000; p.wRisk = 2000; p.wStability = 1000; p.wIncentive = 0;
        p.newAdapterRampBps = 5000;
        p.minSecondsBetweenRebalances = 86400;
        p.minSecondsBetweenHarvests = 86400;
        p.minSecondsBetweenDeployIdle = 300;
        p.harvestThresholdBps = 100;
        p.stabilityEMAPeriod = 7;
        p.maxIdleAfterDepositBps = 10000;
        p.maxIdleBootstrapBps = 10000;
        p.dustTolerance = 1;
        p.externalTVLStalenessSeconds = 1 days;
        p.gateHorizonDays = 7;
        p.gasCostUSDC = 1e6;
        p.degradedViewThresholdBps = 2500;
        s = new UsdcMultiLendingVault(asset, core, router, address(this), address(this), address(0),
            address(params), address(scoring), address(ops), address(gate), p);
        s.setSettingsModule(address(new StrategySettingsModule(asset, core)));
        s.setAllocCalcModule(address(new StrategyAllocCalcModule(asset, core)));
        s.setRebalancePlanModule(address(new StrategyRebalancePlanModule(asset, core, address(params), address(scoring), address(ops))));
        StrategySettingsModule(address(s)).setSafetyOverflowModule(address(new StrategySafetyOverflowModule(asset, core, address(params), address(scoring), address(ops))));
    }
}

contract LendingStrategyMatrixForkTest is LendingStrategyMatrixFixture {
    function test_strategyArbitrumUsdc() public { _lifecycle(42161, false); }
    function test_strategyArbitrumWeth() public { _lifecycle(42161, true); }
    function test_strategyBaseUsdc() public { _lifecycle(8453, false); }
    function test_strategyBaseWeth() public { _lifecycle(8453, true); }
}
