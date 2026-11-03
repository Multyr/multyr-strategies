"""Independently bind successful Linux CI artifacts to exact committed inputs."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[3]
LONG_ROOT = Path('\\\\?\\' + str(ROOT)) if os.name == 'nt' else ROOT
DOC = LONG_ROOT / 'docs/lending-arbitrum-assets-20261103'
RAW = LONG_ROOT / 'deployments/lending-full-validation-20261101/production/final-cleanup/ci-7203247-full'
COMMIT = '7203247f643e364a6d03aae83fc370747188dbd2'


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def digest(data):
    return hashlib.sha256(data).hexdigest()


def ref(path):
    return {'path': path.relative_to(LONG_ROOT).as_posix(), 'sha256': digest(path.read_bytes())}


def blob(name):
    return subprocess.check_output(['git', '-c', 'core.longpaths=true', 'show', f'{COMMIT}:{name}'], cwd=ROOT)


def summary(path, expected):
    values = re.findall(r'Suite result: (?:ok|FAILED)\.\s*(\d+) passed;\s*(\d+) failed;\s*(\d+) skipped',
                        path.read_text(encoding='utf-8-sig'))
    actual = (sum(int(x[0]) for x in values), len(values),
              sum(int(x[1]) for x in values), sum(int(x[2]) for x in values))
    assert actual == (*expected, 0, 0), (path.name, actual)
    return {'passed': actual[0], 'suites': actual[1], 'failed': 0, 'skipped': 0, 'log': ref(path)}


def main():
    workflow_runs = []
    for run_id in [41715625275, 41715625309]:
        data = json.loads(subprocess.check_output([
            'gh', 'run', 'view', str(run_id), '--repo', 'Multyr/multyr-strategies',
            '--json', 'status,conclusion,headSha,url,jobs'], cwd=ROOT))
        assert data['headSha'] == COMMIT
        assert data['status'] == 'completed' and data['conclusion'] == 'success'
        assert all(job['conclusion'] == 'success' for job in data['jobs'])
        workflow_runs.append({'id': run_id, 'headSha': COMMIT, 'url': data['url'], 'conclusion': 'success',
                              'jobs': [{'name': job['name'], 'conclusion': job['conclusion']} for job in data['jobs']]})
    suites = {name: summary(RAW / f'lending-{name}.log', expected) for name, expected in {
        'matrix': (19, 4), 'legacy': (2, 2), 'manifest': (5, 1), 'unmocked': (4, 1),
        'comet': (2, 1), 'v2-wiring': (6, 1), 'regression': (2998, 204)}.items()}
    actual_path = RAW / 'docs/lending-full-validation-20261101/actual-acceptance.json'
    actual = read(actual_path)
    assert (actual['passed'], actual['suites'], actual['failed'], actual['skipped']) == (50, 21, 0, 0)
    assert actual['baseCommit'] == COMMIT
    for item in actual['sources']:
        assert digest(blob(item['path'])) == item['sha256'], item['path']
    assert actual['runnerSha256'] == digest(blob('script/RunLendingActualMarkets.ps1'))
    assert actual['transportClassifierSha256'] == digest(blob('script/lending/validation/RpcTransportFailure.ps1'))
    assert digest((RAW / actual['log']).read_bytes()) == actual['logSha256']
    header_path = RAW / actual['canonicalHeaders']
    header_resolution = 'Original CI artifact'
    if not header_path.exists():
        # The original upload list omitted this generated file. Independent local
        # canonical observations reproduce its EXACT CI-attested bytes after LF
        # normalization. Preserve that provenance instead of altering the download.
        data = (DOC / 'actual-50-infrastructure-acceptance-canonical-headers.json').read_bytes().replace(b'\r\n', b'\n')
        assert digest(data) == actual['canonicalHeadersSha256']
        header_path = DOC / 'ci-canonical-headers-exact-reconstruction.json'
        header_path.write_bytes(data)
        header_resolution = 'Exact SHA256-matching reconstruction from independent canonical local observations; CRLF normalized to LF. Original CI upload omitted this generated file; future upload path fixed.'
    assert digest(header_path.read_bytes()) == actual['canonicalHeadersSha256']
    structure_path = RAW / 'docs/lending-verification-20261031/candidate-structure.json'
    structure, local = read(structure_path), read(DOC / 'cleanup-structure.json')
    assert len(structure['runtimeBytes']) == 34
    assert max(structure['runtimeBytes'].values()) <= 23552
    assert structure['runtimeTemplateKeccak256'] == local['runtimeTemplateKeccak256']
    assert structure['runtimeBytes'] == local['runtimeBytes']
    assert structure['uniqueSelectors'] == 296 and not structure['distinctSignatureCollisions']
    assert structure['identicalModuleLayouts'] == 9
    assert structure['appendOnly'] == local['appendOnly']
    cases = {item['id']: item for item in read(LONG_ROOT / 'script/lending/validation/transaction-gas/cases.json')['cases']}
    receipt_summary_path = next(path for path in RAW.rglob('summary.json') if 'transaction-gas' in path.parts)
    receipt_summary = read(receipt_summary_path)
    assert len(receipt_summary['runs']) == 14 and all(row['status'] == 'PASS' for row in receipt_summary['runs'])
    assert len(receipt_summary['requiredFamilies']) == 7
    assert all(len(chains) == 2 for chains in receipt_summary['configuredChainsPerFamily'].values())
    receipts = []
    operation_count = 0
    for row in receipt_summary['runs']:
        path = receipt_summary_path.parent / row['case_id'] / 'result.json'
        result = read(path)
        assert result['status'] == 'PASS'
        assert digest(blob(cases[row['case_id']]['adapter_source'])) == result['source_utf8_lf_sha256']
        operations = [op['receipt'] for op in result['operations']]
        all_receipts = [result['deploy'], result['initialize']] + result.get('postInitialize', []) + operations
        assert all(receipt['status'] == 1 for receipt in all_receipts)
        operation_count += len(operations)
        receipts.append({'case': row['case_id'], 'operationReceipts': len(operations), 'artifact': ref(path)})
    assert operation_count == 72
    report = {'status': 'ALL_CURRENT_SOURCE_CI_GATES_PASS', 'executionCommit': COMMIT,
              'qualifiedFinancialSources': 'source-equivalence.json', 'workflowRuns': workflow_runs,
              'suiteGates': suites, 'actualMarkets': {'passed': 50, 'suites': 21, 'failed': 0, 'skipped': 0,
                  'artifact': ref(actual_path), 'infrastructureRetries': len(actual.get('infrastructureAttempts', [])),
                  'canonicalHeaders': ref(header_path), 'canonicalHeaderResolution': header_resolution},
              'structure': {'runtimes': 34, 'maximumBytes': max(structure['runtimeBytes'].values()),
                  'allRuntimeTemplatesMatchIndependentWindowsBuild': True, 'selectors': 296,
                  'collisions': 0, 'layouts': 9, 'artifact': ref(structure_path)},
              'transactionProfiles': 14, 'operationReceipts': operation_count, 'receiptArtifacts': receipts,
              'expandedArbitrum': 'ci-expanded-acceptance.json', 'verifier': ref(Path('\\\\?\\' + str(Path(__file__).resolve())) if os.name == 'nt' else Path(__file__)),
              'productionApproval': False, 'mergePerformed': False, 'liveDeploymentPerformed': False}
    (DOC / 'ci-final-acceptance.json').write_text(json.dumps(report, indent=2) + '\n')
    print('PASS: both workflows; 2998/204, 50/21, 14 profiles/72 receipts, all34 runtime templates match Windows, 296 selectors and9 layouts')


if __name__ == '__main__':
    main()
