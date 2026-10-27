// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {StrategyRebalancePlanModule as Plan} from "../../../../src/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol";
import {StrategyRebalanceGateModule as Gate} from "../../../../src/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol";
import {StrategyUpkeep} from "../../../../src/strategies/usdc-lending/automation/LendingStrategyUpkeep.sol";
import {StrategyMigrationGuard} from "../../../../src/strategies/usdc-lending/gas/StrategyMigrationGuard.sol";
import {Test, console2} from "forge-std/Test.sol";
import {DeployUsdcLendingStrategy as Deploy} from "../../../../script/DeployUsdcLendingStrategy.s.sol";
import {UsdcMultiLendingVault as Strategy} from "../../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
import {StrategyAdapterOpsModule as Ops} from "../../../../src/strategies/usdc-lending/controller/StrategyAdapterOpsModule.sol";
import {StrategySettingsModule as Settings} from "../../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {ReadOnlyGasEstimator as E, IFeeInfo, IFeed} from "../../../../src/strategies/usdc-lending/gas/ReadOnlyGasEstimator.sol";
import {GovernedReadOnlyGasEstimator as GE} from "../../../../src/strategies/usdc-lending/gas/GovernedReadOnlyGasEstimator.sol";
import {StrategyRouter} from "@multyr-core/core/modules/StrategyRouter.sol";
import {ILendingAdapter} from "../../../../src/strategies/usdc-lending/interfaces/ILendingAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Local-only rehearsal against existing Core and real lending venues.
contract EstimatorTierCalibrationTest is Test {
    address constant CORE = 0x5e0cdb76487BD96Ff069Ef7F78eaDF5b5909C8cb;
    address constant ROUTER = 0x37847D2e12892e3298DEE695e7E971fba0Ca3e24;
    address constant OLD = 0xa9E676D15976A1332905238ca609Dff9A484Efe0;
    address constant GOV = 0x70ef444799D6FBbE0865bA598Bee6795e064a326;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant ETH_FEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address constant USDC_FEED = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address constant SEQ_FEED = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;
    Deploy.DeploymentResult r;
    E estimator;
    bytes32 coreHash;
    bytes32 routerHash;

    function _deployScenario() internal {
        if (!vm.envOr("RUN_REPLACEMENT_REHEARSAL", false)) { vm.skip(true); return; }
        vm.createSelectFork(vm.envString("REHEARSAL_RPC"), vm.envUint("REHEARSAL_BLOCK"));
        coreHash = CORE.codehash; routerHash = ROUTER.codehash;
        // Foundry does not implement ArbOS precompile 0x6c. Replay the real pinned
        // response, while all feeds/protocols/Core/Router use their original code.
        vm.mockCall(address(0x6c), abi.encodeWithSignature("getPricesInWei()"), vm.envBytes("REHEARSAL_FEES"));
        E.Config memory c = E.Config(2_300_000, 1_700_000, 600_000, 2_000_000, 3_000_000,
            21_612, 164, 3000, 7200, 90000, 3600, 100e6);
        estimator = new GE(IFeeInfo(address(0x6c)), IFeed(ETH_FEED), IFeed(USDC_FEED), IFeed(SEQ_FEED), c, GOV);
        assertEq(estimator.calibrator(), GOV);
        assertEq(estimator.pendingCalibrator(), address(0));
        (bool valid,,) = estimator.validatedPrices(); assertTrue(valid, "feed validation");
        uint256 key = 0xA11CE5EED;
        vm.deal(vm.addr(key), 10 ether);
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(key));
        vm.setEnv("VAULT_ADDRESS", vm.toString(CORE));
        vm.setEnv("STRATEGY_ROUTER_ADDRESS", vm.toString(ROUTER));
        vm.setEnv("BUFFER_MANAGER_ADDRESS", "0x9b3fE5c76e0C10de254Ee2153f71DF6a96020D96");
        vm.setEnv("HEALTH_REGISTRY_ADDRESS", "0x5a866D66089ce7EE63748b172801FbfD584451fF");
        vm.setEnv("GUARDIAN_ADDRESS", "0x7407E68a5553E948eed862f19fc6B292eb48d677");
        vm.setEnv("KEEPER_SIGNER_ADDRESS", "0x404da3b474b8b4c87d5e3c39230c71a7237630da");
        vm.setEnv("GOVERNANCE_ADDRESS", vm.toString(GOV));
        vm.setEnv("SOURCE_STRATEGY", vm.toString(OLD));
        vm.setEnv("SOURCE_STRATEGY_UPKEEP", "0xbcaC314E7237b14E11644FC6Ba73675c8c0612DF");
        vm.setEnv("REBALANCE_GAS_ESTIMATOR", vm.toString(address(estimator)));
        vm.setEnv("GAS_ETH_USD_FEED", vm.toString(ETH_FEED));
        vm.setEnv("GAS_USDC_USD_FEED", vm.toString(USDC_FEED));
        vm.setEnv("GAS_SEQUENCER_FEED", vm.toString(SEQ_FEED));
        vm.setEnv("GAS_CONFIG_HASH", vm.toString(keccak256(abi.encode(c))));
        vm.setEnv("COPY_SOURCE_SETTINGS", "false");
        vm.setEnv("TARGET_IDLE_BUFFER_BPS", "1000");
        vm.setEnv("ADAPTER_MAX_EXPOSURE_BPS", "0");
        vm.setEnv("UNPAUSE_BUFFER", "false"); vm.setEnv("DO_SEAL", "false");
        vm.setEnv("DEPLOY_LENDING_ADAPTERS", "true"); vm.setEnv("DEPLOY_UPKEEP", "true");
        vm.setEnv("STRATEGY_OUTPUT_JSON", "deployments/estimator-margin-20261023/fork-addresses.json");
        r = new Deploy().run();
        uint32[7] memory deposits = [uint32(330000),1860000,290000,550000,790000,220000,420000];
        uint32[7] memory withdrawals = [uint32(170000),2040000,160000,240000,390000,140000,240000];
        for (uint256 i; i < 7; ++i) {
            address adapter = r.strategy.adapters(i);
            vm.prank(GOV);
            estimator.setAdapterFloors(adapter, deposits[i], withdrawals[i]);
        }

        // Candidate-only calibration from recorded component maxima; not production approved.
        vm.prank(GOV);
        estimator.setPathOverhead(E.PathOverhead(2300000,1450000,1600000,1700000,600000));
        vm.prank(GOV);
        Settings(address(r.strategy)).setTargetIdleBufferBps(1000);
        assertFalse(StrategyRouter(ROUTER).isStrategyEnabled(address(r.strategy)));
        assertEq(IERC20(USDC).balanceOf(vm.addr(key)), 0, "deployment must need no USDC");
    }


    function test_representativeTierPlans() public {
        _deployScenario();
        vm.dumpState("deployments/estimator-margin-20261023/deployment-state.json");
        uint256[5] memory sizes = [uint256(10000e6),100000e6,500000e6,2000000e6,6000000e6];
        for (uint256 k; k < sizes.length; ++k) {
            uint256 snapshot = vm.snapshotState();
            console2.log("TIER TVL", sizes[k]);
            deal(USDC, address(r.strategy), sizes[k]);
            vm.prank(CORE);
            try r.strategy.deposit(sizes[k]) {} catch(bytes memory reason) {
                console2.log("INITIAL DEPLOYMENT FAILED"); console2.logBytes(reason);
                revert("initial allocation failed");
            }
            vm.startPrank(GOV);
            Settings(address(r.strategy)).exitBootstrapMode();
            Settings(address(r.strategy)).setCapDriftTolerance(0);
            Settings(address(r.strategy)).setGateParams(30, 0, 0, 0, 1e6);
            r.aaveAdapter.call(abi.encodeWithSignature("setAPYOverrideBps(uint16)", uint16(5000)));
            r.fluidAdapter.call(abi.encodeWithSignature("setAPYOverrideBps(uint16)", uint16(4000)));
            r.morphoAdapter.call(abi.encodeWithSignature("setAPYOverrideBps(uint16)", uint16(6000)));
            r.dolomiteAdapter.call(abi.encodeWithSignature("setAPYOverrideBps(uint16)", uint16(5500)));
            vm.stopPrank();
            vm.prank(0x404da3B474b8b4C87d5e3c39230c71A7237630da); Ops(address(r.strategy)).syncPositionAssets(true);
            (E.Action[] memory actions, E.Quote memory q) = Gate(address(r.strategy)).previewRebalanceGas();
            (bool eligible,uint256 moved,int256 net) = Gate(address(r.strategy)).canRebalance();
            console2.log("GATE MOVED",moved); console2.log("GATE NET",net);
            console2.log("DEPOSITS DISABLED", r.strategy.depositsDisabled());
            console2.log("ELIGIBLE", eligible); console2.log("PLANNED TX COUNT", q.txCount);
            console2.log("MODELED GAS", q.l2Gas); console2.log("MODELED USDC WITH MARGIN",q.costUSDC);
            for(uint256 i; i < actions.length; ++i) {
                console2.log("ADAPTER",actions[i].adapter); console2.log("DEPOSIT",actions[i].deposit); console2.log("AMOUNT",actions[i].amount);
                console2.log("LIQUID",ILendingAdapter(actions[i].adapter).withdrawableAssets());
                console2.log("CAPACITY",ILendingAdapter(actions[i].adapter).maxCapacity());
            }
            vm.dumpState(string.concat("deployments/estimator-margin-20261023/tier-",vm.toString(k),"-state.json"));
            assertTrue(eligible, "scenario must exercise accepted execution");
            if(eligible) {
                vm.prank(0x404da3B474b8b4C87d5e3c39230c71A7237630da); uint256 before = gasleft();
                Plan(address(r.strategy)).prepareRebalance();
                uint256 measured = before - gasleft();
                console2.log("PREPARATION CALL GAS",measured);
                assertEq(r.strategy.rebalancePlanTotalActions(),actions.length);
                for(uint256 i; i < actions.length; ++i) {
                    assertEq(r.strategy.rebalancePlanAdapters(i), actions[i].adapter);
                    assertEq(r.strategy.rebalancePlanAmounts(i) & ((1<<255)-1),actions[i].amount);
                    assertEq(r.strategy.rebalancePlanAmounts(i)>>255==1,actions[i].deposit);
                }
                uint256 steps;
                while(r.strategy.rebalancePlanPhase()!=0 && steps <10) {
                    vm.prank(0x404da3B474b8b4C87d5e3c39230c71A7237630da); before = gasleft(); Plan(address(r.strategy)).executeRebalanceStep();
                    uint256 gasUsed=before-gasleft(); measured+=gasUsed; ++steps;
                    console2.log("STEP CALL GAS",gasUsed);
                }
                console2.log("ACTUAL STEPS",steps);
                console2.log("TOTAL CALL GAS EXCLUDES INTRINSIC",measured);
                console2.log("PLAN FAILURE COUNT",r.strategy.rebalancePlanConsecutiveFailures());
                (bool valid,uint256 eth,uint256 usdcPrice)=estimator.validatedPrices(); assertTrue(valid);
                uint256 cost=((measured+q.txCount*21612)*20118000+q.posterWei)*eth/usdcPrice/1e12;
                console2.log("CALL GAS COST USDC BEFORE MARGIN",cost);
                console2.log("CALL GAS COST USDC AFTER 30 PERCENT",(cost*13000+9999)/10000);
                assertEq(r.strategy.rebalancePlanPhase(),0);
            }
            assertTrue(vm.revertToState(snapshot));
        }
    }
}
