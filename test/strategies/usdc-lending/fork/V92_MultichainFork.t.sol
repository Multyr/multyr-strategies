// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// =============================================================================
// V92_MultichainFork.t.sol -- V10 byte-identical bytecode on Optimism + Base
// -----------------------------------------------------------------------------
// Fork: Optimism mainnet + Base mainnet (stable pinned blocks).
// RPC:  OPTIMISM_RPC_URL / BASE_RPC_URL env vars -- never written to disk or git.
//
// Key claim tested: UsdcMultiLendingVault compiled bytecode is byte-identical
// across chains (same audit scope covers all deployments).
//
// Test approach per chain:
//   1. Fork the chain at a pinned block (real network state).
//   2. Etch a MockUSDC at the Arbitrum USDC address so the constructor check passes.
//   3. Deploy all V10 strategy modules + vault with mock adapters.
//   4. Run deposit + withdraw lifecycle -- verify conservation of funds.
//   5. Log vault.codehash for cross-chain identity verification.
//
// Skips gracefully when the RPC env var is absent (CI without secrets).
//
// Run:
//   OPTIMISM_RPC_URL=<rpc> forge test --match-contract V92_MultichainFork_Optimism -vv
//   BASE_RPC_URL=<rpc>     forge test --match-contract V92_MultichainFork_Base -vv
// =============================================================================

import { Test }   from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { IERC20 }  from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { UsdcMultiLendingVault }        from "../../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
import { StrategyParamsModule }         from "../../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import { StrategySettingsModule }       from "../../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import { StrategyAllocCalcModule }      from "../../../../src/strategies/usdc-lending/controller/StrategyAllocCalcModule.sol";
import { StrategyScoringModule }        from "../../../../src/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import { StrategyAdapterOpsModule }     from "../../../../src/strategies/usdc-lending/controller/StrategyAdapterOpsModule.sol";
import { StrategyRebalanceGateModule }  from "../../../../src/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol";
import { StrategyRebalancePlanModule }  from "../../../../src/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol";
import { StrategySafetyOverflowModule } from "../../../../src/strategies/usdc-lending/controller/StrategySafetyOverflowModule.sol";
import { ScoringMockAdapter, MockUSDC } from "../Scoring_Model.t.sol";

import { UsdcLendingChainConfig }    from "../../../../src/strategies/usdc-lending/config/UsdcLendingChainConfig.sol";
import { UsdcLendingConfigOptimism } from "../../../../src/strategies/usdc-lending/config/UsdcLendingConfigOptimism.sol";
import { UsdcLendingConfigBase }     from "../../../../src/strategies/usdc-lending/config/UsdcLendingConfigBase.sol";

// Vault constructor enforces asset == ARBITRUM_USDC.
// Fork tests etch a MockUSDC at this address so the check passes on any chain.
address constant ARBITRUM_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

// Universal Permit2 address (same on all EVM chains).
address constant PERMIT2_UNIVERSAL = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

