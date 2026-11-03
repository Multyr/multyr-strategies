"""Construct an UNFUNDED source-derived fixture; never project financial state.

Only the owned local Anvil process accepts writes. Public RPCs are read-only.
The resulting checkpoint is a calibration fixture, not deployment approval.
"""
import argparse
import gzip
import hashlib
import importlib.util
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[4]
SPEC = importlib.util.spec_from_file_location('receipt_runner', ROOT / 'script/lending/validation/transaction-gas/runner.py')
g = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(g)
LOCAL = 'http://127.0.0.1:18546'
g.DEDICATED_PORT = 18546
g.LOCAL_ANVIL_URL = LOCAL
PUBLIC = 'https://arb1.arbitrum.io/rpc'
ARCHIVE = 'https://arbitrum-one.public.blastapi.io'
OWNER = '0xF977814e90dA44bFA03b6295A0616a897441aceC'
ASSET = '0xaf88d065e77c8cc2239327c5edb3a432268e5831'
ZERO = '0x' + '00' * 20
ASSET_FEED = '0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3'
ETH_FEED = '0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612'
SEQ_FEED = '0xFdB631F5EE196F0ed6FAa767959853A9F217697D'
MARKETS = {
    'aave': '0x794a61358D6845594F94dc1DB02A252b5b4814aD',
    'comet': '0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf',
    'morpho': '0x7c574174DA4b2be3f705c6244B4BfA0815a8B3Ed',
    # K3 USDai USDC: eligible at the calibration pin. The smaller K3 Arbitrum
    # USDC market is retained as a rejected sub-$100k case in R17 evidence.
    'euler': '0x6aFB8d3F6D4A34e9cB2f217317f4dc8e05Aa673b',
    'fluid': '0x1A996cb54bb95462040408C06122D45D6Cdb6096',
    'dolomite': '0x444868B6e8079ac2c55eea115250f92C2b2c4D14',
    'venus': '0x7D8609f8da70fF9027E9bc5229Af4F6727662707',
}
ABI = {}
ADDRESSES = {}
PROOFS = {}
TRANSACTIONS = []


def cli(args):
    return subprocess.run(args, cwd=ROOT, text=True, capture_output=True, check=True).stdout.strip()


def abi(name):
    if name not in ABI:
        ABI[name] = json.loads(cli(['forge', 'inspect', name, 'abi', '--json']))
    return ABI[name]


def canonical(item):
    t = item['type']
    return '(' + ','.join(canonical(x) for x in item['components']) + ')' + t[5:] if t.startswith('tuple') else t


def literal(value):
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, tuple):
        return '(' + ','.join(literal(x) for x in value) + ')'
    if isinstance(value, list):
        return '[' + ','.join(literal(x) for x in value) + ']'
    return str(value)


def encode(signature, values, selector=True):
    return cli(['cast', 'calldata' if selector else 'abi-encode', signature] + [literal(x) for x in values])


def function(name, method, count=None):
    matches = [x for x in abi(name) if x.get('type') == 'function' and x['name'] == method
               and (count is None or len(x['inputs']) == count)]
    if len(matches) != 1:
        raise RuntimeError(f'Ambiguous/missing ABI {name}.{method}: {len(matches)}')
    return matches[0]


def calldata(name, method, values):
    f = function(name, method, len(values))
    return encode(method + '(' + ','.join(canonical(x) for x in f['inputs']) + ')', values)


def read(name, target, method, values=()):
    return g.rpc(LOCAL, 'eth_call', [{'to': target, 'data': calldata(name, method, values)}, 'latest'])


def send(name, target, method, values=()):
    receipt = g.send_tx(OWNER, target, calldata(name, method, values))
    TRANSACTIONS.append({'contract': name, 'method': method, 'target': target, 'receipt': receipt})
    return receipt


