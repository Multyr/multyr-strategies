import fs from 'node:fs';
import {createRequire} from 'node:module';
const require=createRequire(new URL('../../multyr-periphery/keeper/package.json',import.meta.url));
const {createPublicClient,http,parseAbi,decodeFunctionData,encodeFunctionData,keccak256,toHex,getContractAddress}=require('viem');
const dir='deployments/adapter-only-20261019', prev='deployments/adapter-fixes-20261019';
const state=JSON.parse(fs.readFileSync(`${dir}/preflight.json`));
const book=JSON.parse(fs.readFileSync(`${prev}/addresses.json`));
const broadcast=JSON.parse(fs.readFileSync(`${prev}/deployment-receipts.json`));
const gov='0x70ef444799D6FBbE0865bA598Bee6795e064a326', strategy=state.strategy, upkeep=state.upkeep, factory=book.adapterFactory;
const c=createPublicClient({transport:http('https://arb1.arbitrum.io/rpc',{timeout:30000})});
const read=(address,sig,args=[])=>c.readContract({address,abi:parseAbi(['function '+sig]),functionName:sig.split('(')[0],args,blockNumber:BigInt(state.blockNumber)});
const abi= parseAbi(['function deployAndInit(bytes,bytes32,bytes) returns(address)']);
const tx=(to,sig,args=[])=>({to,value:'0',data:encodeFunctionData({abi:parseAbi(['function '+sig]),functionName:sig.split('(')[0],args}),contractMethod:null,contractInputsValues:null});
const batches=[];
function save(name,description,transactions){const b={version:'1.0',chainId:'42161',createdAt:Date.now(),meta:{name,description,txBuilderVersion:'1.18.0',createdFromSafeAddress:gov,createdFromOwnerAddress:''},transactions};fs.writeFileSync(`${dir}/${name}.safe.json`,JSON.stringify(b,null,2)+'\n');batches.push({file:`${name}.safe.json`,count:transactions.length});}
const param=keccak256(toHex('PARAM_ROLE')),keeper=keccak256(toHex('KEEPER_ROLE'));
if(!await read(factory,'hasRole(bytes32,address) view returns(bool)',[keccak256(toHex('DEPLOYER_ROLE')),gov]))throw Error('Safe lacks factory deployer role');
const guardCode=JSON.parse(fs.readFileSync('out/AdapterSwapGuard.sol/AdapterSwapGuard.json')).bytecode.object;
const salt=keccak256(toHex('multyr.adapter-only.guard.20261019'));
const guard=getContractAddress({from:factory,opcode:'CREATE2',salt,bytecode:guardCode});
save('00-deploy-drain-guard','Deploy stateless adapter drain assertion; no funds move.',[tx(factory,'deployAndInit(bytes,bytes32,bytes)',[guardCode,salt,tx(factory,'initialize()').data])]);
const replacements=[];
for(const [index,key,oldIndex,artifactName] of [[1,'venusAdapter',6,'VenusUsdcMultiMarketAdapter'],[2,'morphoAdapter',1,'MorphoUsdcMultiMarketAdapter'],[3,'dolomiteAdapter',4,'DolomiteUsdcMultiMarketAdapter'],[4,'fluidAdapter',5,'FluidUsdcMultiMarketAdapter']]){
 const artifact=JSON.parse(fs.readFileSync(`${prev}/provenance/${artifactName}.artifact.json`));
 const code=artifact.bytecode.object;
 const source=broadcast.transactions.filter(t=>t.function==='deployAndInit(bytes,bytes32,bytes)').map(t=>decodeFunctionData({abi,data:t.transaction.input})).find(t=>t.args[0].toLowerCase()===code.toLowerCase());
 if(!source)throw Error('Missing exact creation bytecode '+key);
 const init=decodeFunctionData({abi:artifact.abi,data:source.args[2]});
 const old=state.adapters[oldIndex].address;
 init.args[1]=gov;init.args[2]=strategy;init.args[3]=BigInt(state.adapters[oldIndex].maxCapacity);
 if(key==='venusAdapter') {init.args[4]=await read(old,'vToken() view returns(address)');init.args[5]=31536000n;}
 else if(key==='fluidAdapter')init.args[4]=await read(old,'fToken() view returns(address)');
 else init.args[4]=await read(old,'registry() view returns(address)');
 const salt=keccak256(toHex(`multyr.adapter-only.${key}.20261019`));
 const fresh=getContractAddress({from:factory,opcode:'CREATE2',salt,bytecode:code});
 if(await c.getCode({address:fresh}))throw Error('Already deployed '+fresh);
 const initData=encodeFunctionData({abi:artifact.abi,functionName:init.functionName,args:init.args});
 const setup=[tx(factory,'deployAndInit(bytes,bytes32,bytes)',[code,salt,initData])];
 if(key!=='venusAdapter') setup.push(tx(fresh,'grantRole(bytes32,address)',[param,upkeep]));
 if(key==='dolomiteAdapter')for(const [getter,setter,type] of [['rateProvider','setRateProvider','address'],['usdcMarketId','setUsdcMarketId','uint256'],['accountNumber','setAccountNumber','uint256']])setup.push(tx(fresh,`${setter}(${type})`,[await read(old,`${getter}() view returns(${type})`)]));
 if(key!=='venusAdapter')setup.push(tx(fresh,'pokeAPYSnapshots()'));
 save(`0${index}-deploy-${key.replace('Adapter','')}`,`Deploy fixed ${key} bound to CURRENT strategy; Safe owns admin and parameter roles. No existing funds move.`,setup);
 replacements.push({key,old,fresh,codehash:keccak256(code)});
}
const calls=[tx(book.rebalanceGasEstimator,'owner() view returns(address)')];calls.pop();
calls.push(tx('0x03418e9b32e5e5b43c545601376c5064886211f3','assertNoPlan(address)',[strategy]),tx(upkeep,'toggleStrategy(address,bool)',[strategy,false]),tx(strategy,'setDepositsDisabled(bool)',[true]));
for(const r of replacements)calls.push(tx(strategy,'callAdapterEmergencyPull(address)',[r.old]));
calls.push(tx(guard,'assertDrained(address[],uint256)',[replacements.map(r=>r.old),100n]),tx(strategy,'syncPositionAssets()'));
for(const r of replacements){
 calls.push(tx(strategy,'toggleAdapter(address,bool)',[r.old,false]),tx(strategy,'whitelistAdapter(address,bool)',[r.old,false]),tx(strategy,'whitelistAdapter(address,bool)',[r.fresh,true]),tx(strategy,'addAdapter(address)',[r.fresh]),tx(strategy,'toggleAdapter(address,bool)',[r.fresh,true]));
 if(r.key!=='venusAdapter')calls.push(tx(upkeep,'removePokeTarget(address)',[r.old]),tx(upkeep,'addPokeTarget(address)',[r.fresh]));
}
// Preserve the existing Fluid safety designation and caps, replacing its address.
const oldFluid=replacements.find(r=>r.key==='fluidAdapter');
const fb=await read(strategy,'safetyFallback(address) view returns(uint16 absCapBps,uint16 relCapBps)',[oldFluid.old]);
if(fb[0])calls.push(tx(strategy,'removeSafetyFallbackAdapter(address)',[oldFluid.old]),tx(strategy,'addSafetyFallbackAdapter(address,uint16,uint16)',[oldFluid.fresh,fb[0],fb[1]]));
// Euler's zero sentinel blocks allocation in the old adapter. Explicit capacity preserves the other adapters' existing ceiling.
calls.push(tx(state.adapters[3].address,'setCapacity(uint256)',[50000000000000n]));
const floors=[[600000n,300000n],[1100000n,4000000n],[550000n,300000n],[900000n,450000n],[1200000n,600000n],[450000n,300000n],[750000n,350000n]];
for(let i=0;i<7;i++){const a=state.adapters[i].address,r=replacements.find(r=>r.old.toLowerCase()===a.toLowerCase());calls.push(tx(book.rebalanceGasEstimator,'setAdapterFloors(address,uint32,uint32)',[r?.fresh||a,...floors[i]]));}
// These calls are authorized using existing Safe PARAM_ROLE; temporarily add KEEPER_ROLE only if needed.
const hadKeeper=await read(strategy,'hasRole(bytes32,address) view returns(bool)',[keeper,gov]);
if(!hadKeeper)calls.push(tx(strategy,'grantRole(bytes32,address)',[keeper,gov]));
calls.push(tx(strategy,'pokeExternalTVL()'),tx(strategy,'pokeLiquidityBatch(uint256,uint256)',[0n,7n]));
if(!hadKeeper)calls.push(tx(strategy,'revokeRole(bytes32,address)',[keeper,gov]));
calls.push(tx(strategy,'setDepositsDisabled(bool)',[false]),tx(upkeep,'toggleStrategy(address,bool)',[strategy,true]));
save('05-atomic-adapter-swap','Recall affected adapters to SAME strategy, assert drained, disable old adapters, register replacements, rewire upkeep poke targets, restore Fluid safety designation, set Euler capacity and calibrated gas floors. DOES NOT change allocation policy.',calls);
fs.writeFileSync(`${dir}/manifest.json`,JSON.stringify({status:'DRAFT pending fork rehearsal and allocation-policy decision',strategy,upkeep,factory,guard,replacements,batches,blockNumber:state.blockNumber,allocationPolicyChanged:false},null,2)+'\n');
console.log(JSON.stringify({replacements,batches},null,2));
