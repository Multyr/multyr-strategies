"""Read-only Nitro calibration. Simulated gas is NOT mined receipt gas.

Never override existing financial/protocol/precompile accounts. Only unfunded,
constructor-produced, unused fixture contracts may receive code/storage/nonce.
"""
import argparse
import concurrent.futures
import hashlib
import importlib.util
import json
import os
import pathlib
import threading
import time
import urllib.error
import urllib.request
import urllib.parse

SPEC = importlib.util.spec_from_file_location('checkpoint_builder', pathlib.Path(__file__).with_name('build_checkpoint.py'))
b = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(b)
g = b.g
RPC = 'https://arbitrum-one-rpc.publicnode.com'
PUBLIC_ENDPOINTS = {b.PUBLIC, 'https://arbitrum.drpc.org', 'https://arbitrum-one-rpc.publicnode.com'}
SIMULATOR_SHA256 = hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()
USDT = '0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9'
USDT_FEED = '0x3f3f5df88dc9f13eac63df89ec16ef6e7e25dde7'
SWAP = '0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45'
NATIVE = '0x000000000000000000000000000000000000006c'
ATOKEN = '0x724dc807b04555b71ed48a6896b6F41593b8C637'
AMOUNT = 88000 * 10**6
DEPOSIT = 80000 * 10**6
NETWORK_RPC = g.rpc
CANONICAL_CACHE = {}
CACHE_HITS = 0
RATE_LOCK = threading.Lock()
NEXT_REQUEST_AT = 0.0
ENCODE_CACHE = {}
ORIGINAL_ENCODE = b.encode
BATCH_SEQUENCE = 1000000
CANONICAL_BATCH_SIZE = 4
CANONICAL_READS_PER_SECOND = 4


def cached_encode(signature, values, selector=True):
    key = (signature, tuple(b.literal(value) for value in values), selector)
    if key not in ENCODE_CACHE:
        ENCODE_CACHE[key] = ORIGINAL_ENCODE(signature, values, selector)
    return ENCODE_CACHE[key]


b.encode = cached_encode


def rpc_label(url):
    return url if url in PUBLIC_ENDPOINTS else '<authorized-rpc>'


def safe_error(error):
    if RPC in PUBLIC_ENDPOINTS:
        return str(error)
    if isinstance(error, urllib.error.HTTPError):
        return 'Authorized RPC HTTP status ' + str(error.code)
    text = str(error)
    if isinstance(error, RuntimeError) and not text.startswith(('RPC error', 'Canonical batch RPC error', 'Call failed:')) and RPC not in text:
        return text
    return type(error).__name__ + ': authorized RPC error (provider details omitted)'


def trace_for_disk():
    result = []
    for entry in g.RPC_TRACE:
        clean = dict(entry)
        url = clean.get('url', '')
        clean['url'] = rpc_label(url)
        if url not in PUBLIC_ENDPOINTS and 'body' in clean:
            try:
                value = json.loads(clean['body'])
                if isinstance(value, dict) and 'error' in value:
                    value['error'] = {'code': value['error'].get('code'), 'message': 'Provider details omitted for credential safety'}
                elif not isinstance(value, dict) or 'result' not in value:
                    value = {'message': 'Nonstandard provider response omitted for credential safety'}
                clean['body'] = json.dumps(value)
            except (ValueError, TypeError):
                clean['body'] = 'Provider response omitted for credential safety'
        result.append(clean)
    return result


def guarded_rpc(url, method, params):
    """Cache only immutable, explicitly block-pinned canonical reads.

    Stateful counterfactual simulations are always executed by the actual node.
    Every cache entry originates in a successful recorded network response.
    """
    global CACHE_HITS, NEXT_REQUEST_AT
    pinned = method in {'eth_call', 'eth_getCode', 'eth_getBalance', 'eth_getTransactionCount'} and bool(params) and isinstance(params[-1], str) and params[-1].startswith('0x')
    key = (url, method, json.dumps(params, sort_keys=True))
    if pinned and key in CANONICAL_CACHE:
        CACHE_HITS += 1
        return CANONICAL_CACHE[key]
    for retry in range(3):
        with RATE_LOCK:
            delay = max(0.0, NEXT_REQUEST_AT - time.monotonic())
            NEXT_REQUEST_AT = max(NEXT_REQUEST_AT, time.monotonic()) + 0.15
        if delay:
            time.sleep(delay)
        try:
            value = NETWORK_RPC(url, method, params)
            if pinned:
                CANONICAL_CACHE[key] = value
            return value
        except (urllib.error.HTTPError, TimeoutError) as error:
            status = getattr(error, 'code', None)
            if retry == 2 or (status is not None and status not in {429, 502, 503, 504}):
                raise
            time.sleep(2 * (retry + 1))


g.rpc = guarded_rpc


