import os,shlex,subprocess
from pathlib import Path
env=os.environ.copy()
for line in Path('.env').read_text().splitlines():
 if line.startswith('RPC_URL='): env['REHEARSAL_RPC']=shlex.split(line.split('=',1)[1],comments=True)[0]
env['RUN_REPLACEMENT_REHEARSAL']='true'
env['REHEARSAL_BLOCK']='516950276'
env['REHEARSAL_FEES']='0x'+''.join(hex(n)[2:].zfill(64) for n in [43780280320,312716288,402360000000,20000000,118000,20118000])
p=subprocess.run(['/Users/warlock/.foundry/bin/forge','test','--match-path','test/strategies/usdc-lending/fork/EstimatorTierCalibration.fork.t.sol','--match-test','test_representativeTierPlans','-vv'],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
s=p.stdout.replace(env['REHEARSAL_RPC'],'<RPC>')
Path('deployments/estimator-margin-20261023/fork-tiers.log').write_text(s)
print(s[-10000:]);raise SystemExit(p.returncode)
