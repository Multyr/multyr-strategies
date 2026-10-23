import fs from 'node:fs';
import {createRequire} from 'node:module';
const require=createRequire(new URL('../../multyr-periphery/keeper/package.json',import.meta.url));
const {createPublicClient,http,parseAbi}=require('viem');
const c=createPublicClient({transport:http('https://arb1.arbitrum.io/rpc',{timeout:30000})});
const strategy='0xa9E676D15976A1332905238ca609Dff9A484Efe0',upkeep='0xbcaC314E7237b14E11644FC6Ba73675c8c0612DF';
const blockNumber=await c.getBlockNumber();
const read=(address,sig,args=[])=>c.readContract({address,abi:parseAbi(['function '+sig]),functionName:sig.split('(')[0],args,blockNumber});
const out={blockNumber:String(blockNumber),strategy,upkeep,settings:{},adapters:[]};
for(const [n,t] of Object.entries({adapterCount:'uint256',adapterMaxExposureBps:'uint16',rebalancePlanPhase:'uint8',maxAdaptersPerAllocation:'uint16',minAdaptersActive:'uint16',rebalanceMinMoveBps:'uint16',minSecondsBetweenRebalances:'uint32',driftToleranceBps:'uint16',newAdapterRampBps:'uint16',depositsDisabled:'bool',maxIdleAfterDepositBps:'uint16',maxIdleBootstrapBps:'uint16'}))out.settings[n]=await read(strategy,`${n}() view returns(${t})`);
for(let i=0;i<Number(out.settings.adapterCount);i++) {const a=await read(strategy,'adapters(uint256) view returns(address)',[BigInt(i)]);const d={address:a};for(const [n,t] of Object.entries({totalAssets:'uint256',maxCapacity:'uint256',vault:'address'}))d[n]=await read(a,`${n}() view returns(${t})`);d.enabled=await read(strategy,'enabled(address) view returns(bool)',[a]);out.adapters.push(d);}
out.pokeTargets=await read(upkeep,'getPokeTargets() view returns(address[])');out.upkeepOwner=await read(upkeep,'owner() view returns(address)');
fs.writeFileSync('deployments/adapter-only-20261019/preflight.json',JSON.stringify(out,(_,v)=>typeof v==='bigint'?String(v):v,2)+'\n');console.log(JSON.stringify(out,(_,v)=>typeof v==='bigint'?String(v):v,2));