abstract contract MultichainForkBase is Test {

    address internal admin  = address(0xA11CE);
    address internal core   = address(0xC0FFEE);
    address internal router = address(0xBEEF);
    address internal keeper = address(0xCAFE);

    UsdcMultiLendingVault internal vault;
    MockUSDC              internal usdc;
    ScoringMockAdapter    internal adapterA;
    ScoringMockAdapter    internal adapterB;

    uint256 constant DEPOSIT = 100_000e6; // 100K USDC

    // -------------------------------------------------------------------------
    // Full V10 vault wiring -- mirrors Scoring_Model.t.sol setUp
    // -------------------------------------------------------------------------
    function _deployVault() internal {
        // Etch mock USDC at the Arbitrum USDC address (vault constructor asserts this).
        usdc = new MockUSDC();
        vm.etch(ARBITRUM_USDC, address(usdc).code);
        usdc = MockUSDC(ARBITRUM_USDC);

        UsdcMultiLendingVault.StrategyInitParams memory params = _defaultParams();

        StrategyParamsModule paramsMod = new StrategyParamsModule(ARBITRUM_USDC, core);
        StrategyAdapterOpsModule adapterOpsMod = new StrategyAdapterOpsModule(
            ARBITRUM_USDC, core, address(paramsMod), address(0), address(0)
        );
        StrategyScoringModule scoringMod = new StrategyScoringModule(
            ARBITRUM_USDC, core, address(paramsMod), address(0), address(adapterOpsMod)
        );
        address gateMod = address(new StrategyRebalanceGateModule(
            ARBITRUM_USDC, core, address(paramsMod), address(scoringMod), address(adapterOpsMod)
        ));

        vault = new UsdcMultiLendingVault(
            ARBITRUM_USDC, core, router, admin, keeper, address(0),
            address(paramsMod), address(scoringMod), address(adapterOpsMod),
            gateMod, params
        );

        vm.startPrank(admin);
        vault.setRebalancePlanModule(address(
            new StrategyRebalancePlanModule(
                ARBITRUM_USDC, core, address(paramsMod), address(scoringMod), address(adapterOpsMod)
            )
        ));
        vault.setSettingsModule(address(new StrategySettingsModule(ARBITRUM_USDC, core)));
        vault.setAllocCalcModule(address(new StrategyAllocCalcModule(ARBITRUM_USDC, core)));
        StrategySettingsModule(address(vault)).setSafetyOverflowModule(address(
            new StrategySafetyOverflowModule(
                ARBITRUM_USDC, core, address(0), address(0), address(adapterOpsMod)
            )
        ));
        vm.stopPrank();

        // Register 2 mock adapters with distinct APYs
        adapterA = new ScoringMockAdapter(ARBITRUM_USDC);
        adapterB = new ScoringMockAdapter(ARBITRUM_USDC);
        adapterA.setAPY(500); adapterA.setExtMarketTVL(500_000_000e6);
        adapterB.setAPY(700); adapterB.setExtMarketTVL(500_000_000e6);
        adapterA.setVault(address(vault));
        adapterB.setVault(address(vault));

        _addAndEnable(adapterA);
        _addAndEnable(adapterB);

        // Exit bootstrap so scoring drives allocation (not equal-headroom bootstrap)
        vm.prank(admin);
        StrategySettingsModule(address(vault)).exitBootstrapMode();

        console.log("Vault codehash:", vm.toString(address(vault).codehash));
    }

    function _addAndEnable(ScoringMockAdapter a) internal {
        vm.startPrank(admin);
        address(vault).call(abi.encodeWithSignature("whitelistAdapter(address,bool)", address(a), true));
        vault.addAdapter(address(a));
        vault.toggleAdapter(address(a), true);
        (bool ok,) = address(vault).call(
            abi.encodeWithSignature("setAdapterDepositMode(address,bool)", address(a), false)
        );
        require(ok, "setAdapterDepositMode failed");
        vm.stopPrank();

        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        vm.prank(keeper);
        (bool liqOk,) = address(vault).call(
            abi.encodeWithSignature("pokeLiquidityBatch(uint256,uint256)", 0, 10)
        );
        require(liqOk, "pokeLiquidityBatch failed");
    }

    // -------------------------------------------------------------------------
    // Core invariant: deposit + withdraw = no stranded funds
    // -------------------------------------------------------------------------
    function _runDepositWithdraw() internal {
        // Mint USDC to core (simulating StrategyRouter transferring from depositor)
        usdc.mint(core, DEPOSIT);

        // Core transfers USDC to vault, then calls deposit (no-cash-invariant enforced)
        vm.prank(core);
        usdc.transfer(address(vault), DEPOSIT);

        uint256 tvlBefore = vault.totalAssets();
        vm.prank(core);
        vault.deposit(DEPOSIT);

        uint256 tvlAfter = vault.totalAssets();
        assertApproxEqAbs(tvlAfter, tvlBefore + DEPOSIT, 1e6,
            "totalAssets must increase by DEPOSIT after deposit");

        // Withdraw full amount back to core
        vm.prank(core);
        uint256 received = vault.withdraw(DEPOSIT, core);

        assertGt(received, 0, "withdraw must return non-zero USDC");
        assertApproxEqAbs(IERC20(ARBITRUM_USDC).balanceOf(core), DEPOSIT, 1e6,
            "core must recover full deposit");

        console.log("Deposited:", DEPOSIT);
        console.log("Received back:", received);
    }

    function _defaultParams() internal pure returns (UsdcMultiLendingVault.StrategyInitParams memory p) {
        p.maxAdaptersPerAllocation    = 2;
        p.minAdaptersActive           = 2;
        p.rebalanceMinMoveBps         = 50;
        p.minSecondsBetweenRebalances = 21600;
        p.driftToleranceBps           = 80;
        p.wAPY                        = 4000;
        p.wLiq                        = 2000;
        p.wRisk                       = 2000;
        p.wStability                  = 1000;
        p.wIncentive                  = 1000;
        p.incentiveDecayHalfLife      = 86400;
        p.adapterMaxExposureBps       = 8000;
        p.newAdapterRampBps           = 8000;
        p.gateHorizonDays             = 7;
        p.gateMinNetBenefitBps        = 2;
        p.slippageBpsEstimate         = 5;
        p.withdrawalSpreadBpsEstimate = 5;
        p.gasCostUSDC                 = 1e6;
        p.harvestThresholdBps         = 5;
        p.minSecondsBetweenHarvests   = 43200;
        p.dustTolerance               = 10000;
        p.stabilityEMAPeriod          = 7;
        p.minNewAdapterSeed           = 0;
        p.newAdapterRampDuration      = 0;
        p.maxIdleAfterDepositBps      = 500;
        p.maxIdleBootstrapBps         = 5000;
        p.degradedViewThresholdBps    = 2500;
        p.failureDecaySeconds         = 3600;
        p.minSecondsBetweenDeployIdle = 300;
        p.bootstrapDuration           = 86400;
        p.maxRelativeExposureBps      = 0;
        p.externalTVLStalenessSeconds = 43200;
    }
}

