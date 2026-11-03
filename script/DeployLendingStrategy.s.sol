// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployUsdcLendingStrategy} from "./DeployUsdcLendingStrategy.s.sol";
import {GasEstimatorPreflight} from "./GasEstimatorPreflight.sol";
import {UsdcLendingChainConfig} from "../src/strategies/usdc-lending/config/UsdcLendingChainConfig.sol";
import {UsdcMultiLendingVault} from "../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
import {StrategySettingsModule} from "../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {StrategyParamsModule} from "../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import {StrategyBootstrapper} from "../src/strategies/usdc-lending/StrategyBootstrapper.sol";
import {AdapterFactory} from "../src/strategies/usdc-lending/factory/AdapterFactory.sol";
import {RewardSwapHelper} from "../src/strategies/usdc-lending/swap/RewardSwapHelper.sol";
import {ILendingAdapter, IStrategyAssetValuation} from "../src/strategies/usdc-lending/interfaces/ILendingAdapter.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MorphoVaultV2LiquidityView} from "../src/strategies/usdc-lending/adapters/lending/MorphoVaultV2LiquidityView.sol";

interface ILendingAdapterVault { function vault() external view returns (address); }
interface ILendingCoreAsset { function asset() external view returns (address); }
interface ILendingModuleIdentity {
    function ASSET() external view returns (address);
    function core() external view returns (address);
}

