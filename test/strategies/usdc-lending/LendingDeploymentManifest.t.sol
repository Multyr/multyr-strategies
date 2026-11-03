// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployLendingStrategy} from "../../../script/DeployLendingStrategy.s.sol";
import {DeployUsdcLendingStrategy} from "../../../script/DeployUsdcLendingStrategy.s.sol";
import {AaveV3USDCAdapter} from "../../../src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol";
import {UsdcMultiLendingVault} from "../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
import {StrategyParamsModule} from "../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import {ReadOnlyGasEstimator as E, IFeeInfo, IFeed} from "../../../src/strategies/usdc-lending/gas/ReadOnlyGasEstimator.sol";
import {Feed, Fees} from "./ReadOnlyGasEstimator.t.sol";
import {LendingTestPriceOracle, LendingTestParamsProvider} from "./helpers/LendingOracleTestFixture.sol";
import {RewardSwapHelper} from "../../../src/strategies/usdc-lending/swap/RewardSwapHelper.sol";
import {OPStackFeeInfo, IOPGasPriceOracle} from "../../../src/strategies/usdc-lending/gas/OPStackFeeInfo.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ManifestAsset is ERC20 {
    constructor() ERC20("Manifest asset", "ASSET") {}
}

contract ManifestAsset6 is ManifestAsset {
    function decimals() public pure override returns (uint8) { return 6; }
}

contract ManifestCore {
    address public immutable asset;
    address public immutable params;
    constructor(address asset_, address params_) { asset = asset_; params = params_; }
}

