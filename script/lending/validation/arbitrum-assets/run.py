"""Execute every discovered Arbitrum asset/family row; never convert failure to PASS.

Uses actual-holder transfers in local Foundry forks. Public chain is read-only.
Absent inventory entries remain unresolved, not a token incompatibility claim.
"""
import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import time
import probe

ROOT = probe.ROOT
OUT = probe.OUT
FAMILIES = ('aave','comet','morpho','euler','fluid','dolomite','venus')
STAGE_TESTS={'direct':'ArbitrumAssetDirect.t.sol','core':'ArbitrumAssetMatrix.t.sol','warm':'ArbitrumAssetWarm.t.sol','portfolio':'ArbitrumAssetPortfolio.t.sol'}
def exclusions(inventory):
    """Bounded protocol inventory exclusions, never global token incompatibility."""
    wbtc=probe.TOKENS['WBTC'][0]
    directories=json.loads((OUT/'comet-deployment-directories.json').read_text())
    assert {x['name'] for x in directories}=={'usdc.e','usdc','usdt','weth'}, 'Comet inventory changed; reassess WBTC'
    assert all(x['asset'].lower()!=wbtc for x in inventory['fluidFactory']['tokens'])
    factory=inventory['fluidFactory']['address'];assert factory.lower()=='0x54b91a0d94cb471f37f949c60f7fa7935b551d03'
    encoded=probe.call(factory,'allTokens()');count=int(encoded[66:130],16)
    actual=['0x'+encoded[130+i*64+24:194+i*64] for i in range(count)]
    assert actual==[x['market'].lower() for x in inventory['fluidFactory']['tokens']], 'Frozen Fluid inventory differs from actual pinned chain state'
    for x in inventory['fluidFactory']['tokens']:assert probe.addr(x['market'],'asset()').lower()==x['asset'].lower()
    vault=inventory['morphoWbtcTestVault']
    assert vault['pin']==inventory['pin'] and vault['asset'].lower()==wbtc and int(vault['totalAssets'])==0 and int(vault['maxDeposit'])==0
    assert probe.addr(vault['market'],'asset()').lower()==wbtc and probe.uint(vault['market'],'totalAssets()')==0 and probe.uint(vault['market'],'maxDeposit(address)',('33'*20).zfill(64))==0
    blue=json.loads((OUT/'morpho-blue-all.json').read_text())['data']['markets']
    assert blue['pageInfo']['count']==blue['pageInfo']['countTotal']
    assert all(x['loanAsset']['address'].lower()!=wbtc for x in blue['items'])
    vs=json.loads((OUT/'morpho-all-vaults-v1.json').read_text())['data']['vaults']
    assert vs['pageInfo']['count']==vs['pageInfo']['countTotal']
    candidates=[x for x in vs['items'] if (x.get('asset') or {}).get('address','').lower()==wbtc]
    assert len(candidates)==1 and candidates[0]['address'].lower()==vault['market'].lower()
    vs2=json.loads((OUT/'morpho-all-vaults-v2.json').read_text())['data']['vaultV2s']
    assert vs2['pageInfo']['count']==vs2['pageInfo']['countTotal']
    assert not any((x.get('asset') or {}).get('address','').lower()==wbtc for x in vs2['items'])
    return {'comet-WBTC':'NO_OFFICIAL_WBTC_BASE_MARKET',
            'fluid-WBTC':'NO_WBTC_FTOKEN_AT_CANONICAL_PIN',
            'morpho-WBTC':'NO_QUALIFIED_WBTC_PRODUCTION_MARKET'}
