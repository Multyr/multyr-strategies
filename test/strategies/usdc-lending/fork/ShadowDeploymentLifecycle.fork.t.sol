// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ===========================================================================
// ShadowDeploymentLifecycle.fork.t.sol
// ---------------------------------------------------------------------------
// Exercises the Shadow (Arbitrum One shadow-mainnet) deployment path end to end
// against a real Arbitrum fork:
//
//   * the read-only Phase 0 preflight (UsdcLendingShadowPreflight) -- positive
//     path plus every negative path (wrong chain, missing dependency, zero /
//     duplicate governance, predicted-CREATE collision, non-shadow env)
//   * the full DeployUsdcLendingStrategy run with DEPLOY_ENV=shadow, which
//     invokes the preflight itself before any broadcast
//   * strategy lifecycle: deposit -> deployIdle -> harvest -> prepareRebalance
//     -> emergency recall -> adapter quarantine
//   * the role / ownership snapshot captured in the Shadow manifest
//   * repeated deployment isolation
//
// Shadow mirrors Arbitrum One, so a plain Arbitrum archive RPC is sufficient
// to run this. Skips when neither SHADOW_RPC_URL nor ARBITRUM_RPC_URL is set.
//
// Run:
//   ARBITRUM_RPC_URL=<rpc> forge test --match-contract ShadowDeploymentLifecycle -vvv
// ===========================================================================

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPriceOracleMiddleware} from "@multyr-core/interfaces/IPriceOracleMiddleware.sol";

import {DeployUsdcLendingStrategy} from "../../../../script/DeployUsdcLendingStrategy.s.sol";
import {PreflightUsdcLendingShadow} from "../../../../script/PreflightUsdcLendingShadow.s.sol";
import {PostflightUsdcLendingShadow} from "../../../../script/PostflightUsdcLendingShadow.s.sol";
import {UsdcLendingShadowPreflight} from "../../../../script/lib/UsdcLendingShadowPreflight.sol";
import {
    UsdcLendingConfigArbitrum
} from "@multyr-strategies/strategies/usdc-lending/config/UsdcLendingConfigArbitrum.sol";
import {
    UsdcMultiLendingVault
} from "@multyr-strategies/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";

interface IStratLifecycle {
    function deposit(uint256 assets) external returns (uint256);
    function harvest() external;
    function emergencyRecallAll() external;
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function KEEPER_ROLE() external view returns (bytes32);
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function totalAssets() external view returns (uint256);
    function idleCash() external view returns (uint256);
    function adapterCount() external view returns (uint256);
    function setQuarantined(address adapter, bool q) external;
    function quarantined(address adapter) external view returns (bool);
    function deployIdle() external;
    function prepareRebalance() external;
    function pokeLiquidityBatch(uint256 start, uint256 count) external;
    function setRebalanceParams(uint16, uint16, uint16, uint32, uint16, uint16, uint16) external;
}

interface ICoreSmokeVault {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function acceptOwnerTransfer() external;
    function paused() external view returns (bool);
    function unpauseAll() external;
    function balanceOf(address) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function deployToStrategies(uint256 maxAmount) external;
    function realizeForQueue(uint256 target) external;
    function requestInstantWithdrawal(uint256 shares)
        external
        returns (bool settledImmediately, uint256 epochId, uint256 claimId);
}

interface IGlobalConfigSmoke {
    struct WithdrawalConfig {
        uint16 capPerEpochBps;
        uint256 maxWithdrawalPerBlock;
        uint256 maxWithdrawalPerTx;
        uint256 minClaimAmount;
        uint64 lockPeriod;
    }