contract LendingDeploymentManifestTest is Test {
    function test_manifestArbitrum18DecimalsHandoff() public { _deployManifest(42161, false); }
    function test_manifestArbitrum6DecimalsHandoff() public { _deployManifest(42161, true); }
    function test_manifestBase18DecimalsHandoff() public { _deployManifest(8453, false); }
    function test_manifestBase6DecimalsHandoff() public { _deployManifest(8453, true); }

    function _deployManifest(uint256 chain, bool sixDecimals) internal {
        vm.warp(1 days);
        vm.chainId(chain);
        // Deterministic, test-only signer. No workstation credentials are read.
        uint256 testKey = 0xA11CE;
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(testKey));
        address signer = vm.addr(testKey);
        vm.deal(signer, 100 ether);
        ManifestAsset asset = sixDecimals ? new ManifestAsset6() : new ManifestAsset();
        uint256 unit = sixDecimals ? 1e6 : 1e18;
        uint256 price = sixDecimals ? 1e18 : 3000e18;
        LendingTestPriceOracle oracle = new LendingTestPriceOracle();
        oracle.set(price, uint48(block.timestamp), true);
        LendingTestParamsProvider provider = new LendingTestParamsProvider(address(oracle), 1 hours);
        ManifestCore core = new ManifestCore(address(asset), address(provider));
        address router = address(0xABCD);
        address pool = address(0x1001);
        address aToken = address(0x1002);
        vm.etch(router, hex"00"); vm.etch(pool, hex"00"); vm.etch(aToken, hex"00");
        vm.mockCall(aToken, abi.encodeWithSignature("UNDERLYING_ASSET_ADDRESS()"), abi.encode(address(asset)));
        vm.mockCall(aToken, abi.encodeWithSignature("totalSupply()"), abi.encode(uint256(1_000_000 * unit)));
        vm.mockCall(aToken, abi.encodeWithSignature("balanceOf(address)"), abi.encode(uint256(0)));
        Fees feesTemplate = new Fees();
        vm.etch(address(0x6c), address(feesTemplate).code);
        Fees(address(0x6c)).set(20_000_000, 1_000_000_000);
        address feeSource = address(0x6c);
        if (chain == 8453) {
            address opOracle = address(0xFEE);
            vm.etch(opOracle, hex"00");
            vm.fee(2 gwei);
            vm.mockCall(opOracle, abi.encodeCall(IOPGasPriceOracle.getOperatorFee, (0)), abi.encode(uint256(1000)));
            vm.mockCall(opOracle, abi.encodeCall(IOPGasPriceOracle.getOperatorFee, (1_000_000)), abi.encode(uint256(2_001_000)));
            vm.mockCall(opOracle, abi.encodeCall(IOPGasPriceOracle.getL1FeeUpperBound, (4352)), abi.encode(uint256(9000)));
            feeSource = address(new OPStackFeeInfo(IOPGasPriceOracle(opOracle), 4096, 1 gwei));
        }
        Feed eth = new Feed(3000e8);
        Feed sequencer = new Feed(0);
        E.Config memory c = E.Config(100000, 100000, 100000, 300000, 300000, 21000, 512, 3000, 3600, 3600, 3600, 1e6);
        c.usdcMaxPriceAge = 0;
        E estimator = new E(IFeeInfo(feeSource), eth, IFeed(address(0)), sequencer, c);
        // Forge hosts script programs off-chain; they are not deployable protocol contracts.
        DeployLendingStrategy script = DeployLendingStrategy(address(0x5C71));
        vm.etch(address(script), vm.getDeployedCode("DeployLendingStrategy.s.sol:DeployLendingStrategy"));
        vm.allowCheatcodes(address(script));
        DeployLendingStrategy.Manifest memory m;
        m.chainId = block.chainid; m.asset = address(asset); m.coreVault = address(core); m.router = router;
        m.governance = address(this); m.keeper = address(this); m.salt = keccak256("manifest-test");
        m.estimator = address(estimator); m.ethUsdFeed = address(eth); m.usdQuoteFeed = address(0);
        m.feeSource = feeSource; m.sequencerFeed = address(sequencer);
        if (chain == 42161) m.arbitrumFeeSnapshot = abi.encode(uint256(140_000_000_000), uint256(1_000_000_000),
            uint256(0), uint256(0), uint256(0), uint256(20_000_000));
        m.estimatorConfigHash = keccak256(abi.encode(c));
        ManifestAsset reward = new ManifestAsset();
        Feed outputFeed = new Feed(int256(price / 1e10));
        m.assetUsdFeed = address(outputFeed); m.assetFeedMaxAge = 3600;
        m.uniRouter = address(0x2020); vm.etch(m.uniRouter, hex"00");
        m.rewards = new DeployLendingStrategy.RewardSpec[](1);
        m.rewards[0] = DeployLendingStrategy.RewardSpec(address(reward), address(eth), 3600,
            abi.encodePacked(address(reward), uint24(3000), address(asset)), bytes(""), 100);
        m.parameters.maxAdaptersPerAllocation = 1;
        m.parameters.minAdaptersActive = 1;
        m.parameters.newAdapterRampBps = 5000;
        m.parameters.minSecondsBetweenRebalances = 86400;
        m.parameters.wAPY = 5000; m.parameters.wLiq = 2000; m.parameters.wRisk = 2000;
        m.parameters.wStability = 1000; m.parameters.wIncentive = 0;
        m.parameters.gateHorizonDays = 30; m.parameters.gateMinNetBenefitBps = 10;
        m.parameters.slippageBpsEstimate = 2; m.parameters.withdrawalSpreadBpsEstimate = 2;
        m.parameters.gasCostUSDC = 1e6; m.parameters.stabilityEMAPeriod = 7;
        m.parameters.harvestThresholdBps = 100; m.parameters.minSecondsBetweenHarvests = 86400;
        m.parameters.maxIdleAfterDepositBps = 10000;
        m.parameters.maxIdleBootstrapBps = 10000;
        m.parameters.externalTVLStalenessSeconds = 1 days;
        address predicted = vm.computeCreateAddress(signer, vm.getNonce(signer) + 5);
        m.adapters = new DeployLendingStrategy.AdapterSpec[](1);
        // Load the real compiled artifact rather than embedding both large code
        // blobs into each specialized manifest-test path.
        m.adapters[0].creationCode = vm.getCode("AaveV3USDCmarket.sol:AaveV3USDCAdapter");
        m.adapters[0].creationHash = keccak256(m.adapters[0].creationCode);
        m.adapters[0].runtimeHash = keccak256(vm.getDeployedCode("AaveV3USDCmarket.sol:AaveV3USDCAdapter"));
        m.adapters[0].salt = keccak256("aave-manifest-test");
        m.adapters[0].usesRewardHelper = true;
        m.adapters[0].initializer = abi.encodeCall(AaveV3USDCAdapter.initialize,
            (address(asset), pool, aToken, signer, predicted, 1000 * unit));
        DeployUsdcLendingStrategy.DeploymentResult memory r = script.run(m);
        assertEq(address(r.strategy), predicted);
        assertEq(address(r.strategy.ASSET()), address(asset));
        assertEq(r.strategy.adapterCount(), 1);
        assertEq(r.strategy.rebalanceGasEstimator(), address(estimator));
        assertTrue(r.strategy.hasRole(bytes32(0), address(this)));
        assertFalse(r.strategy.hasRole(bytes32(0), signer));
        assertFalse(r.strategy.hasRole(keccak256("PARAM_ROLE"), signer));
        assertEq(StrategyParamsModule(address(r.strategy)).assetUnitsToUsd6(unit), price / 1e12);
        AaveV3USDCAdapter adapter = AaveV3USDCAdapter(payable(r.strategy.adapters(0)));
        RewardSwapHelper helper = RewardSwapHelper(payable(adapter.swapHelper()));
        assertEq(helper.outputAsset(), address(asset));
        assertFalse(helper.legacyUsdcMode());
        assertTrue(helper.canSwap(address(reward)));
        assertTrue(helper.hasRole(keccak256("KEEPER_ROLE"), address(adapter)));
        assertFalse(helper.hasRole(bytes32(0), signer));
        assertFalse(helper.hasRole(keccak256("PARAM_ROLE"), signer));
    }

    function test_arbitrumRequiresExplicitPublicFeeSnapshot() public {
        vm.chainId(42161);
        DeployLendingStrategy script = DeployLendingStrategy(address(0x5C71));
        vm.etch(address(script), vm.getDeployedCode("DeployLendingStrategy.s.sol:DeployLendingStrategy"));
        DeployLendingStrategy.Manifest memory m;
        m.feeSource = address(0x6c);
        vm.expectRevert("ARBITRUM_FEE_SNAPSHOT_REQUIRED");
        script.run(m);
    }
}