def deploy(key, name, values=()):
    ctors = [x for x in abi(name) if x.get('type') == 'constructor']
    inputs = ctors[0]['inputs'] if ctors else []
    if len(inputs) != len(values):
        raise RuntimeError(f'Constructor argument mismatch: {name}')
    creation = cli(['forge', 'inspect', name, 'bytecode', '--json']).strip()
    if not creation.startswith('0x') or '__' in creation:
        raise RuntimeError(f'Invalid/unlinked creation code: {name}')
    args = encode('constructor(' + ','.join(canonical(x) for x in inputs) + ')', values, False) if inputs else '0x'
    receipt, address = g.deploy_adapter(OWNER, creation + args[2:])
    ADDRESSES[key] = address
    code = g.rpc(LOCAL, 'eth_getCode', [address, 'latest'])
    PROOFS[key] = {'contract': name, 'constructorArguments': values, 'constructorAbi': inputs,
                   'creationSha256': hashlib.sha256(bytes.fromhex((creation + args[2:])[2:])).hexdigest(),
                   'runtimeSha256': hashlib.sha256(bytes.fromhex(code[2:])).hexdigest(), 'receipt': receipt}
    return address


def dump():
    return json.loads(gzip.decompress(bytes.fromhex(g.rpc(LOCAL, 'anvil_dumpState', [])[2:])))


def balance(token, account):
    return int(g.rpc(LOCAL, 'eth_call', [{'to': token, 'data': encode('balanceOf(address)', [account])}, 'latest']), 16)


def financial_fingerprint():
    # Existing accounts/markets: these MUST stay canonical through a restore.
    return {'ownerNative': g.rpc(LOCAL, 'eth_getBalance', [OWNER, 'latest']),
            'ownerAsset': balance(ASSET, OWNER),
            'supply': g.rpc(LOCAL, 'eth_call', [{'to': ASSET, 'data': encode('totalSupply()', [])}, 'latest']),
            'marketAssetBalances': {k: str(balance(ASSET, v)) for k, v in MARKETS.items()}}


def owned_accounts():
    accounts = {k.lower(): v for k, v in dump()['accounts'].items()}
    selected = {}
    for address in ADDRESSES.values():
        account = accounts[address.lower()]
        if int(str(account['balance']), 0) != 0:
            raise RuntimeError('Funded owned contract cannot be projected')
        if balance(ASSET, address) != 0:
            raise RuntimeError('Owned contract has financial position')
        # This is deliberately stricter than checking adapter.totalAssets alone.
        for token in [v for k, v in MARKETS.items() if k != 'aave'] + ['0x724dc807b04555b71ed48a6896b6F41593b8C637']:
            if balance(token, address) != 0:
                raise RuntimeError('Owned contract has receipt-token balance')
        selected[address.lower()] = account
    if int(read('CoreVault', ADDRESSES['core'], 'totalSupply'), 16) != 0:
        raise RuntimeError('Core must remain unseeded')
    return selected


def restore(accounts, target):
    g._kill_anvil()
    g.start_anvil(ARCHIVE, target)
    header = g.rpc(LOCAL, 'eth_getBlockByNumber', ['latest', False])
    canonical_header = g.rpc(ARCHIVE, 'eth_getBlockByNumber', [hex(target), False])
    if header['hash'] != canonical_header['hash']:
        raise RuntimeError('Target fork header mismatch')
    before = financial_fingerprint()
    for address in accounts:
        if g.rpc(LOCAL, 'eth_getCode', [address, 'latest']) != '0x' or int(g.rpc(LOCAL, 'eth_getTransactionCount', [address, 'latest']), 16) or int(g.rpc(LOCAL, 'eth_getBalance', [address, 'latest']), 16):
            raise RuntimeError('Own deployment address is occupied at target')
        if balance(ASSET, address):
            raise RuntimeError('Own deployment address prefunded at target')
    target_dump = dump()
    target_dump['accounts'] = accounts
    payload = '0x' + gzip.compress(json.dumps(target_dump).encode()).hex()
    if not g.rpc(LOCAL, 'anvil_loadState', [payload]):
        raise RuntimeError('Owned state restore failed')
    after_header = g.rpc(LOCAL, 'eth_getBlockByNumber', ['latest', False])
    for key in ['number', 'hash', 'timestamp', 'baseFeePerGas']:
        if after_header[key] != header[key]:
            raise RuntimeError('Target canonical context changed')
    if before != financial_fingerprint():
        raise RuntimeError('Existing financial state changed')
    g.rpc(LOCAL, 'anvil_impersonateAccount', [OWNER])
    return header


