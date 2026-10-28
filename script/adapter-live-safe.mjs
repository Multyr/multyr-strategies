import fs from 'node:fs';
import {createRequire} from 'node:module';
const require=createRequire(new URL('../../multyr-periphery/keeper/package.json',import.meta.url));
const {createPublicClient,http,parseAbi,keccak256,toHex}=require('viem');
const source='deployments/adapter-only-20261019',dir='deployments/adapter-live-20261019';fs.mkdirSync(dir,{recursive:true});
const deployed=JSON.parse(fs.readFileSync(`${source}/deployed-addresses.json`));
const old=JSON.parse(fs.readFileSync(`${source}/manifest.json`));
const broadcast=JSON.parse(fs.readFileSync('broadcast/DeployAdapterOnly.s.sol/42161/run-latest.json'));
if(broadcast.receipts.length!==broadcast.transactions.length||!broadcast.receipts.length||broadcast.receipts.some(r=>BigInt(r.status)!==1n))throw Error('Deployment receipts incomplete');
const c=createPublicClient({transport:http(process.env.RPC_URL||'https://arb1.arbitrum.io/rpc',{timeout:30000})});
const blockNumber=await c.getBlockNumber();
const read=(address,sig,args=[])=>c.readContract({address,abi:parseAbi(['function '+sig]),functionName:sig.split('(')[0],args,blockNumber});
const gov='0x70ef444799D6FBbE0865bA598Bee6795e064a326',param=keccak256(toHex('PARAM_ROLE')),admin='0x'+'00'.repeat(32),deployer=broadcast.transactions[0].transaction.from;
const check=(ok,m)=>{if(!ok)throw Error(m)};
check(await c.getChainId()===42161,'Wrong chain');
check(deployed.strategy.toLowerCase()===old.strategy.toLowerCase(),'Strategy changed');
const mappings=[[old.guard,deployed.guard]];
const replacements=[];
for(const r of old.replacements){
 const fresh=deployed[r.key];mappings.push([r.fresh,fresh]);
 check((await read(fresh,'vault() view returns(address)')).toLowerCase()===old.strategy.toLowerCase(),'Wrong vault');
 for(const role of [admin,param]){check(await read(fresh,'hasRole(bytes32,address) view returns(bool)',[role,gov]),'Safe missing role');check(!await read(fresh,'hasRole(bytes32,address) view returns(bool)',[role,deployer]),'Deployer retains role');}
 if(r.key!=='venusAdapter')check(await read(fresh,'hasRole(bytes32,address) view returns(bool)',[param,old.upkeep]),'Missing upkeep APY permission');
 check(await read(fresh,'totalAssets() view returns(uint256)')===0n,'Fresh adapter not empty');
 check(await read(old.strategy,'enabled(address) view returns(bool)',[r.old]),'Old adapter already disabled');
 check(!await read(old.strategy,'isAdapter(address) view returns(bool)',[fresh]),'Replacement already registered');
 replacements.push({...r,fresh,runtimeCodeHash:keccak256(await c.getCode({address:fresh,blockNumber}))});
}
check(await read(deployed.venusAdapter,'blocksPerYear() view returns(uint256)')===31536000n,'Wrong Venus annualization');
check(await read(deployed.factory,'hasRole(bytes32,address) view returns(bool)',[admin,gov]),'Factory owner not Safe');
check(!await read(deployed.factory,'hasRole(bytes32,address) view returns(bool)',[admin,deployer]),'Factory deployer admin remains');
check(await read(old.strategy,'rebalancePlanPhase() view returns(uint8)')===0,'Active rebalance');
const batch=JSON.parse(fs.readFileSync(`${source}/05-atomic-adapter-swap.safe.json`));
for(const t of batch.transactions){for(const [from,to] of mappings){if(t.to.toLowerCase()===from.toLowerCase())t.to=to;t.data=t.data.toLowerCase().replaceAll('0'.repeat(24)+from.slice(2).toLowerCase(),'0'.repeat(24)+to.slice(2).toLowerCase());}}
batch.createdAt=Date.now();batch.meta.name='Activate deployed adapter fixes on existing strategy';
batch.meta.description='All calls must execute atomically. Recall four adapters into same strategy; assert drained; register deployed replacements; update upkeep APY targets; correct Euler capacity; calibrate estimator. Allocation policy unchanged.';
fs.writeFileSync(`${dir}/01-activate-adapter-fixes.safe.json`,JSON.stringify(batch,null,2)+'\n');
const manifest={status:'deployed; awaiting final fork rehearsal and Safe activation',chainId:42161,strategy:old.strategy,upkeep:old.upkeep,factory:deployed.factory,guard:deployed.guard,replacements,batches:[{file:'01-activate-adapter-fixes.safe.json',count:batch.transactions.length}],blockNumber:String(blockNumber),allocationPolicyChanged:false,deploymentTransactions:broadcast.receipts.map(r=>({hash:r.transactionHash,blockNumber:String(BigInt(r.blockNumber))})),governance:gov};
fs.writeFileSync(`${dir}/manifest.json`,JSON.stringify(manifest,null,2)+'\n');
fs.writeFileSync(`${dir}/deployment-receipts.json`,JSON.stringify(broadcast,null,2)+'\n');
console.log(JSON.stringify({blockNumber:String(blockNumber),replacements,calls:batch.transactions.length,transactionsConfirmed:broadcast.receipts.length},null,2));
