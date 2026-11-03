// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {DeployLendingStrategy} from "../../../script/DeployLendingStrategy.s.sol";
import {MorphoUsdcMultiMarketAdapter as Adapter} from "../../../src/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol";
import {MorphoVaultV2LiquidityView as LiquidityView} from "../../../src/strategies/usdc-lending/adapters/lending/MorphoVaultV2LiquidityView.sol";
import {MockUSDCMorpho,MockMorphoVault} from "./adapters/MorphoAdapter.t.sol";
import {SimpleProtocolRegistry} from "../../helpers/SimpleProtocolRegistry.sol";

contract MorphoDeploymentWiringHarness is DeployLendingStrategy {
    function wire(address adapter) external {_configureMorphoV2LiquidityView(adapter,keccak256(type(LiquidityView).runtimeCode));}
    function wireWithHash(address adapter,bytes32 reviewedHash) external {_configureMorphoV2LiquidityView(adapter,reviewedHash);}
}
/// Controlled deployment regression only. No live-market acceptance is claimed.
contract MorphoDeploymentWiringTest is Test {
    MorphoDeploymentWiringHarness harness;
    Adapter adapter;
    MockUSDCMorpho token;
    function setUp() public {
        harness=MorphoDeploymentWiringHarness(address(0x5C71));
        vm.etch(address(harness),vm.getDeployedCode("MorphoDeploymentWiring.t.sol:MorphoDeploymentWiringHarness"));
        token=new MockUSDCMorpho();MockMorphoVault market=new MockMorphoVault(address(token));
        SimpleProtocolRegistry registry=new SimpleProtocolRegistry();registry.addVault(SimpleProtocolRegistry.ProtocolType.MORPHO,address(market),"deployment fixture",10000,1_000_000e6);
        adapter=Adapter(payable(deployCode("MorphoUsdcMultiMarket.sol:MorphoUsdcMultiMarketAdapter")));
        adapter.initialize(address(token),address(harness),address(this),0,address(registry));
    }
    function test_autoWiresAuditedViewAndIsIdempotent() public {
        assertEq(adapter.vaultV2LiquidityView(),address(0));harness.wire(address(adapter));address helper=adapter.vaultV2LiquidityView();
        assertEq(helper.codehash,keccak256(type(LiquidityView).runtimeCode));harness.wire(address(adapter));assertEq(adapter.vaultV2LiquidityView(),helper);
    }
    function test_preservesExplicitReviewedView() public {
        LiquidityView helper=new LiquidityView();vm.prank(address(harness));adapter.setVaultV2LiquidityView(address(helper));
        harness.wire(address(adapter));assertEq(adapter.vaultV2LiquidityView(),address(helper));
    }
    function test_rejectsUnreviewedViewRuntime() public {
        vm.prank(address(harness));adapter.setVaultV2LiquidityView(address(token));
        vm.expectRevert("V2_VIEW_RUNTIME_HASH");harness.wire(address(adapter));
    }
    function test_otherAdapterFamilyDoesNotRequireMorphoGetter() public {harness.wire(address(token));}
    function test_manifestMustIndependentlyPinReviewedHelperRuntime() public {
        vm.expectRevert("V2_VIEW_MANIFEST_HASH");harness.wireWithHash(address(adapter),bytes32(0));assertEq(adapter.vaultV2LiquidityView(),address(0));
        vm.expectRevert("V2_VIEW_MANIFEST_HASH");harness.wireWithHash(address(adapter),bytes32(uint256(1)));assertEq(adapter.vaultV2LiquidityView(),address(0));
    }
    function test_doesNotBypassConfigurationAuthority() public {
        bytes32 paramRole=adapter.PARAM_ROLE();vm.prank(address(harness));adapter.renounceRole(paramRole,address(harness));
        vm.prank(address(harness));adapter.renounceRole(bytes32(0),address(harness));
        vm.expectRevert();harness.wire(address(adapter));assertEq(adapter.vaultV2LiquidityView(),address(0));
    }
}
