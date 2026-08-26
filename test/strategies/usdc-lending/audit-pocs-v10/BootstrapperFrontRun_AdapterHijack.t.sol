// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * FINDING (FIXED at the deploy-script level): `StrategyBootstrapper.initialize()`
 *          has no access control beyond OpenZeppelin's `initializer` one-shot
 *          guard -- `deployer` is a caller-supplied parameter, and whoever's
 *          `initialize()` call is mined FIRST wins. The contract itself is
 *          unchanged (that's inherent to the non-proxy Initializable pattern
 *          used across all V10 adapters); what was fixed is that
 *          `script/DeployUsdcLendingStrategy.s.sol` no longer deploys the
 *          bootstrapper (or any of the 7 adapters) as two separate
 *          transactions. It now calls `AdapterFactory.deployAndInit()`,
 *          which bundles CREATE2-deploy and `initialize()` into a single
 *          atomic transaction -- there is no longer a window on-chain where
 *          an uninitialized bootstrapper/adapter sits exposed.
 *
 * SEVERITY: CRITICAL (was, for the shipped deploy flow).
 *
 * Test 1 below (kept from the original PoC) still reproduces the two-
 * transaction footgun against the RAW pattern (`new X(); x.initialize(...)`)
 * to document exactly why that pattern must never be used for this contract
 * -- it is not, and cannot be, "fixed" at the `StrategyBootstrapper` contract
 * level alone; safety depends on always deploying atomically.
 * Test 2 proves the ACTUAL fix: reproducing the deploy script's real
 * `AdapterFactory.deployAndInit()` call and showing the identical front-run
 * attempt fails, because deploy+init happen in one call with no window for
 * anything else to land in between.
 */

import { Test, console2 } from "forge-std/Test.sol";
import { UsdcMultiLendingVault } from "../../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
import { StrategyBootstrapper } from "../../../../src/strategies/usdc-lending/StrategyBootstrapper.sol";
import { AdapterFactory } from "../../../../src/strategies/usdc-lending/factory/AdapterFactory.sol";
import { StrategyParamsModule } from "../../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import { StrategyAdapterOpsModule } from "../../../../src/strategies/usdc-lending/controller/StrategyAdapterOpsModule.sol";
import { StrategyScoringModule } from "../../../../src/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import { StrategyRebalanceGateModule } from "../../../../src/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol";
import { StrategySettingsModule } from "../../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import { MockUSDC, MockLendingAdapter } from "../UsdcMultiLendingVault.t.sol";

