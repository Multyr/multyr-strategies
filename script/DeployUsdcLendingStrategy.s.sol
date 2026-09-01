// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

// Chain config
import { UsdcLendingChainConfig } from "@multyr-strategies/strategies/usdc-lending/config/UsdcLendingChainConfig.sol";
import { UsdcLendingConfigArbitrum } from "@multyr-strategies/strategies/usdc-lending/config/UsdcLendingConfigArbitrum.sol";

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
import { AdapterFactory } from "@multyr-strategies/strategies/usdc-lending/factory/AdapterFactory.sol";

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
 * Phase 2.6: Poke external TVL + liquidity for all adapters (deployer briefly holds
 *            KEEPER_ROLE, revoked immediately after). Without this every adapter reads
 *            CONFIDENCE_ZERO and the first real deposit reverts (BootstrapIdleTooHigh).
 * Phase 3:   Deploy StrategyUpkeep + grant KEEPER_ROLE
 *            Grant PARAM_ROLE on Morpho/Dolomite/Fluid/AaveRP for poke (fails silently without)
 * Phase 3.5: Transfer adapter admin roles to timelock
 * Phase 4:   Unpause BufferManager (optional, env-gated)
 * Phase 5:   Seal + transfer ownership (optional, env-gated, DO_SEAL=true)
 *
 * Note: this strategy is NOT registered in VaultFactory — VaultFactory tracks
 * CoreVault instances only (DeployCoreSystem.s.sol already registers the one
 * relevant CoreVault during the core deploy). A strategy becomes known to the
 * system by registering with StrategyRouter instead (Phase 2.1 above).
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
        address adapterFactory;
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

        UsdcLendingChainConfig memory chainCfg = UsdcLendingConfigArbitrum.get();
        DeployConfig memory cfg = _loadConfig();

        vm.startBroadcast(cfg.deployerPk);

        result = _phase1_deployModulesAndStrategy(cfg, chainCfg);
        if (cfg.deployAdapters) {
            result = _phase1_5_deployAdapters(cfg, result, chainCfg);
            result = _phase1_6_deployRateProviders(cfg, result);
        }
        result = _phase1_7_deployOptionalModules(cfg, result, chainCfg);
        _phase2_wireStrategy(cfg, result);
        if (cfg.deployAdapters) {
            _phase2_5_bootstrap(cfg, result);
            _phase2_6_pokeAdapterData(cfg, result);
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

    function _phase1_deployModulesAndStrategy(DeployConfig memory cfg, UsdcLendingChainConfig memory chainCfg)
        internal
        returns (DeploymentResult memory result)
    {
        // Nonce layout (V10):
        //   N+0 = AdapterFactory
        //   N+1 = StrategyParamsModule
        //   N+2 = StrategyScoringModule
        //   N+3 = StrategyAdapterOpsModule
        //   N+4 = StrategyRebalanceGateModule
        //   N+5 = UsdcMultiLendingVault (assembly CREATE)
        //   (StrategyBootstrapper is deployed via AdapterFactory.deployAndInit()
        //    below -- a CREATE2 from the factory, not a direct deployer-nonce
        //    CREATE, so its address is predicted via factory.computeAddress()
        //    instead of vm.computeCreateAddress(). This closes the
        //    front-runnable deploy-then-initialize() window: CREATE2 deploy and
        //    initialize() now execute atomically in one transaction.)
        uint64 n = vm.getNonce(cfg.deployer);
        address predictedFactory  = vm.computeCreateAddress(cfg.deployer, n);
        address predictedParams   = vm.computeCreateAddress(cfg.deployer, n + 1);
        address predictedScoring  = vm.computeCreateAddress(cfg.deployer, n + 2);
        address predictedOps      = vm.computeCreateAddress(cfg.deployer, n + 3);
        address predictedGate     = vm.computeCreateAddress(cfg.deployer, n + 4);
        address predictedStrategy = vm.computeCreateAddress(cfg.deployer, n + 5);

        // 1.-1 AdapterFactory — atomic CREATE2-deploy-then-initialize for the
        // bootstrapper and all 7 lending adapters (see factory/AdapterFactory.sol).
        // cfg.deployer receives both DEFAULT_ADMIN_ROLE and DEPLOYER_ROLE via
        // the constructor.
        AdapterFactory factory = new AdapterFactory(cfg.deployer);
        result.adapterFactory = address(factory);
        require(result.adapterFactory == predictedFactory, "AdapterFactory address mismatch");
        console.log("[1.-1] AdapterFactory:", result.adapterFactory);

        bytes32 bootstrapSalt = keccak256(abi.encodePacked(chainCfg.deploySalt, "bootstrapper"));
        address predictedBootstrap = factory.computeAddress(
            type(StrategyBootstrapper).creationCode, bootstrapSalt
        );

        // 1.0a ParamsModule
        StrategyParamsModule params = new StrategyParamsModule(chainCfg.usdc, cfg.vault);
        result.paramsModule = address(params);
        require(result.paramsModule == predictedParams, "ParamsModule address mismatch");
        console.log("[1.0a] StrategyParamsModule:", result.paramsModule);

        // 1.0b ScoringModule
        StrategyScoringModule scoring = new StrategyScoringModule(
            chainCfg.usdc, cfg.vault, result.paramsModule, address(0), predictedOps
        );
        result.scoringModule = address(scoring);
        require(result.scoringModule == predictedScoring, "ScoringModule address mismatch");
        console.log("[1.0b] StrategyScoringModule:", result.scoringModule);

        // 1.0c AdapterOpsModule
        StrategyAdapterOpsModule ops = new StrategyAdapterOpsModule(
            chainCfg.usdc, cfg.vault, result.paramsModule, address(0), address(0)
        );
        result.adapterOpsModule = address(ops);
        require(result.adapterOpsModule == predictedOps, "AdapterOpsModule address mismatch");
        console.log("[1.0c] StrategyAdapterOpsModule:", result.adapterOpsModule);

        // 1.0d RebalanceGateModule
        StrategyRebalanceGateModule gate = new StrategyRebalanceGateModule(
            chainCfg.usdc, cfg.vault, result.paramsModule, result.scoringModule, result.adapterOpsModule
        );
        result.rebalanceGateModule = address(gate);
        require(result.rebalanceGateModule == predictedGate, "GateModule address mismatch");
        console.log("[1.0d] StrategyRebalanceGateModule:", result.rebalanceGateModule);

        // 1.1 UsdcMultiLendingVault (assembly CREATE to control nonce)
        UsdcMultiLendingVault.StrategyInitParams memory p = _defaultParams();
        bytes memory args = abi.encode(
            chainCfg.usdc, cfg.vault, cfg.strategyRouter, cfg.deployer, cfg.guardian,
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
        // Atomic CREATE2-deploy-then-initialize via AdapterFactory: deploy and
        // initialize() now happen in a single transaction, closing the window
        // where an unrelated address could front-run initialize() and set
        // itself as `deployer` (see AdapterFactory.sol docstring).
        result.bootstrapper = factory.deployAndInit(
            type(StrategyBootstrapper).creationCode,
            bootstrapSalt,
            abi.encodeCall(StrategyBootstrapper.initialize, (payable(address(result.strategy)), cfg.deployer))
        );
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

    function _phase1_5_deployAdapters(DeployConfig memory cfg, DeploymentResult memory result, UsdcLendingChainConfig memory chainCfg)
        internal
        returns (DeploymentResult memory)
    {
        // Deploy SimpleProtocolRegistry and configure all market addresses
        SimpleProtocolRegistry reg = new SimpleProtocolRegistry();
        result.protocolRegistry = address(reg);
        console.log("[1.5.1] SimpleProtocolRegistry:", result.protocolRegistry);

        // Morpho markets (5)
        reg.addVault(SimpleProtocolRegistry.ProtocolType.MORPHO, chainCfg.morphoVault1, "Gauntlet USDC Core", 300, 5_000_000e6);
        reg.addVault(SimpleProtocolRegistry.ProtocolType.MORPHO, chainCfg.morphoVault2, "Hyperithm USDC Apex", 350, 2_000_000e6);
        reg.addVault(SimpleProtocolRegistry.ProtocolType.MORPHO, chainCfg.morphoVault4, "Steakhouse HY USDC", 400, 25_000_000e6);
        reg.addVault(SimpleProtocolRegistry.ProtocolType.MORPHO, chainCfg.morphoVault6, "Gauntlet USDC Prime", 300, 10_000_000e6);
        reg.addVault(SimpleProtocolRegistry.ProtocolType.MORPHO, chainCfg.morphoVault8, "Yearn Degen USDC", 500, 1_000_000e6);

        // Comet (Compound III) — 1 market
        reg.addVault(SimpleProtocolRegistry.ProtocolType.COMPOUND_V3, chainCfg.cometUsdcV3, "Compound III USDC", 200, 10_000_000e6);

        // Euler vaults (4)
        reg.addVault(SimpleProtocolRegistry.ProtocolType.EULER_V2, chainCfg.eulerVault1, "Euler USDC 1", 300, 5_000_000e6);
        reg.addVault(SimpleProtocolRegistry.ProtocolType.EULER_V2, chainCfg.eulerVault2, "Euler USDC 2", 300, 5_000_000e6);
        reg.addVault(SimpleProtocolRegistry.ProtocolType.EULER_V2, chainCfg.eulerVault3, "Euler USDC 3", 350, 3_000_000e6);
        reg.addVault(SimpleProtocolRegistry.ProtocolType.EULER_V2, chainCfg.eulerVault4, "Euler USDC 4", 350, 3_000_000e6);

        // Dolomite — 1 market
        reg.addVault(SimpleProtocolRegistry.ProtocolType.DOLOMITE, chainCfg.dolomiteDUsdc, "Dolomite dUSDC", 300, 5_000_000e6);
        console.log("[1.5.2] Registry configured (5 Morpho + 1 Comet + 4 Euler + 1 Dolomite)");

        // All 7 adapters below are deployed via AdapterFactory.deployAndInit():
        // CREATE2 + initialize() execute atomically in one transaction, closing
        // the front-runnable window that a separate `new X(); x.initialize(...)`
        // pair leaves open (an unrelated caller taking DEFAULT_ADMIN_ROLE +
        // PARAM_ROLE on the adapter and pointing its onlyVault gate elsewhere).
        AdapterFactory factory = AdapterFactory(result.adapterFactory);

        // 1.5.3 Aave (single market — no registry needed)
        result.aaveAdapter = factory.deployAndInit(
            type(AaveV3USDCAdapter).creationCode,
            keccak256(abi.encodePacked(chainCfg.deploySalt, "aave")),
            abi.encodeCall(
                AaveV3USDCAdapter.initialize,
                (chainCfg.usdc, chainCfg.aavePool, chainCfg.aaveAUsdc, cfg.deployer, address(result.strategy), DEFAULT_ADAPTER_CAPACITY)
            )
        );
        console.log("[1.5.3] AaveV3USDCAdapter:", result.aaveAdapter);

        // 1.5.4 Morpho
        result.morphoAdapter = factory.deployAndInit(
            type(MorphoUsdcMultiMarketAdapter).creationCode,
            keccak256(abi.encodePacked(chainCfg.deploySalt, "morpho")),
            abi.encodeCall(
                MorphoUsdcMultiMarketAdapter.initialize,
                (chainCfg.usdc, cfg.deployer, address(result.strategy), DEFAULT_ADAPTER_CAPACITY, result.protocolRegistry)
            )
        );
        console.log("[1.5.4] MorphoAdapter:", result.morphoAdapter);

        // 1.5.5 Comet
        result.cometAdapter = factory.deployAndInit(
            type(CometUsdcMultiMarketAdapter).creationCode,
            keccak256(abi.encodePacked(chainCfg.deploySalt, "comet")),
            abi.encodeCall(
                CometUsdcMultiMarketAdapter.initialize,
                (chainCfg.usdc, cfg.deployer, address(result.strategy), DEFAULT_ADAPTER_CAPACITY, result.protocolRegistry)
            )
        );
        console.log("[1.5.5] CometAdapter:", result.cometAdapter);

        // 1.5.6 Euler — initializeMarkets() BEFORE any role transfer
        // ⚠ CRITICAL (v8-hotfix): Euler Permit2 internal allowance must be set before first deposit.
        //   USDC dust transferred to adapter → initializeMarkets() → THEN role transfer in Phase 3.5.
        //   Without this, first strategy deposit to Euler silently fails or quarantines the adapter.
        //   initializeMarkets() itself is a separate, PARAM_ROLE-gated post-init step (not the
        //   OZ `initializer` this fix targets) — safe to run after the atomic deploy+init below.
        address[] memory eulerMarkets = new address[](4);
        eulerMarkets[0] = chainCfg.eulerVault1; eulerMarkets[1] = chainCfg.eulerVault2;
        eulerMarkets[2] = chainCfg.eulerVault3; eulerMarkets[3] = chainCfg.eulerVault4;
        result.eulerAdapter = factory.deployAndInit(
            type(EulerUsdcMultiMarketAdapter).creationCode,
            keccak256(abi.encodePacked(chainCfg.deploySalt, "euler")),
            abi.encodeCall(
                EulerUsdcMultiMarketAdapter.initialize,
                (address(result.strategy), chainCfg.usdc, eulerMarkets, result.protocolRegistry, cfg.deployer)
            )
        );
        {
            EulerUsdcMultiMarketAdapter euler = EulerUsdcMultiMarketAdapter(payable(result.eulerAdapter));
            uint256 EULER_DUST = 1000; // 0.001 USDC for Permit2 setup
            require(
                IERC20(chainCfg.usdc).balanceOf(cfg.deployer) >= EULER_DUST,
                "DEPLOY: insufficient USDC for Euler Permit2 dust (need 0.001 USDC)"
            );
            IERC20(chainCfg.usdc).transfer(address(euler), EULER_DUST);
            euler.initializeMarkets();
        }
        console.log("[1.5.6] EulerAdapter:", result.eulerAdapter, "(initializeMarkets done)");

        // 1.5.7 Dolomite
        result.dolomiteAdapter = factory.deployAndInit(
            type(DolomiteUsdcMultiMarketAdapter).creationCode,
            keccak256(abi.encodePacked(chainCfg.deploySalt, "dolomite")),
            abi.encodeCall(
                DolomiteUsdcMultiMarketAdapter.initialize,
                (chainCfg.usdc, cfg.deployer, address(result.strategy), DEFAULT_ADAPTER_CAPACITY, result.protocolRegistry)
            )
        );
        console.log("[1.5.7] DolomiteAdapter:", result.dolomiteAdapter);

        // 1.5.8 Fluid
        result.fluidAdapter = factory.deployAndInit(
            type(FluidUsdcMultiMarketAdapter).creationCode,
            keccak256(abi.encodePacked(chainCfg.deploySalt, "fluid")),
            abi.encodeCall(
                FluidUsdcMultiMarketAdapter.initialize,
                (chainCfg.usdc, cfg.deployer, address(result.strategy), DEFAULT_ADAPTER_CAPACITY, chainCfg.fluidFUsdc)
            )
        );
        console.log("[1.5.8] FluidAdapter:", result.fluidAdapter);

        // 1.5.9 Venus
        result.venusAdapter = factory.deployAndInit(
            type(VenusUsdcMultiMarketAdapter).creationCode,
            keccak256(abi.encodePacked(chainCfg.deploySalt, "venus")),
            abi.encodeCall(
                VenusUsdcMultiMarketAdapter.initialize,
                (chainCfg.usdc, cfg.deployer, address(result.strategy), DEFAULT_ADAPTER_CAPACITY, chainCfg.venusVToken, chainCfg.venusBlocksPerYear)
            )
        );
        console.log("[1.5.9] VenusAdapter:", result.venusAdapter);
        console.log("  [OK] 7 lending adapters deployed (atomic deploy+init via AdapterFactory)");

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

    function _phase1_7_deployOptionalModules(DeployConfig memory cfg, DeploymentResult memory result, UsdcLendingChainConfig memory chainCfg)
        internal
        returns (DeploymentResult memory)
    {
        UsdcMultiLendingVault strat = result.strategy;

        // SettingsModule — only needs (asset, vault) since it doesn't delegatecall scoring
        StrategySettingsModule settings = new StrategySettingsModule(chainCfg.usdc, cfg.vault);
        result.settingsModule = address(settings);
        console.log("[1.7.1] StrategySettingsModule:", result.settingsModule);

        StrategyAllocCalcModule allocCalc = new StrategyAllocCalcModule(chainCfg.usdc, address(strat));
        result.allocCalcModule = address(allocCalc);
        console.log("[1.7.2] StrategyAllocCalcModule:", result.allocCalcModule);

        StrategyRebalancePlanModule planMod = new StrategyRebalancePlanModule(
            chainCfg.usdc, address(strat),
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

    /// @notice Poke external TVL + liquidity for all 7 adapters right after bootstrap.
    /// @dev    Without this, cachedExternalTVL defaults to 0 on every adapter, which
    ///         reads as CONFIDENCE_ZERO ("< 100K -- NO ALLOCATION") -- every adapter is
    ///         ineligible for allocation and the first real deposit reverts with
    ///         BootstrapIdleTooHigh() (idle stays ~100% of TVL, nothing can be placed).
    ///
    ///         pokeExternalTVL() wraps each adapter's externalMarketTVL() call in an
    ///         EMPTY try/catch (StrategyParamsModule.sol) -- a reverting adapter is
    ///         silently skipped, so a low-level `.call()` succeeding here proves only
    ///         that the loop ran, not that any cache was actually populated. This
    ///         function therefore asserts the OUTCOME directly: cachedExternalTVLTs
    ///         must be nonzero for every adapter after poking. Because that check runs
    ///         during forge script's SIMULATION, a bad outcome reverts before ANYTHING
    ///         broadcasts -- the grantRole below never reaches the chain, so there is no
    ///         window where a partially-broadcast run (RPC drop, on-chain revert from
    ///         state drift vs. simulation) could leave KEEPER_ROLE stuck on the deployer.
    ///
    ///         Confirmed against a live Arbitrum fork:
    ///         test/strategies/usdc-lending/fork/DeployAndDepositReadiness.fork.t.sol
    ///         Both pokeExternalTVL/pokeLiquidityBatch are KEEPER_ROLE-gated, and the
    ///         deployer EOA does not hold that role by default -- grant it temporarily
    ///         (deployer still has DEFAULT_ADMIN_ROLE pre-seal) and revoke immediately
    ///         after, so the deploy leaves no lasting KEEPER_ROLE grant on the deployer.
    function _phase2_6_pokeAdapterData(DeployConfig memory cfg, DeploymentResult memory result)
        internal
    {
        bytes32 KEEPER_ROLE = keccak256("KEEPER_ROLE");
        bytes32 ADMIN_ROLE = result.strategy.DEFAULT_ADMIN_ROLE();
        if (!result.strategy.hasRole(ADMIN_ROLE, cfg.deployer)) {
            console.log("[2.6] SKIP: deployer has no admin - keeper must pokeExternalTVL/pokeLiquidityBatch manually before first deposit");
            return;
        }

        result.strategy.grantRole(KEEPER_ROLE, cfg.deployer);

        (bool okTvl,) = address(result.strategy).call(abi.encodeWithSignature("pokeExternalTVL()"));
        require(okTvl, "pokeExternalTVL failed");
        (bool okLiq,) = address(result.strategy).call(
            abi.encodeWithSignature("pokeLiquidityBatch(uint256,uint256)", uint256(0), uint256(10))
        );
        require(okLiq, "pokeLiquidityBatch failed");

        address[7] memory adapters = [
            result.aaveAdapter,
            result.morphoAdapter,
            result.cometAdapter,
            result.eulerAdapter,
            result.dolomiteAdapter,
            result.fluidAdapter,
            result.venusAdapter
        ];
        for (uint256 i = 0; i < adapters.length; i++) {
            require(
                result.strategy.cachedExternalTVLTs(adapters[i]) != 0,
                "pokeExternalTVL did not populate cache for an adapter -- deposit would revert (BootstrapIdleTooHigh)"
            );
        }

        result.strategy.revokeRole(KEEPER_ROLE, cfg.deployer);
        console.log("[2.6] External TVL + liquidity poked AND VERIFIED for all adapters (deployer KEEPER_ROLE revoked after)");
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
        vm.serializeAddress(j, "adapterFactory", result.adapterFactory);
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
        // vm.envString accepts "" as valid (unlike envAddress/envBool/envUint,
        // which reject "" and fall through to catch). A .env with a blank-but-
        // present STRATEGY_OUTPUT_JSON= would otherwise set path = "" and
        // vm.writeJson(out, "") reverts ("path not allowed for write").
        try vm.envString("STRATEGY_OUTPUT_JSON") returns (string memory p) {
            if (bytes(p).length > 0) path = p;
        } catch {}
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
