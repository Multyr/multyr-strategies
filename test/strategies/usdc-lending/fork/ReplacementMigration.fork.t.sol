// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
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
contract ReplacementMigrationTest is Test {
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

    function setUp() public {
        if (!vm.envOr("RUN_REPLACEMENT_REHEARSAL", false)) { vm.skip(true); return; }
        vm.createSelectFork(vm.envString("REHEARSAL_RPC"), vm.envUint("REHEARSAL_BLOCK"));
        coreHash = CORE.codehash; routerHash = ROUTER.codehash;
        // Foundry does not implement ArbOS precompile 0x6c. Replay the real pinned
        // response, while all feeds/protocols/Core/Router use their original code.
        vm.mockCall(address(0x6c), abi.encodeWithSignature("getPricesInWei()"), vm.envBytes("REHEARSAL_FEES"));
        E.Config memory c = E.Config(1_500_000, 1_000_000, 300_000, 2_000_000, 3_000_000,
            21_000, 164, 5000, 7200, 90000, 3600, 100e6);
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
        vm.setEnv("ADAPTER_MAX_EXPOSURE_BPS", "2500");
        vm.setEnv("UNPAUSE_BUFFER", "false"); vm.setEnv("DO_SEAL", "false");
        vm.setEnv("DEPLOY_LENDING_ADAPTERS", "true"); vm.setEnv("DEPLOY_UPKEEP", "true");
        vm.setEnv("STRATEGY_OUTPUT_JSON", "deployments/adapter-fixes-20261019/rehearsal-addresses.json");
        r = new Deploy().run();
        uint32[7] memory deposits = [uint32(600000),1100000,550000,900000,1200000,450000,750000];
        uint32[7] memory withdrawals = [uint32(300000),4000000,300000,450000,600000,300000,350000];
        for (uint256 i; i < 7; ++i) {
            address adapter = r.strategy.adapters(i);
            vm.prank(GOV);
            estimator.setAdapterFloors(adapter, deposits[i], withdrawals[i]);
        }

        assertFalse(StrategyRouter(ROUTER).isStrategyEnabled(address(r.strategy)));
        assertEq(IERC20(USDC).balanceOf(vm.addr(key)), 0, "deployment must need no USDC");
    }

    function test_migrateActualBookAndFundReplacement() public {
        StrategyRouter router = StrategyRouter(ROUTER);
        vm.prank(GOV); uint256 eta = router.proposeStrategyAllowlist(address(r.strategy));
        vm.warp(eta);
        StrategyMigrationGuard guard = new StrategyMigrationGuard();
        guard.assertNoPlan(OLD);
        uint256 oldNav = Strategy(payable(OLD)).totalAssets();
        uint256 coreBefore = IERC20(USDC).balanceOf(CORE);
        vm.startPrank(GOV);
        Settings(OLD).setDepositsDisabled(true);
        // The legacy strategy recalls cached positions. Sweep each adapter's
        // actual balances first so accrued interest is not stranded at cutover.
        for (uint256 i; i < Strategy(payable(OLD)).adapterCount(); ++i) {
            Settings(OLD).callAdapterEmergencyPull(Strategy(payable(OLD)).adapters(i));
        }
        uint256 recalled = router.withdrawAllToCore(OLD);
        assertGe(recalled + 100, oldNav, "old recall shortfall");
        assertLe(Strategy(payable(OLD)).totalAssets(), 100, "old residual");
        assertEq(IERC20(USDC).balanceOf(CORE), coreBefore + recalled);
        guard.assertDrained(OLD,100);
        router.executeStrategyAllowlist(address(r.strategy));
        router.register(address(r.strategy), 100, 10000);
        router.toggle(OLD, false);
        vm.stopPrank();
        console2.log("Actual old book recalled (USDC raw)", recalled);
        uint256[3] memory amounts = [oldNav, uint256(10_000e6), uint256(200_000e6)];
        for (uint256 k; k < amounts.length; ++k) {
            uint256 snapshot = vm.snapshotState();
            deal(USDC, address(r.strategy), amounts[k]);
            vm.prank(CORE); uint256 t = gasleft(); r.strategy.deposit(amounts[k]);
            console2.log("Deposit amount", amounts[k]); console2.log("Deposit call gas", t - gasleft());
            assertGe(r.strategy.totalAssets() + 100, amounts[k]);
            assertLt(r.strategy.idleCash(), amounts[k], "no protocol received funds");
            for (uint256 i; i < r.strategy.adapterCount(); ++i) {
                assertLe(ILendingAdapter(r.strategy.adapters(i)).totalAssets(), amounts[k] / 4 + 100, "25 percent cap exceeded");
            }
            vm.prank(GOV); Settings(address(r.strategy)).exitBootstrapMode();
            uint256 idleBeforeTopup = IERC20(USDC).balanceOf(address(r.strategy));
            deal(USDC, address(r.strategy), idleBeforeTopup + 1e6);
            vm.prank(CORE); r.strategy.deposit(1e6);
            vm.prank(GOV); t = gasleft(); uint256 got = router.withdrawAllToCore(address(r.strategy));
            console2.log("Recall call gas", t - gasleft()); console2.log("Replacement recall USDC", got);
            assertGe(got + 100, amounts[k], "replacement recall shortfall");
            assertLe(r.strategy.totalAssets(), 100, "replacement residual");
            vm.revertToState(snapshot);
        }
        assertEq(CORE.codehash, coreHash); assertEq(ROUTER.codehash, routerHash);
    }

    function _coolStrategy() internal {
        vm.cool(address(r.strategy)); vm.cool(r.paramsModule); vm.cool(r.scoringModule);
        vm.cool(r.adapterOpsModule); vm.cool(r.rebalanceGateModule); vm.cool(r.rebalancePlanModule);
        vm.cool(r.allocCalcModule); vm.cool(r.settingsModule); vm.cool(r.strategyUpkeep);
        vm.cool(USDC); vm.cool(address(estimator)); vm.cool(ETH_FEED); vm.cool(USDC_FEED); vm.cool(SEQ_FEED);
        for (uint256 i; i < 7; ++i) vm.cool(r.strategy.adapters(i));
    }

    function test_fullKeeperPlanWithRealAdaptersAndModeledCost() public {
        deal(USDC, address(r.strategy), 200_000e6);
        vm.prank(CORE); r.strategy.deposit(200_000e6);
        // Governance APY overrides model a changed opportunity, on real venues.
        vm.startPrank(GOV);
        (bool a,) = r.aaveAdapter.call(abi.encodeWithSignature("setAPYOverrideBps(uint16)",uint16(5000)));
        (bool b,) = r.fluidAdapter.call(abi.encodeWithSignature("setAPYOverrideBps(uint16)",uint16(4000)));
        // Give every zero-rate candidate a positive hypothetical opportunity.
        // Otherwise repricing correctly cancels the final zero-yield deposits.
        (bool c,) = r.morphoAdapter.call(abi.encodeWithSignature("setAPYOverrideBps(uint16)",uint16(6000)));
        (bool d,) = r.dolomiteAdapter.call(abi.encodeWithSignature("setAPYOverrideBps(uint16)",uint16(5500)));
        vm.stopPrank(); assertTrue(a && b && c && d);
        (E.Action[] memory actions, E.Quote memory q) = Gate(address(r.strategy)).previewRebalanceGas();
        (bool eligible,,) = Gate(address(r.strategy)).canRebalance();
        console2.log("Quote reliable", q.reliable);
        console2.log("Idle cash", r.strategy.idleCash());
        for(uint256 i; i < actions.length; ++i) { console2.log("Action adapter",actions[i].adapter); console2.log("Action deposit",actions[i].deposit); console2.log("Action amount",actions[i].amount); console2.log("Withdrawable", ILendingAdapter(actions[i].adapter).withdrawableAssets()); }
        console2.log("Candidate actions", actions.length); console2.log("Eligible", eligible);
        assertTrue(eligible, "economic plan not eligible"); assertTrue(q.reliable, "unreliable quote");
        _coolStrategy(); uint256 t = gasleft();
        StrategyUpkeep(r.strategyUpkeep).performUpkeep(abi.encode(uint8(5),uint256(0)));
        uint256 used = t - gasleft();
        console2.log("Preparation wrapper gas", used);
        assertGt(r.strategy.rebalancePlanPhase(), 0, "prepare failed");
        uint256 steps;
        while (r.strategy.rebalancePlanPhase() != 0 && steps < 10) {
            _coolStrategy(); t = gasleft();
            StrategyUpkeep(r.strategyUpkeep).performUpkeep(abi.encode(uint8(6),uint256(0)));
            uint256 stepUsed = t-gasleft(); used += stepUsed; ++steps;
            console2.log("Execution wrapper gas", stepUsed);
        }
        assertEq(r.strategy.rebalancePlanPhase(), 0, "plan unfinished");
        assertEq(r.strategy.rebalancePlanConsecutiveFailures(), 0, "plan cancelled instead of completed");
        console2.log("Total measured wrapper gas", used); console2.log("Modeled L2 gas", q.l2Gas);
        console2.log("Modeled cost USDC", q.costUSDC);
        assertGt(q.l2Gas, used, "model underestimates measured calls");
        vm.prank(ROUTER); uint256 got = r.strategy.withdrawAll(CORE);
        assertGe(got + 100, 200_000e6, "post-plan recall shortfall");
    }

    function test_sevenAdapterDepositRecallAndGasFloors() public {
        for (uint256 i; i < 7; ++i) {
            uint256 snapshot = vm.snapshotState();
            address a = r.strategy.adapters(i);
            deal(USDC, address(r.strategy), 1_000e6);
            vm.prank(CORE); uint256 t = gasleft();
            bool deposited = Ops(address(r.strategy)).safeAdapterDeposit(a, 1_000e6);
            uint256 depositGas = t - gasleft();
            assertTrue(deposited, "adapter deposit failed");
            uint256 nav = ILendingAdapter(a).totalAssets();
            assertGe(nav + 100, 1_000e6, "adapter NAV missing");
            vm.prank(address(r.strategy)); t = gasleft();
            uint256 got = ILendingAdapter(a).withdraw(nav, address(r.strategy));
            uint256 withdrawGas = t - gasleft();
            console2.log("Adapter index", i); console2.log("Deposit gas", depositGas);
            console2.log("Withdraw gas", withdrawGas); console2.log("Recovered", got);
            assertGe(got + 100, 1_000e6, "adapter recall shortfall");
            assertLt(depositGas, estimator.depositFloor(a), "deposit floor below measured gas");
            assertLt(withdrawGas, estimator.withdrawFloor(a), "withdraw floor below measured gas");
            vm.revertToState(snapshot);
        }
    }
}
