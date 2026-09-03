// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {
    UsdcLendingChainConfig
} from "@multyr-strategies/strategies/usdc-lending/config/UsdcLendingChainConfig.sol";
import {
    UsdcLendingConfigArbitrum
} from "@multyr-strategies/strategies/usdc-lending/config/UsdcLendingConfigArbitrum.sol";

// ── Minimal local ABIs ─────────────────────────────────────────────────────

interface IStrategyView {
    function asset() external view returns (address);
    function adapterCount() external view returns (uint256);
    function paused() external view returns (bool);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function BOOTSTRAP_ROLE() external view returns (bytes32);
}

interface IRouterView {
    function strategyAllowlist(address) external view returns (bool);
}

interface IAccessControlView {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IRegistryView {
    function owner() external view returns (address);
}

interface IRegistryBoundAdapterView {
    function registry() external view returns (address);
}

interface IAdapterFactoryView is IAccessControlView {
    function DEPLOYER_ROLE() external view returns (bytes32);
}

interface IOwnableView {
    function owner() external view returns (address);
}

interface IUpkeepView is IOwnableView {
    function aavePool() external view returns (address);
    function aaveRateProvider() external view returns (address);
    function usdc() external view returns (address);
    function pokeInterval() external view returns (uint64);
    function getPokeTargets() external view returns (address[] memory);
    function isPokeTarget(address target) external view returns (bool);
}

/**
 * @title PostflightUsdcLendingShadow
 * @notice Read-only post-deployment verification for a Shadow deploy. Reads the
 *         address book DeployUsdcLendingStrategy wrote, checks the deployed
 *         strategy is wired and de-privileged correctly, and writes the
 *         reproducibility manifest to deployments/shadow/<id>/manifest.json.
 *
 * @dev    Never broadcasts. Reverts on any wiring/role failure. Run by
 *         script/deploy-usdc-lending-shadow.sh as step 3, or standalone:
 *
 *   DEPLOY_ENV=shadow SHADOW_DEPLOYMENT_ID=<id> \
 *   STRATEGY_OUTPUT_JSON=deployments/shadow/<id>/addresses.json \
 *     forge script script/PostflightUsdcLendingShadow.s.sol --rpc-url "$SHADOW_RPC_URL" -vvv
 */
contract PostflightUsdcLendingShadow is Script {
    using stdJson for string;

    bytes32 constant CORE_ROLE = keccak256("CORE_ROLE");
    bytes32 constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 constant PARAM_ROLE = keccak256("PARAM_ROLE");
    bytes32 constant DEFAULT_ADMIN_ROLE = bytes32(0);

    struct Addrs {
        address strategy;
        address adapterFactory;
        address bootstrapper;
        address strategyUpkeep;
        address protocolRegistry;
        address aaveAdapter;
        address morphoAdapter;
        address cometAdapter;
        address eulerAdapter;
        address dolomiteAdapter;
        address fluidAdapter;
        address venusAdapter;
        address aaveRateProvider;
        address dolomiteRateProvider;
    }

    function run() external {
        require(block.chainid == 42161, "POSTFLIGHT: not chain 42161");
        require(
            keccak256(bytes(vm.envOr("DEPLOY_ENV", string("")))) == keccak256("shadow"),
            "POSTFLIGHT: DEPLOY_ENV must be 'shadow'"
        );

        string memory id = vm.envOr("SHADOW_DEPLOYMENT_ID", string("unversioned"));
        string memory dir = string.concat("deployments/shadow/", id);

        string memory bookPath =
            vm.envOr("STRATEGY_OUTPUT_JSON", string.concat(dir, "/addresses.json"));
        Addrs memory a = _readAddressBook(bookPath);

        UsdcLendingChainConfig memory cc = UsdcLendingConfigArbitrum.get();
        address usdc = cc.usdc;
        address vault = vm.envAddress("VAULT_ADDRESS");
        address router = vm.envAddress("STRATEGY_ROUTER_ADDRESS");
        address governance = vm.envAddress("SHADOW_GOVERNANCE_ADDRESS");
        (address deployer,) = _deployer();

        console.log("== Shadow postflight ==");
        console.log("  strategy:", a.strategy);

        IStrategyView s = IStrategyView(a.strategy);

        // ── wiring ──────────────────────────────────────────────────────
        require(a.strategy.code.length > 0, "POSTFLIGHT: strategy has no code");
        require(s.asset() == usdc, "POSTFLIGHT: strategy.asset() != USDC");
        require(s.adapterCount() == 7, "POSTFLIGHT: adapterCount != 7");
        require(!s.paused(), "POSTFLIGHT: strategy is paused");
        require(s.hasRole(CORE_ROLE, vault), "POSTFLIGHT: CoreVault missing CORE_ROLE");
        require(s.hasRole(CORE_ROLE, router), "POSTFLIGHT: StrategyRouter missing CORE_ROLE");
        console.log("  [ok] code + asset + 7 adapters + not paused + CORE_ROLE x2");

        // ── complete governance handoff ─────────────────────────────────
        require(
            !s.hasRole(s.BOOTSTRAP_ROLE(), a.bootstrapper),
            "POSTFLIGHT: BOOTSTRAP_ROLE not renounced"
        );
        require(
            !s.hasRole(KEEPER_ROLE, deployer),
            "POSTFLIGHT: deployer still holds KEEPER_ROLE (Phase 2.6 cleanup failed)"
        );
        require(
            a.strategyUpkeep == address(0) || s.hasRole(KEEPER_ROLE, a.strategyUpkeep),
            "POSTFLIGHT: StrategyUpkeep missing KEEPER_ROLE"
        );
        require(
            s.hasRole(DEFAULT_ADMIN_ROLE, governance),
            "POSTFLIGHT: governance missing strategy admin"
        );
        require(s.hasRole(PARAM_ROLE, governance), "POSTFLIGHT: governance missing strategy param");
        require(
            !s.hasRole(DEFAULT_ADMIN_ROLE, deployer), "POSTFLIGHT: deployer retains strategy admin"
        );
        require(!s.hasRole(PARAM_ROLE, deployer), "POSTFLIGHT: deployer retains strategy param");

        IAdapterFactoryView factory = IAdapterFactoryView(a.adapterFactory);
        bytes32 factoryDeployerRole = factory.DEPLOYER_ROLE();
        require(
            factory.hasRole(DEFAULT_ADMIN_ROLE, governance),
            "POSTFLIGHT: governance missing factory admin"
        );
        require(
            factory.hasRole(factoryDeployerRole, governance),
            "POSTFLIGHT: governance missing factory deployer"
        );
        require(
            !factory.hasRole(DEFAULT_ADMIN_ROLE, deployer),
            "POSTFLIGHT: deployer retains factory admin"
        );
        require(
            !factory.hasRole(factoryDeployerRole, deployer),
            "POSTFLIGHT: deployer retains factory deployer"
        );

        require(
            IRegistryView(a.protocolRegistry).owner() == governance,
            "POSTFLIGHT: registry not Safe-owned"
        );
        require(
            IOwnableView(a.dolomiteRateProvider).owner() == governance,
            "POSTFLIGHT: Dolomite rate provider not Safe-owned"
        );
        if (a.strategyUpkeep != address(0)) {
            _checkUpkeep(a, cc, governance);
        }
        _checkAdapterRolesAndRegistry(a, governance, deployer);
        console.log("  [ok] all strategy-side ownership and roles handed to governance");

        // ── informational ──────────────────────────────────────────────
        bool sealed_ = vm.envOr("DO_SEAL", false);
        bool registered;
        try IRouterView(router).strategyAllowlist(a.strategy) returns (bool ok) {
            registered = ok;
        } catch {}

        console.log(
            registered
                ? "  [info] strategy allowlisted in router"
                : "  [info] strategy NOT yet allowlisted/registered in router (do via governance)"
        );

        // ── manifest ───────────────────────────────────────────────────
        _writeManifest(dir, id, a, vault, router, cc, registered, sealed_, deployer, governance);

        console.log("== Shadow postflight: PASSED ==");
    }

    // ── helpers ────────────────────────────────────────────────────────

    function _deployer() internal view returns (address addr, uint256 pk) {
        pk = vm.envUint("SHADOW_DEPLOYER_PRIVATE_KEY");
        addr = vm.addr(pk);
    }

    function _readAddressBook(string memory path) internal view returns (Addrs memory a) {
        // DeployUsdcLendingStrategy._writeAddressBook always serialises every key
        // (address(0) when a component is skipped), so no per-key fallback is
        // needed — and `try this.<fn>` would trip forge's address(this) guard.
        string memory j = vm.readFile(path);
        a.strategy = j.readAddress(".strategy");
        a.adapterFactory = j.readAddress(".adapterFactory");
        a.bootstrapper = j.readAddress(".bootstrapper");
        a.strategyUpkeep = j.readAddress(".strategyUpkeep");
        a.protocolRegistry = j.readAddress(".protocolRegistry");
        a.aaveAdapter = j.readAddress(".aaveAdapter");
        a.morphoAdapter = j.readAddress(".morphoAdapter");
        a.cometAdapter = j.readAddress(".cometAdapter");
        a.eulerAdapter = j.readAddress(".eulerAdapter");
        a.dolomiteAdapter = j.readAddress(".dolomiteAdapter");
        a.fluidAdapter = j.readAddress(".fluidAdapter");
        a.venusAdapter = j.readAddress(".venusAdapter");
        a.aaveRateProvider = j.readAddress(".aaveRateProvider");
        a.dolomiteRateProvider = j.readAddress(".dolomiteRateProvider");
        require(a.strategy != address(0), "POSTFLIGHT: address book has no strategy");
    }

    function _checkUpkeep(Addrs memory a, UsdcLendingChainConfig memory cc, address governance)
        private
        view
    {
        IUpkeepView upkeep = IUpkeepView(a.strategyUpkeep);
        require(upkeep.owner() == governance, "POSTFLIGHT: upkeep not Safe-owned");
        require(upkeep.aavePool() == cc.aavePool, "POSTFLIGHT: upkeep Aave pool mismatch");
        require(
            upkeep.aaveRateProvider() == a.aaveRateProvider,
            "POSTFLIGHT: upkeep Aave rate provider mismatch"
        );
        require(upkeep.usdc() == cc.usdc, "POSTFLIGHT: upkeep USDC mismatch");
        require(upkeep.pokeInterval() == 1 days, "POSTFLIGHT: upkeep poke interval != 1 day");
        require(upkeep.getPokeTargets().length == 3, "POSTFLIGHT: upkeep poke target count != 3");
        require(upkeep.isPokeTarget(a.morphoAdapter), "POSTFLIGHT: Morpho not a poke target");
        require(upkeep.isPokeTarget(a.dolomiteAdapter), "POSTFLIGHT: Dolomite not a poke target");
        require(upkeep.isPokeTarget(a.fluidAdapter), "POSTFLIGHT: Fluid not a poke target");
    }

    function _checkAdapterRolesAndRegistry(Addrs memory a, address governance, address deployer)
        private
        view
    {
        address[8] memory controlled = [
            a.aaveAdapter,
            a.morphoAdapter,
            a.cometAdapter,
            a.eulerAdapter,
            a.dolomiteAdapter,
            a.fluidAdapter,
            a.venusAdapter,
            a.aaveRateProvider
        ];
        for (uint256 i = 0; i < controlled.length; ++i) {
            IAccessControlView target = IAccessControlView(controlled[i]);
            require(
                target.hasRole(DEFAULT_ADMIN_ROLE, governance),
                "POSTFLIGHT: governance missing component admin"
            );
            require(
                !target.hasRole(DEFAULT_ADMIN_ROLE, deployer),
                "POSTFLIGHT: deployer retains component admin"
            );
            // Aave adapter uses DEFAULT_ADMIN_ROLE for setters and has no PARAM_ROLE.
            if (i != 0) {
                require(
                    target.hasRole(PARAM_ROLE, governance),
                    "POSTFLIGHT: governance missing component param"
                );
                require(
                    !target.hasRole(PARAM_ROLE, deployer),
                    "POSTFLIGHT: deployer retains component param"
                );
            }
        }

        address[4] memory registryBound =
            [a.morphoAdapter, a.cometAdapter, a.eulerAdapter, a.dolomiteAdapter];
        for (uint256 i = 0; i < registryBound.length; ++i) {
            require(
                IRegistryBoundAdapterView(registryBound[i]).registry() == a.protocolRegistry,
                "POSTFLIGHT: adapter bound to wrong registry"
            );
        }
    }

    function _writeManifest(
        string memory dir,
        string memory id,
        Addrs memory a,
        address vault,
        address router,
        UsdcLendingChainConfig memory cc,
        bool registered,
        bool sealed_,
        address deployer,
        address governance
    ) internal {
        vm.createDir(dir, true);
        string memory m = "m";

        vm.serializeString(m, "deployEnv", "shadow");
        vm.serializeString(m, "gitCommit", vm.envOr("DEPLOY_GIT_COMMIT", string("unknown")));
        vm.serializeString(m, "deploymentId", id);
        vm.serializeUint(m, "chainId", block.chainid);
        vm.serializeUint(m, "sourceBlock", block.number);
        vm.serializeUint(m, "timestamp", block.timestamp);
        vm.serializeAddress(m, "deployer", deployer);

        string memory g = "g";
        vm.serializeAddress(g, "guardian", vm.envOr("SHADOW_GUARDIAN_ADDRESS", address(0)));
        vm.serializeAddress(g, "governanceSafe", governance);
        vm.serializeAddress(g, "keeper", vm.envOr("SHADOW_KEEPER_ADDRESS", address(0)));
        string memory gov =
            vm.serializeAddress(g, "emergency", vm.envOr("SHADOW_EMERGENCY_ADDRESS", address(0)));
        vm.serializeString(m, "governance", gov);

        string memory c = "c";
        vm.serializeAddress(c, "strategy", a.strategy);
        vm.serializeBytes32(c, "strategyCodehash", a.strategy.codehash);
        vm.serializeAddress(c, "adapterFactory", a.adapterFactory);
        vm.serializeAddress(c, "bootstrapper", a.bootstrapper);
        vm.serializeAddress(c, "strategyUpkeep", a.strategyUpkeep);
        vm.serializeAddress(c, "protocolRegistry", a.protocolRegistry);
        vm.serializeAddress(c, "aaveAdapter", a.aaveAdapter);
        vm.serializeAddress(c, "morphoAdapter", a.morphoAdapter);
        vm.serializeAddress(c, "cometAdapter", a.cometAdapter);
        vm.serializeAddress(c, "eulerAdapter", a.eulerAdapter);
        vm.serializeAddress(c, "dolomiteAdapter", a.dolomiteAdapter);
        vm.serializeAddress(c, "fluidAdapter", a.fluidAdapter);
        vm.serializeAddress(c, "venusAdapter", a.venusAdapter);
        vm.serializeAddress(c, "aaveRateProvider", a.aaveRateProvider);
        string memory contracts =
            vm.serializeAddress(c, "dolomiteRateProvider", a.dolomiteRateProvider);
        vm.serializeString(m, "contracts", contracts);

        string memory core = "core";
        vm.serializeAddress(core, "vault", vault);
        vm.serializeAddress(core, "strategyRouter", router);
        vm.serializeAddress(core, "bufferManager", vm.envAddress("BUFFER_MANAGER_ADDRESS"));
        string memory coreOut =
            vm.serializeAddress(core, "healthRegistry", vm.envAddress("HEALTH_REGISTRY_ADDRESS"));
        vm.serializeString(m, "core", coreOut);

        string memory r = "r";
        vm.serializeBool(r, "deployerHasStrategyAdmin", false); // asserted above
        vm.serializeBool(r, "governanceHasStrategyAdmin", true); // asserted above
        vm.serializeBool(r, "deployerHasKeeper", false); // asserted above
        vm.serializeBool(r, "upkeepHasKeeper", a.strategyUpkeep != address(0));
        vm.serializeBool(r, "bootstrapRoleRenounced", true); // asserted above
        vm.serializeBool(r, "registeredInRouter", registered);
        string memory roles = vm.serializeBool(r, "sealed", sealed_);
        vm.serializeString(m, "roles", roles);

        string memory cp = "cp";
        vm.serializeBytes32(cp, "deploySalt", cc.deploySalt);
        vm.serializeUint(cp, "venusBlocksPerYear", cc.venusBlocksPerYear);
        string memory cfgOut =
            vm.serializeUint(cp, "adapterCount", IStrategyView(a.strategy).adapterCount());
        string memory finalJson = vm.serializeString(m, "config", cfgOut);

        string memory path = string.concat(dir, "/manifest.json");
        vm.writeJson(finalJson, path);
        console.log("  manifest:", path);
    }
}