/// @notice Typed, chain/asset-independent candidate deployment. Core activation is a
///         separate governance operation. A reviewed manifest must pin every bytecode hash.
contract DeployLendingStrategy is DeployUsdcLendingStrategy {
    struct AdapterSpec {
        bytes creationCode;
        bytes32 creationHash;
        bytes32 runtimeHash;
        bytes32 salt;
        bytes initializer;
        bytes[] configuration;
        bool usesRewardHelper;
    }
    struct RewardSpec {
        address token;
        address usdFeed;
        uint32 maxAge;
        bytes uniPath;
        bytes camelotPath;
        uint16 slippageBps;
    }
    struct Manifest {
        bytes32 morphoLiquidityViewRuntimeHash;
        uint256 chainId;
        address asset;
        address coreVault;
        address router;
        address governance;
        address guardian;
        address keeper;
        bytes32 salt;
        address estimator;
        address ethUsdFeed;
        address usdQuoteFeed; // Optional legacy estimator binding; zero is supported.
        address feeSource;
        bytes arbitrumFeeSnapshot;
        address assetUsdFeed;
        address sequencerFeed;
        bytes32 estimatorConfigHash;
        uint16 targetIdleBps;
        UsdcMultiLendingVault.StrategyInitParams parameters;
        AdapterSpec[] adapters;
        address uniRouter;
        address camelotRouter;
        uint32 assetFeedMaxAge;
        RewardSpec[] rewards;
    }

    UsdcMultiLendingVault.StrategyInitParams private reviewedParameters;
    event CandidateManifest(bytes32 indexed manifestHash, uint256 indexed chainId, address indexed asset,
        address strategy, address rewardHelper);
    event CandidateAdapter(address indexed strategy, address indexed adapter, bytes32 runtimeHash);
    event CandidateLiquidityView(address indexed adapter, address indexed helper, bytes32 runtimeHash);

    function run() external pure override returns (DeploymentResult memory) {
        revert("TYPED_MANIFEST_REQUIRED");
    }

    function run(Manifest calldata m) external returns (DeploymentResult memory result) {
        // Forge cannot execute ArbOS's native fee precompile. The reviewed public
        // RPC snapshot affects local simulation only and is included in the manifest hash.
        if (block.chainid == 42161 && m.feeSource == address(0x6c)) {
            require(m.arbitrumFeeSnapshot.length == 192, "ARBITRUM_FEE_SNAPSHOT_REQUIRED");
            vm.mockCall(address(0x6c), abi.encodeWithSignature("getPricesInWei()"), m.arbitrumFeeSnapshot);
        }
        _preflight(m);
        DeployConfig memory cfg;
        cfg.deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        cfg.deployer = vm.addr(cfg.deployerPk);
        cfg.vault = m.coreVault;
        cfg.strategyRouter = m.router;
        cfg.governance = m.governance;
        cfg.guardian = m.guardian;
        reviewedParameters = m.parameters;
        UsdcLendingChainConfig memory chainCfg;
        // Legacy struct field name only; the value is the manifest's actual asset.
        chainCfg.usdc = m.asset;
        chainCfg.deploySalt = keccak256(abi.encode(m.chainId, m.asset, m.salt));

        vm.startBroadcast(cfg.deployerPk);
        result = _phase1_deployModulesAndStrategy(cfg, chainCfg);
        result = _phase1_7_deployOptionalModules(cfg, result, chainCfg);
        _verifyModules(result, m.asset, m.coreVault);
        StrategySettingsModule settings = StrategySettingsModule(address(result.strategy));
        _validateInitialSettings(settings, m.parameters);
        settings.setRebalanceGasEstimator(m.estimator);
        settings.setTargetIdleBufferBps(m.targetIdleBps);
        // Prove the fresh core valuation works through the real fallback/delegatecall path.
        IStrategyAssetValuation(address(result.strategy)).assetUnitsToUsd6(10 ** IERC20Metadata(m.asset).decimals());

        address helper = _deployRewardHelper(m, result);
        address[] memory adapters = new address[](m.adapters.length);
        AdapterFactory factory = AdapterFactory(result.adapterFactory);
        for (uint256 i; i < m.adapters.length; ++i) {
            AdapterSpec calldata spec = m.adapters[i];
            address adapter = factory.deployAndInit(spec.creationCode, spec.salt, spec.initializer);
            require(adapter.code.length <= 23552, "ADAPTER_SIZE_BUFFER");
            require(adapter.codehash == spec.runtimeHash, "ADAPTER_RUNTIME_HASH");
            require(ILendingAdapter(adapter).underlying() == m.asset, "ADAPTER_ASSET");
            require(ILendingAdapterVault(adapter).vault() == address(result.strategy), "ADAPTER_VAULT");
            for (uint256 j; j < spec.configuration.length; ++j) {
                (bool ok, bytes memory reason) = adapter.call(spec.configuration[j]);
                if (!ok) { assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) } }
            }
            _configureMorphoV2LiquidityView(adapter, m.morphoLiquidityViewRuntimeHash);
            if (spec.usesRewardHelper) {
                require(helper != address(0), "REWARD_HELPER_REQUIRED");
                (bool ok,) = adapter.call(abi.encodeWithSignature("setSwapHelper(address)", helper));
                require(ok, "REWARD_HELPER_WIRING");
                RewardSwapHelper(payable(helper)).grantRole(keccak256("KEEPER_ROLE"), adapter);
            }
            require(ILendingAdapter(adapter).underlying() == m.asset, "CONFIGURED_ADAPTER_ASSET");
            require(ILendingAdapterVault(adapter).vault() == address(result.strategy), "CONFIGURED_ADAPTER_VAULT");
            adapters[i] = adapter;
            emit CandidateAdapter(address(result.strategy), adapter, spec.runtimeHash);
        }
        StrategyBootstrapper(payable(result.bootstrapper)).bootstrap(adapters);
        bytes32 keeperRole = keccak256("KEEPER_ROLE");
        result.strategy.grantRole(keeperRole, cfg.deployer);
        StrategyParamsModule(address(result.strategy)).pokeExternalTVL();
        StrategyParamsModule(address(result.strategy)).pokeLiquidityBatch(0, adapters.length);
        result.strategy.grantRole(keeperRole, m.keeper);
        if (cfg.deployer != m.keeper && cfg.deployer != m.guardian) {
            result.strategy.renounceRole(keeperRole, cfg.deployer);
        }
        for (uint256 i; i < adapters.length; ++i) _handoff(adapters[i], cfg);
        if (helper != address(0)) _handoff(helper, cfg);
        _phase3_6_handoffGovernance(cfg, result);
        vm.stopBroadcast();
        emit CandidateManifest(keccak256(abi.encode(m)), m.chainId, m.asset, address(result.strategy), helper);
    }

    function _preflight(Manifest calldata m) internal view {
        require(m.chainId == block.chainid, "MANIFEST_CHAIN");
        require(m.asset.code.length > 0 && m.coreVault.code.length > 0 && m.router.code.length > 0, "MISSING_CODE");
        require(ILendingCoreAsset(m.coreVault).asset() == m.asset, "CORE_ASSET");
        require(m.governance != address(0) && m.keeper != address(0), "MISSING_AUTHORITY");
        uint8 decimals = IERC20Metadata(m.asset).decimals();
        require(decimals > 0 && decimals <= 18, "UNSUPPORTED_DECIMALS");
        require(m.targetIdleBps <= 10000 && m.adapters.length > 0 && m.adapters.length <= 7, "INVALID_POLICY");
        GasEstimatorPreflight.validateForSource(m.estimator, m.governance, m.ethUsdFeed, m.usdQuoteFeed,
            m.sequencerFeed, m.estimatorConfigHash, m.feeSource);
        for (uint256 i; i < m.adapters.length; ++i) {
            AdapterSpec calldata spec = m.adapters[i];
            require(spec.creationCode.length > 0 && keccak256(spec.creationCode) == spec.creationHash, "ADAPTER_CREATION_HASH");
            require(spec.runtimeHash != bytes32(0) && spec.initializer.length >= 4, "ADAPTER_MANIFEST");
            for (uint256 j; j < i; ++j) require(spec.salt != m.adapters[j].salt, "DUPLICATE_ADAPTER_SALT");
        }
        if (m.rewards.length > 0) {
            require(m.uniRouter.code.length > 0 && m.assetUsdFeed.code.length > 0, "REWARD_INFRASTRUCTURE");
            require(m.camelotRouter == address(0) || m.camelotRouter.code.length > 0, "CAMELOT_CODE");
        }
    }

    function _verifyModules(DeploymentResult memory r, address asset, address coreVault) internal view {
        address[9] memory modules = [address(r.strategy), r.paramsModule, r.scoringModule,
            r.adapterOpsModule, r.rebalanceGateModule, r.settingsModule, r.allocCalcModule,
            r.rebalancePlanModule, r.safetyOverflowModule];
        for (uint256 i; i < modules.length; ++i) {
            require(modules[i].code.length > 0 && modules[i].code.length <= 23552, "MODULE_SIZE_BUFFER");
            require(ILendingModuleIdentity(modules[i]).ASSET() == asset, "MODULE_ASSET");
            require(ILendingModuleIdentity(modules[i]).core() == coreVault, "MODULE_CORE");
        }
    }

    /// @dev Morpho's configured view is part of deployment readiness, not a
    /// manual post-activation task. Other adapter families have no such getter.
    function _configureMorphoV2LiquidityView(address adapter, bytes32 reviewedRuntimeHash) internal {
        (bool supported, bytes memory raw) = adapter.staticcall(abi.encodeWithSignature("vaultV2LiquidityView()"));
        if (!supported || raw.length < 32) return;
        require(reviewedRuntimeHash == keccak256(type(MorphoVaultV2LiquidityView).runtimeCode), "V2_VIEW_MANIFEST_HASH");
        address viewContract = abi.decode(raw, (address));
        if (viewContract == address(0)) {
            viewContract = address(new MorphoVaultV2LiquidityView());
            (bool ok, bytes memory reason) = adapter.call(abi.encodeWithSignature("setVaultV2LiquidityView(address)", viewContract));
            if (!ok) { assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) } }
        }
        require(viewContract.codehash == reviewedRuntimeHash, "V2_VIEW_RUNTIME_HASH");
        emit CandidateLiquidityView(adapter, viewContract, viewContract.codehash);
    }

    /// @dev Reapply the constructor inputs through the canonical guarded setters.
    ///      This rejects malformed monetary/BPS configurations instead of trusting a manifest label.
    function _validateInitialSettings(StrategySettingsModule settings,
        UsdcMultiLendingVault.StrategyInitParams calldata p) internal
    {
        settings.setRiskWeights(p.wAPY, p.wLiq, p.wRisk, p.wStability, p.wIncentive);
        settings.setRebalanceParams(p.maxAdaptersPerAllocation, p.minAdaptersActive,
            p.rebalanceMinMoveBps, p.minSecondsBetweenRebalances, p.driftToleranceBps,
            p.adapterMaxExposureBps, p.newAdapterRampBps);
        settings.setGateParams(p.gateHorizonDays, p.gateMinNetBenefitBps,
            p.slippageBpsEstimate, p.withdrawalSpreadBpsEstimate, p.gasCostUSDC);
        settings.setHarvestParams(p.harvestThresholdBps, p.minSecondsBetweenHarvests);
        settings.setDustTolerance(p.dustTolerance);
    }

    function _deployRewardHelper(Manifest calldata m, DeploymentResult memory result) internal returns (address helper) {
        if (m.rewards.length == 0) return address(0);
        helper = AdapterFactory(result.adapterFactory).deployAndInit(type(RewardSwapHelper).creationCode,
            keccak256(abi.encode(m.chainId, m.asset, m.salt, "rewards")),
            abi.encodeCall(RewardSwapHelper.initializeAsset, (m.asset, vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY")), m.uniRouter, m.camelotRouter)));
        RewardSwapHelper h = RewardSwapHelper(payable(helper));
        h.setOutputAssetOracle(m.assetUsdFeed, m.assetFeedMaxAge);
        if (m.sequencerFeed != address(0)) h.setSequencerUptimeFeed(m.sequencerFeed);
        for (uint256 i; i < m.rewards.length; ++i) {
            RewardSpec calldata r = m.rewards[i];
            (bool ok, bytes memory data) = r.usdFeed.staticcall(abi.encodeWithSignature("decimals()"));
            require(ok && data.length == 32, "REWARD_FEED");
            h.setRewardConfig(r.token, r.usdFeed, abi.decode(data, (uint8)), IERC20Metadata(r.token).decimals(),
                r.maxAge, r.uniPath, r.camelotPath, r.slippageBps);
            require(h.canSwap(r.token), "REWARD_ORACLE_NOT_READY");
        }
    }

    function _handoff(address target, DeployConfig memory cfg) internal {
        IAccessControl controlled = IAccessControl(target);
        bytes32 param = keccak256("PARAM_ROLE");
        controlled.grantRole(bytes32(0), cfg.governance);
        bool hasParam = controlled.hasRole(param, cfg.deployer);
        if (hasParam) controlled.grantRole(param, cfg.governance);
        if (cfg.deployer != cfg.governance) {
            if (hasParam) controlled.renounceRole(param, cfg.deployer);
            controlled.renounceRole(bytes32(0), cfg.deployer);
        }
        require(controlled.hasRole(bytes32(0), cfg.governance), "GOVERNANCE_ADMIN");
        require(cfg.deployer == cfg.governance || !controlled.hasRole(bytes32(0), cfg.deployer), "DEPLOYER_ADMIN_REMAINS");
    }

    function _defaultParams() internal view override returns (UsdcMultiLendingVault.StrategyInitParams memory) {
        return reviewedParameters;
    }
}
