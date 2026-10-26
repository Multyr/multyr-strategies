// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {stdJson} from "forge-std/StdJson.sol";
import {ReadOnlyGasEstimator as GasEstimator} from "../../../../src/strategies/usdc-lending/gas/ReadOnlyGasEstimator.sol";
import {Test,console2} from "forge-std/Test.sol";
interface IRepairView {function balanceOf(address) external view returns(uint256);function approve(address,uint256) external returns(bool);function mint(uint256) external returns(uint256);function positionAssets(address) external view returns(uint256);function totalAssets() external view returns(uint256);function syncPositionAsset(address) external;function selectiveRecall(address[] calldata) external;function canRebalance() external returns(bool,uint256,int256);function transfer(address,uint256) external returns(bool);}
contract RetiredAdapterAccountingTest is Test {
 using stdJson for string;
 address constant S=0xa9E676D15976A1332905238ca609Dff9A484Efe0;
 address constant OLD=0xAba3D7015fFC9b8dEEb404389296864A1607E828;
 address constant SAFE=0x70ef444799D6FBbE0865bA598Bee6795e064a326;
 address constant DONOR=0x908756f36954f2853134259B8846c49F90E84ECe;
 address constant TOKEN=0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
 function test_reconcileRetiredPosition() public {
 if(!vm.envOr("RUN_ADAPTER_ONLY",false)){vm.skip(true);return;}
 vm.createSelectFork(vm.envString("REHEARSAL_RPC"),vm.envOr("REPAIR_FORK_BLOCK",uint256(516577617)));
 assertGt(IRepairView(S).positionAssets(OLD),0);
 if(IRepairView(OLD).totalAssets()==0){
 address vToken=0x7D8609f8da70fF9027E9bc5229Af4F6727662707;
 uint256 prior=IRepairView(vToken).balanceOf(DONOR);vm.startPrank(DONOR);assertTrue(IRepairView(TOKEN).approve(vToken,1000));assertEq(IRepairView(vToken).mint(1000),0);uint256 shares=IRepairView(vToken).balanceOf(DONOR)-prior;assertGt(shares,0);assertTrue(IRepairView(vToken).transfer(OLD,shares));vm.stopPrank();uint256 seed=IRepairView(OLD).totalAssets();assertGt(seed,0);
 }
 uint256 batchGas=gasleft();
 string memory batch=vm.readFile(vm.envOr("REPAIR_BATCH",string("deployments/accounting-repair-20261020/01-reconcile-retired-venus.safe.json")));
 for(uint i;i<vm.envOr("REPAIR_CALLS",uint256(3));i++){string memory key=string.concat(".transactions[",vm.toString(i),"]");vm.prank(SAFE);(bool success,bytes memory reason)=batch.readAddress(string.concat(key,".to")).call(batch.readBytes(string.concat(key,".data")));if(!success){assembly{revert(add(reason,32),mload(reason))}}}
 console2.log("Safe batch gas",batchGas-gasleft());
 assertEq(IRepairView(S).positionAssets(OLD),0,"phantom position cleared");assertEq(IRepairView(OLD).totalAssets(),0);
 if(vm.envOr("REPAIR_CALLS",uint256(3))==4) console2.log("Residual vToken units (totalAssets must remain zero)",IRepairView(0x7D8609f8da70fF9027E9bc5229Af4F6727662707).balanceOf(OLD));
 (bool previewOk,bytes memory preview)=S.call(abi.encodeWithSignature("previewRebalanceGas()"));assertTrue(previewOk);(GasEstimator.Action[] memory actions,)=abi.decode(preview,(GasEstimator.Action[],GasEstimator.Quote));uint256 cash=IRepairView(TOKEN).balanceOf(S);uint256 withdrawals;for(uint i;i<actions.length;i++){if(actions[i].deposit){assertLe(actions[i].amount,cash,"unfunded candidate deposit");cash-=actions[i].amount;}else{cash+=actions[i].amount;withdrawals+=actions[i].amount;}}assertGt(withdrawals,0,"candidate must fund deposits by withdrawal");console2.log("Funded candidate actions",actions.length);console2.log("Remaining modeled cash",cash); (bool ok,uint moved,int benefit)=IRepairView(S).canRebalance();console2.log("gate",ok);console2.log("moved",moved);console2.logInt(benefit);
 }
}
