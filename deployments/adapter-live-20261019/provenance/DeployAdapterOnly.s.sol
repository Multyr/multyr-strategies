// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Script,console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {AdapterFactory} from "../src/strategies/usdc-lending/factory/AdapterFactory.sol";
interface IAdapterOnlyRoles {
 function grantRole(bytes32,address) external;
 function renounceRole(bytes32,address) external;
}
contract DeployAdapterOnly is Script {
 using stdJson for string;
 string constant DIR="deployments/adapter-only-20261019/";
 address constant GOV=0x70ef444799D6FBbE0865bA598Bee6795e064a326;
 function run() external {
  uint256 pk=vm.envUint("DEPLOYER_PRIVATE_KEY");address sender=vm.addr(pk);
  string memory manifest=vm.readFile(string.concat(DIR,"manifest.json"));
  vm.startBroadcast(pk);
  AdapterFactory factory=new AdapterFactory(sender);
  string memory obj="deployedAdapterOnly";
  vm.serializeAddress(obj,"factory",address(factory));
  for(uint256 b;b<5;b++){
   string memory prefix=string.concat(".batches[",vm.toString(b),"]");
   string memory batch=vm.readFile(string.concat(DIR,manifest.readString(string.concat(prefix,".file"))));
   bytes memory data=batch.readBytes(".transactions[0].data");
   bytes memory args=new bytes(data.length-4);for(uint256 i;i<args.length;i++)args[i]=data[i+4];
   (bytes memory code,bytes32 salt,bytes memory init)=abi.decode(args,(bytes,bytes32,bytes));
   // All adapter initializers take admin as their second ABI word.
   if(b>0){require(init.length>=100,"BAD_INIT");assembly {mstore(add(init,68),sender)}}
   address fresh=factory.deployAndInit(code,salt,init);
   uint256 count=manifest.readUint(string.concat(prefix,".count"));
   for(uint256 i=1;i<count;i++){
    bytes memory callData=batch.readBytes(string.concat(".transactions[",vm.toString(i),"].data"));
    (bool ok,bytes memory reason)=fresh.call(callData);if(!ok)assembly {revert(add(reason,32),mload(reason))}
   }
   string memory key=b==0?"guard":manifest.readString(string.concat(".replacements[",vm.toString(b-1),"].key"));
   vm.serializeAddress(obj,key,fresh);
   if(b>0){IAdapterOnlyRoles r=IAdapterOnlyRoles(fresh);bytes32 param=keccak256("PARAM_ROLE");r.grantRole(bytes32(0),GOV);r.grantRole(param,GOV);r.renounceRole(param,sender);r.renounceRole(bytes32(0),sender);}
   console2.log(key,fresh);
  }
  factory.grantRole(bytes32(0),GOV);factory.grantRole(factory.DEPLOYER_ROLE(),GOV);
  factory.renounceRole(factory.DEPLOYER_ROLE(),sender);factory.renounceRole(bytes32(0),sender);
  vm.stopBroadcast();
  string memory output=vm.serializeAddress(obj,"strategy",0xa9E676D15976A1332905238ca609Dff9A484Efe0);
  vm.writeJson(output,vm.envOr("ADAPTER_DEPLOY_OUTPUT",string.concat(DIR,"deployed-addresses.json")));
 }
}