def build(output, old_block=518500000, sample_block=None, acceptance_path=None):
    acceptance_path = acceptance_path or ROOT / 'docs/lending-production-remediation-20261101/r25-actual-50-acceptance.json'
    acceptance = json.loads(acceptance_path.read_text(encoding='utf-8-sig'))
    if (acceptance['passed'], acceptance['failed'], acceptance['skipped'], acceptance['suites']) != (50, 0, 0, 21):
        raise RuntimeError('Complete actual-market acceptance required')
    if cli(['git', 'branch', '--show-current']) != 'codex/lending-multitoken-multichain':
        raise RuntimeError('Candidate branch required')
    core_pin = '9a9d120709de99a6216e9fe75d36e9ffdcb1a4d9'
    if cli(['git', '-C', 'lib/multyr-core', 'rev-parse', 'HEAD']) != core_pin:
        raise RuntimeError('Frozen Core pin changed')
    cli(['git', '-C', 'lib/multyr-core', 'diff', '--exit-code', '--quiet', 'HEAD'])
    config = json.loads(cli(['forge', 'config', '--json']))
    required = {'solc': '0.8.28', 'optimizer': True, 'optimizer_runs': 200,
                'via_ir': True, 'evm_version': 'cancun', 'bytecode_hash': 'none', 'cbor_metadata': False}
    if any(config.get(key) != value for key, value in required.items()):
        raise RuntimeError('Unexpected production compiler configuration')
    current_paths = set(cli(['git', 'ls-files', '--', 'src', 'script', 'test', 'foundry.toml']).splitlines())
    current_paths.update(cli(['git', 'ls-files', '--others', '--exclude-standard', '--', 'src', 'script', 'test', 'foundry.toml']).splitlines())
    current_paths = {path for path in current_paths if path.endswith('.sol') or path == 'foundry.toml'}
    if current_paths != {item['path'] for item in acceptance['sources']}:
        raise RuntimeError('Candidate source file set changed since accepted fork gate')
    for item in acceptance['sources']:
        if hashlib.sha256((ROOT / item['path']).read_bytes()).hexdigest() != item['sha256']:
            raise RuntimeError('Candidate source changed since accepted fork gate: ' + item['path'])
    if sample_block is None:
        latest = g.rpc(PUBLIC, 'eth_getBlockByNumber', ['latest', False])
        sample_block = int(latest['number'], 16) - 300000
    if sample_block <= old_block:
        raise RuntimeError('Need genuinely later canonical PPS sample')
    g.ARTIFACTS_DIR = output.parent / 'checkpoint-raw'
    g.ARTIFACTS_DIR.mkdir(parents=True, exist_ok=True)
    g.ANVIL_METHODS = g.ANVIL_METHODS | {'anvil_dumpState', 'anvil_loadState'}
    g.start_anvil(ARCHIVE, old_block)
    if int(g.rpc(LOCAL, 'eth_chainId', []), 16) != 42161:
        raise RuntimeError('Wrong chain')
    old_header = g.rpc(LOCAL, 'eth_getBlockByNumber', ['latest', False])
    g.rpc(LOCAL, 'anvil_impersonateAccount', [OWNER])
    config = deploy('globalConfig', 'GlobalConfig', [OWNER, 0, 0, 0, 86400, 10, 100, 300, 86400])
    oracle = deploy('oracle', 'PriceOracleMiddleware', [OWNER])
    send('PriceOracleMiddleware', oracle, 'setOracleFeed', [ASSET, ASSET_FEED, 86400])
    send('GlobalConfig', config, 'setAssetOracleConfig', [ASSET, oracle, 86400])
    core = deploy('core', 'CoreVault', [ASSET, 'Native keeper calibration', 'rGAS', OWNER, OWNER, config])
    registry = deploy('selectorRegistry', 'SelectorRegistry')
    send('CoreVault', core, 'setSelectorRegistry', [registry])
    modules = {k: deploy(k, n) for k, n in [('admin', 'AdminModule'), ('erc', 'ERC4626Module'), ('queue', 'EpochedQueueModule'), ('liq', 'LiquidityOpsModule')]}
    bindings = {'admin': ['setBufferManager', 'setRouter', 'setInitialFees', 'setInitialPerfParams', 'seedDeadDeposit', 'freezeParams'],
                'erc': ['deposit', 'mint', 'withdraw', 'redeem'],
                'queue': ['requestEpochWithdrawal', 'closeCurrentEpoch', 'fundEpoch', 'claimEpochAssets', 'epochClaim', 'epochDeficit'],
                'liq': ['deployToStrategies', 'realizeForQueue']}
    names = {'admin': 'AdminModule', 'erc': 'ERC4626Module', 'queue': 'EpochedQueueModule', 'liq': 'LiquidityOpsModule'}
    for key, methods in bindings.items():
        for method in methods:
            arity = {'deposit': 2, 'mint': 2, 'withdraw': 3, 'redeem': 3}.get(method) if key == 'erc' else None
            f = function(names[key], method, arity)
            signature = method + '(' + ','.join(canonical(x) for x in f['inputs']) + ')'
            selector = encode(signature, [default(x) for x in f['inputs']])[:10]
            role = int(read('SelectorRegistry', registry, 'getRequiredRole', [selector]), 16)
            if role > 4:
                raise RuntimeError('Unknown canonical selector role')
            send('CoreVault', core, 'setModule', [selector, modules[key], role])
    send('CoreVault', core, 'authorizeModule', [modules['erc'], True])
    buffer = deploy('buffer', 'BufferManager', [OWNER, core, (400, 200, 600, 800, 400, 50, ASSET, ZERO, 0, False)])
    router = deploy('router', 'StrategyRouter', [OWNER, core, config])
    send('AdminModule', core, 'setBufferManager', [buffer])
    send('AdminModule', core, 'setRouter', [router])
    send('AdminModule', core, 'setInitialFees', [0, 0, 0, 0, OWNER])
    send('AdminModule', core, 'setInitialPerfParams', [200000000000000000, 604800])
    params = deploy('params', 'StrategyParamsModule', [ASSET, core])
    ops = deploy('ops', 'StrategyAdapterOpsModule', [ASSET, core, params, ZERO, ZERO])
    scoring = deploy('scoring', 'StrategyScoringModule', [ASSET, core, params, ZERO, ops])
    gate = deploy('gate', 'StrategyRebalanceGateModule', [ASSET, core, params, scoring, ops])
    constructor = next(x for x in abi('UsdcMultiLendingVault') if x['type'] == 'constructor')
    x = {v['name']: default(v) for v in constructor['inputs'][-1]['components']}
    x.update(maxAdaptersPerAllocation=5, minAdaptersActive=1, wAPY=5000, wLiq=2000, wRisk=2000, wStability=1000,
             newAdapterRampBps=5000, minSecondsBetweenRebalances=86400, minSecondsBetweenHarvests=86400,
             minSecondsBetweenDeployIdle=300, harvestThresholdBps=100, stabilityEMAPeriod=7,
             maxIdleAfterDepositBps=500, maxIdleBootstrapBps=500, dustTolerance=1,
             externalTVLStalenessSeconds=86400, gateHorizonDays=7, gasCostUSDC=1000000, degradedViewThresholdBps=2500)
    if set(x) != {v['name'] for v in constructor['inputs'][-1]['components']}:
        raise RuntimeError('Strategy init field drift')
    strategy = deploy('strategy', 'UsdcMultiLendingVault', [ASSET, core, router, OWNER, OWNER, ZERO, params, scoring, ops, gate, tuple(x.values())])
    for key, name, method, args in [('settings', 'StrategySettingsModule', 'setSettingsModule', [ASSET, core]),
                                    ('alloc', 'StrategyAllocCalcModule', 'setAllocCalcModule', [ASSET, core]),
                                    ('plan', 'StrategyRebalancePlanModule', 'setRebalancePlanModule', [ASSET, core, params, scoring, ops])]:
        send('UsdcMultiLendingVault', strategy, method, [deploy(key, name, args)])
    safety = deploy('safety', 'StrategySafetyOverflowModule', [ASSET, core, params, scoring, ops])
    send('StrategySettingsModule', strategy, 'setSafetyOverflowModule', [safety])
    cfg_values = dict(prepareGas=4000000, stepGas=2000000, finalizeGas=600000, defaultDepositGas=1500000,
                      defaultWithdrawGas=2000000, intrinsicGas=23112, calldataBytes=132, marginBps=3000,
                      maxPriceAge=3600, usdcMaxPriceAge=3600, sequencerGrace=3600, fallbackUSDC=100000000)
    ec = next(z for z in abi('ReadOnlyGasEstimator') if z['type'] == 'constructor')['inputs'][-1]['components']
    if {v['name'] for v in ec} != set(cfg_values):
        raise RuntimeError('Estimator config ABI drift')
    estimator = deploy('estimator', 'ReadOnlyGasEstimator', ['0x000000000000000000000000000000000000006c', ETH_FEED, ASSET_FEED, SEQ_FEED, tuple(cfg_values[v['name']] for v in ec)])
    send('StrategySettingsModule', strategy, 'setRebalanceGasEstimator', [estimator])
    send('StrategySettingsModule', strategy, 'setMaxRebalanceActionsPerTx', [2])
    upkeep = deploy('upkeep', 'StrategyUpkeep', [[strategy]])
    keeper_role = read('UsdcMultiLendingVault', strategy, 'KEEPER_ROLE')
    send('UsdcMultiLendingVault', strategy, 'grantRole', [keeper_role, upkeep])
    protocol_registry = deploy('protocolRegistry', 'ProtocolRegistry', [OWNER])
    for key, enum in [('morpho', 2), ('comet', 3), ('dolomite', 4)]:
        send('ProtocolRegistry', protocol_registry, 'addVault', [enum, MARKETS[key], key, 5000, 10000000 * 10**6])
    adapter_names = {'aave': 'AaveV3USDCAdapter', 'comet': 'CometUsdcMultiMarketAdapter', 'morpho': 'MorphoUsdcMultiMarketAdapter',
                     'euler': 'EulerUsdcMultiMarketAdapter', 'fluid': 'FluidUsdcMultiMarketAdapter',
                     'dolomite': 'DolomiteUsdcMultiMarketAdapter', 'venus': 'VenusUsdcMultiMarketAdapter'}
    for key, name in adapter_names.items():
        deploy(key, name)
    for key in ['morpho', 'dolomite']:
        send(adapter_names[key], ADDRESSES[key], 'initialize', [ASSET, OWNER, strategy, 10000000 * 10**6, protocol_registry])
        send(adapter_names[key], ADDRESSES[key], 'pokeAPYSnapshots')
    send(adapter_names['fluid'], ADDRESSES['fluid'], 'initialize', [ASSET, OWNER, strategy, 10000000 * 10**6, MARKETS['fluid']])
    send('StrategyRouter', router, 'proposeStrategyAllowlist', [strategy])
    allowlist_eta = int(read('StrategyRouter', router, 'strategyAllowlistEta', [strategy]), 16)
    old_accounts = owned_accounts()
    sample_header = restore(old_accounts, sample_block)
    for key in ['morpho', 'dolomite', 'fluid']:
        send(adapter_names[key], ADDRESSES[key], 'pokeAPYSnapshots')
    final_accounts = owned_accounts()
    overrides = {a: {'code': v['code'], 'nonce': hex(int(str(v['nonce']), 0)),
                     'state': {pad(k): pad(value) for k, value in v['storage'].items()}}
                 for a, v in final_accounts.items()}
    result = {'schemaVersion': 1, 'chainId': 42161, 'deployer': OWNER, 'asset': ASSET,
              'oldBlock': old_block, 'sampleBlock': sample_block, 'oldHeader': old_header, 'sampleHeader': sample_header,
              'addresses': ADDRESSES, 'stateOverrides': overrides, 'ownedAccounts': final_accounts,
              'constructorProofs': PROOFS, 'transactions': TRANSACTIONS, 'markets': MARKETS,
              'eulerMarketSelection': {'source': 'https://github.com/euler-xyz/euler-labels/blob/master/42161/products.json',
                                       'positiveMarket': MARKETS['euler'],
                                       'negativeUnderMinimumMarket': '0x0a1eCC5Fe8C9be3C809844fcBe615B46A869b899',
                                       'reason': 'Use an actual market above the unchanged $100k eligibility floor for positive gas calibration; retain the original negative case.',
                                       'productionApproval': False},
              'initialization': {'initialized': ['morpho', 'dolomite', 'fluid'], 'deferred': ['aave', 'comet', 'euler', 'venus'], 'allowlistEta': str(allowlist_eta)},
              'sourceAcceptanceSha256': hashlib.sha256(acceptance_path.read_bytes()).hexdigest(),
              'builderSha256': hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
              'compiler': cli(['forge', '--version']),
              'compilerConfiguration': required, 'frozenCoreCommit': core_pin,
              'policy': {'strategyInitParams': x, 'estimatorConfig': cfg_values, 'maxActionsPerTx': 2,
                         'adapterCapacityRaw': str(10000000 * 10**6),
                         'benchmarkOnly': True}, 'readiness': 'NOT_PRODUCTION_READY'}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'status': 'UNFUNDED_CHECKPOINT_BUILT', 'contracts': len(ADDRESSES), 'output': str(output)}))


