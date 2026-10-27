// Local-only first/repeated deposit and full-recall gas observations.
import fs from 'node:fs';import {createRequire} from 'node:module';
const require=createRequire(new URL('../../multyr-periphery/keeper/package.json',import.meta.url));
const {encodeFunctionData,parseAbi,decodeEventLog}=require('viem');
let id=0;const url='http://127.0.0.1:8558';
async function rpc(method,params){let r=await fetch(url,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({jsonrpc:'2.0',id:++id,method,params})});let j=await r.json();if(j.error)throw Error(JSON.stringify(j.error));return j.result;}
async function receipt(h){for(let i=0;i<300;i++){let r=await rpc('eth_getTransactionReceipt',[h]);if(r)return r;await new Promise(r=>setTimeout(r,100));}throw Error('receipt timeout');}
async function batch(calls){let r=await fetch(url,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(calls.map(([method,params])=>({jsonrpc:'2.0',id:++id,method,params})))});for(let j of await r.json())if(j.error)throw Error(JSON.stringify(j.error));}
const dir='deployments/estimator-validation-20261022',a=JSON.parse(fs.readFileSync(dir+'/fork-addresses.json'));
const usdc='0xaf88d065e77c8cC2239327C5EDb3A432268e5831',core='0x5e0cdb76487BD96Ff069Ef7F78eaDF5b5909C8cb',gov='0x70ef444799D6FBbE0865bA598Bee6795e064a326';
const balanceData=encodeFunctionData({abi:parseAbi(['function balanceOf(address) view returns(uint256)']),functionName:'balanceOf',args:[a.strategy]});
const current=await rpc('eth_call',[{to:usdc,data:balanceData},'latest']);if(BigInt(current)===0n)throw Error('need nonzero probe balance');
const tr=await rpc('debug_traceCall',[{to:usdc,data:balanceData},'latest',{disableStorage:true,disableMemory:true}]);
const candidates=new Set(tr.structLogs.filter(x=>x.op==='SLOAD').map(x=>'0x'+x.stack.at(-1).replace(/^0x/,'')));
let matches=[];for(let slot of candidates)if(BigInt(await rpc('eth_getStorageAt',[usdc,slot,'latest']))===BigInt(current))matches.push(slot);
if(matches.length!==1)throw Error('ambiguous balance storage probe');const slot=matches[0];
await rpc('anvil_reset',[{forking:{jsonRpcUrl:process.env.CHECK_RPC,blockNumber:516950276}}]);
let calls=[];for(let [address,v] of Object.entries(JSON.parse(fs.readFileSync(dir+'/deployment-state.json')))){
 calls.push(['anvil_setCode',[address,v.code]],['anvil_setBalance',[address,v.balance]],['anvil_setNonce',[address,v.nonce]]);
 for(let [k,w] of Object.entries(v.storage))calls.push(['anvil_setStorageAt',[address,k,w]]);
}for(let n=0;n<calls.length;n+=100)await batch(calls.slice(n,n+100));
for(let who of [core,gov]){await rpc('anvil_impersonateAccount',[who]);await rpc('anvil_setBalance',[who,'0x56bc75e2d63100000']);}
const abi=parseAbi(['function safeAdapterDeposit(address,uint256) returns(bool)','function selectiveRecall(address[])']);
const ev=parseAbi(['event ExecutionGasObserved(address indexed adapter,uint256 gasUsed,bool deposit)']);
let base=await rpc('evm_snapshot',[]);const out={block:516950276,scope:'Cold separate local EVM transactions; 1,000 USDC first and repeated deposits/full recalls, real protocol code and rate reads; gas observations exclude outer strategy and intrinsic costs',adapters:[]};
for(let key of ['aaveAdapter','morphoAdapter','cometAdapter','eulerAdapter','dolomiteAdapter','fluidAdapter','venusAdapter']){
 await rpc('evm_revert',[base]);base=await rpc('evm_snapshot',[]);let row={adapter:key,address:a[key],cycles:[]};out.adapters.push(row);
 for(let cycle=0;cycle<5;cycle++){
  await rpc('anvil_setStorageAt',[usdc,slot,'0x'+(1000n*1000000n).toString(16).padStart(64,'0')]);
  if(BigInt(await rpc('eth_call',[{to:usdc,data:balanceData},'latest']))!==1000000000n)throw Error('funding verification failed');
  let samples=[];
  for(let deposit of [true,false]){
   let data=encodeFunctionData({abi,functionName:deposit?'safeAdapterDeposit':'selectiveRecall',args:deposit?[a[key],1000000000n]:[[a[key]]]});
   let h=await rpc('eth_sendTransaction',[{from:deposit?core:gov,to:a.strategy,data,gas:'0x55d4a80'}]);let r=await receipt(h);
   if(r.status!=='0x1')throw Error(key+' operation reverted');
   let observed=[];for(let log of r.logs)try{observed.push(decodeEventLog({abi:ev,data:log.data,topics:log.topics}).args)}catch{}
   if(observed.length!==1)throw Error(key+' no unique observation');
   samples.push({deposit,gasUsed:String(observed[0].gasUsed),receiptGas:parseInt(r.gasUsed,16)});
  }
  row.cycles.push(samples);console.log(key,cycle,samples.map(x=>x.gasUsed).join('/'));
  fs.writeFileSync(dir+'/adapter-roundtrips.json',JSON.stringify(out,null,2));
 }
}
