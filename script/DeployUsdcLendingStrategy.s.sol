// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

// Core — type references only
import { CoreVault } from "@multyr-core/core/CoreVault.sol";
import { BufferManager } from "@multyr-core/core/modules/BufferManager.sol";
import { StrategyRouter } from "@multyr-core/core/modules/StrategyRouter.sol";
import { StrategyHealthRegistry } from "@multyr-core/core/modules/StrategyHealthRegistry.sol";
import { FeeCollector } from "@multyr-core/core/modules/FeeCollector.sol";
import { GlobalConfig } from "@multyr-core/core/config/GlobalConfig.sol";
import { SelectorRegistry } from "@multyr-core/core/libraries/SelectorRegistry.sol";
import { SystemSealer } from "@multyr-core/core/SystemSealer.sol";
import { VaultFactory } from "@multyr-core/factory/VaultFactory.sol";
import { Incentives } from "@multyr-core/core/modules/Incentives.sol";
import { PriceOracleMiddleware } from "@multyr-core/core/modules/PriceOracleMiddleware.sol";

// Core interfaces
import { IAdminModule } from "@multyr-core/interfaces/IAdminModule.sol";
import { IStrategyRouter } from "@multyr-core/interfaces/IStrategyRouter.sol";
import { IBufferManager } from "@multyr-core/interfaces/IBufferManager.sol";

// Strategy (V9.1 3-contract split)
import { UsdcMultiLendingVault } from "@multyr-strategies/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
import { StrategyParamsModule } from "@multyr-strategies/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import { StrategyScoringModule } from "@multyr-strategies/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import { StrategyAdapterOpsModule } from "@multyr-strategies/strategies/usdc-lending/controller/StrategyAdapterOpsModule.sol";
import { StrategyRebalanceGateModule } from "@multyr-strategies/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol";
import { StrategySettingsModule } from "@multyr-strategies/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import { StrategyAllocCalcModule } from "@multyr-strategies/strategies/usdc-lending/controller/StrategyAllocCalcModule.sol";
import { StrategyRebalancePlanModule } from "@multyr-strategies/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol";
import { StrategyBootstrapper } from "@multyr-strategies/strategies/usdc-lending/StrategyBootstrapper.sol";

// Automation
import { StrategyUpkeep } from "@multyr-strategies/strategies/usdc-lending/automation/LendingStrategyUpkeep.sol";

// 7 Lending Adapters
import { AaveV3USDCAdapter } from "@multyr-strategies/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol";
import { MorphoUsdcMultiMarketAdapter } from "@multyr-strategies/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol";
import { CometUsdcMultiMarketAdapter } from "@multyr-strategies/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol";
import { EulerUsdcMultiMarketAdapter } from "@multyr-strategies/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol";
import { DolomiteUsdcMultiMarketAdapter } from "@multyr-strategies/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol";
import { FluidUsdcMultiMarketAdapter } from "@multyr-strategies/strategies/usdc-lending/adapters/lending/FluidUsdcMultiMarket.sol";
import { VenusUsdcMultiMarketAdapter } from "@multyr-strategies/strategies/usdc-lending/adapters/lending/VenusUsdcMultiMarket.sol";

// 2 Rate Providers
import { AaveLiquidityRateProvider } from "@multyr-strategies/strategies/usdc-lending/adapters/rates/AaveLiquidityRateProvider.sol";
import { DolomiteSupplyRateProvider } from "@multyr-strategies/strategies/usdc-lending/adapters/rates/DolomiteSupplyRateProvider.sol";

// Protocol registry (deploy-time utility — configures adapter market lists)
import { SimpleProtocolRegistry } from "../test/helpers/SimpleProtocolRegistry.sol";

/**
 * @title DeployUsdcLendingStrategy
 * @notice Deploys the USDC Lending Strategy, wires the ecosystem, and registers adapters.
 * @dev Run after deploying core system via multyr-core/script/DeployCoreSystem.s.sol.
 *
 * V9.1 DEPLOYMENT ARCHITECTURE
 * ════════════════════════════
 * Phase 1:   Deploy V9.1 modules (ParamsModule, ScoringModule, AdapterOpsModule,
 *            RebalanceGateModule) + UsdcMultiLendingVault + StrategyBootstrapper
 * Phase 1.5: Deploy 7 lending adapters (Aave, Morpho, Comet, Euler, Dolomite, Fluid, Venus)
 *            ⚠ Euler: initializeMarkets() BEFORE role transfer (Permit2 internal allowance)
 * Phase 1.6: Deploy 2 rate providers (AaveRP, DolomiteRP) + configure on adapters
 * Phase 1.7: Deploy optional modules (SettingsModule, AllocCalcModule, RebalancePlanModule)
 *            ⚠ MUST happen BEFORE Phase 2.5 bootstrap (bootstrap calls whitelistAdapter)
 * Phase 2:   Wire strategy (register in router, verify CORE_ROLE, setEcosystem)
 * Phase 2.5: Bootstrap — StrategyBootstrapper.bootstrap(adapters[]) registers all adapters +
 *            renounces BOOTSTRAP_ROLE permanently (one-shot, no separate script)
 * Phase 3:   Deploy StrategyUpkeep + grant KEEPER_ROLE
 *            Grant PARAM_ROLE on Morpho/Dolomite/Fluid/AaveRP for poke (fails silently without)
 * Phase 3.5: Transfer adapter admin roles to timelock
 * Phase 4:   Unpause BufferManager (optional, env-gated)
 * Phase 5:   Seal + transfer ownership (optional, env-gated, DO_SEAL=true)
 * Phase 6:   Register in VaultFactory (optional, env-gated)
 *
 * ENVIRONMENT VARIABLES
 * ─────────────────────
 * Required:
 *   DEPLOYER_PRIVATE_KEY   — private key for deployment
 *   VAULT_ADDRESS          — CoreVault address (from DeployCoreSystem)
 *   STRATEGY_ROUTER_ADDRESS
 *   BUFFER_MANAGER_ADDRESS
 *   HEALTH_REGISTRY_ADDRESS
 *   GUARDIAN_ADDRESS
 *
 * Required if DO_SEAL=true:
 *   TIMELOCK_ADDRESS          — ROOT_TIMELOCK (final owner)
 *   GLOBAL_CONFIG_ADDRESS
 *   PRICE_ORACLE_ADDRESS
 *   VAULT_FACTORY_ADDRESS
 *   FEE_COLLECTOR_ADDRESS
 *   SELECTOR_REGISTRY_ADDRESS
 *   SYSTEM_SEALER_ADDRESS
 *
 * Optional:
 *   INCENTIVES_ADDRESS        — Incentives module (default: address(0))
 *   VETOER_ADDRESS            — Vetoer (default: address(0))
 *   DO_SEAL                   — "true" to seal and transfer ownership
 *   DEPLOY_UPKEEP             — "true" to deploy StrategyUpkeep (default: true)
 *   DEPLOY_LENDING_ADAPTERS   — "true" to deploy all 7 adapters (default: true)
 *   UNPAUSE_BUFFER            — "true" to unpause BufferManager (default: true)
 *   ADAPTER_MAX_EXPOSURE_BPS  — uint16, default 5000 (50%)
 *   STRATEGY_OUTPUT_JSON      — output path for address book JSON
 *
 * @custom:chain-id 42161
 */