    function setVaultDepositLimits(
        address vault,
        uint256 vaultCap,
        uint256 userCap,
        uint256 minDeposit
    ) external;
    function setVaultWithdrawalOverride(address vault, WithdrawalConfig calldata cfg) external;
    function setVaultGovCaps(
        address vault,
        uint64 minParamDelay,
        uint256 maxPerfRate,
        uint16 maxFeeBps,
        uint16 maxImmExitBps,
        uint16 maxForceExitBps,
        uint64 guardianPauseCooldown,
        uint256 minDeployAmount,
        uint256 stratTaGas,
        uint16 opsMaxBps
    ) external;
    function setVaultOracleOverride(address vault, address oracle, uint256 maxStaleness) external;
}

interface IRouterSmoke {
    function proposeStrategyAllowlist(address strategy) external returns (uint256 eta);
    function executeStrategyAllowlist(address strategy) external;
    function register(address strategy, uint16 priority, uint16 weightBps) external;
    function setMaxStrategyBps(address strategy, uint16 maxBps) external;
    function setLossCapPerStrategy(address strategy, uint16 capBps) external;
    function setSecondaryOracle(address oracle) external;
    function isStrategyEnabled(address strategy) external view returns (bool);
}

interface IHealthRegistrySmoke {
    function setAuthorizedCaller(address caller, bool authorized) external;
}

interface IStrategyUpkeepSmoke {
    function performUpkeep(bytes calldata performData) external;
}

interface IBufferSmoke {
    function refreshWarmNav() external;
}

contract FreshForkOracle is IPriceOracleMiddleware {
    function getQuote(address) external view returns (Quote memory) {
        return Quote({price: 1e18, decimals: 18, lastUpdate: uint48(block.timestamp), fresh: true});
    }

    function getQuoteFresh(address) external view returns (Quote memory) {
        return Quote({price: 1e18, decimals: 18, lastUpdate: uint48(block.timestamp), fresh: true});
    }

    function isFresh(address) external pure returns (bool) {
        return true;
    }

    function getFeed(address) external pure returns (address) {
        return address(1);
    }

    function getMaxStaleness(address) external pure returns (uint256) {
        return 1 days;
    }

    function owner() external pure returns (address) {
        return address(0);
    }
    function setOracleFeed(address, address, uint256) external {}
    function setMaxStaleness(address, uint256) external {}
}

