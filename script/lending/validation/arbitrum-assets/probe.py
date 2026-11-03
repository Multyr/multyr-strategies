"""Pinned read-only RPC checks for the complete 7 x 4 Arbitrum matrix."""
import concurrent.futures
import json
import os
import pathlib
import subprocess
import functools
import time
import urllib.request
try:
    from Crypto.Hash import keccak
except ImportError:
    keccak = None

ROOT = pathlib.Path(__file__).resolve().parents[4]
OUT = ROOT / 'deployments/lending-full-validation-20261101/production/arbitrum-assets'
PIN = 520094008
TOKENS = {
    'USDC': ('0xaf88d065e77c8cc2239327c5edb3a432268e5831', 6, '0x50834f3163758fcc1df9973b6e91f0f0f0434ad3'),
    'WETH': ('0x82af49447d8a07e3bd95bd0d56f35241523fbab1', 18, '0x639fe6ab55c921f74e7fac1ee960c0b6293ba612'),
    'USDT0': ('0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9', 6, '0x3f3f5df88dc9f13eac63df89ec16ef6e7e25dde7'),
    'WBTC': ('0x2f2a2543b76a4166549f7aab2e75bef0aefc5b0f', 8, '0x6ce185860a4963106506c203335a2910413708e9'),
}
RPC = os.environ['ARBITRUM_RPC_URL']
def rpc(method, params):
    assert method in ('eth_call','eth_getCode','eth_getBlockByNumber','eth_chainId','eth_blockNumber')
    for attempt in range(4):
        try:
            req = urllib.request.Request(RPC, data=json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(), headers={'Content-Type':'application/json'})
            data = json.load(urllib.request.urlopen(req, timeout=40))
            if 'error' in data:
                raise RuntimeError('RPC_ERROR_'+str(data['error'].get('code')))
            return data['result']
        except Exception:
            if attempt==3: raise RuntimeError('RPC_READ_FAILED') from None
            time.sleep(attempt+1)
@functools.lru_cache(maxsize=None)
def selector(sig):
    if keccak is not None:
        h=keccak.new(digest_bits=256);h.update(sig.encode());return h.hexdigest()[:8]
    raw=subprocess.check_output(['cast','sig',sig],text=True).strip()
    assert len(raw)==10 and raw.startswith('0x'), 'Invalid Foundry selector'
    return raw[2:]
def call(address, sig, args='', pin=PIN):
    return rpc('eth_call',[{'to':address,'data':'0x'+selector(sig)+args},hex(pin)])
def uint(address,sig,args='',pin=PIN): return int(call(address,sig,args,pin),16)
def addr(address,sig,args='',pin=PIN): return '0x'+call(address,sig,args,pin)[-40:]

def markets():
    venus=json.loads((OUT/'venus.json').read_text())['addresses']
    d={f:{} for f in ('aave','comet','morpho','euler','fluid','dolomite','venus')}
    for symbol,(token,_,_) in TOKENS.items():
        d['aave'][symbol]='0x794a61358d6845594f94dc1db02a252b5b4814ad'
        key='USDT' if symbol=='USDT0' else symbol
        d['venus'][symbol]=venus['VToken_v'+key+'_Core']
    for symbol,key in [('USDC','usdc'),('WETH','weth'),('USDT0','usdt')]:
        d['comet'][symbol]=json.loads((OUT/('comet-'+key+'.json')).read_text())['comet']
        d['fluid'][symbol]=json.loads((OUT/('fToken_f'+('USDT' if symbol=='USDT0' else symbol)+'.json')).read_text())['address']
    d['morpho']['USDC']='0x7c574174da4b2be3f705c6244b4bfa0815a8b3ed'
    # Unlisted existing vault: technical test profile only. Its tiny actual TVL
    # must be rejected by the unchanged strategy floor, never approved by name.
    d['morpho']['WETH']='0x0623a67d69bb2f59d266897a15dc1509d291d631'
    d['morpho']['USDT0']='0xbeeff77ce5c059445714e6a3490e273fe7f2492f'
    d['euler'].update(USDC='0x6afb8d3f6d4a34e9cb2f217317f4dc8e05aa673b',WETH='0x78e3e051d32157aacd550fbb78458762d8f7edff',USDT0='0x37512f45b4ba8808910632323b73783ca938cd51',WBTC='0x889e1c458b2469b70accdfb5b59726dc1668896c')
    d['dolomite'].update(USDC='0x444868b6e8079ac2c55eea115250f92c2b2c4d14',WETH='0xf7b5127b510e568fdc39e6bb54e2081bfad489af',USDT0='0xf2d2d55daf93b0660297eaa10969ebe90ead5ce8',WBTC='0x29cf6e8ecefb8d3c9dd2b727c1b7d1df1a754f6f')
    return d
