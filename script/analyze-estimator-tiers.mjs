// Analyze local EVM receipts; L1 poster cost remains the separately identified model allowance.
import fs from 'node:fs';
const dir=process.env.CALIBRATION_DIR || 'deployments/estimator-validation-20261022';
const prefix=process.env.CALIBRATION_REAL_RATES==='1'?'real-rate-':'';
const data=JSON.parse(fs.readFileSync(dir+'/'+prefix+'cold-transactions.json'));
const debug=JSON.parse(fs.readFileSync(dir+'/plan-debug-output.json')).contracts['src/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol'].StrategyRebalancePlanModule.evm.deployedBytecode;
const addresses=JSON.parse(fs.readFileSync(dir+'/fork-addresses.json'));
let id=0;
async function rpc(method,params){const r=await fetch('http://127.0.0.1:8558',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({jsonrpc:'2.0',id:++id,method,params})});const j=await r.json();if(j.error)throw Error(JSON.stringify(j.error));return j.result;}
let actual=(await rpc('eth_getCode',[addresses.rebalancePlanModule,'latest'])).slice(2),expected=debug.object;
for(const refs of Object.values(debug.immutableReferences))for(const {start,length} of refs){const mask='0'.repeat(length*2);actual=actual.slice(0,start*2)+mask+actual.slice((start+length)*2);expected=expected.slice(0,start*2)+mask+expected.slice((start+length)*2);}
if(actual!==expected)throw Error('debug bytecode mismatch');
const entry=debug.functionDebugData.fun_finalizePlan.entryPoint;
const eth=2505900000000000000000n,usdc=999900350000000000n,price=20118000n;
const marginBps=BigInt(process.env.GAS_MARGIN_BPS || '5000');
function cost(gas,poster){const wei=BigInt(gas)*price+BigInt(poster);const usd=(wei*eth+usdc-1n)/usdc;const raw=(usd+10n**12n-1n)/10n**12n;return{beforeMarginUSDC:Number(raw)/1e6,marginBps:Number(marginBps),withMarginUSDC:Number((raw*(10000n+marginBps)+9999n)/10000n)/1e6};}
const out={scope:data.scope,conditionalEconomicOverride:data.conditionalEconomicOverride,pricing:'Pinned L2 gas price and validated ETH/USDC prices; L1 is the model allowance, not measured native ArbOS receipt cost',tiers:[]};
for(const tier of data.tiers){
 const row={tvlUSDC:tier.tvlUSDC,operations:tier.actions,txCount:tier.quote.txCount,quote:tier.acceptedQuote||tier.quote,gate:tier.gateResult,previewMatchesPreparation:tier.previewMatchesPreparation,executionFailed:!!tier.executionFailed,transactions:[]};
 for(const tx of tier.transactions){
  row.transactions.push({step:tx.step,receiptGas:Number(tx.gasUsed),...tx.gasBreakdown,adapterObservations:tx.observations});
 }
 row.totals={};for(const field of ['receiptGas','grossGas','refund','intrinsic','adapterGas','finalizationGas','otherStrategyOverhead'])row.totals[field]=row.transactions.reduce((n,t)=>n+t[field],0);
 row.measuredNetPriced=cost(row.totals.receiptGas,row.quote.posterWei);
 row.measuredGrossPriced=cost(row.totals.grossGas,row.quote.posterWei);
 row.estimatedPriced=cost(row.quote.l2Gas,row.quote.posterWei);
 out.tiers.push(row);console.log(row.tvlUSDC,row.totals,row.measuredNetPriced);
 fs.writeFileSync(dir+'/'+prefix+'component-results.json',JSON.stringify(out,null,2));
}