def pad(value):
    return '0x' + hex(int(str(value), 0))[2:].zfill(64)


def default(item):
    t = item['type']
    if t.endswith('[]'):
        return []
    if t.startswith('tuple'):
        return tuple(default(x) for x in item['components'])
    if t == 'address':
        return ZERO
    if t == 'bool':
        return False
    if t == 'string':
        return ''
    if t.startswith('bytes'):
        return '0x' if t == 'bytes' else '0x' + '00' * int(t[5:])
    if t.startswith(('uint', 'int')):
        return 0
    raise RuntimeError('Unsupported ABI default: ' + t)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / 'deployments/lending-full-validation-20261101/production/keeper-gas/checkpoint.json')
    parser.add_argument('--old-block', type=int, default=518500000)
    parser.add_argument('--sample-block', type=int, help='Explicit canonical later PPS sampling block.')
    parser.add_argument('--acceptance', type=pathlib.Path, help='Matching source-bound actual-market acceptance receipt.')
    options = parser.parse_args()
    try:
        build(options.output.resolve(), options.old_block, options.sample_block,
              options.acceptance.resolve() if options.acceptance else None)
    finally:
        g._kill_anvil()
        trace_path = options.output.resolve().parent / 'checkpoint-rpc-trace.json'
        trace_path.parent.mkdir(parents=True, exist_ok=True)
        trace_path.write_text(json.dumps(g.RPC_TRACE, indent=2) + '\n', encoding='utf-8')
