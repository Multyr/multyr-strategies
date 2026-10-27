import fs from 'node:fs';
import {createRequire} from 'node:module';
const require=createRequire(new URL('../../multyr-periphery/keeper/package.json',import.meta.url));
const {createPublicClient,http,parseAbi}=require('viem');
const c=createPublicClient({transport:http('https://arb1.arbitrum.io/rpc')});
const hashes=['0x471052742773d3bc404f9f34271b72b95b148eb45ea0df84a773a7181b958b6d','0x7182a34925acbcb8e030b3229f6fa9527b5baa7406915299f0228a058ff9567f','0x0982d1207561044c6172ce83564676e438126b7744550490e7e82ca5dc3566ca'];
const rows=[];for(const hash of hashes){const r=await c.getTransactionReceipt({hash});rows.push({hash,status:r.status,blockNumber:String(r.blockNumber),from:r.from,to:r.to});}
const feeBalance=await c.readContract({address:'0xaf88d065e77c8cC2239327C5EDb3A432268e5831',abi:parseAbi(['function balanceOf(address) view returns(uint256)']),functionName:'balanceOf',args:['0x6917CE91cdC284e637EF51Dc844feFca83789e92']});
const feeShares=await c.readContract({address:'0x5e0cdb76487BD96Ff069Ef7F78eaDF5b5909C8cb',abi:parseAbi(['function balanceOf(address) view returns(uint256)']),functionName:'balanceOf',args:['0x6917CE91cdC284e637EF51Dc844feFca83789e92']});
fs.writeFileSync('deployments/adapter-only-20261019/receipt-checks.json',JSON.stringify({rows,feeCollectorUsdcRaw:String(feeBalance),feeCollectorCoreSharesRaw:String(feeShares)},null,2)+'\n');console.log(JSON.stringify({rows,feeCollectorUsdcRaw:String(feeBalance),feeCollectorCoreSharesRaw:String(feeShares)},null,2));
