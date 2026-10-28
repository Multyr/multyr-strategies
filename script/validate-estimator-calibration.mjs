import fs from 'node:fs';import {createRequire} from 'node:module';
const require=createRequire(new URL('../../multyr-periphery/keeper/package.json',import.meta.url));
const {createPublicClient,http,encodeFunctionData,parseAbi,encodeAbiParameters,keccak256}=require('viem');
const dir='deployments/estimator-validation-20261022';let id=0;
async function rpc(method,params){const r=await fetch('http://127.0.0.1:8558',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({jsonrpc:'2.0',id:++id,method,params})});const j=await r.json();if(j.error)throw Error(JSON.stringify(j.error));return j.result;}
async function send(to,data){const h=await rpc('eth_sendTransaction',[{from:gov,to,data,gas:'0x989680'}]);for(let i=0;i<300;i++){const r=await rpc('eth_getTransactionReceipt',[h]);if(r){if(r.status!=='0x1')throw Error('calibration setter failed');return;}await new Promise(r=>setTimeout(r,100));}throw Error('receipt timeout');}
const a=JSON.parse(fs.readFileSync(dir+'/fork-addresses.json')),profile=JSON.parse(fs.readFileSync(dir+'/candidate-calibration.json'));
const gov='0x70ef444799D6FBbE0865bA598Bee6795e064a326';
const abi=JSON.parse(fs.readFileSync('out/ReadOnlyGasEstimator.sol/ReadOnlyGasEstimator.json')).abi;
const c=createPublicClient({transport:http('http://127.0.0.1:8558',{timeout:120000,retryCount:0})});
const fees=[43780280320n,312716288n,402360000000n,20000000n,118000n,20118000n];
await rpc('anvil_setCode',['0x000000000000000000000000000000000000006c','0x60c0600c60003960c06000f3'+encodeAbiParameters(Array(6).fill({type:'uint256'}),fees).slice(2)]);
await send(a.rebalanceGasEstimator,encodeFunctionData({abi,functionName:'setConfig',args:[profile.config]}));
await send(a.rebalanceGasEstimator,encodeFunctionData({abi,functionName:'setPathOverhead',args:[profile.pathOverhead]}));
for(const v of profile.adapterDefaults)await send(a.rebalanceGasEstimator,encodeFunctionData({abi,functionName:'setAdapterFloors',args:[v.address,v.depositDefault,v.withdrawDefault]}));
const single=[{adapter:a.venusAdapter,amount:1000000000n,deposit:true}];
const emaQuote=await c.readContract({address:a.rebalanceGasEstimator,abi,functionName:'estimate',args:[a.strategy,single,2,true]});
const sampleAbi=parseAbi(['function emaDepositGas(address) view returns(uint64)','function depositGasObservation(address) view returns(uint32,uint64)']);
const ema=await c.readContract({address:a.strategy,abi:sampleAbi,functionName:'emaDepositGas',args:[a.venusAdapter]});
const evidence=await c.readContract({address:a.strategy,abi:sampleAbi,functionName:'depositGasObservation',args:[a.venusAdapter]});
if(!emaQuote.reliable||emaQuote.usedDefaults||evidence[0]<3)throw Error('measured EMA-first proof failed');
// Force cold-start metadata only on localhost to validate the candidate fallback profile.
for(const v of profile.adapterDefaults)for(const slot of [85n,86n])await rpc('anvil_setStorageAt',[a.strategy,keccak256(encodeAbiParameters([{type:'address'},{type:'uint256'}],[v.address,slot])),'0x'+'0'.repeat(64)]);
const coldQuote=await c.readContract({address:a.rebalanceGasEstimator,abi,functionName:'estimate',args:[a.strategy,single,2,true]});
const venus=profile.adapterDefaults.find(x=>x.adapter==='venusAdapter');
if(coldQuote.l2Gas-emaQuote.l2Gas!==BigInt(venus.depositDefault)-ema)throw Error('EMA/fallback delta incorrect');
const prices=await c.readContract({address:a.rebalanceGasEstimator,abi,functionName:'validatedPrices'});if(!prices[0])throw Error('prices invalid');
const out={scope:'Candidate configuration applied ONLY on localhost; quotes use exact saved action lists with cold metadata. This is not a live deployment.',emaFirstProof:{adapter:a.venusAdapter,ema,evidence,emaQuote,coldQuote},prices,quotes:[]};
for(const source of ['cold-transactions.json','real-rate-cold-transactions.json'])for(const t of JSON.parse(fs.readFileSync(dir+'/'+source)).tiers){
 const actions=(t.preparedActions||t.actions).map(x=>({...x,amount:BigInt(x.amount)}));
 const q=await c.readContract({address:a.rebalanceGasEstimator,abi,functionName:'estimate',args:[a.strategy,actions,2,true]});
 if(!q.reliable||q.txCount!==BigInt(t.transactions.length))throw Error('quote reliability/count mismatch');
 const wei=q.executionWei+q.posterWei;const usd=(wei*prices[1]+prices[2]-1n)/prices[2];const raw=(usd+10n**12n-1n)/10n**12n;
 out.quotes.push({source,tvlUSDC:t.tvlUSDC,actions,q,beforeMarginUSDC:Number(raw)/1e6,withMarginUSDC:Number(q.costUSDC)/1e6});
 console.log(source,t.tvlUSDC,String(q.l2Gas),Number(raw)/1e6,Number(q.costUSDC)/1e6);
}
fs.writeFileSync(dir+'/calibrated-quotes.json',JSON.stringify(out,(_,v)=>typeof v==='bigint'?String(v):v,2));
console.log('EMA PROOF',String(ema),'samples',evidence[0],'default',venus.depositDefault);