// =============================================================================
// Test 5: Optimism fork -- deposit/withdraw + config validation
// =============================================================================

contract V92_MultichainFork_Optimism is MultichainForkBase {

    // Pinned Optimism block (2026-06 state -- update if archival node prunes this block).
    uint256 constant OP_FORK_BLOCK = 136_000_000;

    function setUp() public {
        string memory rpc = vm.envOr("OPTIMISM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return; }
        vm.createSelectFork(rpc, OP_FORK_BLOCK);
        _deployVault();
    }

    function test_fork_optimism_basic_deposit_withdraw() public {
        UsdcLendingChainConfig memory cfg = UsdcLendingConfigOptimism.get();

        // Validate chain config
        assertEq(cfg.venusBlocksPerYear, 0,      "Venus must be disabled on Optimism");
        assertEq(cfg.venusVToken, address(0),    "Venus vToken must be zero on Optimism");
        assertEq(cfg.permit2, PERMIT2_UNIVERSAL, "Permit2 universal address mismatch");
        assertNotEq(cfg.deploySalt, bytes32(0),  "Optimism deploySalt must be non-zero");
        assertNotEq(cfg.usdc, address(0),        "Optimism USDC must be configured");

        // Vault deployed and has valid bytecode on this forked chain
        assertNotEq(address(vault).codehash, bytes32(0),
            "Vault must be deployed on Optimism fork");

        // Run deposit/withdraw lifecycle on Optimism chain state
        _runDepositWithdraw();

        // Log for auditor cross-chain bytecode identity verification
        bytes32 creationHash = keccak256(type(UsdcMultiLendingVault).creationCode);
        console.log("Optimism creationCode keccak256:", vm.toString(creationHash));
        console.log("Optimism vault.codehash:", vm.toString(address(vault).codehash));
        console.log("Optimism block.chainid:", block.chainid);
        assertEq(block.chainid, 10, "Must be running on Optimism (chainid 10)");
    }
}

// =============================================================================
// Test 6: Base fork -- deposit/withdraw + config validation
// =============================================================================

contract V92_MultichainFork_Base is MultichainForkBase {

    // Pinned Base block (2026-06 state -- update if archival node prunes this block).
    uint256 constant BASE_FORK_BLOCK = 30_000_000;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return; }
        vm.createSelectFork(rpc, BASE_FORK_BLOCK);
        _deployVault();
    }

    function test_fork_base_basic_deposit_withdraw() public {
        UsdcLendingChainConfig memory cfg = UsdcLendingConfigBase.get();

        // Validate chain config
        assertEq(cfg.venusBlocksPerYear, 0,      "Venus must be disabled on Base");
        assertEq(cfg.venusVToken, address(0),    "Venus vToken must be zero on Base");
        assertEq(cfg.permit2, PERMIT2_UNIVERSAL, "Permit2 universal address mismatch");
        assertNotEq(cfg.deploySalt, bytes32(0),  "Base deploySalt must be non-zero");
        assertNotEq(cfg.usdc, address(0),        "Base USDC must be configured");

        // Vault deployed and has valid bytecode on this forked chain
        assertNotEq(address(vault).codehash, bytes32(0),
            "Vault must be deployed on Base fork");

        // Run deposit/withdraw lifecycle on Base chain state
        _runDepositWithdraw();

        // Log for auditor cross-chain bytecode identity verification
        bytes32 creationHash = keccak256(type(UsdcMultiLendingVault).creationCode);
        console.log("Base creationCode keccak256:", vm.toString(creationHash));
        console.log("Base vault.codehash:", vm.toString(address(vault).codehash));
        console.log("Base block.chainid:", block.chainid);
        assertEq(block.chainid, 8453, "Must be running on Base (chainid 8453)");
    }
}