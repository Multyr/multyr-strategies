// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {
    UsdcLendingChainConfig
} from "@multyr-strategies/strategies/usdc-lending/config/UsdcLendingChainConfig.sol";
import {
    UsdcLendingConfigArbitrum
} from "@multyr-strategies/strategies/usdc-lending/config/UsdcLendingConfigArbitrum.sol";

// ── Minimal local ABIs (decoupled from lib/multyr-core version drift) ────────

interface IERC20MetaLike {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function balanceOf(address) external view returns (uint256);
}

interface ICoreLike {
    function asset() external view returns (address);
}

interface IOwnedLike {
    function owner() external view returns (address);
}

/**
 * @title UsdcLendingShadowPreflight
 * @notice Read-only pre-deployment checks for the Shadow (Arbitrum One fork)
 *         environment. Reverts BEFORE any broadcast if a dependency, core
 *         deployment, governance address, predicted CREATE2 slot or config
 *         parameter is missing or inconsistent.
 *
 * @dev    `abstract contract ... is Script` so both DeployUsdcLendingStrategy
 *         and the standalone PreflightUsdcLendingShadow script inherit `_preflight`
 *         with the cheatcode `vm` in scope. No state, no broadcast.
 */
abstract contract UsdcLendingShadowPreflight is Script {
    uint256 internal constant SHADOW_CHAIN_ID = 42161;
    uint256 internal constant EULER_PERMIT2_DUST = 1000; // 0.001 USDC (6dp)
    uint256 internal constant MIN_DEPLOYER_ETH = 0.01 ether;

    /// @notice Environment-specific operator/governance inputs for Shadow.
    ///         Protocol + core addresses are NOT here — they come from
    ///         UsdcLendingConfigArbitrum (Shadow mirrors Arbitrum state).
    struct ShadowGovernance {
        address deployer; // vm.addr(SHADOW_DEPLOYER_PRIVATE_KEY)
        address guardian;
        address governance;
        address keeper;
        address emergency;
    }

    struct PreflightInputs {
        UsdcLendingChainConfig chainCfg;
        // Multyr core (already deployed on the Shadow fork — mainnet addresses)
        address vault;
        address strategyRouter;
        address bufferManager;
        address healthRegistry;
        // Environment
        ShadowGovernance gov;
        uint16 adapterMaxExposureBps;
        string deployEnv; // must be "shadow"
        bool checkPredictedAddresses; // false when the deployer nonce is already advanced
    }

    // ── Entry point ─────────────────────────────────────────────────────────

    function _preflight(PreflightInputs memory p) internal view {
        console.log("== Shadow preflight ==");

        _checkEnvironment(p);
        _checkUsdc(p.chainCfg.usdc);
        _checkProtocolDependencies(p.chainCfg);
        _checkCore(p);
        _checkGovernance(p.gov);
        _checkDeployerResources(p.chainCfg.usdc, p.gov.deployer);
        _checkConfigParams(p);
        if (p.checkPredictedAddresses) {
            _checkPredictedAddresses(p.gov.deployer);
        }

        console.log("== Shadow preflight: ALL CHECKS PASSED ==");
    }

    // ── 1. Environment identity ─────────────────────────────────────────────

    function _checkEnvironment(PreflightInputs memory p) private view {
        require(
            block.chainid == SHADOW_CHAIN_ID,
            "PREFLIGHT: not chain 42161 (Shadow mirrors Arbitrum One)"
        );
        require(
            keccak256(bytes(p.deployEnv)) == keccak256("shadow"),
            "PREFLIGHT: DEPLOY_ENV must be 'shadow' for the Shadow entrypoint"
        );
        console.log("  [ok] chainid 42161 + DEPLOY_ENV=shadow");
    }

    // ── 2. Deposit / accounting asset ───────────────────────────────────────

    function _checkUsdc(address usdc) private view {
        _requireCode(usdc, "USDC");
        require(IERC20MetaLike(usdc).decimals() == 6, "PREFLIGHT: USDC decimals != 6");
        require(
            keccak256(bytes(IERC20MetaLike(usdc).symbol())) == keccak256("USDC"),
            "PREFLIGHT: token at USDC address does not report symbol USDC"
        );
        console.log("  [ok] USDC: code + 6 decimals + symbol");
    }

    // ── 3. External protocol dependencies (all 7 venues + Permit2) ───────────

    function _checkProtocolDependencies(UsdcLendingChainConfig memory c) private view {
        _requireCode(c.aavePool, "Aave v3 Pool");
        _requireCode(c.aaveAUsdc, "Aave aUSDC");
        _requireCode(c.cometUsdcV3, "Compound III Comet USDC");
        _requireCode(c.dolomiteDUsdc, "Dolomite dUSDC");
        _requireCode(c.eulerVault1, "Euler vault 1");
        _requireCode(c.eulerVault2, "Euler vault 2");
        _requireCode(c.eulerVault3, "Euler vault 3");
        _requireCode(c.eulerVault4, "Euler vault 4");
        _requireCode(c.fluidFUsdc, "Fluid fUSDC");
        _requireCode(c.morphoVault1, "Morpho vault 1");
        _requireCode(c.morphoVault2, "Morpho vault 2");
        _requireCode(c.morphoVault4, "Morpho vault 4");
        _requireCode(c.morphoVault6, "Morpho vault 6");
        _requireCode(c.morphoVault8, "Morpho vault 8");
        _requireCode(c.venusVToken, "Venus vToken");
        _requireCode(c.permit2, "Permit2");
        require(
            c.venusBlocksPerYear > 0,
            "PREFLIGHT: venusBlocksPerYear = 0 (Venus adapter would misprice APY)"
        );
        console.log("  [ok] 7 lending venues + Permit2 have code");
    }

    // ── 4. Multyr core system (deployed on the fork) ────────────────────────

    function _checkCore(PreflightInputs memory p) private view {
        _requireCode(p.vault, "CoreVault");
        _requireCode(p.strategyRouter, "StrategyRouter");
        _requireCode(p.bufferManager, "BufferManager");
        _requireCode(p.healthRegistry, "StrategyHealthRegistry");

        address coreAsset = ICoreLike(p.vault).asset();
        require(coreAsset == p.chainCfg.usdc, "PREFLIGHT: CoreVault.asset() != USDC");

        // Informational: whether the Shadow deployer already owns the router.
        // The deploy script's Phase 2.1 self-registers only if it does; otherwise
        // registration must be done through Shadow governance.
        try IOwnedLike(p.strategyRouter).owner() returns (address rOwner) {
            console.log(
                rOwner == p.gov.deployer
                    ? "  [ok] core: code + asset; router owner IS deployer (self-register)"
                    : "  [ok] core: code + asset; router owner is NOT deployer (register via governance)"
            );
        } catch {
            console.log("  [ok] core: code + asset (router.owner() not readable)");
        }
    }

    // ── 5. Governance / operator addresses ─────────────────────────────────

    function _checkGovernance(ShadowGovernance memory g) private view {
        address[5] memory a = [g.deployer, g.guardian, g.governance, g.keeper, g.emergency];
        string[5] memory n = ["deployer", "guardian", "governance", "keeper", "emergency"];
        for (uint256 i = 0; i < 5; ++i) {
            require(
                a[i] != address(0), string.concat("PREFLIGHT: Shadow ", n[i], " address is zero")
            );
            for (uint256 j = i + 1; j < 5; ++j) {
                require(
                    a[i] != a[j],
                    string.concat(
                        "PREFLIGHT: Shadow ", n[i], " and ", n[j], " are the same address"
                    )
                );
            }
        }
        require(
            g.governance.code.length > 0, "PREFLIGHT: Shadow governance must be a Safe contract"
        );
    }

    // ── 6. Deployer resources ─────────────────────────────────────────────

    function _checkDeployerResources(address usdc, address deployer) private view {
        require(
            deployer.balance >= MIN_DEPLOYER_ETH,
            "PREFLIGHT: Shadow deployer has < 0.01 ETH for gas"
        );
        require(
            IERC20MetaLike(usdc).balanceOf(deployer) >= EULER_PERMIT2_DUST,
            "PREFLIGHT: Shadow deployer holds < 0.001 USDC (Euler Permit2 init dust)"
        );
        console.log("  [ok] deployer: >= 0.01 ETH + >= 0.001 USDC");
    }

    // ── 7. Config parameters vs strategy bounds ────────────────────────────

    function _checkConfigParams(PreflightInputs memory p) private pure {
        require(
            p.adapterMaxExposureBps > 0 && p.adapterMaxExposureBps <= 5000,
            "PREFLIGHT: ADAPTER_MAX_EXPOSURE_BPS out of (0, 5000] (StrategySettingsModule.ParamOutOfRange above 5000)"
        );
        require(p.chainCfg.deploySalt != bytes32(0), "PREFLIGHT: chainCfg.deploySalt is zero");
        console.log("  [ok] config params within bounds");
    }

    // ── 8. Predicted deployer-nonce CREATE addresses are unoccupied ─────────

    function _checkPredictedAddresses(address deployer) private view {
        // Mirrors DeployUsdcLendingStrategy._phase1 nonce layout:
        //   N+0 AdapterFactory, N+1..N+4 modules, N+5 UsdcMultiLendingVault.
        uint64 nonce = vm.getNonce(deployer);
        for (uint64 k = 0; k <= 5; ++k) {
            address predicted = vm.computeCreateAddress(deployer, nonce + k);
            require(
                predicted.code.length == 0,
                string.concat(
                    "PREFLIGHT: bytecode already present at predicted CREATE address (nonce offset ",
                    vm.toString(uint256(k)),
                    ") -- prior partial deploy, or wrong deployer nonce. Use a fresh deployment id."
                )
            );
        }
        console.log(
            "  [ok] predicted CREATE slots N..N+5 are empty (no collision / partial deploy)"
        );
    }

    // ── env loading (shared by the deploy script and the standalone) ──────

    /// @notice Build PreflightInputs from the Shadow environment. The Shadow
    ///         entrypoint (deploy-usdc-lending-shadow.sh) is responsible for
    ///         populating SHADOW_* vars; core addresses reuse the canonical
    ///         VAULT/ROUTER/BUFFER/HEALTH names (forked-in mainnet core).
    function _loadShadowInputs(bool checkPredictedAddresses)
        internal
        view
        returns (PreflightInputs memory p)
    {
        p.chainCfg = UsdcLendingConfigArbitrum.get();

        p.vault = vm.envAddress("VAULT_ADDRESS");
        p.strategyRouter = vm.envAddress("STRATEGY_ROUTER_ADDRESS");
        p.bufferManager = vm.envAddress("BUFFER_MANAGER_ADDRESS");
        p.healthRegistry = vm.envAddress("HEALTH_REGISTRY_ADDRESS");

        p.gov = ShadowGovernance({
            deployer: vm.addr(vm.envUint("SHADOW_DEPLOYER_PRIVATE_KEY")),
            guardian: vm.envAddress("SHADOW_GUARDIAN_ADDRESS"),
            governance: vm.envAddress("SHADOW_GOVERNANCE_ADDRESS"),
            keeper: vm.envAddress("SHADOW_KEEPER_ADDRESS"),
            emergency: vm.envAddress("SHADOW_EMERGENCY_ADDRESS")
        });

        p.adapterMaxExposureBps = 5000;
        try vm.envUint("ADAPTER_MAX_EXPOSURE_BPS") returns (uint256 v) {
            if (v > 0 && v <= type(uint16).max) p.adapterMaxExposureBps = uint16(v);
        } catch {}

        p.deployEnv = vm.envOr("DEPLOY_ENV", string(""));
        p.checkPredictedAddresses = checkPredictedAddresses;
    }

    // ── helpers ───────────────────────────────────────────────────────────

    function _requireCode(address a, string memory label) private view {
        require(a != address(0), string.concat("PREFLIGHT: ", label, " address is zero"));
        require(
            a.code.length > 0,
            string.concat("PREFLIGHT: no bytecode at ", label, " (", vm.toString(a), ")")
        );
    }
}