def canonical_batch(items):
    """Read canonical data in bounded JSON-RPC batches, never simulations/writes."""
    global BATCH_SEQUENCE, NEXT_REQUEST_AT, CACHE_HITS
    values = [None] * len(items)
    pending = []
    for index, (method, params) in enumerate(items):
        if method not in {'eth_call', 'eth_getCode', 'eth_getBalance', 'eth_getTransactionCount'} or not isinstance(params[-1], str) or not params[-1].startswith('0x'):
            raise RuntimeError('Batch accepts explicitly pinned canonical reads only')
        g._guard_rpc(RPC, method)
        key = (RPC, method, json.dumps(params, sort_keys=True))
        if key in CANONICAL_CACHE:
            CACHE_HITS += 1
            values[index] = CANONICAL_CACHE[key]
        else:
            pending.append((index, method, params, key))
    for start in range(0, len(pending), CANONICAL_BATCH_SIZE):
        chunk = pending[start:start + CANONICAL_BATCH_SIZE]
        payload = []
        for _, method, params, _ in chunk:
            BATCH_SEQUENCE += 1
            payload.append({'jsonrpc': '2.0', 'id': BATCH_SEQUENCE, 'method': method, 'params': params})
        with RATE_LOCK:
            delay = max(0.0, NEXT_REQUEST_AT - time.monotonic())
            NEXT_REQUEST_AT = max(NEXT_REQUEST_AT, time.monotonic()) + len(chunk) / CANONICAL_READS_PER_SECOND
        if delay:
            time.sleep(delay)
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                return None
        request = urllib.request.Request(RPC, data=json.dumps(payload).encode(), headers={'Content-Type': 'application/json', 'User-Agent': 'lending-validation/1.0'})
        try:
            with urllib.request.build_opener(NoRedirect).open(request, timeout=45) as response:
                body = response.read().decode()
                status = response.status
        except urllib.error.HTTPError as error:
            body = error.read().decode(errors='replace')
            for item in payload:
                g.RPC_TRACE.append({'url': RPC, 'request': item, 'httpStatus': error.code, 'body': body, 'batchSize': len(payload)})
            raise
        decoded = json.loads(body)
        if not isinstance(decoded, list) or len(decoded) != len(payload):
            raise RuntimeError('Canonical batch response cardinality mismatch')
        by_id = {entry['id']: entry for entry in decoded}
        if len(by_id) != len(payload):
            raise RuntimeError('Duplicate canonical batch response id')
        for (index, _, _, key), item in zip(chunk, payload):
            entry = by_id[item['id']]
            g.RPC_TRACE.append({'url': RPC, 'request': item, 'httpStatus': status, 'body': json.dumps(entry), 'batchSize': len(payload)})
            if 'error' in entry:
                raise RuntimeError('Canonical batch RPC error: ' + str(entry['error']))
            values[index] = entry['result']
            CANONICAL_CACHE[key] = entry['result']
    return values


def number(value):
    return int(str(value), 0)


def ceil_div(a, c):
    return (a + c - 1) // c


def words(data):
    if not data.startswith('0x') or (len(data) - 2) % 64:
        raise RuntimeError('Invalid ABI return length')
    return [int(data[i:i + 64], 16) for i in range(2, len(data), 64)]


def decode(name, method, data):
    f = b.function(name, method)
    signature = 'f()(' + ','.join(b.canonical(x) for x in f['outputs']) + ')'
    return json.loads(b.cli(['cast', 'abi-decode', signature, data, '--json']))


