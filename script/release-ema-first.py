"""Release runner: secrets stay in subprocess environment; logs are redacted."""
import os, sys, shlex, subprocess, json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
os.chdir(ROOT)
OUT = ROOT / 'deployments/ema-first-20261023'
env = os.environ.copy()
for path in [ROOT / '.env', OUT / 'public.env']:
    for line in path.read_text().splitlines():
        line = line.strip()
        if line.startswith('export '): line = line[7:]
        if not line or line.startswith('#') or '=' not in line: continue
        key, value = line.split('=', 1)
        values = shlex.split(value, comments=True)
        if values: env[key] = values[0]
env['ETH_RPC_URL'] = env['RPC_URL']
env['RUST_LOG'] = 'error'
binpath = '/Users/warlock/.foundry/bin/'

def run(args, name):
    p = subprocess.Popen(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    lines=[]
    with (OUT / (name + '.log')).open('w') as log:
        for line in p.stdout:
            for k,v in env.items():
                if v and any(t in k for t in ['PRIVATE_KEY','RPC_URL','API_KEY','SECRET','TOKEN']): line=line.replace(v,'<redacted>')
            log.write(line);log.flush();lines.append(line)
    p.wait()
    s=''.join(lines)
    print(s[-5000:])
    if p.returncode: raise SystemExit(p.returncode)
    return s

mode = sys.argv[1]
if mode == 'preflight':
    run(['node', 'script/release-ema-preflight.mjs'], 'preflight')
elif mode == 'safe':
    run(['node','script/ema-first-safe.mjs'],'safe-generation')
elif mode == 'safe-rehearsal':
    state=json.loads((OUT/'preflight.json').read_text())
    env.update(RUN_RELEASE_SAFE_REHEARSAL='true',REHEARSAL_RPC=env['RPC_URL'],REHEARSAL_BLOCK=state['blockNumber'],REHEARSAL_FEES=state['feeSnapshot'])
    run([binpath+'forge','test','--match-path','test/strategies/usdc-lending/fork/ReleaseSafeBatch.fork.t.sol','-vv'],'safe-rehearsal')
elif mode == 'verify-allocator-check':
    import urllib.request, urllib.parse
    job=json.loads((OUT/'allocator-verification-job.json').read_text())
    query=urllib.parse.urlencode(dict(chainid=42161,module='contract',action='checkverifystatus',guid=job['guid'],apikey=env['ETHERSCAN_API_KEY']))
    result=json.loads(urllib.request.urlopen('https://api.etherscan.io/v2/api?'+query,timeout=30).read())
    (OUT/'allocator-exact-verification.json').write_text(json.dumps(result,indent=2)+'\n');print(result)
elif mode == 'verify-allocator-exact':
    import urllib.request, urllib.parse, time
    name='StrategyAllocCalcModule';source='src/strategies/usdc-lending/controller/'+name+'.sol'
    artifact=json.loads((ROOT/f'out/{name}.sol/{name}.json').read_text())
    broadcast=json.loads((ROOT/'broadcast/DeployUsdcLendingStrategy.s.sol/42161/run-latest.json').read_text())
    t=next(t for t in broadcast['transactions'] if t.get('contractName')==name and t['transactionType']=='CREATE')
    bytecode=artifact['bytecode']['object'].removeprefix('0x');data=t['transaction']['input'].removeprefix('0x')
    compiled=json.loads((OUT/'allocator-exact-output.json').read_text())['contracts'][source][name]['evm']['bytecode']['object']
    assert data.startswith(compiled) and compiled==bytecode
    def api(payload):
        payload.update(apikey=env['ETHERSCAN_API_KEY'],chainid='42161',module='contract')
        req=urllib.request.Request('https://api.etherscan.io/v2/api?chainid=42161',data=urllib.parse.urlencode(payload).encode())
        return json.loads(urllib.request.urlopen(req,timeout=60).read())
    response=api(dict(action='verifysourcecode',contractaddress=t['contractAddress'],sourceCode=(OUT/'allocator-exact-input.json').read_text(),codeformat='solidity-standard-json-input',contractname=source+':'+name,compilerversion='v'+artifact['metadata']['compiler']['version'],constructorArguements=data[len(bytecode):]))
    print(response,flush=True)
    assert response['status']=='1',response
    guid=response['result']
    for _ in range(12):
        time.sleep(5)
        result=api(dict(action='checkverifystatus',guid=guid));print(result,flush=True)
        (OUT/'allocator-exact-verification.json').write_text(json.dumps(result,indent=2)+'\n')
        if result['status']=='1': break
        if 'Pending' not in result['result']:raise SystemExit(1)
    else:raise SystemExit('Verification still pending')
elif mode in ['verify-estimator','verify-strategy']:
    script='DeployReadOnlyGasEstimator' if mode=='verify-estimator' else 'DeployUsdcLendingStrategy'
    broadcast=json.loads((ROOT/f'broadcast/{script}.s.sol/42161/run-latest.json').read_text())
    receipts={r['transactionHash'].lower():r for r in broadcast['receipts']}
    deployments=[]
    for t in broadcast['transactions']:
        if t.get('transactionType')=='CREATE': deployments.append(t)
        for child in t.get('additionalContracts',[]):
            deployments.append({'hash':t['hash'],'contractName':child['contractName'],'contractAddress':child['address'],'transaction':{'input':child['initCode']}})
    for t in deployments:
        assert t['hash'].lower() in receipts and int(receipts[t['hash'].lower()]['status'],16)==1
        name=t['contractName']
        if name in os.environ.get('VERIFY_SKIP','').split(','): continue
        prior=OUT/('verify-'+name+'.log')
        if prior.exists() and any(x in prior.read_text() for x in ['Contract successfully verified','is already verified. Skipping verification.']): continue
        files=list((ROOT/'out').glob(f'*/{name}.json'))
        assert len(files)==1,(name,files)
        artifact=json.loads(files[0].read_text())
        source=next(iter(artifact['metadata']['settings']['compilationTarget']))
        bytecode=artifact['bytecode']['object'].removeprefix('0x')
        data=t['transaction']['input'].removeprefix('0x')
        assert data.startswith(bytecode),'Initcode mismatch'
        args=data[len(bytecode):]
        command=[binpath+'forge','verify-contract',t['contractAddress'],source+':'+name,'--chain','42161','--watch']
        if args: command+=['--constructor-args','0x'+args]
        run(command,'verify-'+name)
elif mode in ['estimator-dry', 'estimator-live', 'strategy-dry', 'strategy-live']:
    target = 'DeployReadOnlyGasEstimator' if mode.startswith('estimator') else 'DeployUsdcLendingStrategy'
    if mode.startswith('strategy'):
        state = json.loads((OUT / 'preflight.json').read_text())
        env['ARBITRUM_FEE_SNAPSHOT'] = state['feeSnapshot']
    args = [binpath+'forge','script',f'script/{target}.s.sol:{target}','--rpc-url',env['RPC_URL'],'--slow','-vv']
    if mode.endswith('live'): args += ['--broadcast']
    run(args, mode)
else:
    raise SystemExit('Unknown mode')