def probe_row(item):
    family,symbol,market=item;token,decimals,feed=TOKENS[symbol]
    row={'family':family,'symbol':symbol,'asset':token,'decimals':decimals,'feed':feed,'market':market,'pin':PIN,'status':'NOT_EXECUTED'}
    if not market:
        row['status']='NO_CANDIDATE_IN_QUERIED_INVENTORY';return row
    try:
        row['codeBytes']=len(rpc('eth_getCode',[market,hex(PIN)]))//2-1
        if not row['codeBytes']:row['status']='NOT_DEPLOYED_AT_PIN';return row
        if family=='aave':
            raw=call(market,'getReserveData(address)',token[2:].zfill(64));words=[raw[2+i:66+i] for i in range(0,len(raw)-2,64)]
            row['receipt']='0x'+words[8][-40:];row['underlying']=addr(row['receipt'],'UNDERLYING_ASSET_ADDRESS()');row['totalAssets']=str(uint(row['receipt'],'totalSupply()'));row['rateRay']=str(int(words[2],16))
        elif family=='venus':
            row['underlying']=addr(market,'underlying()');row['cash']=str(uint(market,'getCash()'));row['borrows']=str(uint(market,'totalBorrows()'));row['supplyRatePerSlot']=str(uint(market,'supplyRatePerBlock()'))
        elif family=='comet':
            row['underlying']=addr(market,'baseToken()');row['totalAssets']=str(uint(market,'totalSupply()'));row['utilization']=str(uint(market,'getUtilization()'))
        else:
            row['underlying']=addr(market,'asset()');row['totalAssets']=str(uint(market,'totalAssets()'));row['pps24']=str(uint(market,'convertToAssets(uint256)',hex(10**24)[2:].zfill(64)))
        row['status']='PINNED_IDENTITY_MATCH' if row['underlying'].lower()==token else 'WRONG_UNDERLYING'
    except Exception as exc:row['status']='PROBE_FAILED';row['errorType']=type(exc).__name__
    return row

if __name__=='__main__':
    OUT.mkdir(parents=True,exist_ok=True)
    assert int(rpc('eth_chainId',[]),16)==42161
    pins={}
    checkpoints={513000000,513800000,514200000,515000000,517000000,517500000,519094008,520000000,PIN,PIN-100000}
    for start,end in ((514200000,515000000),(515000000,517500000),(517500000,PIN),(515000000,PIN)):
        current=start
        while current<end:current=min(current+400000,end);checkpoints.add(current)
    for block in sorted(checkpoints):
        h=rpc('eth_getBlockByNumber',[hex(block),False]);pins[str(block)]={k:h[k] for k in ('number','hash','timestamp')}
    catalog=markets()
    factory=json.loads((OUT/'fluid-factory.json').read_text())['address']
    encoded=call(factory,'allTokens()');count=int(encoded[66:130],16)
    assert 0<count<=200, 'Bounded complete Fluid inventory required'
    fluid_tokens=[]
    for i in range(count):
        market='0x'+encoded[130+i*64+24:194+i*64];asset=addr(market,'asset()')
        fluid_tokens.append({'market':market,'asset':asset})
        for symbol,(token,_,_) in TOKENS.items():
            if asset.lower()==token:catalog['fluid'][symbol]=market
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        rows=list(pool.map(probe_row,[(f,s,m.get(s)) for f,m in catalog.items() for s in TOKENS]))
    funding=[]
    for symbol,(token,_,feed) in TOKENS.items():
        r={'symbol':symbol,'feed':feed,'holders':{}}
        try:r['latestRoundData']=call(feed,'latestRoundData()')
        except Exception:r['feedStatus']='READ_FAILED'
        for holder in ('0xf977814e90da44bfa03b6295a0616a897441acec','0xb38e8c17e38363af6ebdcb3dae12e0243582891d'):
            r['holders'][holder]=str(uint(token,'balanceOf(address)',holder[2:].zfill(64)))
        funding.append(r)
    test_wbtc='0x24717fddd4fdf9dffa856d8a7f1a41d2b9de9dec'
    wbtc_probe={'market':test_wbtc,'asset':addr(test_wbtc,'asset()'),'totalAssets':str(uint(test_wbtc,'totalAssets()')),'maxDeposit':str(uint(test_wbtc,'maxDeposit(address)',('33'*20).zfill(64))),'pin':PIN}
    result={'chainId':42161,'pin':PIN,'canonicalHeaders':pins,'rows':rows,'funding':funding,'fluidFactory':{'address':factory,'tokens':fluid_tokens},'morphoWbtcTestVault':wbtc_probe,'rpcReference':'ARBITRUM_RPC_URL','scope':'Read-only identities; NOT lifecycle acceptance'}
    (OUT/'pinned-inventory.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    for r in rows:print(r['family'],r['symbol'],r['status'],r.get('totalAssets',r.get('cash','')),r.get('receipt',''))
    print('funding',json.dumps(funding))
