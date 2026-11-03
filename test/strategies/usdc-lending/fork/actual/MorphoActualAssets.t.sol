// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MorphoUsdcMultiMarketAdapter as Adapter} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol";
import {ProtocolRegistry} from "@multyr-strategies/strategies/usdc-lending/registry/ProtocolRegistry.sol";
interface IActualMorphoVault {function asset() external view returns(address);function convertToAssets(uint256) external view returns(uint256);function maxWithdraw(address) external view returns(uint256);function totalAssets() external view returns(uint256);}
contract MorphoActualAssetsTest is Test {
    using SafeERC20 for IERC20;
    string constant RPC="https://eth-mainnet.public.blastapi.io";
    uint256 constant PIN=26300000;
    uint256 firstForkPin;
    uint256 finalForkPin;
    address constant HOLDER=0xF977814e90dA44bFA03b6295A0616a897441aceC;
    event ActualMorpho(address token,address market,uint256 rpcBlock,uint8 decimals,uint256 tvl,uint256 wrapperCash,uint256 position,uint256 redeemable,uint16 rate);
    event ActualFunding(address token,address holder,uint256 beforeBalance,uint256 amount,uint256 afterBalance);
    event ActualPpsReference(address market,uint256 firstBlock,uint256 secondBlock,uint256 firstTimestamp,uint256 secondTimestamp,uint256 firstPps,uint256 secondPps,uint256 independentlyCalculatedBps);
    event ActualCappedMarketRejected(address market,uint256 rpcBlock,uint256 requestedAssets,uint256 unchangedCallerAssets,uint256 adapterAssets);
    function test_actualMorphoUsdtLifecycleAndHistoricalRate() public {_run(address(bytes20(hex"beef047a543e45807105e51a8bbefcc5950fcfba")),1000e6,HOLDER);}
    function test_actualMorphoPyusdLifecycleAndHistoricalRate() public {_run(address(bytes20(hex"19b3cd7032b8c062e8d44eacad661a0970dd8c55")),1000e6,0xAFBb1a7E9ddEf38D9bC4A220E702B18DAcaa2a62);}
    function test_actualMorphoV2PyusdLifecycleAndHistoricalRate() public {_run(address(bytes20(hex"b576765fb15505433af24fee2c0325895c559fb2")),1000e6,0xAFBb1a7E9ddEf38D9bC4A220E702B18DAcaa2a62);}
    function test_actualMorphoWethLifecycleAndHistoricalRate() public {_run(address(bytes20(hex"beef050ecd6a16c4e7bffbb52ebba7846c4b8cd4")),1e18,HOLDER);}
    function test_actualMorphoArbitrumUsdcLifecycleAndHistoricalRate() public {_runOn(42161,0x7c574174DA4b2be3f705c6244B4BfA0815a8B3Ed,1000e6,0xB38e8c17e38363aF6EbdCb3dAE12e0243582891D);}
    function test_actualMorphoArbitrumCappedCoreRejectsWithoutLoss() public {_runOn(42161,0x7e97fa6893871A2751B5fE961978DCCb2c201E65,1000e6,0xB38e8c17e38363aF6EbdCb3dAE12e0243582891D);}
    function _observe(Adapter a,address m) internal {
        address token=a.underlying();
        uint256 actual=IActualMorphoVault(m).convertToAssets(IERC20(m).balanceOf(address(a)));
        assertApproxEqAbs(a.investedAssets(),actual,2,"independent actual ERC4626 share conversion");
        assertEq(a.externalMarketTVL(),IActualMorphoVault(m).totalAssets());
        emit ActualMorpho(token,m,finalForkPin,IERC20Metadata(token).decimals(),IActualMorphoVault(m).totalAssets(),IERC20(token).balanceOf(m),a.totalAssets(),IActualMorphoVault(m).maxWithdraw(address(a)),a.currentAPYBps());
    }
    function _run(address m,uint256 amount,address holder) internal {
        _runOn(1,m,amount,holder);
    }
    function _runOn(uint256 chain,address m,uint256 amount,address holder) internal {
        finalForkPin=chain==1?PIN:520094008;firstForkPin=chain==1?PIN-1000:519994008;
        vm.createSelectFork(chain==1?RPC:"https://arbitrum-one.public.blastapi.io",firstForkPin);assertEq(block.chainid,chain);
        address token=IActualMorphoVault(m).asset();
        ProtocolRegistry r=ProtocolRegistry(deployCode("ProtocolRegistry.sol:ProtocolRegistry",abi.encode(address(this))));
        r.addVault(ProtocolRegistry.ProtocolType.MORPHO,m,"actual MetaMorpho",1000,type(uint128).max);
        Adapter a=Adapter(payable(deployCode("MorphoUsdcMultiMarket.sol:MorphoUsdcMultiMarketAdapter")));
        a.initialize(token,address(this),address(this),0,address(r));assertLe(address(a).code.length,23552);
        if(m==address(bytes20(hex"b576765fb15505433af24fee2c0325895c559fb2"))){
            address helper=deployCode("MorphoVaultV2LiquidityView.sol:MorphoVaultV2LiquidityView");
            assertLe(helper.code.length,23552);a.setVaultV2LiquidityView(helper);vm.makePersistent(helper);
        }
        this.primeActualRate(a,m,address(r));
        uint256 beforeHolder=IERC20(token).balanceOf(holder);uint256 supply=IERC20(token).totalSupply();
        uint256 beforeSelf=IERC20(token).balanceOf(address(this));assertGe(beforeHolder,amount);
        vm.prank(holder);IERC20(token).safeTransfer(address(this),amount);
        assertEq(IERC20(token).balanceOf(holder),beforeHolder-amount);assertEq(IERC20(token).balanceOf(address(this))-beforeSelf,amount);
        assertEq(IERC20(token).totalSupply(),supply);emit ActualFunding(token,holder,beforeHolder,amount,IERC20(token).balanceOf(holder));
        _observe(a,m);IERC20(token).forceApprove(address(a),amount);
        if(m==0x7e97fa6893871A2751B5fE961978DCCb2c201E65){
            uint256 unchanged=IERC20(token).balanceOf(address(this));vm.expectRevert(abi.encodeWithSelector(Adapter.AllMarketsFailed.selector,amount));a.deposit(amount);
            assertEq(IERC20(token).balanceOf(address(this)),unchanged);assertEq(a.totalAssets(),0);assertEq(IERC20(m).balanceOf(address(a)),0);
            emit ActualCappedMarketRejected(m,finalForkPin,amount,unchanged,a.totalAssets());return;
        }
        a.deposit(amount);
        assertApproxEqAbs(a.totalAssets(),amount,2);_observe(a,m);
        vm.expectRevert(bytes4(keccak256("PositionsActive()")));a.refreshFromRegistry();
        uint256 before=IERC20(token).balanceOf(address(this));uint256 paid=a.withdraw(amount/4,address(this));
        assertEq(paid,amount/4,"actual partial withdrawal must succeed");assertEq(IERC20(token).balanceOf(address(this))-before,paid);_observe(a,m);
        before=IERC20(token).balanceOf(address(this));uint256 remaining=a.totalAssets();
        a.emergencyPullAllToVault();assertApproxEqAbs(IERC20(token).balanceOf(address(this))-before,remaining,2);
        assertLe(a.totalAssets(),2);assertLe(IERC20(m).balanceOf(address(a)),2);_observe(a,m);
    }
    function primeActualRate(Adapter a,address m,address registry) external {
        require(msg.sender==address(this),"self-only reference");
        uint256 firstPps=IActualMorphoVault(m).convertToAssets(1e24);uint256 firstTime=vm.getBlockTimestamp();
        a.pokeAPYSnapshots();assertEq(a.currentAPYBps(),0,"unprimed observed rate");
        // No modified market positions or funding exist before this roll.
        vm.makePersistent(address(a));vm.makePersistent(registry);vm.rollFork(finalForkPin);
        uint256 secondPps=IActualMorphoVault(m).convertToAssets(1e24);uint256 secondTime=vm.getBlockTimestamp();
        assertGe(secondTime-firstTime,1 hours);assertLe(secondTime-firstTime,2 days);assertGe(secondPps,firstPps);
        uint256 expected=(secondPps-firstPps)*315360000000/firstPps/(secondTime-firstTime);
        if(expected>type(uint16).max)expected=type(uint16).max;
        // A genuinely flat real PPS (e.g. an idle PYUSD vault) must report zero,
        // never fabricated positive yield. This preserves production rate policy.
        assertEq(a.currentAPYBps(),expected,"independent actual PPS rate, including actual zero");
        a.pokeAPYSnapshots();assertEq(a.currentAPYBps(),expected,"authorized maintenance preserves rate");
        emit ActualPpsReference(m,firstForkPin,finalForkPin,firstTime,secondTime,firstPps,secondPps,expected);
    }
}
