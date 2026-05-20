// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import {
    UsdcMultiLendingVault
} from "../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
import {
    StrategyBootstrapper
} from "../../../src/strategies/usdc-lending/StrategyBootstrapper.sol";
import {
    StrategyParamsModule
} from "../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import {
    StrategyAdapterOpsModule
} from "../../../src/strategies/usdc-lending/controller/StrategyAdapterOpsModule.sol";
import {
    StrategyScoringModule
} from "../../../src/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import {
    StrategyRebalanceGateModule
} from "../../../src/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol";
import {
    StrategyRebalancePlanModule
} from "../../../src/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol";
import { StrategySettingsModule } from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import { StrategyAllocCalcModule } from "../../../src/strategies/usdc-lending/controller/StrategyAllocCalcModule.sol";
import {
    ILendingAdapter
} from "../../../src/strategies/usdc-lending/interfaces/ILendingAdapter.sol";

// ============================================================================
// MINIMAL MOCKS
// ============================================================================

contract BootstrapMockUSDC {
    string public constant name = "USD Coin";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "allowance");
            allowance[from][msg.sender] -= amount;
        }
        require(balanceOf[from] >= amount, "insufficient");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract BootstrapMockAdapter is ILendingAdapter {
    address public immutable underlying_;

    constructor(address _underlying) {
        underlying_ = _underlying;
    }

    function name() external pure override returns (string memory) { return "MockAdapter"; }
    function underlying() external view override returns (address) { return underlying_; }
    function totalAssets() external pure override returns (uint256) { return 0; }
    function withdrawableAssets() external pure override returns (uint256) { return 0; }
    function deposit(uint256) external override {}
    function withdraw(uint256, address) external pure override returns (uint256) { return 0; }
    function currentAPYBps() external pure override returns (uint16) { return 500; }
    function incentiveAPYBps() external pure override returns (uint16) { return 0; }
    function harvestableProfit() external pure override returns (uint256) { return 0; }
    function harvest(address) external pure override returns (uint256) { return 0; }
    function maxCapacity() external pure override returns (uint256) { return type(uint256).max; }
    function externalMarketTVL() external pure override returns (uint256) { return 0; }
    function isPushMode() external pure override returns (bool) { return false; }
    function idleAssetBalance() external pure override returns (uint256) { return 0; }
    function investedAssets() external pure override returns (uint256) { return 0; }
    function sweepIdleAssetToVault() external override {}
    function emergencyPullAllToVault() external override {}
}

// ============================================================================
// TEST BASE
// ============================================================================

