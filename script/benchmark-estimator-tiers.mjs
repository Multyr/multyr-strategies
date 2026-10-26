// LOCAL FORK ONLY. Load states exported by EstimatorTierCalibration.fork.t.sol.
// No wallet keys or live RPC endpoints are used by this script.
import fs from 'node:fs';
import { createRequire } from 'node:module';
const require = createRequire(new URL('../../multyr-periphery/keeper/package.json', import.meta.url));
const {createPublicClient,http,parseAbi,encodeFunctionData,encodeAbiParameters,decodeEventLog,keccak256,toBytes}=require('viem');
const url='http://127.0.0.1:8558';
const client=createPublicClient({transport:http(url,{timeout:120000,retryCount:0})});
let id=0;
async function rpc(method,params){const r=await fetch(url,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({jsonrpc:'2.0',id:++id,method,params})});const j=await r.json();if(j.error)throw Error(JSON.stringify(j.error));return j.result;}
async function receipt(hash){
 for(let i=0;i<300;i++){
  const r=await rpc('eth_getTransactionReceipt',[hash]);
  if(r)return {...r,status:r.status==='0x1'?'success':'reverted',gasUsed:BigInt(r.gasUsed)};
  await new Promise(resolve=>setTimeout(resolve,100));
 }
 throw Error('missing receipt');
}
async function batch(calls){if(!calls.length)return;const r=await fetch(url,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(calls.map(([method,params])=>({jsonrpc:'2.0',id:++id,method,params})))});for(const j of await r.json())if(j.error)throw Error(JSON.stringify(j.error));}
const dir=process.env.CALIBRATION_DIR || 'deployments/estimator-validation-20261022';
const realRates=process.env.CALIBRATION_REAL_RATES==='1';
const prefix=realRates?'real-rate-':'';
const addresses=JSON.parse(fs.readFileSync(dir+'/fork-addresses.json'));
const strategy=addresses.strategy,upkeep=addresses.strategyUpkeep;
const keeper='0x404da3B474b8b4C87d5e3c39230c71A7237630da';
const gate=JSON.parse(fs.readFileSync('out/StrategyRebalanceGateModule.sol/StrategyRebalanceGateModule.json')).abi;
const abi=parseAbi(['function performUpkeep(bytes)','function rebalancePlanPhase() view returns(uint8)','function rebalancePlanConsecutiveFailures() view returns(uint8)','function lastSnapshotTs() view returns(uint64)','function rebalancePlanAdapters(uint256) view returns(address)','function rebalancePlanAmounts(uint256) view returns(uint256)','function rebalancePlanTotalActions() view returns(uint8)']);
const debug=JSON.parse(fs.readFileSync(dir+'/plan-debug-output.json')).contracts['src/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol'].StrategyRebalancePlanModule.evm.deployedBytecode;
const entry=debug.functionDebugData.fun_finalizePlan.entryPoint;
const eventAbi=parseAbi(['event ExecutionGasObserved(address indexed adapter,uint256 gasUsed,bool deposit)']);
const quoteAbi=parseAbi(['event RebalanceGasEvaluated(bytes32 indexed actionsHash,uint256 costUSDC,uint256 l2Gas,uint256 posterWei,bool reliable)']);
const prices=[43780280320n,312716288n,402360000000n,20000000n,118000n,20118000n];
const stringify=x=>JSON.stringify(x,(_,v)=>typeof v==='bigint'?v.toString():v,2);
const result={realRates,conditionalEconomicOverride:realRates,block:516950276,scope:'Separate local EVM transactions; hypothetical starting books and APY overrides; ArbGasInfo stubbed with pinned prices; not native ArbOS receipts',tiers:[]};
if(!process.env.CHECK_RPC)throw Error('CHECK_RPC is required to reset the local fork');
await rpc('anvil_reset',[{forking:{jsonRpcUrl:process.env.CHECK_RPC,blockNumber:516950276}}]);
const startTime=Number((await client.getBlock()).timestamp)+1;
let base=await rpc('evm_snapshot',[]);
for(let tier=0;tier<5;tier++){
 await rpc('evm_revert',[base]);base=await rpc('evm_snapshot',[]);
 const state=JSON.parse(fs.readFileSync(`${dir}/deployment-state.json`));
 const changes=JSON.parse(fs.readFileSync(`${dir}/tier-${tier}-state.json`));
 for(const [a,v] of Object.entries(changes))state[a]={...state[a],...v,storage:{...state[a]?.storage,...v.storage}};
 let calls=[];
 for(const [address,a] of Object.entries(state)){
  calls.push(['anvil_setCode',[address,a.code]],['anvil_setBalance',[address,a.balance]],['anvil_setNonce',[address,a.nonce]]);
  for(const [slot,value] of Object.entries(a.storage))calls.push(['anvil_setStorageAt',[address,slot,value]]);
 }
 for(let n=0;n<calls.length;n+=100)await batch(calls.slice(n,n+100));
 await rpc('anvil_setCode',['0x000000000000000000000000000000000000006c','0x60c0600c60003960c06000f3'+encodeAbiParameters(Array(6).fill({type:'uint256'}),prices).slice(2)]);
 await rpc('anvil_impersonateAccount',[keeper]);await rpc('anvil_setBalance',[keeper,'0x56bc75e2d63100000']);
 // Forge exports touched accounts only; recreate the untouched coordinator with
 // its exact compiled runtime and initialize its single-strategy registration.
 if(!state[upkeep.toLowerCase()]){
  const runtime=JSON.parse(fs.readFileSync('out/LendingStrategyUpkeep.sol/StrategyUpkeep.json')).deployedBytecode.object;
  await rpc('anvil_setCode',[upkeep,runtime]);
  await rpc('anvil_setStorageAt',[upkeep,'0x'+'0'.repeat(64),'0x'+keeper.slice(2).toLowerCase().padStart(64,'0')]);
  const init=encodeFunctionData({abi:parseAbi(['function addStrategy(address)']),functionName:'addStrategy',args:[strategy]});
  await rpc('evm_setNextBlockTimestamp',[startTime]);
  const h=await rpc('eth_sendTransaction',[{from:keeper,to:upkeep,data:init,gas:'0xf4240'}]);
  const r=await receipt(h);if(r.status!=='success')throw Error('upkeep initialization failed');
 }

 // The export omits role slots never read in the Forge direct-call scenario.
 const gov='0x70ef444799D6FBbE0865bA598Bee6795e064a326';
 await rpc('anvil_impersonateAccount',[gov]);await rpc('anvil_setBalance',[gov,'0x56bc75e2d63100000']);
 const roleData=encodeFunctionData({abi:parseAbi(['function grantRole(bytes32,address)']),functionName:'grantRole',args:[keccak256(toBytes('KEEPER_ROLE')),upkeep]});
 await rpc('evm_setNextBlockTimestamp',[startTime+1]);
 const roleHash=await rpc('eth_sendTransaction',[{from:gov,to:strategy,data:roleData,gas:'0xf4240'}]);
 if((await receipt(roleHash)).status!=='success')throw Error('restore upkeep role failed');
 let originalGateResult;
 if(realRates){
  for(const key of ['aaveAdapter','fluidAdapter','morphoAdapter','dolomiteAdapter']){
   const call=encodeFunctionData({abi:parseAbi(['function setAPYOverrideBps(uint16)']),functionName:'setAPYOverrideBps',args:[0]});
   const h=await rpc('eth_sendTransaction',[{from:gov,to:addresses[key],data:call,gas:'0xf4240'}]);
   if((await receipt(h)).status!=='success')throw Error('clear APY override failed');
  }
  const patched=JSON.parse(fs.readFileSync(dir+'/real-rate-gate-output.json')).contracts['src/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol'].StrategyRebalanceGateModule;
  const args=['0xaf88d065e77c8cC2239327C5EDb3A432268e5831','0x5e0cdb76487BD96Ff069Ef7F78eaDF5b5909C8cb',addresses.paramsModule,addresses.scoringModule,addresses.adapterOpsModule];
  const h=await rpc('eth_sendTransaction',[{from:gov,data:'0x'+patched.evm.bytecode.object+encodeAbiParameters(Array(5).fill({type:'address'}),args).slice(2),gas:'0x1c9c380'}]);
  const deployed=await receipt(h);if(deployed.status!=='success')throw Error('local gate instrumentation failed');
  originalGateResult=await client.readContract({address:strategy,abi:gate,functionName:'canRebalance'});
  const before=await client.readContract({address:strategy,abi:gate,functionName:'previewRebalanceGas'});
  await rpc('anvil_setCode',[addresses.rebalanceGateModule,await rpc('eth_getCode',[deployed.contractAddress,'latest'])]);
  const after=await client.readContract({address:strategy,abi:gate,functionName:'previewRebalanceGas'});
  if(stringify(before)!==stringify(after))throw Error('instrumentation changed priced plan');
 }
 const executionStartTime=Number(BigInt((await rpc('eth_getBlockByNumber',['latest',false])).timestamp))+1;
 let actual=(await rpc('eth_getCode',[addresses.rebalancePlanModule,'latest'])).slice(2),expected=debug.object;
 for(const refs of Object.values(debug.immutableReferences))for(const {start,length} of refs){const mask='0'.repeat(length*2);actual=actual.slice(0,start*2)+mask+actual.slice((start+length)*2);expected=expected.slice(0,start*2)+mask+expected.slice((start+length)*2);}
 if(actual!==expected)throw Error('debug bytecode mismatch');
 const [actions,quote]=await client.readContract({address:strategy,abi:gate,functionName:'previewRebalanceGas'});
 const gateResult=await client.readContract({address:strategy,abi:gate,functionName:'canRebalance'});
 const row={tier,tvlUSDC:[10000,100000,500000,2000000,6000000][tier],actions,quote,gateResult,originalGateResult,transactions:[]};result.tiers.push(row);
 console.log('TIER',tier,'eligible',gateResult[0],'operations',actions.length);
 if(gateResult[0])for(let step=0;step<10;step++){
  if(step>0&&await client.readContract({address:strategy,abi,functionName:'rebalancePlanPhase'})===0)break;
  const calldata=encodeFunctionData({abi,functionName:'performUpkeep',args:[encodeAbiParameters([{type:'uint8'},{type:'uint256'}],[step===0?5:6,0n])]});
  await rpc('evm_setNextBlockTimestamp',[executionStartTime+step]);await rpc('anvil_setNextBlockBaseFeePerGas',['0x'+prices[5].toString(16)]);
  const hash=await rpc('eth_sendTransaction',[{from:keeper,to:upkeep,data:calldata,gas:'0x55d4a80',gasPrice:'0x'+prices[5].toString(16)}]);
  const txReceipt=await receipt(hash);
  const observations=[];
  for(const log of txReceipt.logs)try{observations.push(decodeEventLog({abi:eventAbi,data:log.data,topics:log.topics}).args)}catch{}
  if(step===0){
   row.preparedActions=[];
   const count=await client.readContract({address:strategy,abi,functionName:'rebalancePlanTotalActions'});
   for(let i=0;i<count;i++){
    const adapter=await client.readContract({address:strategy,abi,functionName:'rebalancePlanAdapters',args:[BigInt(i)]});
    const raw=await client.readContract({address:strategy,abi,functionName:'rebalancePlanAmounts',args:[BigInt(i)]});
    row.preparedActions.push({adapter,amount:raw&((1n<<255n)-1n),deposit:raw>>255n===1n});
   }
   row.previewMatchesPreparation=stringify(actions)===stringify(row.preparedActions);
   for(const log of txReceipt.logs)try{row.acceptedQuote=decodeEventLog({abi:quoteAbi,data:log.data,topics:log.topics}).args}catch{}
  }
  const phase=await client.readContract({address:strategy,abi,functionName:'rebalancePlanPhase'});
  const failures=await client.readContract({address:strategy,abi,functionName:'rebalancePlanConsecutiveFailures'});
  const final=step>0&&phase===0&&failures===0;
  const trace=await rpc('debug_traceTransaction',[hash,{disableStorage:true,disableMemory:true,disableStack:!final}]);
  const last=trace.structLogs.at(-1);
  const grossGas=90000000-Number(last.gas)+Number(last.gasCost);
  let finalizationGas=0;
  if(final){const matches=[];
   for(let i=0;i<trace.structLogs.length;i++){
    const l=trace.structLogs[i];if(l.depth!==3||l.pc!==entry)continue;
    const ret=parseInt(l.stack.at(-1),16);
    const end=trace.structLogs.findIndex((x,j)=>j>i&&x.depth===3&&x.pc===ret);
    if(end>=0)matches.push(Number(l.gas)-Number(trace.structLogs[end].gas));
   }
   if(matches.length!==1)throw Error('ambiguous finalization '+JSON.stringify(matches));
   finalizationGas=matches[0];
  }
  const intrinsic=21000+calldata.slice(2).match(/../g).reduce((n,b)=>n+(b==='00'?4:16),0);
  const adapterGas=observations.reduce((n,o)=>n+Number(o.gasUsed),0);
  const gasBreakdown={grossGas,refund:grossGas-Number(txReceipt.gasUsed),intrinsic,adapterGas,finalizationGas,otherStrategyOverhead:grossGas-intrinsic-adapterGas-finalizationGas};
  row.transactions.push({step,hash,status:txReceipt.status,gasUsed:txReceipt.gasUsed,observations,phase,failures,calldata,gasBreakdown});
  fs.writeFileSync(`${dir}/${prefix}cold-transactions.json`,stringify(result));
  console.log('TX',step,txReceipt.status,String(txReceipt.gasUsed),'phase',phase,'failures',failures);
  if(txReceipt.status!=='success'||failures>0||(step===0&&phase===0)){row.executionFailed=true;break;}
 }
 fs.writeFileSync(`${dir}/${prefix}cold-transactions.json`,stringify(result));
}
