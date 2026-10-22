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
binpath = '/Users/warlock/.foundry/bin/'

def run(args, name):
    p = subprocess.run(args, env=env, capture_output=True, text=True)
    s = p.stdout + p.stderr
    for k,v in env.items():
        if v and any(t in k for t in ['PRIVATE_KEY','RPC_URL','API_KEY','SECRET','TOKEN']): s = s.replace(v, '<redacted>')
    (OUT / (name + '.log')).write_text(s)
    print(s[-5000:])
    if p.returncode: raise SystemExit(p.returncode)
    return p.stdout

mode = sys.argv[1]
if mode == 'preflight':
    run(['node', 'script/release-ema-preflight.mjs'], 'preflight')
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