contract StrategyBootstrapperTestBase is Test {
    address constant ARBITRUM_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    UsdcMultiLendingVault public vault;
    BootstrapMockUSDC public usdc;
    BootstrapMockAdapter public adapter1;
    BootstrapMockAdapter public adapter2;

    address public admin = address(0x10);
    address public core  = address(0x20);
    address public router = address(0x60);
    address public keeper = address(0x30);
    address public deployer = address(0x99);

    bytes32 constant BOOTSTRAP_ROLE = keccak256("BOOTSTRAP_ROLE");

    function setUp() public virtual {
        usdc = new BootstrapMockUSDC();
        vm.etch(ARBITRUM_USDC, address(usdc).code);
        usdc = BootstrapMockUSDC(ARBITRUM_USDC);

        adapter1 = new BootstrapMockAdapter(ARBITRUM_USDC);
        adapter2 = new BootstrapMockAdapter(ARBITRUM_USDC);

        UsdcMultiLendingVault.StrategyInitParams memory params = UsdcMultiLendingVault
            .StrategyInitParams({
                maxAdaptersPerAllocation: 3,
                minAdaptersActive: 2,
                rebalanceMinMoveBps: 50,
                minSecondsBetweenRebalances: 21600,
                driftToleranceBps: 80,
                wAPY: 4000,
                wLiq: 2000,
                wRisk: 2000,
                wStability: 1000,
                wIncentive: 1000,
                incentiveDecayHalfLife: 86400,
                adapterMaxExposureBps: 5000,
                newAdapterRampBps: 3400,
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

        vault = new UsdcMultiLendingVault(
            ARBITRUM_USDC,
            core,
            router,
            admin,
            keeper,
            address(0),
            address(paramsModule),
            address(scoringMod),
            address(adapterOpsMod),
            address(gateMod),
            params
        );

        StrategyRebalancePlanModule planMod = new StrategyRebalancePlanModule(
            ARBITRUM_USDC, core, address(paramsModule), address(scoringMod), address(adapterOpsMod)
        );
        vm.prank(admin);
        vault.setRebalancePlanModule(address(planMod));

        // REFACTOR-A: wire StrategySettingsModule (governance setters, last in fallback chain)
        StrategySettingsModule _settingsMod0 = new StrategySettingsModule(ARBITRUM_USDC, core);
        vm.prank(admin);
        vault.setSettingsModule(address(_settingsMod0));
        StrategyAllocCalcModule _allocCalcMod0 = new StrategyAllocCalcModule(ARBITRUM_USDC, core);
        vm.prank(admin);
        vault.setAllocCalcModule(address(_allocCalcMod0));
    }

    /// @dev Deploy a bootstrapper from deployer address, grant it BOOTSTRAP_ROLE
    function _deployBootstrapper() internal returns (StrategyBootstrapper bs) {
        vm.prank(deployer);
        bs = new StrategyBootstrapper(payable(address(vault)));
        vm.prank(admin);
        vault.grantRole(BOOTSTRAP_ROLE, address(bs));
    }
}

// ============================================================================
// TESTS
// ============================================================================

contract StrategyBootstrapperConstructorTest is StrategyBootstrapperTestBase {
    function test_constructor_setsStrategy() public {
        vm.prank(deployer);
        StrategyBootstrapper bs = new StrategyBootstrapper(payable(address(vault)));
        assertEq(address(bs.strategy()), address(vault));
    }

    function test_constructor_setsDeployer() public {
        vm.prank(deployer);
        StrategyBootstrapper bs = new StrategyBootstrapper(payable(address(vault)));
        assertEq(bs.deployer(), deployer);
    }

    function test_constructor_usedIsFalse() public {
        vm.prank(deployer);
        StrategyBootstrapper bs = new StrategyBootstrapper(payable(address(vault)));
        assertFalse(bs.used());
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(StrategyBootstrapper.ZeroAddress.selector);
        new StrategyBootstrapper(payable(address(0)));
    }
}

contract StrategyBootstrapperBootstrapTest is StrategyBootstrapperTestBase {
    function test_bootstrap_happyPath_singleAdapter() public {
        StrategyBootstrapper bs = _deployBootstrapper();

        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter1);

        vm.prank(deployer);
        bs.bootstrap(adapters);

        assertTrue(vault.isAdapter(address(adapter1)));
    }

    function test_bootstrap_happyPath_multipleAdapters() public {
        StrategyBootstrapper bs = _deployBootstrapper();

        address[] memory adapters = new address[](2);
        adapters[0] = address(adapter1);
        adapters[1] = address(adapter2);

        vm.prank(deployer);
        bs.bootstrap(adapters);

        assertTrue(vault.isAdapter(address(adapter1)));
        assertTrue(vault.isAdapter(address(adapter2)));
    }

    function test_bootstrap_setsUsedFlag() public {
        StrategyBootstrapper bs = _deployBootstrapper();

        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter1);

        vm.prank(deployer);
        bs.bootstrap(adapters);

        assertTrue(bs.used());
    }

    function test_bootstrap_renouncesBOOTSTRAP_ROLE() public {
        StrategyBootstrapper bs = _deployBootstrapper();

        assertTrue(bs.hasBootstrapRole());

        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter1);

        vm.prank(deployer);
        bs.bootstrap(adapters);

        assertFalse(bs.hasBootstrapRole());
    }

    function test_bootstrap_emitsBootstrapped() public {
        StrategyBootstrapper bs = _deployBootstrapper();

        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter1);

        vm.expectEmit(true, false, false, true);
        emit StrategyBootstrapper.Bootstrapped(address(vault), 1);

        vm.prank(deployer);
        bs.bootstrap(adapters);
    }

    function test_bootstrap_emitsAdapterRegistered() public {
        StrategyBootstrapper bs = _deployBootstrapper();

        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter1);

        vm.expectEmit(true, false, false, false);
        emit StrategyBootstrapper.AdapterRegistered(address(adapter1));

        vm.prank(deployer);
        bs.bootstrap(adapters);
    }

    function test_bootstrap_revertsIfAlreadyBootstrapped() public {
        StrategyBootstrapper bs = _deployBootstrapper();

        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter1);

        vm.prank(deployer);
        bs.bootstrap(adapters);

        vm.expectRevert(StrategyBootstrapper.AlreadyBootstrapped.selector);
        vm.prank(deployer);
        bs.bootstrap(adapters);
    }

    function test_bootstrap_revertsIfNotDeployer() public {
        StrategyBootstrapper bs = _deployBootstrapper();

        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter1);

        vm.expectRevert(StrategyBootstrapper.NotDeployer.selector);
        vm.prank(admin); // wrong caller
        bs.bootstrap(adapters);
    }

    function test_bootstrap_revertsIfEmptyAdapters() public {
        StrategyBootstrapper bs = _deployBootstrapper();

        address[] memory adapters = new address[](0);

        vm.expectRevert(StrategyBootstrapper.EmptyAdapters.selector);
        vm.prank(deployer);
        bs.bootstrap(adapters);
    }

    function test_bootstrap_revertsIfZeroAddressInArray() public {
        StrategyBootstrapper bs = _deployBootstrapper();

        address[] memory adapters = new address[](2);
        adapters[0] = address(adapter1);
        adapters[1] = address(0);

        vm.expectRevert(StrategyBootstrapper.ZeroAddress.selector);
        vm.prank(deployer);
        bs.bootstrap(adapters);
    }
}

contract StrategyBootstrapperViewTest is StrategyBootstrapperTestBase {
    function test_isBootstrapped_falseBeforeBootstrap() public {
        StrategyBootstrapper bs = _deployBootstrapper();
        assertFalse(bs.isBootstrapped());
    }

    function test_isBootstrapped_trueAfterBootstrap() public {
        StrategyBootstrapper bs = _deployBootstrapper();

        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter1);

        vm.prank(deployer);
        bs.bootstrap(adapters);

        assertTrue(bs.isBootstrapped());
    }

    function test_hasBootstrapRole_trueBeforeBootstrap() public {
        StrategyBootstrapper bs = _deployBootstrapper();
        assertTrue(bs.hasBootstrapRole());
    }

    function test_hasBootstrapRole_falseAfterBootstrap() public {
        StrategyBootstrapper bs = _deployBootstrapper();

        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter1);

        vm.prank(deployer);
        bs.bootstrap(adapters);

        assertFalse(bs.hasBootstrapRole());
    }

    function test_hasBootstrapRole_falseWithoutRoleGrant() public {
        // Bootstrapper deployed but BOOTSTRAP_ROLE never granted
        vm.prank(deployer);
        StrategyBootstrapper bs = new StrategyBootstrapper(payable(address(vault)));
        assertFalse(bs.hasBootstrapRole());
    }
}
