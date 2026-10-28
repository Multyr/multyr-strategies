// Read-only live checks and unsigned Safe Transaction Builder files. Never signs.
import fs from 'node:fs';
import { createRequire } from 'node:module';
const require = createRequire(new URL('../../multyr-periphery/keeper/package.json', import.meta.url));
const { createPublicClient, http, parseAbi, encodeFunctionData, keccak256, toHex } = require('viem');
const dir = process.env.RELEASE_DIR || 'deployments/replacement-20261017';
const env = Object.fromEntries(fs.readFileSync(`${dir}/public.env`, 'utf8').split('\n').filter(x => x && !x.startsWith('#')).map(x => { const i=x.indexOf('='); return [x.slice(0,i),x.slice(i+1)]; }));
const book = JSON.parse(fs.readFileSync(`${dir}/addresses.json`, 'utf8'));
const client = createPublicClient({transport:http('https://arb1.arbitrum.io/rpc',{batch:true,timeout:30000})});
const blockNumber = await client.getBlockNumber();
const read = (address,signature,args=[]) => client.readContract({address,abi:parseAbi([`function ${signature}`]),functionName:signature.split('(')[0],args,blockNumber});
const equal = (a,b) => String(a).toLowerCase() === String(b).toLowerCase();
const check = (ok,label) => { if(!ok) throw Error(label); };
check(await client.getChainId() === 42161,'Wrong chain');
check(book.copiedSourceSettings === false,'Unexpected copied settings');
const gov=env.GOVERNANCE_ADDRESS, router=env.STRATEGY_ROUTER_ADDRESS, old=env.SOURCE_STRATEGY, fresh=book.strategy;
const admin='0x'+'00'.repeat(32), param=keccak256(toHex('PARAM_ROLE')), keeper=keccak256(toHex('KEEPER_ROLE')), coreRole=keccak256(toHex('CORE_ROLE'));
const broadcast=JSON.parse(fs.readFileSync('broadcast/DeployUsdcLendingStrategy.s.sol/42161/run-latest.json','utf8'));
check(broadcast.receipts.length === broadcast.transactions.length && broadcast.receipts.length > 0 && broadcast.receipts.every(x=>BigInt(x.status)===1n),'Unconfirmed deployment receipts');
const deployer=broadcast.transactions[0].transaction.from;
const checked=[];
for(const [key,address] of Object.entries(book)) {
  if(typeof address !== 'string' || !/^0x[0-9a-fA-F]{40}$/.test(address) || key.startsWith('settingsSource')) continue;
  const code=await client.getCode({address,blockNumber});check(code && code!=='0x',`Missing code: ${key}`);
  checked.push({key,address,codehash:keccak256(code)});
}
check(equal(await read(router,'owner() view returns(address)'),gov),'Router owner');
check(equal(await read(fresh,'core() view returns(address)'),env.VAULT_ADDRESS),'Core binding');
check(equal(await read(fresh,'rebalanceGasEstimator() view returns(address)'),env.REBALANCE_GAS_ESTIMATOR),'Estimator binding');
check(await read(fresh,'adapterCount() view returns(uint256)')===7n,'Adapter count');
if(process.env.CALIBRATE_ADAPTERS === 'true') {
  check(await read(fresh,'adapterMaxExposureBps() view returns(uint16)')===2500,'Exposure must be 25%');
  check(await read(fresh,'maxIdleAfterDepositBps() view returns(uint16)')===10000,'Idle retention configuration');
  check(await read(fresh,'maxIdleBootstrapBps() view returns(uint16)')===10000,'Bootstrap idle retention');
  check(Number(await read(fresh,'maxAdaptersPerAllocation() view returns(uint16)'))>=4,'Insufficient adapter slots');
  check(await read(book.venusAdapter,'blocksPerYear() view returns(uint256)')===31536000n,'Venus time units');
  for (const key of ['aaveAdapter','morphoAdapter','cometAdapter','eulerAdapter','dolomiteAdapter','fluidAdapter','venusAdapter'])
    check(await read(book[key],'maxCapacity() view returns(uint256)')>0n,`${key} zero capacity`);
}