contract DeployUsdcLendingStrategy is Script {
    // ─── Arbitrum One constants ───────────────────────────────────────────────

    address constant USDC        = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant AAVE_POOL   = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant AAVE_AUSDC  = 0x724dc807b04555b71ed48a6896b6F41593b8C637;

    // Euler vaults (4 markets)
    address constant EULER_VAULT_1 = 0x6aFB8d3F6D4A34e9cB2f217317f4dc8e05Aa673b;
    address constant EULER_VAULT_2 = 0x44C10DA836d2aBe881b77bbB0b3DCE5f85C0C1Cc;
    address constant EULER_VAULT_3 = 0x05d28A86E057364F6ad1a88944297E58Fc6160b3;
    address constant EULER_VAULT_4 = 0x0a1eCC5Fe8C9be3C809844fcBe615B46A869b899;

    // Morpho vaults (5 markets added to registry)
    address constant MORPHO_VAULT_1 = 0x7e97fa6893871A2751B5fE961978DCCb2c201E65;
    address constant MORPHO_VAULT_2 = 0x4B6F1C9E5d470b97181786b26da0d0945A7cf027;
    address constant MORPHO_VAULT_4 = 0x5c0C306Aaa9F877de636f4d5822cA9F2E81563BA;
    address constant MORPHO_VAULT_6 = 0x7c574174DA4b2be3f705c6244B4BfA0815a8B3Ed;
    address constant MORPHO_VAULT_8 = 0x36b69949d60d06ECcC14DE0Ae63f4E00cc2cd8B9;

    address constant COMET_USDC_V3 = 0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf;
    address constant DOLOMITE_dUSDC = 0x444868B6e8079ac2c55eea115250f92C2b2c4D14;
    address constant FLUID_FUSDC    = 0x1A996cb54bb95462040408C06122D45D6Cdb6096;
    address constant VENUS_VTOKEN   = 0x7D8609f8da70fF9027E9bc5229Af4F6727662707;
    // Arbitrum: 0.25s blocks → 365.25d × 24h × 3600s / 0.25s = 126,144,000
    uint256 constant VENUS_BLOCKS_PER_YEAR = 126_144_000;

    uint256 constant DEFAULT_ADAPTER_CAPACITY = 50_000_000e6; // 50M USDC

    // ─── Deployment result ───────────────────────────────────────────────────

    struct DeploymentResult {
        // V9.1 modules
        address paramsModule;
        address scoringModule;
        address adapterOpsModule;
        address rebalanceGateModule;
        address settingsModule;
        address allocCalcModule;
        address rebalancePlanModule;
        // Strategy
        UsdcMultiLendingVault strategy;
        address bootstrapper;
        // Automation
        address strategyUpkeep;
        // Registry
        address protocolRegistry;
        // Adapters
        address aaveAdapter;
        address morphoAdapter;
        address cometAdapter;
        address eulerAdapter;
        address dolomiteAdapter;
        address fluidAdapter;
        address venusAdapter;
        // Rate providers
        address aaveRateProvider;
        address dolomiteRateProvider;
        // Core references
        CoreVault vault;
        StrategyRouter router;
        BufferManager bufferManager;
        StrategyHealthRegistry healthRegistry;
    }

    // ─── Config ──────────────────────────────────────────────────────────────

    struct DeployConfig {
        uint256 deployerPk;
        address deployer;
        address vault;
        address strategyRouter;
        address bufferManager;
        address healthRegistry;
        address incentives;
        address guardian;
        address vetoer;
        address timelock;
        address globalConfig;
        address priceOracle;
        address vaultFactory;
        address feeCollector;
        address selectorRegistry;
        address systemSealer;
        bool deployAdapters;
        bool deployUpkeep;
        bool unpauseBuffer;
        bool doSeal;
    }

    // ─── Entry point ─────────────────────────────────────────────────────────

    function run() external returns (DeploymentResult memory result) {
        require(block.chainid == 42161, "WRONG_CHAIN: DeployUsdcLendingStrategy is Arbitrum-only");

        DeployConfig memory cfg = _loadConfig();

        vm.startBroadcast(cfg.deployerPk);

        result = _phase1_deployModulesAndStrategy(cfg);
        if (cfg.deployAdapters) {
            result = _phase1_5_deployAdapters(cfg, result);
            result = _phase1_6_deployRateProviders(cfg, result);
        }
        result = _phase1_7_deployOptionalModules(cfg, result);
        _phase2_wireStrategy(cfg, result);
        if (cfg.deployAdapters) {
            _phase2_5_bootstrap(cfg, result);
        }
        if (cfg.deployUpkeep) {
            result = _phase3_deployAutomation(cfg, result);
            if (cfg.deployAdapters) {
                _phase3_4_grantParamRoles(cfg, result);
                _phase3_5_transferAdapterAdmins(cfg, result);
            }
        }
        if (cfg.unpauseBuffer) {
            _phase4_unpauseBuffer(cfg, result);
        }

        vm.stopBroadcast();

        if (cfg.doSeal) {
            vm.startBroadcast(cfg.deployerPk);
            _phase5_seal(cfg, result);
            vm.stopBroadcast();
        }

        _writeAddressBook(cfg, result);
        _printSummary(result);
    }

    // ─── Phase 1: Deploy modules + strategy ──────────────────────────────────

    function _phase1_deployModulesAndStrategy(DeployConfig memory cfg)
        internal
        returns (DeploymentResult memory result)
    {
        // Nonce layout (V10):
        //   N+0 = StrategyParamsModule
        //   N+1 = StrategyScoringModule
        //   N+2 = StrategyAdapterOpsModule
        //   N+3 = StrategyRebalanceGateModule
        //   N+4 = UsdcMultiLendingVault (assembly CREATE)
        //   N+5 = StrategyBootstrapper
        uint64 n = vm.getNonce(cfg.deployer);
        address predictedParams   = vm.computeCreateAddress(cfg.deployer, n);
        address predictedScoring  = vm.computeCreateAddress(cfg.deployer, n + 1);
        address predictedOps      = vm.computeCreateAddress(cfg.deployer, n + 2);
        address predictedGate     = vm.computeCreateAddress(cfg.deployer, n + 3);
        address predictedStrategy = vm.computeCreateAddress(cfg.deployer, n + 4);
        address predictedBootstrap = vm.computeCreateAddress(cfg.deployer, n + 5);

        // 1.0a ParamsModule
        StrategyParamsModule params = new StrategyParamsModule(USDC, cfg.vault);
        result.paramsModule = address(params);
        require(result.paramsModule == predictedParams, "ParamsModule address mismatch");
        console.log("[1.0a] StrategyParamsModule:", result.paramsModule);

        // 1.0b ScoringModule
        StrategyScoringModule scoring = new StrategyScoringModule(
            USDC, cfg.vault, result.paramsModule, address(0), predictedOps
        );
        result.scoringModule = address(scoring);
        require(result.scoringModule == predictedScoring, "ScoringModule address mismatch");
        console.log("[1.0b] StrategyScoringModule:", result.scoringModule);

        // 1.0c AdapterOpsModule
        StrategyAdapterOpsModule ops = new StrategyAdapterOpsModule(
            USDC, cfg.vault, result.paramsModule, address(0), address(0)
        );
        result.adapterOpsModule = address(ops);
        require(result.adapterOpsModule == predictedOps, "AdapterOpsModule address mismatch");
        console.log("[1.0c] StrategyAdapterOpsModule:", result.adapterOpsModule);

        // 1.0d RebalanceGateModule
        StrategyRebalanceGateModule gate = new StrategyRebalanceGateModule(
            USDC, cfg.vault, result.paramsModule, result.scoringModule, result.adapterOpsModule
        );
        result.rebalanceGateModule = address(gate);
        require(result.rebalanceGateModule == predictedGate, "GateModule address mismatch");
        console.log("[1.0d] StrategyRebalanceGateModule:", result.rebalanceGateModule);

        // 1.1 UsdcMultiLendingVault (assembly CREATE to control nonce)
        UsdcMultiLendingVault.StrategyInitParams memory p = _defaultParams();
        bytes memory args = abi.encode(
            USDC, cfg.vault, cfg.strategyRouter, cfg.deployer, cfg.guardian,
            predictedBootstrap,
            result.paramsModule, result.scoringModule, result.adapterOpsModule,
            result.rebalanceGateModule, p
        );
        bytes memory code = abi.encodePacked(type(UsdcMultiLendingVault).creationCode, args);
        address deployed;
        assembly { deployed := create(0, add(code, 0x20), mload(code)) }
        require(deployed != address(0), "Strategy deploy failed");
        result.strategy = UsdcMultiLendingVault(payable(deployed));
        require(address(result.strategy) == predictedStrategy, "Strategy address mismatch");
        console.log("[1.1] UsdcMultiLendingVault:", address(result.strategy));

        // 1.2 StrategyBootstrapper (INTERNAL — one-shot, no separate script)
        StrategyBootstrapper boot = new StrategyBootstrapper();
        boot.initialize(payable(address(result.strategy)), cfg.deployer);
        result.bootstrapper = address(boot);
        require(result.bootstrapper == predictedBootstrap, "Bootstrapper address mismatch");
        require(
            result.strategy.hasRole(result.strategy.BOOTSTRAP_ROLE(), result.bootstrapper),
            "BOOTSTRAP_ROLE not granted"
        );
        console.log("[1.2] StrategyBootstrapper:", result.bootstrapper);
        console.log("  BOOTSTRAP_ROLE granted to bootstrapper");

        result.vault = CoreVault(payable(cfg.vault));
        result.router = StrategyRouter(cfg.strategyRouter);
        result.bufferManager = BufferManager(cfg.bufferManager);
        result.healthRegistry = StrategyHealthRegistry(cfg.healthRegistry);
    }

    // ─── Phase 1.5: Deploy 7 lending adapters ────────────────────────────────

    function _phase1_5_deployAdapters(DeployConfig memory cfg, DeploymentResult memory result)
        internal
        returns (DeploymentResult memory)
    {
        // Deploy SimpleProtocolRegistry and configure all market addresses
        SimpleProtocolRegistry reg = new SimpleProtocolRegistry();
        result.protocolRegistry = address(reg);
        console.log("[1.5.1] SimpleProtocolRegistry:", result.protocolRegistry);

        // Morpho markets (5)
        reg.addVault(SimpleProtocolRegistry.ProtocolType.MORPHO, MORPHO_VAULT_1, "Gauntlet USDC Core", 300, 5_000_000e6);
        reg.addVault(SimpleProtocolRegistry.ProtocolType.MORPHO, MORPHO_VAULT_2, "Hyperithm USDC Apex", 350, 2_000_000e6);
        reg.addVault(SimpleProtocolRegistry.ProtocolType.MORPHO, MORPHO_VAULT_4, "Steakhouse HY USDC", 400, 25_000_000e6);
        reg.addVault(SimpleProtocolRegistry.ProtocolType.MORPHO, MORPHO_VAULT_6, "Gauntlet USDC Prime", 300, 10_000_000e6);
        reg.addVault(SimpleProtocolRegistry.ProtocolType.MORPHO, MORPHO_VAULT_8, "Yearn Degen USDC", 500, 1_000_000e6);

        // Comet (Compound III) — 1 market
        reg.addVault(SimpleProtocolRegistry.ProtocolType.COMPOUND_V3, COMET_USDC_V3, "Compound III USDC", 200, 10_000_000e6);

        // Euler vaults (4)
        reg.addVault(SimpleProtocolRegistry.ProtocolType.EULER_V2, EULER_VAULT_1, "Euler USDC 1", 300, 5_000_000e6);
        reg.addVault(SimpleProtocolRegistry.ProtocolType.EULER_V2, EULER_VAULT_2, "Euler USDC 2", 300, 5_000_000e6);
        reg.addVault(SimpleProtocolRegistry.ProtocolType.EULER_V2, EULER_VAULT_3, "Euler USDC 3", 350, 3_000_000e6);
        reg.addVault(SimpleProtocolRegistry.ProtocolType.EULER_V2, EULER_VAULT_4, "Euler USDC 4", 350, 3_000_000e6);

        // Dolomite — 1 market
        reg.addVault(SimpleProtocolRegistry.ProtocolType.DOLOMITE, DOLOMITE_dUSDC, "Dolomite dUSDC", 300, 5_000_000e6);
        console.log("[1.5.2] Registry configured (5 Morpho + 1 Comet + 4 Euler + 1 Dolomite)");

        // 1.5.3 Aave (single market — no registry needed)
        AaveV3USDCAdapter aave = new AaveV3USDCAdapter();
        aave.initialize(USDC, AAVE_POOL, AAVE_AUSDC, cfg.deployer, address(result.strategy), DEFAULT_ADAPTER_CAPACITY);
        result.aaveAdapter = address(aave);
        console.log("[1.5.3] AaveV3USDCAdapter:", result.aaveAdapter);

        // 1.5.4 Morpho
        MorphoUsdcMultiMarketAdapter morph = new MorphoUsdcMultiMarketAdapter();
        morph.initialize(USDC, cfg.deployer, address(result.strategy), DEFAULT_ADAPTER_CAPACITY, result.protocolRegistry);
        result.morphoAdapter = address(morph);
        console.log("[1.5.4] MorphoAdapter:", result.morphoAdapter);

        // 1.5.5 Comet
        CometUsdcMultiMarketAdapter cmt = new CometUsdcMultiMarketAdapter();
        cmt.initialize(USDC, cfg.deployer, address(result.strategy), DEFAULT_ADAPTER_CAPACITY, result.protocolRegistry);
        result.cometAdapter = address(cmt);
        console.log("[1.5.5] CometAdapter:", result.cometAdapter);

        // 1.5.6 Euler — initializeMarkets() BEFORE any role transfer
        // ⚠ CRITICAL (v8-hotfix): Euler Permit2 internal allowance must be set before first deposit.
        //   USDC dust transferred to adapter → initializeMarkets() → THEN role transfer in Phase 3.5.
        //   Without this, first strategy deposit to Euler silently fails or quarantines the adapter.
        address[] memory eulerMarkets = new address[](4);
        eulerMarkets[0] = EULER_VAULT_1; eulerMarkets[1] = EULER_VAULT_2;
        eulerMarkets[2] = EULER_VAULT_3; eulerMarkets[3] = EULER_VAULT_4;
        EulerUsdcMultiMarketAdapter euler = new EulerUsdcMultiMarketAdapter();
        euler.initialize(address(result.strategy), USDC, eulerMarkets, result.protocolRegistry, cfg.deployer);
        result.eulerAdapter = address(euler);
        {
            uint256 EULER_DUST = 1000; // 0.001 USDC for Permit2 setup
            require(
                IERC20(USDC).balanceOf(cfg.deployer) >= EULER_DUST,
                "DEPLOY: insufficient USDC for Euler Permit2 dust (need 0.001 USDC)"
            );
            IERC20(USDC).transfer(address(euler), EULER_DUST);
            euler.initializeMarkets();
        }
        console.log("[1.5.6] EulerAdapter:", result.eulerAdapter, "(initializeMarkets done)");

        // 1.5.7 Dolomite
        DolomiteUsdcMultiMarketAdapter dolo = new DolomiteUsdcMultiMarketAdapter();
        dolo.initialize(USDC, cfg.deployer, address(result.strategy), DEFAULT_ADAPTER_CAPACITY, result.protocolRegistry);
        result.dolomiteAdapter = address(dolo);
        console.log("[1.5.7] DolomiteAdapter:", result.dolomiteAdapter);

        // 1.5.8 Fluid
        FluidUsdcMultiMarketAdapter fluid = new FluidUsdcMultiMarketAdapter();
        fluid.initialize(USDC, cfg.deployer, address(result.strategy), DEFAULT_ADAPTER_CAPACITY, FLUID_FUSDC);
        result.fluidAdapter = address(fluid);
        console.log("[1.5.8] FluidAdapter:", result.fluidAdapter);

        // 1.5.9 Venus
        VenusUsdcMultiMarketAdapter venus = new VenusUsdcMultiMarketAdapter();
        venus.initialize(USDC, cfg.deployer, address(result.strategy), DEFAULT_ADAPTER_CAPACITY, VENUS_VTOKEN, VENUS_BLOCKS_PER_YEAR);
        result.venusAdapter = address(venus);
        console.log("[1.5.9] VenusAdapter:", result.venusAdapter);
        console.log("  [OK] 7 lending adapters deployed");

        return result;
    }

    // ─── Phase 1.6: Deploy rate providers ────────────────────────────────────

    function _phase1_6_deployRateProviders(DeployConfig memory cfg, DeploymentResult memory result)
        internal
        returns (DeploymentResult memory)
    {
        AaveLiquidityRateProvider aaveRp = new AaveLiquidityRateProvider(cfg.deployer, cfg.deployer);
        result.aaveRateProvider = address(aaveRp);
        console.log("[1.6.1] AaveLiquidityRateProvider:", result.aaveRateProvider);

        DolomiteSupplyRateProvider doloRp = new DolomiteSupplyRateProvider(cfg.deployer);
        result.dolomiteRateProvider = address(doloRp);
        console.log("[1.6.2] DolomiteSupplyRateProvider:", result.dolomiteRateProvider);

        // Configure rate providers on adapters
        AaveV3USDCAdapter(payable(result.aaveAdapter)).setRateProvider(result.aaveRateProvider);
        DolomiteUsdcMultiMarketAdapter(payable(result.dolomiteAdapter))
            .setRateProvider(result.dolomiteRateProvider);

        // Dolomite market config (audit requirement)
        DolomiteUsdcMultiMarketAdapter dolo = DolomiteUsdcMultiMarketAdapter(payable(result.dolomiteAdapter));
        dolo.setUsdcMarketId(17);
        dolo.setAccountNumber(0);
        require(dolo.usdcMarketId() == 17, "DOLO_MKTID_NOT_SET");
        require(dolo.accountNumber() == 0, "DOLO_ACCT_NOT_SET");
        console.log("[1.6.3] Rate providers configured; Dolomite marketId=17 accountNumber=0");
        console.log("  [OK] Rate providers deployed and configured");

        return result;
    }

    // ─── Phase 1.7: Optional modules (MUST run before Phase 2.5 bootstrap) ───

    function _phase1_7_deployOptionalModules(DeployConfig memory cfg, DeploymentResult memory result)
        internal
        returns (DeploymentResult memory)
    {
        UsdcMultiLendingVault strat = result.strategy;

        // SettingsModule — only needs (asset, vault) since it doesn't delegatecall scoring
        StrategySettingsModule settings = new StrategySettingsModule(USDC, cfg.vault);
        result.settingsModule = address(settings);
        console.log("[1.7.1] StrategySettingsModule:", result.settingsModule);

        StrategyAllocCalcModule allocCalc = new StrategyAllocCalcModule(USDC, address(strat));
        result.allocCalcModule = address(allocCalc);
        console.log("[1.7.2] StrategyAllocCalcModule:", result.allocCalcModule);

        StrategyRebalancePlanModule planMod = new StrategyRebalancePlanModule(
            USDC, address(strat),
            result.paramsModule, result.scoringModule, result.adapterOpsModule
        );
        result.rebalancePlanModule = address(planMod);
        console.log("[1.7.3] StrategyRebalancePlanModule:", result.rebalancePlanModule);

        // Wire modules on-chain (deployer has DEFAULT_ADMIN_ROLE at this point)
        strat.setSettingsModule(result.settingsModule);
        strat.setAllocCalcModule(result.allocCalcModule);
        strat.setRebalancePlanModule(result.rebalancePlanModule);
        console.log("  [OK] settingsModule, allocCalcModule, rebalancePlanModule wired");

        return result;
    }

    // ─── Phase 2: Wire strategy ───────────────────────────────────────────────

    function _phase2_wireStrategy(DeployConfig memory cfg, DeploymentResult memory result)
        internal
    {
        // 2.1 Register in router (idempotent)
        if (!_isRegistered(result.router, address(result.strategy))) {
            if (result.router.owner() == cfg.deployer) {
                result.router.register(address(result.strategy), 100, 10000);
                result.router.setMaxStrategyBps(address(result.strategy), 10000);
                result.router.setLossCapPerStrategy(address(result.strategy), 50);
                console.log("[2.1] Strategy registered in router (maxBps=10000, lossCap=50bps)");
            } else {
                console.log("[2.1] SKIP: router owner is not deployer - register via Timelock/Safe");
            }
        } else {
            console.log("[2.1] SKIP: strategy already registered");
        }

        // 2.2 Verify CORE_ROLE (set in constructor)
        bytes32 CORE_ROLE = keccak256("CORE_ROLE");
        require(
            result.strategy.hasRole(CORE_ROLE, cfg.vault),
            "DEPLOY_BUG: CoreVault missing CORE_ROLE"
        );
        require(
            result.strategy.hasRole(CORE_ROLE, cfg.strategyRouter),
            "DEPLOY_BUG: StrategyRouter missing CORE_ROLE"
        );
        console.log("[2.2] CORE_ROLE: CoreVault + StrategyRouter verified");

        // 2.3 setEcosystem (idempotent)
        IAdminModule.EcosystemConfig memory eco = IAdminModule(cfg.vault).getEcosystem();
        if (eco.bufferManager == address(0)) {
            IAdminModule(cfg.vault).setEcosystem(
                IAdminModule.EcosystemConfig({
                    bufferManager: cfg.bufferManager,
                    strategyRouter: cfg.strategyRouter,
                    healthRegistry: cfg.healthRegistry,
                    incentives: cfg.incentives,
                    guardian: cfg.guardian,
                    vetoer: cfg.vetoer
                })
            );
            console.log("[2.3] Ecosystem configured");
        } else {
            console.log("[2.3] SKIP: ecosystem already set");
        }
    }

    // ─── Phase 2.5: Bootstrap adapters ───────────────────────────────────────

    function _phase2_5_bootstrap(DeployConfig memory cfg, DeploymentResult memory result)
        internal
    {
        address[] memory adapters = new address[](7);
        adapters[0] = result.aaveAdapter;
        adapters[1] = result.morphoAdapter;
        adapters[2] = result.cometAdapter;
        adapters[3] = result.eulerAdapter;
        adapters[4] = result.dolomiteAdapter;
        adapters[5] = result.fluidAdapter;
        adapters[6] = result.venusAdapter;

        StrategyBootstrapper(payable(result.bootstrapper)).bootstrap(adapters);
        require(
            !StrategyBootstrapper(payable(result.bootstrapper)).hasBootstrapRole(),
            "BOOTSTRAP_ROLE not renounced"
        );
        console.log("[2.5] Bootstrap complete - 7 adapters registered, BOOTSTRAP_ROLE renounced");
    }

    // ─── Phase 3: Automation + PARAM_ROLE grants ─────────────────────────────

    function _phase3_deployAutomation(DeployConfig memory cfg, DeploymentResult memory result)
        internal
        returns (DeploymentResult memory)
    {
        address[] memory strategies = new address[](1);
        strategies[0] = address(result.strategy);
        StrategyUpkeep upkeep = new StrategyUpkeep(strategies);
        result.strategyUpkeep = address(upkeep);
        console.log("[3.1] StrategyUpkeep:", result.strategyUpkeep);

        bytes32 KEEPER_ROLE = keccak256("KEEPER_ROLE");
        bytes32 ADMIN_ROLE  = result.strategy.DEFAULT_ADMIN_ROLE();
        if (result.strategy.hasRole(ADMIN_ROLE, cfg.deployer)) {
            result.strategy.grantRole(KEEPER_ROLE, result.strategyUpkeep);
            console.log("[3.2] KEEPER_ROLE granted to StrategyUpkeep");
        } else {
            console.log("[3.2] SKIP: deployer has no admin - timelock must grant KEEPER_ROLE");
            console.log("  ACTION: strategy.grantRole(KEEPER_ROLE, upkeep)");
        }
        return result;
    }

    /// @notice Grant PARAM_ROLE to StrategyUpkeep on Morpho/Dolomite/Fluid/AaveRP.
    /// @dev Poke (APY refresh) fails silently on these adapters without PARAM_ROLE.
    ///      v8-hotfix: must be done BEFORE Phase 3.5 role transfers.
    function _phase3_4_grantParamRoles(DeployConfig memory cfg, DeploymentResult memory result)
        internal
    {
        bytes32 PARAM_ROLE = keccak256("PARAM_ROLE");

        IAccessControl(result.morphoAdapter).grantRole(PARAM_ROLE, result.strategyUpkeep);
        IAccessControl(result.dolomiteAdapter).grantRole(PARAM_ROLE, result.strategyUpkeep);
        IAccessControl(result.fluidAdapter).grantRole(PARAM_ROLE, result.strategyUpkeep);
        IAccessControl(result.aaveRateProvider).grantRole(PARAM_ROLE, result.strategyUpkeep);

        require(IAccessControl(result.morphoAdapter).hasRole(PARAM_ROLE, result.strategyUpkeep), "Morpho PARAM_ROLE not granted");
        require(IAccessControl(result.dolomiteAdapter).hasRole(PARAM_ROLE, result.strategyUpkeep), "Dolomite PARAM_ROLE not granted");
        require(IAccessControl(result.fluidAdapter).hasRole(PARAM_ROLE, result.strategyUpkeep), "Fluid PARAM_ROLE not granted");
        require(IAccessControl(result.aaveRateProvider).hasRole(PARAM_ROLE, result.strategyUpkeep), "AaveRP PARAM_ROLE not granted");
        console.log("[3.4] PARAM_ROLE granted to StrategyUpkeep on Morpho/Dolomite/Fluid/AaveRP");
    }

    /// @notice Transfer adapter admin roles to timelock (AFTER Phase 3.4 PARAM_ROLE grants).
    function _phase3_5_transferAdapterAdmins(DeployConfig memory cfg, DeploymentResult memory result)
        internal
    {
        if (cfg.timelock == address(0)) {
            console.log("[3.5] SKIP: TIMELOCK_ADDRESS not set - transfer manually");
            return;
        }
        bytes32 ADMIN_ROLE = bytes32(0); // DEFAULT_ADMIN_ROLE = 0x00
        bytes32 PARAM_ROLE = keccak256("PARAM_ROLE");

        // Morpho
        IAccessControl(result.morphoAdapter).grantRole(ADMIN_ROLE, cfg.timelock);
        IAccessControl(result.morphoAdapter).renounceRole(ADMIN_ROLE, cfg.deployer);
        // Comet
        IAccessControl(result.cometAdapter).grantRole(ADMIN_ROLE, cfg.timelock);
        IAccessControl(result.cometAdapter).renounceRole(ADMIN_ROLE, cfg.deployer);
        // Euler — PARAM_ROLE to timelock before renounce (grants done here since no Phase 3.4 for Euler)
        EulerUsdcMultiMarketAdapter euler = EulerUsdcMultiMarketAdapter(payable(result.eulerAdapter));
        IAccessControl(result.eulerAdapter).grantRole(euler.PARAM_ROLE(), cfg.timelock);
        IAccessControl(result.eulerAdapter).grantRole(ADMIN_ROLE, cfg.timelock);
        euler.renounceRole(euler.PARAM_ROLE(), cfg.deployer);
        IAccessControl(result.eulerAdapter).renounceRole(ADMIN_ROLE, cfg.deployer);
        // Dolomite — PARAM_ROLE to timelock
        DolomiteUsdcMultiMarketAdapter dolo = DolomiteUsdcMultiMarketAdapter(payable(result.dolomiteAdapter));
        IAccessControl(result.dolomiteAdapter).grantRole(dolo.PARAM_ROLE(), cfg.timelock);
        IAccessControl(result.dolomiteAdapter).grantRole(ADMIN_ROLE, cfg.timelock);
        dolo.renounceRole(dolo.PARAM_ROLE(), cfg.deployer);
        IAccessControl(result.dolomiteAdapter).renounceRole(ADMIN_ROLE, cfg.deployer);
        // Fluid
        IAccessControl(result.fluidAdapter).grantRole(ADMIN_ROLE, cfg.timelock);
        IAccessControl(result.fluidAdapter).renounceRole(ADMIN_ROLE, cfg.deployer);
        // Venus
        IAccessControl(result.venusAdapter).grantRole(ADMIN_ROLE, cfg.timelock);
        IAccessControl(result.venusAdapter).renounceRole(ADMIN_ROLE, cfg.deployer);
        // Aave
        IAccessControl(result.aaveAdapter).revokeRole(PARAM_ROLE, cfg.deployer);
        IAccessControl(result.aaveAdapter).grantRole(ADMIN_ROLE, cfg.timelock);
        IAccessControl(result.aaveAdapter).renounceRole(ADMIN_ROLE, cfg.deployer);
        // AaveRP
        IAccessControl(result.aaveRateProvider).revokeRole(PARAM_ROLE, cfg.deployer);
        IAccessControl(result.aaveRateProvider).grantRole(ADMIN_ROLE, cfg.timelock);
        IAccessControl(result.aaveRateProvider).renounceRole(ADMIN_ROLE, cfg.deployer);
        // DolomiteRP
        DolomiteSupplyRateProvider(address(result.dolomiteRateProvider)).transferOwnership(cfg.timelock);
        console.log("[3.5] All adapter admin roles transferred to timelock");
    }

    // ─── Phase 4: Unpause BufferManager ──────────────────────────────────────

    function _phase4_unpauseBuffer(DeployConfig memory cfg, DeploymentResult memory) internal {
        if (IBufferManager(cfg.bufferManager).getConfig().paused) {
            IBufferManager(cfg.bufferManager).setPaused(false);
            console.log("[4] BufferManager unpaused");
        } else {
            console.log("[4] SKIP: BufferManager already unpaused");
        }
    }

    // ─── Phase 5: Seal (optional, DO_SEAL=true) ───────────────────────────────

    function _phase5_seal(DeployConfig memory cfg, DeploymentResult memory result) internal {
        require(cfg.timelock != address(0), "SEAL: TIMELOCK_ADDRESS required");
        require(cfg.selectorRegistry != address(0), "SEAL: SELECTOR_REGISTRY_ADDRESS required");
        require(cfg.systemSealer != address(0), "SEAL: SYSTEM_SEALER_ADDRESS required");

        // Transfer strategy admin roles to timelock
        bytes32 ADMIN_ROLE = result.strategy.DEFAULT_ADMIN_ROLE();
        bytes32 PARAM_ROLE_STRAT = keccak256("PARAM_ROLE");
        result.strategy.grantRole(ADMIN_ROLE, cfg.timelock);
        result.strategy.grantRole(PARAM_ROLE_STRAT, cfg.timelock);
        result.strategy.renounceRole(ADMIN_ROLE, cfg.deployer);
        console.log("[5] Strategy admin roles transferred to timelock");

        // Verify vault routing frozen and components timelocked
        require(CoreVault(payable(cfg.vault)).isRoutingFrozen(), "SEAL: routing not frozen");
        require(IAdminModule(cfg.vault).isComponentsTimelocked(), "SEAL: components timelock not enabled");
        console.log("[5] Routing frozen + components timelocked: PASS");
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _isRegistered(StrategyRouter router, address strategy) internal view returns (bool) {
        IStrategyRouter.StrategyInfo[] memory list = router.list();
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i].strat == strategy) return true;
        }
        return false;
    }

    function _defaultParams() internal view returns (UsdcMultiLendingVault.StrategyInitParams memory) {
        uint16 maxExpBps = 5000;
        try vm.envUint("ADAPTER_MAX_EXPOSURE_BPS") returns (uint256 val) {
            if (val > 0 && val <= 10000) maxExpBps = uint16(val);
        } catch {}
        return UsdcMultiLendingVault.StrategyInitParams({
            maxAdaptersPerAllocation: 3,
            minAdaptersActive: 2,
            rebalanceMinMoveBps: 50,
            minSecondsBetweenRebalances: 86400,
            driftToleranceBps: 80,
            wAPY: 4000,
            wLiq: 2000,
            wRisk: 2000,
            wStability: 1000,
            wIncentive: 1000,
            incentiveDecayHalfLife: 604800,
            adapterMaxExposureBps: maxExpBps,
            newAdapterRampBps: 500,
            gateHorizonDays: 30,
            gateMinNetBenefitBps: 10,
            slippageBpsEstimate: 2,
            withdrawalSpreadBpsEstimate: 2,
            gasCostUSDC: 1e6,
            harvestThresholdBps: 100,
            minSecondsBetweenHarvests: 86400,
            dustTolerance: 1e4,
            stabilityEMAPeriod: 7,
            minNewAdapterSeed: 100_000e6,
            newAdapterRampDuration: 259200,
            maxIdleAfterDepositBps: 500,
            maxIdleBootstrapBps: 5000,
            degradedViewThresholdBps: 2500,
            failureDecaySeconds: 3600,
            minSecondsBetweenDeployIdle: 300,
            bootstrapDuration: 259200,
            maxRelativeExposureBps: 1000,
            externalTVLStalenessSeconds: 100800
        });
    }

    function _loadConfig() internal returns (DeployConfig memory cfg) {
        cfg.deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        cfg.deployer   = vm.addr(cfg.deployerPk);
        cfg.vault         = vm.envAddress("VAULT_ADDRESS");
        cfg.strategyRouter = vm.envAddress("STRATEGY_ROUTER_ADDRESS");
        cfg.bufferManager  = vm.envAddress("BUFFER_MANAGER_ADDRESS");
        cfg.healthRegistry = vm.envAddress("HEALTH_REGISTRY_ADDRESS");
        cfg.guardian       = vm.envAddress("GUARDIAN_ADDRESS");

        try vm.envAddress("TIMELOCK_ADDRESS")          returns (address a) { cfg.timelock = a; } catch {}
        try vm.envAddress("GLOBAL_CONFIG_ADDRESS")     returns (address a) { cfg.globalConfig = a; } catch {}
        try vm.envAddress("PRICE_ORACLE_ADDRESS")      returns (address a) { cfg.priceOracle = a; } catch {}
        try vm.envAddress("VAULT_FACTORY_ADDRESS")     returns (address a) { cfg.vaultFactory = a; } catch {}
        try vm.envAddress("FEE_COLLECTOR_ADDRESS")     returns (address a) { cfg.feeCollector = a; } catch {}
        try vm.envAddress("SELECTOR_REGISTRY_ADDRESS") returns (address a) { cfg.selectorRegistry = a; } catch {}
        try vm.envAddress("SYSTEM_SEALER_ADDRESS")     returns (address a) { cfg.systemSealer = a; } catch {}
        try vm.envAddress("INCENTIVES_ADDRESS")        returns (address a) { cfg.incentives = a; } catch {}
        try vm.envAddress("VETOER_ADDRESS")            returns (address a) { cfg.vetoer = a; } catch {}

        cfg.deployAdapters = true;
        cfg.deployUpkeep   = true;
        cfg.unpauseBuffer  = true;
        try vm.envBool("DEPLOY_LENDING_ADAPTERS") returns (bool v) { cfg.deployAdapters = v; } catch {}
        try vm.envBool("DEPLOY_UPKEEP")           returns (bool v) { cfg.deployUpkeep = v; } catch {}
        try vm.envBool("UNPAUSE_BUFFER")          returns (bool v) { cfg.unpauseBuffer = v; } catch {}
        try vm.envBool("DO_SEAL")                 returns (bool v) { cfg.doSeal = v; } catch {}
    }

    function _writeAddressBook(DeployConfig memory, DeploymentResult memory result) internal {
        string memory j = "strategy";
        vm.serializeUint(j, "chainId", block.chainid);
        vm.serializeUint(j, "blockNumber", block.number);
        vm.serializeUint(j, "timestamp", block.timestamp);
        vm.serializeAddress(j, "strategy", address(result.strategy));
        vm.serializeAddress(j, "paramsModule", result.paramsModule);
        vm.serializeAddress(j, "scoringModule", result.scoringModule);
        vm.serializeAddress(j, "adapterOpsModule", result.adapterOpsModule);
        vm.serializeAddress(j, "rebalanceGateModule", result.rebalanceGateModule);
        vm.serializeAddress(j, "settingsModule", result.settingsModule);
        vm.serializeAddress(j, "allocCalcModule", result.allocCalcModule);
        vm.serializeAddress(j, "rebalancePlanModule", result.rebalancePlanModule);
        vm.serializeAddress(j, "bootstrapper", result.bootstrapper);
        vm.serializeAddress(j, "strategyUpkeep", result.strategyUpkeep);
        vm.serializeAddress(j, "protocolRegistry", result.protocolRegistry);
        vm.serializeAddress(j, "aaveAdapter", result.aaveAdapter);
        vm.serializeAddress(j, "morphoAdapter", result.morphoAdapter);
        vm.serializeAddress(j, "cometAdapter", result.cometAdapter);
        vm.serializeAddress(j, "eulerAdapter", result.eulerAdapter);
        vm.serializeAddress(j, "dolomiteAdapter", result.dolomiteAdapter);
        vm.serializeAddress(j, "fluidAdapter", result.fluidAdapter);
        vm.serializeAddress(j, "venusAdapter", result.venusAdapter);
        vm.serializeAddress(j, "aaveRateProvider", result.aaveRateProvider);
        string memory out = vm.serializeAddress(j, "dolomiteRateProvider", result.dolomiteRateProvider);

        string memory path = "broadcast/strategy-addresses.json";
        try vm.envString("STRATEGY_OUTPUT_JSON") returns (string memory p) { path = p; } catch {}
        vm.writeJson(out, path);
        console.log("Address book written to:", path);
    }

    function _printSummary(DeploymentResult memory result) internal view {
        console.log("");
        console.log("=== DEPLOY COMPLETE ===");
        console.log("UsdcMultiLendingVault:", address(result.strategy));
        if (result.strategyUpkeep != address(0)) console.log("StrategyUpkeep:", result.strategyUpkeep);
        if (result.aaveAdapter   != address(0)) console.log("Aave:      ", result.aaveAdapter);
        if (result.morphoAdapter != address(0)) console.log("Morpho:    ", result.morphoAdapter);
        if (result.cometAdapter  != address(0)) console.log("Comet:     ", result.cometAdapter);
        if (result.eulerAdapter  != address(0)) console.log("Euler:     ", result.eulerAdapter);
        if (result.dolomiteAdapter != address(0)) console.log("Dolomite:  ", result.dolomiteAdapter);
        if (result.fluidAdapter  != address(0)) console.log("Fluid:     ", result.fluidAdapter);
        if (result.venusAdapter  != address(0)) console.log("Venus:     ", result.venusAdapter);
    }
}
