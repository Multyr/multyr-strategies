"""Prepare indexer/keeper addresses only from a fully confirmed deployment."""
import json
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
OUT=ROOT/'deployments/ema-first-20261023'
j=json.loads((ROOT/'broadcast/DeployUsdcLendingStrategy.s.sol/42161/run-latest.json').read_text())
assert len(j['receipts'])==len(j['transactions'])==105
assert all(int(r['status'],16)==1 for r in j['receipts'])
book=json.loads((OUT/'addresses.json').read_text())
receipts={r['transactionHash'].lower():r for r in j['receipts']}
blocks={}
for t in j['transactions']:
    r=receipts[t['hash'].lower()]
    addresses=[t.get('contractAddress','')]+[a['address'] for a in t.get('additionalContracts',[])]
    if t.get('transactionType')!='CREATE': addresses=addresses[1:]
    for key,value in book.items():
        if isinstance(value,str) and value.lower() in [a.lower() for a in addresses if a]:blocks[key]=int(r['blockNumber'],16)
assert 'strategy' in blocks and 'strategyUpkeep' in blocks
book['deploymentReportedL1BlockNumber']=book['blockNumber']
book['blockNumber']=blocks['strategy'];book['startBlocks']=blocks
book['sourceCommit']='407b3df';book['sourceTag']='usdc-lending-ema-first-20261023'
book['status']='deployed-awaiting-Safe-migration'
(OUT/'addresses.json').write_text(json.dumps(book,indent=2)+'\n')
(OUT/'deployment-receipts.json').write_text(json.dumps(j['receipts'],indent=2)+'\n')
keeper=ROOT.parent/'multyr-periphery/keeper'
config=json.loads((keeper/'config/arbitrum-one.json').read_text())
previous=config['addresses']['strategyVault'];previousUpkeep=config['addresses']['strategyUpkeep']
config['addresses']['strategyVault']=book['strategy'];config['addresses']['strategyUpkeep']=book['strategyUpkeep']
for job in config['jobs']:
    if job['id']=='W2':job['target']=book['strategyUpkeep']
    if job['id']=='W5':job['strategyVault']=book['strategy']
(keeper/'config/arbitrum-one.ema-first-20261023.json').write_text(json.dumps(config,indent=2)+'\n')
release={'status':'prepared-not-rolled-out','requires':'Safe migration executed and check-ema-migration.mjs passed','router':'0x37847D2e12892e3298DEE695e7E971fba0Ca3e24','previousStrategy':previous,'previousUpkeep':previousUpkeep,'strategy':book['strategy'],'upkeep':book['strategyUpkeep'],'estimator':book['rebalanceGasEstimator'],'config':'/app/config/arbitrum-one.ema-first-20261023.json','awsAccount':'820140266807','region':'eu-north-1','cluster':'multyr-keeper','service':'multyr-keeper-simulation','deploymentConfiguration':{'minimumHealthyPercent':0,'maximumPercent':100}}
(keeper/'deploy/aws/ema-first-20261023.json').write_text(json.dumps(release,indent=2)+'\n')
graph=ROOT.parent/'subgraphs'
(graph/'deployments/arbitrum/ema-first-20261023.json').write_text(json.dumps(book,indent=2)+'\n')
p=graph/'arbitrum/subgraph.yaml';s=p.read_text()
if 'name: StrategyUpkeepEmaFirst' not in s:
    start=s.index('  - kind: ethereum/contract\n    name: StrategyUpkeepCurrent')
    end=s.index('\n  - kind:',start+10)
    template=s[start:end].replace('name: StrategyUpkeepCurrent','name: StrategyUpkeepEmaFirst').replace('0xbcaC314E7237b14E11644FC6Ba73675c8c0612DF',book['strategyUpkeep']).replace('startBlock: 515604935','startBlock: '+str(blocks['strategyUpkeep'])).replace('17 Oct 2026','23 Oct 2026')
    p.write_text(s[:end]+'\n'+template+s[end:])
print(json.dumps({'confirmedTransactions':len(j['receipts']),'strategy':book['strategy'],'upkeep':book['strategyUpkeep'],'startBlocks':blocks},indent=2))
