#!/usr/bin/env python3
"""Read-only, block-pinned migration inventory. Never signs or submits transactions."""
import argparse
import concurrent.futures
import json
from pathlib import Path
import re
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--rpc', required=True)
p.add_argument('--source', required=True)
p.add_argument('--upkeep', required=True)
p.add_argument('--block', required=True, type=int)
p.add_argument('--output', required=True)
p.add_argument('--cast', default='cast')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
selectors = {}
def selector(sig):
    if sig not in selectors:
        selectors[sig] = subprocess.check_output([a.cast, 'sig', sig], text=True).strip()
    return selectors[sig]
def rpc(method, params):
    command = [a.cast, 'rpc', '--rpc-url', a.rpc, method]
    command += [json.dumps(value) for value in params]
    return json.loads(subprocess.check_output(command, text=True, timeout=90))

def call(target, sig, *args):
    data = selector(sig) + ''.join(f'{int(x, 16) if isinstance(x, str) else x:064x}' for x in args)
    return rpc('eth_call', [{'to':target, 'data':data}, hex(a.block)])
def number(target, sig, *args):
    data = call(target, sig, *args)
    if len(data) != 66: raise RuntimeError(f'Invalid scalar: {target} {sig}: {data}')
    return int(data, 16)
def address(target, sig, *args):
    return '0x' + f'{number(target, sig, *args):040x}'
def parallel(items, fn):
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        return dict(pool.map(lambda k: (k, fn(k)), items))
layout = (root/'src/strategies/usdc-lending/controller/StrategyStorageLayout.sol').read_text()
scalars = re.findall(r'\b(?:uint\d+|bool) public (\w+)\s*;', layout)
# Include lifecycle flags from Pausable and array lengths from module views.
scalars += ['paused', 'adapterCount', 'safetyFallbackAdaptersLength']
values = parallel(scalars, lambda k: str(number(a.source, k+'()')))
mappings = ['enabled','flagged','quarantined','whitelistedAdapters','pushDepositMode','depositModeKnown','adapterAbsCapOverrideBps','riskScoreBps','lastRiskScoreUpdateTs']
adapters = []
for i in range(int(values['adapterCount'])):
    addr = address(a.source, 'adapters(uint256)', i)
    raw = bytes.fromhex(call(addr, 'name()')[2:])
    offset = int.from_bytes(raw[:32], 'big')
    length = int.from_bytes(raw[offset:offset+32], 'big')
    item = {'address':addr,'name':raw[offset+32:offset+32+length].decode()}
    item['settings'] = parallel(mappings, lambda k: str(number(a.source, k+'(address)', addr)))
    caps = call(a.source, 'safetyFallback(address)', addr)[2:]
    item['safetyFallback'] = {'absCapBps':str(int(caps[:64],16)),'relCapBps':str(int(caps[64:],16))}
    adapters.append(item)
fallbacks = [address(a.source,'safetyFallbackAdapters(uint256)',i) for i in range(int(values['safetyFallbackAdaptersLength']))]
upkeep = {'address':a.upkeep,'pokeInterval':str(number(a.upkeep,'pokeInterval()')),
          'enabled':bool(number(a.upkeep,'enabled(address)',a.source)),
          'aavePool':address(a.upkeep,'aavePool()'), 'usdc':address(a.upkeep,'usdc()')}
raw=call(a.upkeep,'getPokeTargets()')[2:]
upkeep['pokeTargets']=['0x'+raw[128+i*64+24:128+(i+1)*64] for i in range(int(raw[64:128],16))]
block=rpc('eth_getBlockByNumber',[hex(a.block),False])
result={'chainId':int(rpc('eth_chainId',[]),16),'blockNumber':a.block,'blockHash':block['hash'],
        'blockTimestamp':int(block['timestamp'],16),'source':a.source,'scalarsIncludingRuntimeState':values,
        'adapters':adapters,'safetyFallbackOrder':fallbacks,'upkeep':upkeep,
        'note':'Inventory includes runtime state for review; copier imports configuration only. Adapter-internal markets/capacities/roles require separate parity review.'}
Path(a.output).write_text(json.dumps(result,indent=2)+'\n')
print(f'Saved {len(scalars)} scalars and {len(adapters)} adapter settings at block {a.block} to {a.output}')