def run(checkpoint, output, attempt, venue, block, expected_hash):
    c = json.loads(checkpoint.read_text(encoding='utf-8-sig'))
    asset_profile = c.get('assetProfile', 'usdc')
    profile = b.configure_profile(asset_profile)
    direct_holder_deposit = asset_profile == 'usdt0-aave'
    atoken = profile['aToken']
    if direct_holder_deposit and venue != 'aave':
        raise RuntimeError('USDT0 qualification is Aave-only, never seven-family coverage')
    if c['chainId'] != 42161 or c['asset'].lower() != b.ASSET.lower() or c['deployer'].lower() != b.OWNER.lower():
        raise RuntimeError('Checkpoint identity mismatch')
    if c['builderSha256'] != hashlib.sha256(pathlib.Path(b.__file__).read_bytes()).hexdigest():
        raise RuntimeError('Checkpoint builder changed; rebuild before simulation')
    if c.get('compilerGraph') != b.COMPILER_GRAPH:
        raise RuntimeError('Checkpoint requires isolated production compilation')
    b.configure_compiler(checkpoint.parent)
    a, overrides = c['addresses'], c['stateOverrides']
    expected_names = set('globalConfig oracle core selectorRegistry admin erc queue liq buffer router params ops scoring gate strategy settings alloc plan safety estimator upkeep protocolRegistry'.split()) | set(profile['markets'])
    if c.get('activeVenues', list(profile['markets'])) != list(profile['markets']) or c['markets'] != profile['markets']:
        raise RuntimeError('Checkpoint active venue/market policy mismatch')
    if set(a) != expected_names or set(x.lower() for x in a.values()) != set(overrides) or len(set(a.values())) != len(a):
        raise RuntimeError('Unexpected checkpoint account set')
    for key, address in a.items():
        if int(address, 16) <= 0xffff:
            raise RuntimeError('Native/precompile address must never be projected')
        value = overrides[address.lower()]
        if set(value) != {'code', 'nonce', 'state'} or value['code'] == '0x':
            raise RuntimeError('Only own code/nonce/full-storage projection is permitted')
        if hashlib.sha256(bytes.fromhex(value['code'][2:])).hexdigest() != c['constructorProofs'][key]['runtimeSha256']:
            raise RuntimeError('Constructor/runtime provenance mismatch')
        proof = c['constructorProofs'][key]
        encoded = proof.get('encodedConstructorArguments', '')
        if not encoded.startswith('0x'):
            raise RuntimeError('Missing encoded constructor provenance')
        creation = b.creation_bytecode(proof['contract'])
        if hashlib.sha256(bytes.fromhex(creation[2:] + encoded[2:])).hexdigest() != proof['creationSha256']:
            raise RuntimeError('Fresh production creation bytecode mismatch')
    header = g.rpc(RPC, 'eth_getBlockByNumber', [hex(block), False])
    if header['hash'] != expected_hash:
        raise RuntimeError('Pinned canonical header changed')
    pin, basefee = header['number'], number(header['baseFeePerGas'])
    if number(header['timestamp']) < number(c['initialization']['allowlistEta']):
        raise RuntimeError('Real allowlist delay not elapsed')
    if number(g.rpc(RPC, 'eth_chainId', [])) != 42161 or basefee == 0:
        raise RuntimeError('Wrong chain/native fee context')

    def direct(target, data):
        return g.rpc(RPC, 'eth_call', [{'from': b.OWNER, 'to': target, 'data': data, 'gasPrice': hex(basefee)}, pin])

    # Parallel independent reads keep the explicitly pinned latest state recent.
    checks = []
    for address in a.values():
        checks.extend([('code', address, 'eth_getCode', [address, pin]),
                       ('nonce', address, 'eth_getTransactionCount', [address, pin]),
                       ('native', address, 'eth_getBalance', [address, pin])])
    values = canonical_batch([(x[2], x[3]) for x in checks])
    for (kind, address, _, _), value in zip(checks, values):
        if (kind == 'code' and value != '0x') or (kind != 'code' and number(value) != 0):
            raise RuntimeError('Projected address is occupied/funded: ' + address)
    if g.rpc(RPC, 'eth_getCode', [b.OWNER, pin]) != '0x' or number(g.rpc(RPC, 'eth_getBalance', [b.OWNER, pin])) < 10**18:
        raise RuntimeError('Need genuinely funded canonical EOA')
    receipt_tokens = [atoken] + [v for k, v in b.MARKETS.items() if k != 'aave']
    holdings = [(token, address) for token in [b.ASSET] + receipt_tokens for address in a.values()]
    balances = [number(value) for value in canonical_batch([('eth_call', [{'from': b.OWNER, 'to': token, 'data': b.encode('balanceOf(address)', [address]), 'gasPrice': hex(basefee)}, pin]) for token, address in holdings])]
    if any(balances):
        raise RuntimeError('Projected account has canonical financial assets')

    def price(feed):
        v = words(direct(feed, b.encode('latestRoundData()', [])))
        decimals = words(direct(feed, b.encode('decimals()', [])))[0]
        if len(v) != 5 or not 0 < v[1] < 2**255 or not 0 < v[3] <= number(header['timestamp']) or number(header['timestamp']) - v[3] > 86400 or v[4] < v[0] or decimals > 18:
            raise RuntimeError('Invalid canonical price round')
        return v[1] * 10**(18 - decimals)

    usdt_price, asset_price, eth_price = price(USDT_FEED), price(b.ASSET_FEED), price(b.ETH_FEED)
    native_words = words(direct(NATIVE, b.encode('getPricesInWei()', [])))
    if len(native_words) != 6 or native_words[-1] == 0:
        raise RuntimeError('Invalid actual Nitro native prices')
    calls, indices = [], {}
    block_calls = [[]]
    simulation_context = {}

    def raw(label, target, signature, args=(), gas=6000000):
        data = b.encode(signature, args)
        indices[label] = len(calls)
        calls.append({'from': b.OWNER, 'to': target, 'data': data, 'gas': hex(gas), 'gasPrice': hex(basefee)})
        block_calls[-1].append(len(calls) - 1)

    def add(label, name, target, method, args=(), gas=6000000):
        f = b.function(name, method, len(args))
        raw(label, target, method + '(' + ','.join(b.canonical(x) for x in f['inputs']) + ')', args, gas)

    def token(label, target, method, args=()):
        signatures = {'balanceOf': 'balanceOf(address)', 'approve': 'approve(address,uint256)', 'totalSupply': 'totalSupply()'}
        raw(label, target, signatures[method], args)

    def simulate(label):
        # Node-generated blocks honor the actual cooldown. No timestamp/number
        # override and no shortened production parameter is permitted.
        blocks = [{'blockOverrides': {'baseFeePerGas': hex(basefee)}, 'calls': [calls[i] for i in group],
                   **({'stateOverrides': overrides} if index == 0 else {})}
                  for index, group in enumerate(block_calls)]
        request = {'blockStateCalls': blocks, 'validation': True}
        response = g.rpc(RPC, 'eth_simulateV1', [request, pin])
        (output.parent / f'attempt-{attempt}-{label}.json').write_text(json.dumps({'pin': pin, 'request': request, 'response': response}, indent=2) + '\n', encoding='utf-8')
        if len(response) != len(blocks) or sum(len(block['calls']) for block in response) != len(calls):
            raise RuntimeError('Simulation cardinality mismatch')
        for index, block in enumerate(response):
            expected_parent = header['hash'] if index == 0 else response[index - 1]['hash']
            if block.get('parentHash') != expected_parent or number(block['baseFeePerGas']) != basefee:
                raise RuntimeError('Simulation parent/native fee context mismatch')
        interval = number(response[0]['timestamp']) - number(header['timestamp'])
        if interval <= 0:
            raise RuntimeError('Invalid node-generated block interval')
        simulation_context.update(interval=interval, timestamp=number(response[-1]['timestamp']), blocks=len(response))
        results = [call for block in response for call in block['calls']]
        errored = '0x' + g.keccak256(b'UpkeepErrored(uint8,address,bytes)').hex()
        poke_errors = {'0x' + g.keccak256((event['name'] + '(' + ','.join(b.canonical(x) for x in event['inputs']) + ')').encode()).hex()
                       for event in b.abi('StrategyUpkeep') if event.get('type') == 'event'
                       and 'poke' in event['name'].lower() and 'fail' in event['name'].lower()}
        for label_key, index in indices.items():
            result = results[index]
            if number(result.get('status', '0x0')) != 1:
                raise RuntimeError(f'Call failed: {label_key}: {result}')
            if any(log.get('topics', [None])[0] in {errored} | poke_errors for log in result.get('logs', [])):
                raise RuntimeError('Hidden keeper failure: ' + label_key)
        if words(results[indices['native']]['returnData']) != native_words:
            raise RuntimeError('Actual native fee parity failed')
        return results

    raw('native', NATIVE, 'getPricesInWei()')
    # Establish native context independently before any capital movement.
    simulate('parity')
    token('usdt-before', USDT, 'balanceOf', [b.OWNER])
    token('asset-before', b.ASSET, 'balanceOf', [b.OWNER])
    token('supply-before', b.ASSET, 'totalSupply')
    token('usdt-supply-before', USDT, 'totalSupply')
    if not direct_holder_deposit:
        token('swap-clear', USDT, 'approve', [SWAP, 0])
        token('swap-approve', USDT, 'approve', [SWAP, AMOUNT])
        minimum = (AMOUNT * usdt_price // asset_price) * 99 // 100
        path = USDT + '000064' + b.ASSET[2:]
        raw('swap', SWAP, 'exactInput((bytes,address,uint256,uint256))', [(path, b.OWNER, AMOUNT, minimum)])
        token('swap-revoke', USDT, 'approve', [SWAP, 0])
        token('usdt-after', USDT, 'balanceOf', [b.OWNER])
        token('asset-after', b.ASSET, 'balanceOf', [b.OWNER])
    cap = number(c['policy']['adapterCapacityRaw'])
    registry = a['protocolRegistry']
    adapter_names = {'aave': 'AaveV3USDCAdapter', 'comet': 'CometUsdcMultiMarketAdapter', 'morpho': 'MorphoUsdcMultiMarketAdapter',
                     'euler': 'EulerUsdcMultiMarketAdapter', 'fluid': 'FluidUsdcMultiMarketAdapter',
                     'dolomite': 'DolomiteUsdcMultiMarketAdapter', 'venus': 'VenusUsdcMultiMarketAdapter'}
    adapter_names = {key: name for key, name in adapter_names.items() if key in profile['markets']}
    initializers = {'aave': [b.ASSET, b.MARKETS['aave'], atoken, b.OWNER, a['strategy'], cap],
                    'comet': [b.ASSET, b.OWNER, a['strategy'], cap, registry],
                    'euler': [a['strategy'], b.ASSET, [b.MARKETS.get('euler')], b.ZERO, b.OWNER],
                    'fluid': [b.ASSET, b.OWNER, a['strategy'], cap, b.MARKETS.get('fluid')],
                    'venus': [b.ASSET, b.OWNER, a['strategy'], cap, b.MARKETS.get('venus'), 31536000]}
    for key in c['initialization']['deferred']:
        add('init-' + key, adapter_names[key], a[key], 'initialize', initializers[key])
    if 'euler' in adapter_names:
        add('euler-markets', adapter_names['euler'], a['euler'], 'initializeMarkets')
    pps_keys = [key for key in ['morpho', 'dolomite', 'fluid'] if key in adapter_names]
    for key in pps_keys:
        add('pps-' + key, adapter_names[key], a[key], 'pokeAPYSnapshots')
        param_role = '0x' + g.keccak256(b'PARAM_ROLE').hex()
        add('poke-role-' + key, adapter_names[key], a[key], 'grantRole', [param_role, a['upkeep']])
        add('poke-target-' + key, 'StrategyUpkeep', a['upkeep'], 'addPokeTarget', [a[key]])
    add('default-poke-interval', 'StrategyUpkeep', a['upkeep'], 'pokeInterval')
    add('first-poke-check', 'StrategyUpkeep', a['upkeep'], 'checkUpkeep', ['0x'])
    poke_payload = b.encode('f(uint8,uint256)', [3, 0], False)
    if pps_keys:
        add('actual-poke', 'StrategyUpkeep', a['upkeep'], 'performUpkeep', [poke_payload])
    add('after-poke-check', 'StrategyUpkeep', a['upkeep'], 'checkUpkeep', ['0x'])
    for key in adapter_names:
        add('whitelist-' + key, 'StrategySettingsModule', a['strategy'], 'whitelistAdapter', [a[key], True])
        add('register-' + key, 'UsdcMultiLendingVault', a['strategy'], 'addAdapter', [a[key]])
        add('enable-' + key, 'UsdcMultiLendingVault', a['strategy'], 'toggleAdapter', [a[key], venue == 'all' or venue == key])
        add('enabled-' + key, 'UsdcMultiLendingVault', a['strategy'], 'enabled', [a[key]])
    add('tvl', 'StrategyParamsModule', a['strategy'], 'pokeExternalTVL')
    add('liquidity', 'StrategyParamsModule', a['strategy'], 'pokeLiquidityBatch', [0, len(adapter_names)])
    add('allowlist', 'StrategyRouter', a['router'], 'executeStrategyAllowlist', [a['strategy']])
    add('register-strategy', 'StrategyRouter', a['router'], 'register', [a['strategy'], 0, 10000])
    add('strategy-cap', 'StrategyRouter', a['router'], 'setMaxStrategyBps', [a['strategy'], 10000])
    add('loss-cap', 'StrategyRouter', a['router'], 'setLossCapPerStrategy', [a['strategy'], 50])
    unit = 10**6
    seed = ceil_div(10**18 * unit, asset_price)
    add('limits', 'GlobalConfig', a['globalConfig'], 'setVaultDepositLimits', [a['core'], 10000000 * 10**18 * unit // asset_price,
        500000 * 10**18 * unit // asset_price, ceil_div(100 * 10**18 * unit, asset_price)])
    if direct_holder_deposit:
        token('core-approve-clear', b.ASSET, 'approve', [a['core'], 0])
    token('core-approve', b.ASSET, 'approve', [a['core'], DEPOSIT + seed])
    add('seed', 'AdminModule', a['core'], 'seedDeadDeposit', [seed])
    add('unpause', 'CoreVault', a['core'], 'unpauseAll')
    add('freeze-routing', 'CoreVault', a['core'], 'freezeRouting')
    add('freeze-params', 'AdminModule', a['core'], 'freezeParams')
    raw('deposit', a['core'], 'deposit(uint256,address)', [DEPOSIT, '0x0000000000000000000000000000000000000b0b'])
    if direct_holder_deposit:
        token('holder-after-deposit', b.ASSET, 'balanceOf', [b.OWNER])
        add('core-nav-after-deposit', 'CoreVault', a['core'], 'totalAssets')
    token('core-before-route', b.ASSET, 'balanceOf', [a['core']])
    add('route', 'LiquidityOpsModule', a['core'], 'deployToStrategies', [2**256 - 1])
    token('core-after-route', b.ASSET, 'balanceOf', [a['core']])
    add('can', 'StrategyRebalanceGateModule', a['strategy'], 'canRebalance')
    add('preview', 'StrategyRebalanceGateModule', a['strategy'], 'previewRebalanceGas')
    add('idle-before-plan', 'UsdcMultiLendingVault', a['strategy'], 'idleCash')
    first = simulate('setup')
    result_at = lambda results, label: results[indices[label]]['returnData']
    if words(result_at(first, 'default-poke-interval'))[0] != 86400:
        raise RuntimeError('Production keeper default interval not applied')
    needed, data = decode('StrategyUpkeep', 'checkUpkeep', result_at(first, 'first-poke-check'))
    if pps_keys and (not needed or words(data)[0] != 3):
        raise RuntimeError('Actual APY refresh not selected')
    if not pps_keys and needed and words(data)[0] == 3:
        raise RuntimeError('APY refresh selected with no PPS targets')
    needed_after, data_after = decode('StrategyUpkeep', 'checkUpkeep', result_at(first, 'after-poke-check'))
    if needed_after and words(data_after)[0] == 3:
        raise RuntimeError('APY refresh starves subsequent automation')
    if any(bool(words(result_at(first, 'enabled-' + key))[0]) != (venue == 'all' or venue == key) for key in adapter_names):
        raise RuntimeError('Declared enabled-venue policy mismatch')
    swap_credit = None
    if direct_holder_deposit:
        funding = DEPOSIT + seed
        before_holder = words(result_at(first, 'asset-before'))[0]
        if before_holder < funding or before_holder - words(result_at(first, 'holder-after-deposit'))[0] != funding:
            raise RuntimeError('Canonical USDT0 holder deposit debit mismatch')
        if words(result_at(first, 'core-nav-after-deposit'))[0] != funding:
            raise RuntimeError('Canonical USDT0 Core deposit credit mismatch')
    else:
        if words(result_at(first, 'usdt-before'))[0] - words(result_at(first, 'usdt-after'))[0] != AMOUNT:
            raise RuntimeError('Noncanonical swap funding debit')
        swap_credit = words(result_at(first, 'asset-after'))[0] - words(result_at(first, 'asset-before'))[0]
        if swap_credit < minimum or swap_credit != words(result_at(first, 'swap'))[0]:
            raise RuntimeError('Swap credit mismatch')
    if not decode('StrategyRebalanceGateModule', 'canRebalance', result_at(first, 'can'))[0]:
        raise RuntimeError('Natural native economic gate rejected plan')
    actions, quote = decode('StrategyRebalanceGateModule', 'previewRebalanceGas', result_at(first, 'preview'))
    n = len(actions)
    if not n or not quote[6] or not quote[7] or len({x[0].lower() for x in actions}) != n:
        raise RuntimeError('Need reliable cold quote with unique real venues')
    if venue != 'all' and (n != 1 or actions[0][0].lower() != a[venue].lower()):
        raise RuntimeError('Dedicated profile did not select its real venue')
    cfg = c['policy']['estimatorConfig']
    steps = ceil_div(n, 2)
    l2gas = cfg['prepareGas'] + (steps + 1) * cfg['intrinsicGas'] + cfg['finalizeGas'] + steps * cfg['stepGas']
    l2gas += sum(cfg['defaultDepositGas'] if x[2] else cfg['defaultWithdrawGas'] for x in actions)
    execution = l2gas * max(basefee, native_words[-1])
    poster = (steps + 1) * (native_words[0] + cfg['calldataBytes'] * native_words[1])
    usd6 = ceil_div(ceil_div((execution + poster) * eth_price, 10**18), 10**12)
    cost = ceil_div(usd6 * (10000 + cfg['marginBps']), 10000)
    if [number(quote[i]) for i in [1, 2, 3, 4, 5]] != [cost, l2gas, poster, execution, steps + 1]:
        raise RuntimeError('Independent native quote arithmetic mismatch')
    action_hash_data = b.encode('f(uint256,address,(address,uint256,bool)[],uint8,bool)', [42161, a['strategy'], [tuple(x) for x in actions], 2, True], False)
    if quote[0].lower() != '0x' + g.keccak256(bytes.fromhex(action_hash_data[2:])).hex():
        raise RuntimeError('Action hash mismatch')
    wrapper_labels = []
    for index, operation in enumerate([5] + [6] * steps):
        label = 'keeper-' + str(index)
        payload = b.encode('f(uint8,uint256)', [operation, 0], False)
        add(label, 'StrategyUpkeep', a['upkeep'], 'performUpkeep', [payload], 15000000)
        if (len(calls[-1]['data']) - 2) // 2 != 132:
            raise RuntimeError('Keeper wrapper payload length mismatch')
        wrapper_labels.append(label)
        if index == 0:
            add('prepared-phase', 'UsdcMultiLendingVault', a['strategy'], 'rebalancePlanPhase')
            add('prepared-count', 'UsdcMultiLendingVault', a['strategy'], 'rebalancePlanTotalActions')
    add('phase', 'UsdcMultiLendingVault', a['strategy'], 'rebalancePlanPhase')
    add('nav-before-recall', 'UsdcMultiLendingVault', a['strategy'], 'totalAssets')
    add('idle-after-plan', 'UsdcMultiLendingVault', a['strategy'], 'idleCash')
    for key, name in adapter_names.items():
        add('position-' + key, name, a[key], 'totalAssets')
        token('receipt-' + key, atoken if key == 'aave' else b.MARKETS[key], 'balanceOf', [a[key]])
    partial_requests = []
    if venue != 'all':
        planned = sum(number(action[1]) for action in actions)
        probe = min(100 * 10**6, planned // 10)
        if probe <= 0:
            raise RuntimeError('Insufficient actual allocation for ordinary withdrawal observations')
        # Cold/non-accruing and later accruing calls can be different regimes.
        # Four real withdrawals allow three stable samples after a genuine reset;
        # the controller's observation count is never seeded or overridden.
        partial_requests = [words(result_at(first, 'idle-before-plan'))[0] - planned + probe, probe, probe, probe]
        token('core-before-partials', b.ASSET, 'balanceOf', [a['core']])
        for index, target in enumerate(partial_requests):
            if index:
                config_proof = c['constructorProofs']['globalConfig']
                configured = {item['name']: number(value) for item, value in zip(config_proof['constructorAbi'], config_proof['constructorArguments']) if item['type'].startswith('uint')}
                cooldown = configured['_cooldown']
                block_calls.extend([[] for _ in range(ceil_div(cooldown, simulation_context['interval']))])
            add('ordinary-withdraw-' + str(index), 'LiquidityOpsModule', a['core'], 'realizeForQueue', [target], 15000000)
        token('core-after-partials', b.ASSET, 'balanceOf', [a['core']])
        add('withdraw-observation', 'UsdcMultiLendingVault', a['strategy'], 'withdrawGasObservation', [a[venue]])
        add('withdraw-ema', 'UsdcMultiLendingVault', a['strategy'], 'emaWithdrawGas', [a[venue]])
        raw('warm-native', NATIVE, 'getPricesInWei()')
        add('observed-quote', 'ReadOnlyGasEstimator', a['estimator'], 'estimate', [a['strategy'], [(a[venue], probe, False)], 2, False])
        add('nav-after-partials', 'UsdcMultiLendingVault', a['strategy'], 'totalAssets')
    token('core-before-recall', b.ASSET, 'balanceOf', [a['core']])
    add('recall', 'StrategyRouter', a['router'], 'withdrawAllToCore', [a['strategy']], 15000000)
    token('core-after-recall', b.ASSET, 'balanceOf', [a['core']])
    add('nav-after-recall', 'UsdcMultiLendingVault', a['strategy'], 'totalAssets')
    token('supply-after', b.ASSET, 'totalSupply')
    token('usdt-supply-after', USDT, 'totalSupply')
    final = simulate('keeper-recall')
    if words(result_at(final, 'prepared-phase'))[0] == 0 or words(result_at(final, 'prepared-count'))[0] != n:
        raise RuntimeError('Prepared plan differs from quoted actions')
    if words(result_at(final, 'phase'))[0] != 0:
        raise RuntimeError('Plan did not complete')
    nav = words(result_at(final, 'nav-before-recall'))[0]
    recall_nav = words(result_at(final, 'nav-after-partials'))[0] if partial_requests else nav
    got = words(result_at(final, 'recall'))[0]
    positions = {key: words(result_at(final, 'position-' + key))[0] for key in adapter_names}
    receipts = {key: words(result_at(final, 'receipt-' + key))[0] for key in adapter_names}
    # Rebalance targets can deliberately retain cash under ramp/cap constraints.
    # The deposit-entry idle ceiling is not a universal rebalance postcondition.
    # Verify every quoted action and the entire inventory instead of inventing
    # a 95% investment target that the actual risk engine did not authorize.
    if any(not action[2] for action in actions):
        raise RuntimeError('Unfunded cold fixture unexpectedly plans withdrawals')
    expected = {action[0].lower(): number(action[1]) for action in actions}
    if not set(expected).issubset({a[key].lower() for key in adapter_names}):
        raise RuntimeError('Unknown quoted venue')
    for key in adapter_names:
        if abs(positions[key] - expected.get(a[key].lower(), 0)) > 2:
            raise RuntimeError('Quoted allocation not realized: ' + key)
    idle_before = words(result_at(first, 'idle-before-plan'))[0]
    idle_after = words(result_at(final, 'idle-after-plan'))[0]
    core_before_route = words(result_at(first, 'core-before-route'))[0]
    core_after_route = words(result_at(first, 'core-after-route'))[0]
    if core_before_route != DEPOSIT + seed or idle_before <= 0 or core_before_route - core_after_route != idle_before:
        raise RuntimeError('Actual Core buffer/routing cash ledger mismatch')
    if idle_before - idle_after != sum(expected.values()) or abs(sum(positions.values()) + idle_after - nav) > 2 * n:
        raise RuntimeError('Plan cash/inventory conservation failed')
    if not sum(positions.values()) or any(positions[key] > 2 and receipts[key] == 0 for key in adapter_names):
        raise RuntimeError('Real protocol investment/receipt proof missing')
    if abs(nav - idle_before) > 2 * n or recall_nav - got > 2 or words(result_at(final, 'nav-after-recall'))[0] > 2:
        raise RuntimeError('Investment/full recall mismatch')
    if words(result_at(final, 'core-after-recall'))[0] - words(result_at(final, 'core-before-recall'))[0] != got:
        raise RuntimeError('Core recall cash conservation failed')
    recovered = words(result_at(final, 'core-after-recall'))[0]
    if (not partial_requests and abs(recovered - core_before_route) > 2 * n) or recovered + 2 * n < core_before_route:
        raise RuntimeError('Seed/deposit capital not recovered')
    observed = None
    if partial_requests:
        count, updated_at = words(result_at(final, 'withdraw-observation'))
        ema = words(result_at(final, 'withdraw-ema'))[0]
        if count < 3 or ema <= 0 or not 0 < updated_at <= simulation_context['timestamp'] or simulation_context['timestamp'] - updated_at > 3600:
            raise RuntimeError('Three genuine fresh ordinary withdrawal measurements not obtained')
        paid = words(result_at(final, 'core-after-partials'))[0] - words(result_at(final, 'core-before-partials'))[0]
        if paid != sum(partial_requests) or recall_nav + paid + 2 * n < nav:
            raise RuntimeError('Ordinary withdrawal cash/NAV ledger mismatch')
        oq = decode('ReadOnlyGasEstimator', 'estimate', result_at(final, 'observed-quote'))[0]
        observed_gas = cfg['intrinsicGas'] + cfg['finalizeGas'] + cfg['stepGas'] + ema
        warm_native = words(result_at(final, 'warm-native'))
        observed_execution = observed_gas * max(basefee, warm_native[-1])
        observed_poster = warm_native[0] + cfg['calldataBytes'] * warm_native[1]
        observed_usd = ceil_div(ceil_div((observed_execution + observed_poster) * eth_price, 10**18), 10**12)
        observed_cost = ceil_div(observed_usd * (10000 + cfg['marginBps']), 10000)
        if not oq[6] or oq[7] or [number(oq[i]) for i in [1, 2, 3, 4, 5]] != [observed_cost, observed_gas, observed_poster, observed_execution, 1]:
            raise RuntimeError('Observed EMA quote arithmetic/reliability mismatch')
        partial_gas = [number(final[indices['ordinary-withdraw-' + str(i)]]['gasUsed']) for i in range(len(partial_requests))]
        if observed_gas < max(partial_gas) or ema > max(partial_gas):
            raise RuntimeError('Observed quote does not cover actual ordinary wrapper gas')
        observed = {'count': str(count), 'updatedAt': str(updated_at), 'emaWithdrawGas': str(ema),
                    'actualNativeCoreWithdrawalGasUsed': [str(x) for x in partial_gas],
                    'usedDefaults': False, 'l2Gas': str(observed_gas), 'costUSD6': str(observed_cost),
                    'requestsRaw': [str(x) for x in partial_requests], 'nativePriceWords': [str(x) for x in warm_native],
                    'configuredCooldownSeconds': str(cooldown), 'generatedBlocks': simulation_context['blocks'],
                    'generatedEndTimestamp': str(simulation_context['timestamp']),
                    'counterfactualAccrualRaw': str(recovered - core_before_route)}
    for before_label, after_label in [('supply-before', 'supply-after'), ('usdt-supply-before', 'usdt-supply-after')]:
        if result_at(final, before_label) != result_at(final, after_label):
            raise RuntimeError('Token total supply changed')
    measured = {label: str(number(final[indices[label]]['gasUsed'])) for label in wrapper_labels}
    if sum(int(v) for v in measured.values()) > l2gas:
        raise RuntimeError('Quote fails to cover measured native wrapper gas')
    status = 'COLD_NATIVE_SEVEN_ENABLED_KEEPER_RECALL_PASS' if venue == 'all' else 'DEDICATED_NATIVE_KEEPER_ORDINARY_EMA_RECALL_PASS'
    report = {'status': status, 'chainId': 42161, 'header': header, 'profile': venue,
              'assetProfile': asset_profile, 'asset': b.ASSET,
              'nativeRpc': rpc_label(RPC), 'simulatorSha256': SIMULATOR_SHA256,
              'checkpointSha256': hashlib.sha256(checkpoint.read_bytes()).hexdigest(), 'actions': actions,
              'nativePriceWords': [str(x) for x in native_words], 'independentQuote': {'l2Gas': str(l2gas), 'posterWei': str(poster), 'executionWei': str(execution), 'costUSD6': str(cost)},
              'simulatedNativeWrapperGasUsed': measured,
              'fundingMethod': 'CANONICAL_USDT0_HOLDER_CORE_DEPOSIT' if direct_holder_deposit else 'CANONICAL_USDT0_USDC_SWAP',
              'holderDepositRaw': str(DEPOSIT + seed),
              'swapInputRaw': None if direct_holder_deposit else str(AMOUNT), 'swapCreditRaw': None if direct_holder_deposit else str(swap_credit),
              'investedNavRaw': str(nav), 'recalledRaw': str(got), 'indices': indices,
              'protocolPositionRaw': {key: str(value) for key, value in positions.items()},
              'protocolReceiptRaw': {key: str(value) for key, value in receipts.items()},
              'idleBeforeRaw': str(idle_before), 'idleAfterRaw': str(idle_after),
              'coreBeforeRouteRaw': str(core_before_route), 'coreAfterRouteRaw': str(core_after_route),
              'actualPokeDefaultInterval': '86400', 'simulatedNativeRefreshGasUsed': str(number(final[indices['actual-poke']]['gasUsed'])) if pps_keys else None,
              'ordinaryWithdrawalObservation': observed,
              'canonicalReadCache': {'entries': len(CANONICAL_CACHE), 'hits': CACHE_HITS, 'policy': 'Only immutable explicitly pinned canonical reads; every simulation executed on real node.'},
              'limits': ['Native per-call simulated gas, not mined transaction receipts.', 'Only unused unfunded constructor-produced fixture accounts projected.',
                         'Calibration is specific to this asset, chain, market universe and policy; live deployment authorization is separate.',
                         'Enabled/scanned venues do not imply equal investment actions; only actual risk-engine-selected actions execute.'],
              'readiness': 'NOT_PRODUCTION_READY'}
    output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'status': report['status'], 'actions': n, 'wrapperGas': measured}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkpoint', type=pathlib.Path, default=b.ROOT / 'deployments/lending-full-validation-20261101/production/keeper-gas/checkpoint.json')
    parser.add_argument('--output', type=pathlib.Path, default=b.ROOT / 'deployments/lending-full-validation-20261101/production/keeper-gas/native-result.json')
    parser.add_argument('--rpc-url', choices=[b.PUBLIC, 'https://arbitrum.drpc.org', 'https://arbitrum-one-rpc.publicnode.com'], default=RPC)
    parser.add_argument('--rpc-env', help='Authorized RPC URL read from this process environment variable; never printed.')
    parser.add_argument('--probe-only', action='store_true', help='Verify native/archive capability without running fixture scenarios.')
    parser.add_argument('--venue', choices=['all', 'aave', 'comet', 'morpho', 'euler', 'fluid', 'dolomite', 'venus'], default='all')
    parser.add_argument('--block', type=int, help='Explicit canonical RPC block; otherwise resolve latest once.')
    parser.add_argument('--all-profiles', action='store_true', help='Run natural seven-enabled case and all seven dedicated observation profiles at one actual pin.')
    args = parser.parse_args()
    RPC = os.environ.get(args.rpc_env) if args.rpc_env else args.rpc_url
    if not RPC:
        raise RuntimeError('Named RPC variable is unavailable in the process environment')
    parsed_rpc = urllib.parse.urlsplit(RPC)
    if parsed_rpc.scheme != 'https' and not (parsed_rpc.scheme == 'http' and parsed_rpc.hostname in {'127.0.0.1', 'localhost', '::1'}):
        raise RuntimeError('RPC must use HTTPS or an explicitly authorized loopback endpoint')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    g.READ_ONLY_METHODS = g.READ_ONLY_METHODS | {'eth_simulateV1'}
    errors = []
    profiles = ['all', 'aave', 'comet', 'morpho', 'euler', 'fluid', 'dolomite', 'venus'] if args.all_profiles else [args.venue]
    completed = []
    try:
        if args.probe_only:
            h = g.rpc(RPC, 'eth_getBlockByNumber', [hex(args.block) if args.block is not None else 'latest', False])
            if number(g.rpc(RPC, 'eth_chainId', [])) != 42161:
                raise RuntimeError('Authorized RPC is not Arbitrum One')
            call = {'from': b.OWNER, 'to': NATIVE, 'data': b.encode('getPricesInWei()', []), 'gas': '0x30d40', 'gasPrice': h['baseFeePerGas']}
            direct_result = g.rpc(RPC, 'eth_call', [call, h['number']])
            simulated = g.rpc(RPC, 'eth_simulateV1', [{'blockStateCalls': [{'blockOverrides': {'baseFeePerGas': h['baseFeePerGas']}, 'calls': [call]}], 'validation': True}, h['number']])
            if len(words(direct_result)) != 6 or words(direct_result)[-1] == 0 or simulated[0]['calls'][0]['returnData'] != direct_result:
                raise RuntimeError('Authorized RPC native parity failed')
            args.output.write_text(json.dumps({'status': 'AUTHORIZED_NATIVE_ARCHIVE_PARITY_PASS', 'header': h, 'rpc': rpc_label(RPC), 'readiness': 'NOT_PRODUCTION_READY'}, indent=2) + '\n', encoding='utf-8')
            print('AUTHORIZED_NATIVE_ARCHIVE_PARITY_PASS')
            raise SystemExit(0)
        checkpoint_data = json.loads(args.checkpoint.read_text(encoding='utf-8-sig'))
        if checkpoint_data.get('compilerGraph') != b.COMPILER_GRAPH:
            raise RuntimeError('Checkpoint requires isolated production compilation')
        b.configure_compiler(args.checkpoint.parent)
        if checkpoint_data.get('assetProfile', 'usdc') == 'usdt0-aave':
            if args.all_profiles or args.venue not in {'all', 'aave'}:
                raise RuntimeError('USDT0 profile supports dedicated Aave qualification only')
            profiles = ['aave']
        for proof in checkpoint_data['constructorProofs'].values():
            b.abi(proof['contract'])
        for address in checkpoint_data['addresses'].values():
            b.encode('balanceOf(address)', [address])
        for profile in profiles:
            result_path = args.output.parent / profile / 'native-result.json' if args.all_profiles else args.output
            result_path.parent.mkdir(parents=True, exist_ok=True)
            for attempt in range(1, 4):
                try:
                    initial_header = g.rpc(RPC, 'eth_getBlockByNumber', [hex(args.block) if args.block is not None else 'latest', False])
                    pinned_block = number(initial_header['number'])
                    run(args.checkpoint, result_path, attempt, profile, pinned_block, initial_header['hash'])
                    completed.append({'profile': profile, 'block': str(pinned_block), 'blockHash': initial_header['hash'], 'report': str(result_path), 'sha256': hashlib.sha256(result_path.read_bytes()).hexdigest()})
                    break
                except Exception as error:
                    errors.append({'profile': profile, 'attempt': attempt, 'error': safe_error(error)})
                    (args.output.parent / 'native-errors.json').write_text(json.dumps(errors, indent=2) + '\n', encoding='utf-8')
                    if not any(x in str(error).lower() for x in ['timeout', 'timed out', '429', '502', '503', '504']) or attempt == 3:
                        if RPC not in PUBLIC_ENDPOINTS:
                            raise RuntimeError(safe_error(error)) from None
                        raise
            if args.all_profiles:
                args.output.write_text(json.dumps({'status': 'IN_PROGRESS' if len(completed) != 8 else 'EIGHT_NATIVE_PROFILES_PASS', 'pinPolicy': 'Explicit canonical block' if args.block is not None else 'Fresh canonical pin per profile', 'profiles': completed,
                                                  'simulatorSha256': SIMULATOR_SHA256, 'readiness': 'NOT_PRODUCTION_READY'}, indent=2) + '\n', encoding='utf-8')
    except Exception as error:
        if RPC not in PUBLIC_ENDPOINTS:
            raise RuntimeError(safe_error(error)) from None
        raise
    finally:
        (args.output.parent / 'native-rpc-trace.json').write_text(json.dumps(trace_for_disk(), indent=2) + '\n', encoding='utf-8')
