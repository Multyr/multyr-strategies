"""Seal the twelve explicit post-fix Native results without rerunning simulations."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DOC = ROOT / 'docs/lending-arbitrum-assets-20261103'
RAW = ROOT / 'deployments/lending-full-validation-20261101/production/final-cleanup/suffix-native'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def ref(path):
    return {'path': path.relative_to(ROOT).as_posix(), 'sha256': sha(path)}


def main():
    acceptance = DOC / 'actual-50-acceptance.json'
    for item in read(acceptance)['sources']:
        assert sha(ROOT / item['path']) == item['sha256'], item['path']
    simulator = ROOT / 'script/lending/validation/keeper-gas/native_simulation.py'
    builder = ROOT / 'script/lending/validation/keeper-gas/build_checkpoint.py'
    driver = DOC / 'tools/reuse_native_graph.py'
    reference = RAW / 'checkpoint-usdc.json'
    canonical = read(reference)
    assert 'compilationReuse' not in canonical
    plan = read(DOC / 'native-profile-plan.json')
    rows = []
    for spec in plan['profiles']:
        asset, venue = spec['assetProfile'], spec['venue']
        negative = asset == 'wbtc-aave'
        if asset == 'usdc':
            checkpoint = reference
            result = RAW / f'qualified-usdc/{venue}/native-result.json'
        else:
            key = {'weth-aave': 'weth', 'usdt0-aave': 'usdt0'}.get(asset, asset)
            checkpoint = RAW / f'checkpoint-{key}.json'
            directory = 'wbtc-aave-negative' if negative else key
            result = RAW / f'qualified-{directory}/native-result.json'
        c, d = read(checkpoint), read(result)
        assert d['simulatorSha256'] == sha(simulator)
        assert d['checkpointSha256'] == sha(checkpoint)
        assert c['builderSha256'] == sha(builder)
        assert c['sourceAcceptanceSha256'] == sha(acceptance)
        assert c['compilerGraph'] == 'full_project_graph_storage_layout'
        assert c['frozenCoreCommit'] == '9a9d120709de99a6216e9fe75d36e9ffdcb1a4d9'
        assert c['compilerConfiguration'] == canonical['compilerConfiguration']
        assert c['oldBlock'] == plan['fixtureOldBlock']
        assert c['sampleBlock'] == plan['ppsSampleBlock']
        assert len(c['constructorProofs']) >= 20
        if asset != 'usdc':
            reuse = c['compilationReuse']
            assert reuse['referenceCheckpointSha256'] == sha(reference)
            assert reuse['driverSha256'] == sha(driver)
            bindings = {item['name'] for item in reuse['creationBindings']}
            assert bindings == set(canonical['constructorProofs'])
            assert set(c['constructorProofs']) <= bindings
        assert d['assetProfile'] == asset and d['profile'] == venue
        assert d['header']['hash'] == plan['canonicalHash']
        assert int(d['header']['number'], 16) == plan['canonicalBlock']
        age = int(d['header']['timestamp'], 16) - int(c['oldHeader']['timestamp'], 16)
        assert age >= 2 * 86400
        row = {'assetProfile': asset, 'venue': venue, 'result': ref(result),
               'checkpoint': ref(checkpoint), 'status': d['status']}
        if negative:
            assert d['status'] == 'EXPECTED_NATIVE_ECONOMIC_REJECTION_AND_CORE_RECALL_PASS'
            assert not d['keeperInvestmentExecuted']
            assert 0 < int(d['grossBenefitUSD6']) < int(d['gasCostUSD6'])
            assert int(d['recalledRaw']) > 0
            row.update({key: d[key] for key in ['ratesBps', 'grossBenefitUSD6',
                       'gasCostUSD6', 'coreAfterRaw', 'recalledRaw']})
        else:
            expected = ('COLD_NATIVE_SEVEN_ENABLED_KEEPER_RECALL_PASS' if venue == 'all'
                        else 'DEDICATED_NATIVE_KEEPER_ORDINARY_EMA_RECALL_PASS')
            assert d['status'] == expected
            gas = sum(map(int, d['simulatedNativeWrapperGasUsed'].values()))
            assert gas > 0 and int(d['independentQuote']['l2Gas']) >= gas
            assert int(d['recalledRaw']) > 0
            if venue != 'all':
                assert int(d['protocolPositionRaw'][venue]) > 0
                assert int(d['protocolReceiptRaw'][venue]) > 0
                assert int(d['ordinaryWithdrawalObservation']['count']) >= 3
                assert not d['ordinaryWithdrawalObservation']['usedDefaults']
            row.update({'nativeKeeperGas': d['simulatedNativeWrapperGasUsed'],
                        'ordinaryWithdrawalObservations': (d.get('ordinaryWithdrawalObservation') or {}).get('count')})
        rows.append(row)
    assert len(rows) == 12
    out = {'status': 'TWELVE_POST_FIX_NATIVE_PROFILES_PASS', 'sourceCommit': '3fcc4d4',
           'canonicalBlock': plan['canonicalBlock'], 'canonicalHash': plan['canonicalHash'],
           'executed': 12, 'positiveKeeperProfiles': 11, 'requiredEconomicRejections': 1,
           'failed': 0, 'skipped': 0, 'productionApproval': False,
           'sourceAcceptance': ref(acceptance), 'simulator': ref(simulator),
           'builder': ref(builder), 'reuseDriver': ref(driver), 'verifier': ref(Path(__file__)),
           'buildProvenance': 'One fresh isolated full-project compilation; four fresh constructor fixtures reuse only exact creation templates, never financial state.',
           'limits': ['Genuine eth_simulateV1 and Nitro per-call gas, not mined mainnet receipts.',
                      'Constructor-produced unused fixture accounts; real canonical protocol state and holder funds.',
                      'Scoped historical market/policy qualification; fresh activation preflight and approved manifests remain required.'],
           'profiles': rows}
    (DOC / 'post-fix-native-acceptance.json').write_text(json.dumps(out, indent=2) + '\n')
    print('12 Native profiles PASS: 11 positive, 1 required economic rejection; Euler included.')


if __name__ == '__main__':
    main()
