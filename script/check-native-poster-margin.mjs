import fs from 'node:fs'; import {createRequire} from 'node:module';
const require=createRequire(new URL('../../multyr-periphery/keeper/package.json',import.meta.url));
const {createPublicClient,http,parseAbi,encodeFunctionData,encodeAbiParameters}=require('viem');
const client=createPublicClient({transport:http(process.env.CHECK_RPC,{timeout:30000,retryCount:0})});
const dir='deployments/estimator-margin-20261023';
// Public existing upkeep. Generic op 5/6, index 0: no adapter address or amount is encoded.
const destination='0xbcaC314E7237b14E11644FC6Ba73675c8c0612DF';
const rows=[];
for(const blockNumber of [516950276n,await client.getBlockNumber()]){
 const fees=await client.readContract({address:'0x000000000000000000000000000000000000006c',abi:parseAbi(['function getPricesInWei() view returns(uint256,uint256,uint256,uint256,uint256,uint256)']),functionName:'getPricesInWei',blockNumber});
 for(const op of [5,6]){
  const data=encodeFunctionData({abi:parseAbi(['function performUpkeep(bytes)']),functionName:'performUpkeep',args:[encodeAbiParameters([{type:'uint8'},{type:'uint256'}],[op,0n])]});
  const native=await client.readContract({address:'0x00000000000000000000000000000000000000c8',abi:parseAbi(['function gasEstimateL1Component(address,bool,bytes) returns(uint64,uint256,uint256)']),functionName:'gasEstimateL1Component',args:[destination,false,data],account:'0x404da3B474b8b4C87d5e3c39230c71A7237630da',blockNumber});
  const modeledPosterWei=fees[0]+164n*fees[1],nativePosterWei=native[0]*native[1];
  rows.push({blockNumber,op,strategyIndex:0,destination,calldataBytes:(data.length-2)/2,modeledPosterWei,nativePosterWei,nativeGasForL1:native[0],nativeL2Price:native[1],nativeL1Price:native[2],covered:modeledPosterWei>=nativePosterWei});
 }
}
fs.writeFileSync(dir+'/native-poster-check.json',JSON.stringify({scope:'Native RPC L1 estimates of generic keeper op 5/6 index 0 on the existing public upkeep address. No adapter amounts transmitted. Not live execution receipts or future deployed-address verification.',reference:'https://developer.arbitrum.io/arbitrum-essentials/nodeinterface/reference',rows},(_,v)=>typeof v==='bigint'?String(v):v,2));
console.log(JSON.stringify(rows,(_,v)=>typeof v==='bigint'?String(v):v));
