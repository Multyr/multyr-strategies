import fs from 'node:fs'; import {createRequire} from 'node:module';
const require=createRequire(new URL('../../multyr-periphery/keeper/package.json',import.meta.url));
const {createPublicClient,http,parseAbi,encodeFunctionData,encodeAbiParameters}=require('viem');
const client=createPublicClient({transport:http(process.env.CHECK_RPC,{timeout:30000,retryCount:0})});
const dir='deployments/estimator-margin-20261023';
// Public existing upkeep. Generic op 5/6, index 0: no adapter address or amount is encoded.
const destination='0xbcaC314E7237b14E11644FC6Ba73675c8c0612DF';
const blockNumber=await client.getBlockNumber();
const block=await client.getBlock({blockNumber});
const fees=await client.readContract({address:'0x000000000000000000000000000000000000006c',abi:parseAbi(['function getPricesInWei() view returns(uint256,uint256,uint256,uint256,uint256,uint256)']),functionName:'getPricesInWei',blockNumber});
fs.writeFileSync(dir+'/latest-fork-inputs.json',JSON.stringify({blockNumber,blockHash:block.hash,timestamp:block.timestamp,fees},(_,v)=>typeof v==='bigint'?String(v):v,2));
console.log('Captured current public block and fee inputs.');
