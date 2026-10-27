// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test,console2} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
interface IAdapterOnlyView {
 function totalAssets() external view returns(uint256);
 function enabled(address) external view returns(bool);
 function vault() external view returns(address);
 function adapterCount() external view returns(uint256);
 function blocksPerYear() external view returns(uint256);
 function maxCapacity() external view returns(uint256);
 function hasRole(bytes32,address) external view returns(bool);
 function isPokeTarget(address) external view returns(bool);
}
contract AdapterOnlySafeTest is Test {
 using stdJson for string;
 string constant DIR="deployments/adapter-only-20261019/";
 address constant GOV=0x70ef444799D6FBbE0865bA598Bee6795e064a326;
 address constant STRATEGY=0xa9E676D15976A1332905238ca609Dff9A484Efe0;
 address constant UPKEEP=0xbcaC314E7237b14E11644FC6Ba73675c8c0612DF;
 address constant KEEPER=0x404da3B474b8b4C87d5e3c39230c71A7237630da;
 function test_exactAdapterOnlySafeFiles() public {
  if(!vm.envOr("RUN_ADAPTER_ONLY",false)){vm.skip(true);return;}
  string memory manifest=vm.readFile(string.concat(DIR,"manifest.json"));
  vm.createSelectFork(vm.envString("REHEARSAL_RPC"),vm.parseUint(manifest.readString(".blockNumber")));
  uint256 beforeNav=IAdapterOnlyView(STRATEGY).totalAssets();
  bytes32 strategyHash=STRATEGY.codehash;
  for(uint256 b;b<6;b++){
   string memory prefix=string.concat(".batches[",vm.toString(b),"]");
   string memory batch=vm.readFile(string.concat(DIR,manifest.readString(string.concat(prefix,".file"))));
   uint256 count=manifest.readUint(string.concat(prefix,".count"));
   uint256 start=gasleft();
   for(uint256 i;i<count;i++){
    string memory key=string.concat(".transactions[",vm.toString(i),"]");
    vm.prank(GOV);
    (bool ok,bytes memory reason)=batch.readAddress(string.concat(key,".to")).call(batch.readBytes(string.concat(key,".data")));
    if(!ok){console2.log("Failed batch/call",b,i);assembly {revert(add(reason,32),mload(reason))}}
   }
   console2.log("Batch gas",b,start-gasleft());
  }
  assertEq(STRATEGY.codehash,strategyHash);
  assertGe(IAdapterOnlyView(STRATEGY).totalAssets()+400,beforeNav,"lost NAV during recall");
  assertEq(IAdapterOnlyView(STRATEGY).adapterCount(),11);
  for(uint256 i;i<4;i++){
   string memory key=string.concat(".replacements[",vm.toString(i),"]");
   address old=manifest.readAddress(string.concat(key,".old"));
   address fresh=manifest.readAddress(string.concat(key,".fresh"));
   assertFalse(IAdapterOnlyView(STRATEGY).enabled(old));assertTrue(IAdapterOnlyView(STRATEGY).enabled(fresh));
   assertLe(IAdapterOnlyView(old).totalAssets(),100);
   assertEq(IAdapterOnlyView(fresh).vault(),STRATEGY);
   assertTrue(IAdapterOnlyView(fresh).hasRole(bytes32(0),GOV));
   if(i==0)assertEq(IAdapterOnlyView(fresh).blocksPerYear(),31536000);
   else {assertFalse(IAdapterOnlyView(UPKEEP).isPokeTarget(old));assertTrue(IAdapterOnlyView(UPKEEP).isPokeTarget(fresh));assertTrue(IAdapterOnlyView(fresh).hasRole(keccak256("PARAM_ROLE"),UPKEEP));vm.prank(UPKEEP);(bool pokeOk,)=fresh.call(abi.encodeWithSignature("pokeAPYSnapshots()"));assertTrue(pokeOk,"upkeep cannot poke replacement");}
  }
  assertGt(IAdapterOnlyView(0x543E0Bb27FDb271Ac87A9c0963C9498131549059).maxCapacity(),0);
  vm.prank(KEEPER);(bool ok,)=STRATEGY.call(abi.encodeWithSignature("deployIdle()"));assertTrue(ok,"keeper deployIdle failed after swap");
  assertGe(IAdapterOnlyView(STRATEGY).totalAssets()+1000,beforeNav,"lost NAV after keeper deployment");
  console2.log("NAV preserved",beforeNav);
 }
}