def snapshot(stage):
    tracked = subprocess.check_output(['git','ls-files','--','src','script','foundry.toml'],cwd=ROOT,text=True).splitlines()
    extra = subprocess.check_output(['git','ls-files','--others','--exclude-standard','--','src','script'],cwd=ROOT,text=True).splitlines()
    paths={p for p in tracked+extra if p.endswith(('.sol','.py','.ps1')) or p=='foundry.toml'}
    # Bind the executed program's complete first-party import closure. Unrelated
    # test edits do not change this program; production and scripts stay bound.
    queue=[ROOT/'test/strategies/usdc-lending/fork/arbitrum-assets'/STAGE_TESTS[stage]]
    while queue:
        file=queue.pop().resolve();rel=file.relative_to(ROOT).as_posix()
        if rel.startswith('lib/'):continue
        if rel in paths:continue
        paths.add(rel)
        for imp in re.findall(r'\bimport\b[^;]*?["\x27]([^"\x27]+)["\x27][^;]*;',file.read_text(encoding='utf-8-sig')):
            if imp.startswith('.'):queue.append(file.parent/imp)
    return {p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sorted(paths)}

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--case',help='e.g. aave-WBTC');ap.add_argument('--stage',choices=('direct','core','warm','portfolio'),default='core');args=ap.parse_args()
    assert os.environ.get('ARBITRUM_RPC_URL'), 'Named authorized RPC required'
    assert int(probe.rpc('eth_chainId',[]),16)==42161
    config=json.loads(subprocess.check_output(['forge','config','--json'],cwd=ROOT,text=True))
    assert config['solc']=='0.8.28' and config['optimizer'] and config['optimizer_runs']==200 and config['via_ir'] and config['evm_version']=='cancun' and config['bytecode_hash']=='none' and not config['cbor_metadata'], 'Unexpected qualification compiler settings'
    dependencies=subprocess.check_output(['git','-c','core.longpaths=true','submodule','status'],cwd=ROOT,text=True).splitlines()
    assert all(s.startswith(' ') for s in dependencies) and any('9a9d120709de99a6216e9fe75d36e9ffdcb1a4d9 lib/multyr-core' in s for s in dependencies), 'Frozen dependency pin mismatch'
    assert not subprocess.check_output(['git','-c','core.longpaths=true','-C','lib/multyr-core','status','--porcelain','--untracked-files=no'],cwd=ROOT,text=True).strip(), 'Frozen Core source changed'
    prohibited=re.compile(r'\b(?:vm\.)?(?:deal|etch|store|mockCall|mockCallRevert|warp)\s*\(')
    for folder in ('test/strategies/usdc-lending/fork/actual','test/strategies/usdc-lending/fork/arbitrum-assets'):
        for path in (ROOT/folder).glob('*.sol'):
            assert not prohibited.search(path.read_text(encoding='utf-8-sig')), 'Synthetic-state operation: '+str(path.relative_to(ROOT))
    before=snapshot(args.stage)
    inventory=json.loads((OUT/'pinned-inventory.json').read_text(encoding='utf-8'))
    inventory_hash=hashlib.sha256((OUT/'pinned-inventory.json').read_bytes()).hexdigest()
    for block,expected_header in inventory['canonicalHeaders'].items():
        header=probe.rpc('eth_getBlockByNumber',[hex(int(block)),False])
        assert header['hash']==expected_header['hash'] and header['timestamp']==expected_header['timestamp'], 'Canonical header mismatch: '+block
    unavailable=exclusions(inventory)
    catalogue_files=['comet-deployment-directories.json','morpho-all-vaults-v1.json','morpho-all-vaults-v2.json','morpho-blue-all.json']
    catalogue_hashes={p:hashlib.sha256((OUT/p).read_bytes()).hexdigest() for p in catalogue_files}
    assert len(inventory['rows'])==28
    identities=[(r['family'],r['symbol']) for r in inventory['rows']]
    assert len(set(identities))==28 and set(identities)=={(f,s) for f in FAMILIES for s in probe.TOKENS}, 'Missing or duplicate adapter/token cell'
    for row in inventory['rows']:
        asset,decimals,feed=probe.TOKENS[row['symbol']]
        assert (row['asset'].lower(),row['decimals'],row['feed'].lower())==(asset,decimals,feed), 'Requested token identity changed'
    run=OUT/('runs-'+time.strftime('%Y%m%dT%H%M%S',time.gmtime())+'-'+args.stage+'-'+str(os.getpid()));run.mkdir(parents=True)
    results=[]
    for row in inventory['rows']:
        if args.stage in ('warm','portfolio') and row['family']!='aave':continue
        case=row['family']+'-'+row['symbol']
        if args.case and args.case!=case:continue
        result={'case':case,'market':row['market'],'asset':row['asset'],'status':'NOT_EXECUTED'}
        if row['status']!='PINNED_IDENTITY_MATCH':
            result['status']=unavailable.get(case,row['status']) if row['status']=='NO_CANDIDATE_IN_QUERIED_INVENTORY' else row['status'];results.append(result);continue
        env=os.environ.copy()
        env.update({'MATRIX_ASSET':row['asset'],'MATRIX_FEED':row['feed'],
            'MATRIX_HOLDER':'0xb38e8c17e38363af6ebdcb3dae12e0243582891d' if row['symbol']=='USDC' else '0xf977814e90da44bfa03b6295a0616a897441acec',
            'MATRIX_MARKET':row['market'],'MATRIX_RECEIPT':row.get('receipt','0x'+'00'*20),
            'MATRIX_FAMILY':str(FAMILIES.index(row['family'])),
            'MATRIX_V2':str(row['family']=='morpho' and row['symbol']=='USDT0').lower(),
            'MATRIX_START_BLOCK':'513000000','MATRIX_SETUP_BLOCK':'513800000',
            'MATRIX_PIN_BLOCK':'520094008' if args.stage=='direct' else '514200000','MATRIX_EXIT_BLOCK':'520000000',
            'GIT_CONFIG_COUNT':'1','GIT_CONFIG_KEY_0':'core.longpaths','GIT_CONFIG_VALUE_0':'true'})
        if args.stage=='portfolio':
            env['MATRIX_MARKETS']=','.join(next(r['market'] for r in inventory['rows'] if r['family']==f and r['symbol']==row['symbol']) or '0x'+'00'*20 for f in FAMILIES)
        # Configure the address-specific endpoint retry policy too: Foundry forks
        # constructed by vm.createSelectFork do not inherit every CLI RPC option.
        rpc_url=env['ARBITRUM_RPC_URL']
        quoted=json.dumps(rpc_url)
        env['FOUNDRY_RPC_ENDPOINTS']='{ '+quoted+' = { endpoint = '+quoted+', retries = 8, retry_backoff = 2000, compute_units_per_second = 20 } }'
        selected_test={'direct':'test_arbitrumRealAssetDirectLifecycle','core':'test_arbitrumRealAssetCoreStrategyLifecycle','warm':'test_arbitrumFrozenWarmCoreStrategyLifecycle','portfolio':'test_arbitrumRealAssetPortfolioScoringRebalanceAndExit'}[args.stage]
        cmd=['forge','test','--match-path','test/strategies/usdc-lending/fork/arbitrum-assets/**',
             '--match-test',selected_test,'--threads','1','-vvvv','--summary']
        started=time.monotonic()
        timed_out=False;attempts=[]
        for attempt in range(2):
            try:
                proc=subprocess.run(cmd,cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,encoding='utf-8',errors='replace',timeout=1200)
                raw=proc.stdout;code=proc.returncode
            except subprocess.TimeoutExpired as exc:
                raw=exc.stdout or b'';raw=raw.decode('utf-8',errors='replace') if isinstance(raw,bytes) else raw;code=124;timed_out=True
            text=raw.replace(rpc_url,'[ARBITRUM_RPC_URL]')
            unavailable_rpc=code!=0 and ('historical state' in text and 'is not available' in text or 'database error: failed to get storage' in text)
            if unavailable_rpc and attempt==0:
                failed_log=run/(case+'.rpc-attempt-1.log');failed_log.write_text(text,encoding='utf-8')
                attempts.append({'status':'INFRASTRUCTURE_RPC_DATA_UNAVAILABLE','log':str(failed_log.relative_to(ROOT)),'logSha256':hashlib.sha256(failed_log.read_bytes()).hexdigest()})
                header=probe.rpc('eth_getBlockByNumber',[hex(inventory['pin']),False]);assert header['hash']==inventory['canonicalHeaders'][str(inventory['pin'])]['hash'], 'Canonical pin changed during infrastructure retry'
                continue
            break
        log=run/(case+'.log');log.write_text(text,encoding='utf-8')
        summaries=re.findall(r'^Suite result: (?:ok|FAILED)\.\s*(\d+) passed;\s*(\d+) failed;\s*(\d+) skipped',text,re.MULTILINE)
        ok=code==0 and summaries==[('1','0','0')]
        policy_rejected=ok and args.stage=='core' and 'emit ActualMatrixPolicyRejection(' in text
        result.update(status={'direct':'PASS_DIRECT_LIFECYCLE','core':'PASS_CORE_STRATEGY_LIFECYCLE','warm':'PASS_FROZEN_AAVE_WARM_LIFECYCLE','portfolio':'PASS_ACTUAL_WEIGHTED_PORTFOLIO_REBALANCE_AND_EXIT'}[args.stage] if ok else ('INFRASTRUCTURE_TIMEOUT' if timed_out else 'INFRASTRUCTURE_RPC_DATA_UNAVAILABLE' if unavailable_rpc else 'FAIL'),exitCode=code,infrastructureAttempts=attempts,
            elapsedSeconds=round(time.monotonic()-started,2),log=str(log.relative_to(ROOT)),
            logSha256=hashlib.sha256(log.read_bytes()).hexdigest(),
            observations=[s.strip() for s in text.splitlines() if 'emit ' in s and any(k in s for k in ('Actual','Matrix','Real'))])
        if policy_rejected:result['status']='PASS_POLICY_REJECTION_AND_IDLE_CORE_EXIT'
        results.append(result)
        print(case,result['status'],flush=True)
        (run/'progress.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
    after=snapshot(args.stage)
    inventory_stable=inventory_hash==hashlib.sha256((OUT/'pinned-inventory.json').read_bytes()).hexdigest()
    catalogues_stable=all(hashlib.sha256((OUT/p).read_bytes()).hexdigest()==sha for p,sha in catalogue_hashes.items())
    expected=4 if args.stage in ('warm','portfolio') else 28
    policy_cases={'morpho-WETH','euler-USDT0','euler-WBTC'}
    def required_status(case):
        if args.stage in ('core','direct') and case in unavailable:return unavailable[case]
        if args.stage=='core':return 'PASS_POLICY_REJECTION_AND_IDLE_CORE_EXIT' if case in policy_cases else 'PASS_CORE_STRATEGY_LIFECYCLE'
        return {'direct':'PASS_DIRECT_LIFECYCLE','warm':'PASS_FROZEN_AAVE_WARM_LIFECYCLE','portfolio':'PASS_ACTUAL_WEIGHTED_PORTFOLIO_REBALANCE_AND_EXIT'}[args.stage]
    classified=all(r['status']==required_status(r['case']) for r in results)
    complete=len(results)==expected and classified and before==after and inventory_stable and catalogues_stable
    status=('COMPLETE_WITH_MARKET_EXCLUSIONS' if any(not r['status'].startswith('PASS_') for r in results) else 'PASS') if complete else 'INCOMPLETE_OR_BLOCKED'
    report={'status':status,'stage':args.stage,'fullySupportedCartesianProduct':len(results)==28 and all(r['status']=='PASS_CORE_STRATEGY_LIFECYCLE' for r in results),'productionApproval':False,
        'sourceStable':before==after,'sourceHashes':before,'baseCommit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'dependencies':dependencies,
        'sourceScope':'All production and script inputs, foundry.toml and the executed stage complete first-party Solidity import closure; vendor versions bound by frozen git submodule pins.',
        'compiler':{'version':'0.8.28','optimizerRuns':200,'viaIR':True,'evmVersion':'cancun','metadata':'none'},
        'coreScope':'Frozen public source 9a9d120, fresh per-asset instances; not a claim that the deployed USDC Core changed underlying or that every deployed Core component has identical executable code.',
        'inventorySha256':inventory_hash,'inventoryStable':inventory_stable,
        'catalogueHashes':catalogue_hashes,'cataloguesStable':catalogues_stable,
        'rows':results,'scope':'Local fork, frozen Core source, real markets and holder transfers. No mainnet broadcast. No native Nitro fee certification.'}
    (run/'acceptance.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(str(run.relative_to(ROOT)),report['status'],flush=True)
    return 0 if complete else 1

if __name__=='__main__':raise SystemExit(main())