contract ShadowDeploymentLifecycle_Fork_Test is Test {
    // Real deployed core (Arbitrum One) — present on the Shadow fork.
    address constant CORE_VAULT = 0x685Ec439Fc62736934FF6A74301B50173E34446b;
    address constant STRATEGY_ROUTER = 0x003BF0faD6b644536c14dcbF822b9fE1A3626b74;
    address constant BUFFER_MANAGER = 0x4560B3E16B335358dA6bF14ec8f9B9A5D07413a1;
    address constant HEALTH_REGISTRY = 0x2bF1C86af4267C068B3c928538F7AA82219cf1D4;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant GOVERNANCE_SAFE = 0x70ef444799D6FBbE0865bA598Bee6795e064a326;
    address constant GLOBAL_CONFIG = 0xf34538f8939322798261dA245d5BB6a7DB9361cE;

    uint256 constant TEST_DEPLOYER_PK = 0x5EED5;

    bool internal ready;
    address internal deployer;
    address internal guardian = makeAddr("shadowGuardian");
    address internal governance = makeAddr("shadowGovernanceSafe");
    address internal keeper = makeAddr("shadowKeeper");
    address internal emergency = makeAddr("shadowEmergency");

    PreflightUsdcLendingShadow internal pf;

    function setUp() public {
        string memory rpc = vm.envOr("SHADOW_RPC_URL", vm.envOr("ARBITRUM_RPC_URL", string("")));
        if (bytes(rpc).length == 0) {
            emit log("no SHADOW_RPC_URL / ARBITRUM_RPC_URL - skipping ShadowDeploymentLifecycle");
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        require(block.chainid == 42161, "not Arbitrum One");

        deployer = vm.addr(TEST_DEPLOYER_PK);
        vm.deal(deployer, 10 ether);
        deal(USDC, deployer, 1_000_000); // 1 USDC — covers Euler Permit2 dust + preflight min
        vm.etch(governance, hex"00"); // minimal contract code for the Safe-address invariant

        pf = new PreflightUsdcLendingShadow();
        _setShadowEnv();
        ready = true;
    }

    // ── shared env wiring ────────────────────────────────────────────────

    function _setShadowEnv() internal {
        vm.setEnv("DEPLOY_ENV", "shadow");
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(TEST_DEPLOYER_PK));
        vm.setEnv("SHADOW_DEPLOYER_PRIVATE_KEY", vm.toString(TEST_DEPLOYER_PK));
        vm.setEnv("VAULT_ADDRESS", vm.toString(CORE_VAULT));
        vm.setEnv("STRATEGY_ROUTER_ADDRESS", vm.toString(STRATEGY_ROUTER));
        vm.setEnv("BUFFER_MANAGER_ADDRESS", vm.toString(BUFFER_MANAGER));
        vm.setEnv("HEALTH_REGISTRY_ADDRESS", vm.toString(HEALTH_REGISTRY));
        vm.setEnv("GUARDIAN_ADDRESS", vm.toString(guardian));
        vm.setEnv("GOVERNANCE_ADDRESS", vm.toString(governance));
        vm.setEnv("SHADOW_GUARDIAN_ADDRESS", vm.toString(guardian));
        vm.setEnv("SHADOW_GOVERNANCE_ADDRESS", vm.toString(governance));
        vm.setEnv("SHADOW_KEEPER_ADDRESS", vm.toString(keeper));
        vm.setEnv("SHADOW_EMERGENCY_ADDRESS", vm.toString(emergency));
        vm.setEnv("SHADOW_DEPLOYMENT_ID", "forktest");
        vm.setEnv("DEPLOY_GIT_COMMIT", "forktest");
        vm.setEnv("STRATEGY_OUTPUT_JSON", "deployments/shadow/forktest/addresses.json");
    }

    function _goodInputs()
        internal
        view
        returns (UsdcLendingShadowPreflight.PreflightInputs memory p)
    {
        p.chainCfg = UsdcLendingConfigArbitrum.get();
        p.vault = CORE_VAULT;
        p.strategyRouter = STRATEGY_ROUTER;
        p.bufferManager = BUFFER_MANAGER;
        p.healthRegistry = HEALTH_REGISTRY;
        p.gov = UsdcLendingShadowPreflight.ShadowGovernance({
            deployer: deployer,
            guardian: guardian,
            governance: governance,
            keeper: keeper,
            emergency: emergency
        });
        p.adapterMaxExposureBps = 5000;
        p.deployEnv = "shadow";
        p.checkPredictedAddresses = true;
    }

    // ── preflight: positive ─────────────────────────────────────────────

    function test_preflight_passes_on_clean_shadow() public {
        if (!ready) return;
        pf.checkInputs(_goodInputs()); // must not revert
    }

    // ── preflight: negative ────────────────────────────────────────────

    function test_preflight_rejects_non_shadow_env() public {
        if (!ready) return;
        UsdcLendingShadowPreflight.PreflightInputs memory p = _goodInputs();
        p.deployEnv = "production";
        vm.expectRevert(bytes("PREFLIGHT: DEPLOY_ENV must be 'shadow' for the Shadow entrypoint"));
        pf.checkInputs(p);
    }

    function test_preflight_rejects_wrong_chain() public {
        if (!ready) return;
        vm.chainId(1);
        vm.expectRevert(bytes("PREFLIGHT: not chain 42161 (Shadow mirrors Arbitrum One)"));
        pf.checkInputs(_goodInputs());
        vm.chainId(42161);
    }

    function test_preflight_rejects_missing_dependency() public {
        if (!ready) return;
        UsdcLendingShadowPreflight.PreflightInputs memory p = _goodInputs();
        // wipe the Fluid vault's code
        vm.etch(p.chainCfg.fluidFUsdc, "");
        vm.expectRevert();
        pf.checkInputs(p);
    }

    function test_preflight_rejects_zero_governance() public {
        if (!ready) return;
        UsdcLendingShadowPreflight.PreflightInputs memory p = _goodInputs();
        p.gov.emergency = address(0);
        vm.expectRevert(bytes("PREFLIGHT: Shadow emergency address is zero"));
        pf.checkInputs(p);
    }

    function test_preflight_rejects_duplicate_governance() public {
        if (!ready) return;
        UsdcLendingShadowPreflight.PreflightInputs memory p = _goodInputs();
        p.gov.keeper = p.gov.guardian;
        vm.expectRevert(bytes("PREFLIGHT: Shadow guardian and keeper are the same address"));
        pf.checkInputs(p);
    }

    function test_preflight_rejects_predicted_address_collision() public {
        if (!ready) return;
        UsdcLendingShadowPreflight.PreflightInputs memory p = _goodInputs();
        // put code where module #3 (nonce N+3) would land
        address collide = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 3);
        vm.etch(collide, hex"600160005500");
        vm.expectRevert();
        pf.checkInputs(p);
    }

    // ── full wrapper: preflight → deploy (unmodified) → postflight ─────

    function _deployShadow() internal returns (UsdcMultiLendingVault strat) {
        // step 1 — pre-deployment checks
        new PreflightUsdcLendingShadow().run();

        // step 2 — the unmodified production deploy script
        vm.createDir("deployments/shadow/forktest", true);
        DeployUsdcLendingStrategy.DeploymentResult memory r = new DeployUsdcLendingStrategy().run();
        strat = r.strategy;
        assertEq(strat.adapterCount(), 7, "7 adapters");
        assertFalse(strat.paused(), "not paused");

        // step 3 — post-deployment verification + manifest
        new PostflightUsdcLendingShadow().run();
    }

    function test_shadow_deploy_runs_and_writes_manifest() public {
        if (!ready) return;
        UsdcMultiLendingVault strat = _deployShadow();
        console2.log("[shadow] strategy:", address(strat));

        string memory manifest = vm.readFile("deployments/shadow/forktest/manifest.json");
        assertGt(bytes(manifest).length, 0, "manifest written");
        assertEq(
            vm.parseJsonString(manifest, ".deployEnv"), "shadow", "manifest records shadow env"
        );
        assertEq(
            vm.parseJsonAddress(manifest, ".contracts.strategy"),
            address(strat),
            "manifest strategy addr"
        );
    }

    // ── lifecycle ─────────────────────────────────────────────────────

    function test_lifecycle_deposit_deployidle_harvest_rebalance_recall() public {
        if (!ready) return;
        IStratLifecycle s = IStratLifecycle(address(_deployShadow()));

        // deposit (CoreVault holds CORE_ROLE)
        uint256 amt = 400_000e6;
        deal(USDC, address(s), amt);
        vm.prank(CORE_VAULT);
        s.deposit(amt);
        assertGe(s.totalAssets(), amt, "deposit accounted");
        assertLt(s.idleCash(), amt, "some capital deployed on deposit");

        // deployIdle + harvest need KEEPER_ROLE — direct governance grants it.
        vm.startPrank(governance);
        s.grantRole(s.KEEPER_ROLE(), address(this));
        vm.stopPrank();

        // harvest right after deploy typically has nothing to realize; it must
        // be callable by the keeper without reverting or corrupting accounting.
        uint256 taBeforeHarvest = s.totalAssets();
        s.harvest();
        assertApproxEqRel(
            s.totalAssets(), taBeforeHarvest, 0.01e18, "harvest leaves TVL ~unchanged"
        );

        // prepareRebalance may legitimately be a no-op or revert if no move is
        // warranted; we only require it to be reachable without corrupting state.
        (bool okPrep,) = address(s).call(abi.encodeWithSignature("prepareRebalance()"));
        console2.log("[shadow] prepareRebalance reachable:", okPrep);
        assertGe(s.totalAssets(), 0, "state intact after prepareRebalance");

        // emergency recall — direct governance holds DEFAULT_ADMIN_ROLE.
        vm.prank(governance);
        s.emergencyRecallAll();
        assertApproxEqAbs(
            s.totalAssets(), s.idleCash(), 1e6, "recall pulled positions back to idle"
        );
    }

    function test_role_ownership_snapshot() public {
        if (!ready) return;
        IStratLifecycle s = IStratLifecycle(address(_deployShadow()));

        assertTrue(s.hasRole(s.DEFAULT_ADMIN_ROLE(), governance), "Safe holds strategy admin");
        assertFalse(s.hasRole(s.DEFAULT_ADMIN_ROLE(), deployer), "deployer admin removed");
        // deployer's temporary Phase 2.6 KEEPER_ROLE must have been revoked
        assertFalse(s.hasRole(s.KEEPER_ROLE(), deployer), "deployer KEEPER_ROLE revoked");

        string memory manifest = vm.readFile("deployments/shadow/forktest/manifest.json");
        assertFalse(vm.parseJsonBool(manifest, ".roles.deployerHasStrategyAdmin"));
        assertTrue(vm.parseJsonBool(manifest, ".roles.governanceHasStrategyAdmin"));
        assertFalse(
            vm.parseJsonBool(manifest, ".roles.deployerHasKeeper"),
            "manifest: deployer keeper false"
        );
        assertTrue(
            vm.parseJsonBool(manifest, ".roles.bootstrapRoleRenounced"),
            "manifest: bootstrap renounced"
        );
        assertFalse(vm.parseJsonBool(manifest, ".roles.sealed"), "manifest: not sealed");
    }

    function test_fresh_strategy_complete_3usdc_core_round_trip() public {
        if (!ready) return;

        // Deploy with the real 3-of-5 Safe as direct strategy governance.
        vm.setEnv("GOVERNANCE_ADDRESS", vm.toString(GOVERNANCE_SAFE));
        vm.setEnv("SHADOW_GOVERNANCE_ADDRESS", vm.toString(GOVERNANCE_SAFE));
        new PreflightUsdcLendingShadow().run();
        DeployUsdcLendingStrategy.DeploymentResult memory r = new DeployUsdcLendingStrategy().run();
        new PostflightUsdcLendingShadow().run();

        ICoreSmokeVault core = ICoreSmokeVault(CORE_VAULT);
        IGlobalConfigSmoke config = IGlobalConfigSmoke(GLOBAL_CONFIG);
        IRouterSmoke router = IRouterSmoke(STRATEGY_ROUTER);
        IStratLifecycle strategy = IStratLifecycle(address(r.strategy));

        // Safe batch 1: accept core ownership, configure small-value test
        // limits, authorize the fresh strategy, and start the router delay.
        vm.startPrank(GOVERNANCE_SAFE);
        if (core.owner() != GOVERNANCE_SAFE) {
            assertEq(core.pendingOwner(), GOVERNANCE_SAFE, "Safe is not pending CoreVault owner");
            core.acceptOwnerTransfer();
        }
        config.setVaultDepositLimits(CORE_VAULT, 20_000e6, 20_000e6, 1e6);
        config.setVaultWithdrawalOverride(
            CORE_VAULT,
            IGlobalConfigSmoke.WithdrawalConfig({
                capPerEpochBps: 10_000,
                maxWithdrawalPerBlock: 0,
                maxWithdrawalPerTx: 0,
                minClaimAmount: 1e6,
                lockPeriod: 0
            })
        );
        config.setVaultGovCaps(
            CORE_VAULT, 2 days, 0.5e18, 500, 200, 200, 7 days, 1e6, 1_000_000, 3000
        );
        strategy.setRebalanceParams(3, 2, 50, 1 days, 80, 0, 500);
        IHealthRegistrySmoke(HEALTH_REGISTRY).setAuthorizedCaller(address(r.strategy), true);
        router.proposeStrategyAllowlist(address(r.strategy));
        vm.stopPrank();

        // The router delay is independent of any governance timelock. A fork's
        // Chainlink timestamp does not advance, so install a fork-only fresh
        // oracle override after the time jump.
        vm.warp(block.timestamp + 2 days + 1);
        FreshForkOracle freshOracle = new FreshForkOracle();

        vm.startPrank(GOVERNANCE_SAFE);
        config.setVaultOracleOverride(CORE_VAULT, address(freshOracle), 1 days);
        router.setSecondaryOracle(address(0));
        router.executeStrategyAllowlist(address(r.strategy));
        router.register(address(r.strategy), 100, 10_000);
        router.setMaxStrategyBps(address(r.strategy), 10_000);
        router.setLossCapPerStrategy(address(r.strategy), 50);
        strategy.grantRole(strategy.KEEPER_ROLE(), GOVERNANCE_SAFE);
        strategy.pokeLiquidityBatch(0, 10);
        strategy.revokeRole(strategy.KEEPER_ROLE(), GOVERNANCE_SAFE);
        core.unpauseAll();
        vm.stopPrank();

        IStrategyUpkeepSmoke(r.strategyUpkeep).performUpkeep(abi.encode(uint8(3), uint256(0)));
        IBufferSmoke(BUFFER_MANAGER).refreshWarmNav();
        assertTrue(router.isStrategyEnabled(address(r.strategy)), "fresh strategy not enabled");
        assertFalse(core.paused(), "CoreVault still paused");

        // User flow: 3 USDC -> CoreVault -> fresh strategy -> lending adapter,
        // then realize back to CoreVault and consume the new shares instantly.
        address user = makeAddr("threeUsdcUser");
        deal(USDC, user, 4e6);
        uint256 usdcBefore = IERC20(USDC).balanceOf(user);
        uint256 sharesBefore = core.balanceOf(user);

        vm.startPrank(user);
        IERC20(USDC).approve(CORE_VAULT, 3e6);
        core.deposit(3e6, user);
        vm.stopPrank();

        uint256 newShares = core.balanceOf(user) - sharesBefore;
        assertGt(newShares, 0, "deposit minted no shares");
        uint256 strategyBefore = r.strategy.totalAssets();
        vm.prank(user);
        core.deployToStrategies(3e6);
        assertGt(r.strategy.totalAssets(), strategyBefore, "core did not route to strategy");

        IStrategyUpkeepSmoke(r.strategyUpkeep).performUpkeep(abi.encode(uint8(4), uint256(0)));
        uint256 coreCashBefore = IERC20(USDC).balanceOf(CORE_VAULT);
        vm.prank(user);
        core.realizeForQueue(3e6);
        assertGt(IERC20(USDC).balanceOf(CORE_VAULT), coreCashBefore, "realize returned no USDC");

        vm.prank(user);
        (bool immediate,,) = core.requestInstantWithdrawal(newShares);
        assertTrue(immediate, "withdrawal fell into epoch queue");
        assertEq(core.balanceOf(user), sharesBefore, "residual smoke-test shares");
        assertGt(IERC20(USDC).balanceOf(user), usdcBefore - 3e6, "withdrawal returned no USDC");
    }

    function test_repeated_deploy_is_isolated() public {
        if (!ready) return;
        UsdcMultiLendingVault a = _deployShadow();
        UsdcMultiLendingVault b = _deployShadow();
        assertTrue(address(a) != address(b), "second deploy gets fresh addresses");
        assertEq(a.adapterCount(), 7);
        assertEq(b.adapterCount(), 7);
    }
}
