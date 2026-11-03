"""Verify the actual remaining-plan event units in existing Native RPC responses."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DOC = ROOT / 'docs/lending-arbitrum-assets-20261103'
RAW = ROOT / 'deployments/lending-full-validation-20261101/production/final-cleanup/suffix-native'
GAS = '0x3d022d3e62e4c69b78c02904901424491d9641bc920c2abfd5643699229a95d7'
ECONOMICS = '0x8395627e37f1f964aaf548e923a40ecfcc361067a11835525faa5763cc273009'


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def ref(path):
    return {'path': path.relative_to(ROOT).as_posix(),
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}


def words(encoded):
    encoded = encoded.removeprefix('0x')
    assert len(encoded) % 64 == 0
    return [int(encoded[i:i + 64], 16) for i in range(0, len(encoded), 64)]


def main():
    assets = {a['symbol']: a for a in read(DOC / 'production-inputs-draft.json')['assets']}
    rows = []
    for profile, symbol in [('weth', 'WETH'), ('usdt0', 'USDT0'), ('wbtc-dolomite', 'WBTC')]:
        directory = RAW / ('qualified-' + profile)
        result_path = directory / 'native-result.json'
        response_path = directory / 'attempt-1-keeper-recall.json'
        trace_path = directory / 'native-rpc-trace.json'
        result, response, trace = read(result_path), read(response_path), read(trace_path)
        assert result['status'] == 'DEDICATED_NATIVE_KEEPER_ORDINARY_EMA_RECALL_PASS'
        assert response['pin'] == result['header']['number']
        feed = assets[symbol]['assetUsdFeed'].lower()
        feed_values = {}
        for entry in trace:
            request = entry['request']
            params = request.get('params', [])
            if (request['method'] == 'eth_call' and params[0].get('to', '').lower() == feed
                    and params[1] == response['pin']):
                selector = params[0]['data']
                if selector in ('0xfeaf968c', '0x313ce567'):
                    value = words(json.loads(entry['body'])['result'])
                    assert selector not in feed_values or feed_values[selector] == value
                    feed_values[selector] = value
        decimals = feed_values['0x313ce567'][0]
        answer = feed_values['0xfeaf968c'][1]
        assert 0 <= decimals <= 18 and 0 < answer < 2**255
        price18 = answer * 10**(18 - decimals)
        unit = int(result['assetUnit'])
        costs = []
        for label in ['keeper-0', 'keeper-1']:
            call = response['response'][0]['calls'][result['indices'][label]]
            assert int(call['status'], 16) == 1
            logs = call['logs']
            gas = [words(x['data']) for x in logs if x.get('topics', [None])[0] == GAS]
            economics = [words(x['data']) for x in logs if x.get('topics', [None])[0] == ECONOMICS]
            assert len(gas) == len(economics) == 1
            quote, event = gas[0], economics[0]
            assert quote[3] == 1 and event[4] == 1
            expected = (quote[0] * 10**12 * unit + price18 - 1) // price18
            assert event[2] == expected, (symbol, label, event[2], expected)
            costs.append({'call': label, 'quoteUSD6': str(quote[0]),
                          'economicCostAssetUnits': str(event[2]), 'accepted': True})
        assert costs[0]['quoteUSD6'] == result['independentQuote']['costUSD6']
        assert 0 < int(costs[1]['quoteUSD6']) < int(costs[0]['quoteUSD6'])
        rows.append({'asset': symbol, 'assetUnit': str(unit), 'canonicalAssetPrice18': str(price18),
                     'block': int(response['pin'], 16), 'result': ref(result_path),
                     'nativeResponse': ref(response_path), 'rpcTrace': ref(trace_path), 'events': costs})
    report = {'status': 'THREE_NATIVE_REMAINING_PLAN_UNIT_PROOFS_PASS',
              'sourceCommit': '3fcc4d405153a3b534daed98f92f836e6d61957c',
              'dispatch': 'StrategyRebalancePlanModule.executeRebalanceStep calls checkRemainingPlan before every step, including the first/only step; no nextAction>0 condition.',
              'eventUnits': 'RebalanceGasEvaluated.costUSDC is USD6. RebalanceEconomicsEvaluated moved/gross/cost are underlying asset units; legacy ABI field names are preserved.',
              'profiles': rows, 'verifier': ref(Path(__file__)), 'productionApproval': False}
    (DOC / 'native-suffix-event-proof.json').write_text(json.dumps(report, indent=2) + '\n')
    print('PASS: WETH, USDT0 and WBTC remaining-plan Native costs equal independently rounded real-oracle asset conversion')


if __name__ == '__main__':
    main()