check(!await read(fresh,'paused() view returns(bool)'),'Paused');
check(!await read(fresh,'depositsDisabled() view returns(bool)'),'Deposits disabled');
for(const [role,who,want] of [[admin,gov,true],[param,gov,true],[admin,deployer,false],[param,deployer,false],[keeper,deployer,false],[keeper,book.strategyUpkeep,true],[keeper,env.KEEPER_SIGNER_ADDRESS,true],[coreRole,env.VAULT_ADDRESS,true],[coreRole,router,true]]) {
  check(await read(fresh,'hasRole(bytes32,address) view returns(bool)',[role,who])===want,`Strategy role mismatch ${role} ${who}`);
}
for(const key of ['aaveAdapter','morphoAdapter','cometAdapter','eulerAdapter','dolomiteAdapter','fluidAdapter','venusAdapter','aaveRateProvider','adapterFactory']) {
  check(await read(book[key],'hasRole(bytes32,address) view returns(bool)',[admin,gov]),`${key} governance`);
  check(!await read(book[key],'hasRole(bytes32,address) view returns(bool)',[admin,deployer]),`${key} deployer remains`);
}
check(!await read(fresh,'hasRole(bytes32,address) view returns(bool)',[keccak256(toHex('BOOTSTRAP_ROLE')),book.bootstrapper]),'Bootstrap role remains');
check(await read(book.strategyUpkeep,'enabled(address) view returns(bool)',[fresh]),'New upkeep disabled');
for(const key of ['settingsModule','allocCalcModule','rebalancePlanModule','safetyOverflowModule','rebalanceGateModule']) check(equal(await read(fresh,`${key}_addr() view returns(address)`),book[key]),`${key} wiring`);
for(const key of ['strategyUpkeep','protocolRegistry','dolomiteRateProvider']) check(equal(await read(book[key],'owner() view returns(address)'),gov),`${key} owner`);
check(equal(await read(env.REBALANCE_GAS_ESTIMATOR,'calibrator() view returns(address)'),gov),'Estimator owner');
check((await read(env.REBALANCE_GAS_ESTIMATOR,'validatedPrices() view returns(bool,uint256,uint256)'))[0],'Invalid price feeds');
check(!await read(router,'isStrategyEnabled(address) view returns(bool)',[fresh]),'Replacement already active; reconcile before generating migration');
const oldAdapters=await Promise.all(Array.from({length:7},(_,i)=>read(old,'adapters(uint256) view returns(address)',[BigInt(i)])));
const delay=await read(router,'strategyAllowlistDelay() view returns(uint256)');
const list=await read(router,'list() view returns((address strat,bool enabled,uint16 priority,uint16 weightBps)[])');
check(list.filter(x=>x.enabled).every(x=>equal(x.strat,old)),'Other enabled strategies require a reviewed weight plan');
const tx=(to,signature,args=[])=>({to,value:'0',data:encodeFunctionData({abi:parseAbi([`function ${signature}`]),functionName:signature.split('(')[0],args}),contractMethod:null,contractInputsValues:null});
const batch=(name,description,transactions)=>({version:'1.0',chainId:'42161',createdAt:Date.now(),meta:{name,description,txBuilderVersion:'1.18.0',createdFromSafeAddress:gov,createdFromOwnerAddress:''},transactions});
const proposal=batch(`${dir.split('/').at(-1)}: propose allowlist`,`Step 1. Starts Router delay (${delay} seconds). Does not move vault funds.`,[tx(router,'proposeStrategyAllowlist(address)',[fresh])]);
const migration=batch(`${dir.split('/').at(-1)}: atomic migration`,'Step 2. Execute only after allowlist ETA. Stop old upkeep, sweep old adapters, recall to Core, assert drained, register replacement, retire old strategy. AWS rollout follows successful Safe execution.',[
  tx(env.SOURCE_STRATEGY_UPKEEP,'toggleStrategy(address,bool)',[old,false]),
  tx(env.MIGRATION_GUARD,'assertNoPlan(address)',[old]),
  tx(old,'setDepositsDisabled(bool)',[true]),
  ...oldAdapters.map(a=>tx(old,'callAdapterEmergencyPull(address)',[a])),
  tx(router,'withdrawAllToCore(address)',[old]),
  tx(env.MIGRATION_GUARD,'assertDrained(address,uint256)',[old,100n]),
  ...(process.env.CALIBRATE_ADAPTERS === 'true' ? [
    ['aaveAdapter',600000,300000], ['morphoAdapter',1100000,4000000],
    ['cometAdapter',550000,300000], ['eulerAdapter',900000,450000],
    ['dolomiteAdapter',1200000,600000], ['fluidAdapter',450000,300000],
    ['venusAdapter',750000,350000]
  ].map(([key,d,w])=>tx(env.REBALANCE_GAS_ESTIMATOR,'setAdapterFloors(address,uint32,uint32)',[book[key],d,w])) : []),
  tx(router,'executeStrategyAllowlist(address)',[fresh]),
  tx(router,'register(address,uint16,uint16)',[fresh,100,10000]),
  tx(router,'setMaxStrategyBps(address,uint16)',[fresh,10000]),
  tx(router,'setLossCapPerStrategy(address,uint16)',[fresh,50]),
  tx(router,'setWeights(address[],uint16[])',[[old,fresh],[0,10000]]),
  tx(router,'toggle(address,bool)',[old,false]),
]);
fs.writeFileSync(`${dir}/01-propose-allowlist.safe.json`,JSON.stringify(proposal,null,2)+'\n');
fs.writeFileSync(`${dir}/02-migrate.safe.json`,JSON.stringify(migration,null,2)+'\n');
fs.writeFileSync(`${dir}/postflight.json`,JSON.stringify({blockNumber,chainId:42161,deployer,governance:gov,allowlistDelaySeconds:delay,copiedSourceSettings:false,checked,checksPassed:true},(_,v)=>typeof v==='bigint'?v.toString():v,2)+'\n');
console.log(JSON.stringify({strategy:fresh,upkeep:book.strategyUpkeep,delaySeconds:delay.toString(),transactions:[proposal.transactions.length,migration.transactions.length],postflight:'passed'}));