contract BootstrapperFrontRun_PoC is Test {
    address constant ARBITRUM_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    address deployer = address(0xD00D);       // legitimate operator running the deploy script
    address attacker = address(0xBAD);        // has no role, no special access anywhere
    address core = address(0x2);
    address router = address(0x6);
    address rootTimelock = address(0x7);
    address guardian = address(0x8);

    MockUSDC usdc;
    UsdcMultiLendingVault vault;

    function setUp() public {
        usdc = new MockUSDC();
        vm.etch(ARBITRUM_USDC, address(usdc).code);
        usdc = MockUSDC(ARBITRUM_USDC);
    }

    function _defaultParams() internal pure returns (UsdcMultiLendingVault.StrategyInitParams memory) {
        return UsdcMultiLendingVault.StrategyInitParams({
            maxAdaptersPerAllocation: 3,
            minAdaptersActive: 1,
            rebalanceMinMoveBps: 50,
            minSecondsBetweenRebalances: 21600,
            driftToleranceBps: 80,
            wAPY: 4000, wLiq: 2000, wRisk: 2000, wStability: 1000, wIncentive: 1000,
            incentiveDecayHalfLife: 86400,
            adapterMaxExposureBps: 5000,
            newAdapterRampBps: 5000,
            gateHorizonDays: 7,
            gateMinNetBenefitBps: 2,
            slippageBpsEstimate: 5,
            withdrawalSpreadBpsEstimate: 5,
            gasCostUSDC: 1e6,
            harvestThresholdBps: 5,
            minSecondsBetweenHarvests: 43200,
            dustTolerance: 3e6,
            stabilityEMAPeriod: 7,
            minNewAdapterSeed: 0,
            newAdapterRampDuration: 0,
            maxIdleAfterDepositBps: 500,
            maxIdleBootstrapBps: 5000,
            degradedViewThresholdBps: 2500,
            failureDecaySeconds: 3600,
            minSecondsBetweenDeployIdle: 300,
            bootstrapDuration: 86400,
            maxRelativeExposureBps: 0,
            externalTVLStalenessSeconds: 43200
        });
    }

    /// @notice Test 1: the RAW `new X(); x.initialize(...)` pattern is still
    ///         exploitable -- this is why it must never be used, not proof
    ///         the underlying issue is unfixed.
    function test_POC_1_raw_new_then_initialize_pattern_is_still_frontrunnable() public {
        // --- Replicate the OLD (pre-fix) two-transaction pattern exactly ---

        StrategyParamsModule paramsModule = new StrategyParamsModule(ARBITRUM_USDC, core);
        StrategyAdapterOpsModule adapterOpsMod = new StrategyAdapterOpsModule(
            ARBITRUM_USDC, core, address(paramsModule), address(0), address(0)
        );
        StrategyScoringModule scoringMod = new StrategyScoringModule(
            ARBITRUM_USDC, core, address(paramsModule), address(0), address(adapterOpsMod)
        );
        StrategyRebalanceGateModule gateMod = new StrategyRebalanceGateModule(
            ARBITRUM_USDC, core, address(paramsModule), address(scoringMod), address(adapterOpsMod)
        );

        // The deploy script pre-computes the bootstrapper's future CREATE address
        // and passes it into the vault constructor so BOOTSTRAP_ROLE can be
        // granted before the bootstrapper even exists on-chain.
        vm.startPrank(deployer);
        address predictedBootstrapper = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);

        // Phase 1.1: deploy the vault (tx N-ish)
        vault = new UsdcMultiLendingVault(
            ARBITRUM_USDC, core, router, rootTimelock, guardian,
            predictedBootstrapper,
            address(paramsModule), address(scoringMod), address(adapterOpsMod), address(gateMod),
            _defaultParams()
        );
        assertTrue(vault.hasRole(vault.BOOTSTRAP_ROLE(), predictedBootstrapper), "sanity: role pre-granted to predicted address");

        // Phase 1.2, first half — "StrategyBootstrapper boot = new StrategyBootstrapper();" (tx N)
        StrategyBootstrapper boot = new StrategyBootstrapper();
        assertEq(address(boot), predictedBootstrapper, "sanity: address prediction matches (as it does in the real script)");
        vm.stopPrank();

        // Wire StrategySettingsModule (holds whitelistAdapter()) so bootstrap()
        // can complete -- rootTimelock holds DEFAULT_ADMIN_ROLE from the
        // vault constructor.
        StrategySettingsModule settingsMod = new StrategySettingsModule(ARBITRUM_USDC, core);
        vm.prank(rootTimelock);
        vault.setSettingsModule(address(settingsMod));

        // *** THE WINDOW ***
        // On a real chain, "boot.initialize(strategy, cfg.deployer);" (tx N+1) is
        // now sitting in the mempool. Nothing stops anyone else from getting
        // their own initialize() call mined first.
        vm.prank(attacker);
        boot.initialize(payable(address(vault)), attacker);

        assertEq(boot.deployer(), attacker, "VULNERABLE: attacker, not the legitimate deployer, is now the bootstrapper's deployer");

        // The legitimate operator's own initialize() call (tx N+1 in the real
        // script) now reverts -- the honest deployment is bricked/DoS'd.
        vm.prank(deployer);
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        boot.initialize(payable(address(vault)), deployer);

        // Worse: the attacker is now the ONLY address that can call bootstrap().
        // whitelistAdapter() accepts BOOTSTRAP_ROLE, so the bootstrapper can
        // self-whitelist whatever the attacker passes in.
        MockLendingAdapter maliciousAdapter = new MockLendingAdapter(ARBITRUM_USDC);
        maliciousAdapter.setVault(address(vault));
        address[] memory hijackedList = new address[](1);
        hijackedList[0] = address(maliciousAdapter);

        vm.prank(attacker);
        boot.bootstrap(hijackedList);

        assertTrue(vault.isAdapter(address(maliciousAdapter)), "VULNERABLE: attacker-supplied adapter is now a registered, trusted strategy adapter");
        assertTrue(vault.enabled(address(maliciousAdapter)), "VULNERABLE: and it's enabled -- eligible to receive real depositor USDC");
        assertFalse(
            vault.hasRole(vault.BOOTSTRAP_ROLE(), address(boot)),
            "BOOTSTRAP_ROLE permanently renounced -- legitimate governance can NEVER use this one-shot path again"
        );
    }

    /// @notice Test 2: the FIXED deploy-script pattern -- AdapterFactory
    ///         atomically bundles CREATE2-deploy + initialize() into one
    ///         transaction, exactly as script/DeployUsdcLendingStrategy.s.sol
    ///         now does. There is no window for an attacker's initialize()
    ///         call to land in between.
    function test_POC_2_AdapterFactory_deployAndInit_is_not_frontrunnable() public {
        StrategyParamsModule paramsModule = new StrategyParamsModule(ARBITRUM_USDC, core);
        StrategyAdapterOpsModule adapterOpsMod = new StrategyAdapterOpsModule(
            ARBITRUM_USDC, core, address(paramsModule), address(0), address(0)
        );
        StrategyScoringModule scoringMod = new StrategyScoringModule(
            ARBITRUM_USDC, core, address(paramsModule), address(0), address(adapterOpsMod)
        );
        StrategyRebalanceGateModule gateMod = new StrategyRebalanceGateModule(
            ARBITRUM_USDC, core, address(paramsModule), address(scoringMod), address(adapterOpsMod)
        );

        vm.startPrank(deployer);
        AdapterFactory factory = new AdapterFactory(deployer); // deployer gets DEPLOYER_ROLE

        bytes32 salt = keccak256("bootstrapper-salt");
        address predictedBootstrapper = factory.computeAddress(type(StrategyBootstrapper).creationCode, salt);
        assertEq(predictedBootstrapper.code.length, 0, "sanity: nothing deployed there yet -- no attacker target exists");

        vault = new UsdcMultiLendingVault(
            ARBITRUM_USDC, core, router, rootTimelock, guardian,
            predictedBootstrapper,
            address(paramsModule), address(scoringMod), address(adapterOpsMod), address(gateMod),
            _defaultParams()
        );

        // Single atomic call: CREATE2-deploy + initialize(deployer) happen
        // together. An attacker cannot insert a call between them -- there is
        // no "between" on-chain, it's one transaction.
        address bootstrapperAddr = factory.deployAndInit(
            type(StrategyBootstrapper).creationCode,
            salt,
            abi.encodeCall(StrategyBootstrapper.initialize, (payable(address(vault)), deployer))
        );
        vm.stopPrank();

        assertEq(bootstrapperAddr, predictedBootstrapper, "address prediction still matches (CREATE2-deterministic)");
        assertEq(StrategyBootstrapper(bootstrapperAddr).deployer(), deployer, "FIXED: deployer is correctly set to the legitimate operator");

        // An attacker trying the exact same front-run now finds the contract
        // already initialized -- their call simply reverts, nothing to hijack.
        vm.prank(attacker);
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        StrategyBootstrapper(bootstrapperAddr).initialize(payable(address(vault)), attacker);

        assertEq(StrategyBootstrapper(bootstrapperAddr).deployer(), deployer, "still the legitimate deployer, unchanged");
    }
}
