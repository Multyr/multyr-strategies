"""Read-only protocol inventories. No keys, transactions or balance overrides."""
import concurrent.futures
import hashlib
import json
import pathlib
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[4]
OUT = ROOT / 'deployments/lending-full-validation-20261101/production/arbitrum-assets'
SOURCES = {
    'comet-usdc': 'https://raw.githubusercontent.com/compound-finance/comet/main/deployments/arbitrum/usdc/roots.json',
    'comet-usdt': 'https://raw.githubusercontent.com/compound-finance/comet/main/deployments/arbitrum/usdt/roots.json',
    'comet-weth': 'https://raw.githubusercontent.com/compound-finance/comet/main/deployments/arbitrum/weth/roots.json',
    'comet-deployment-directories': 'https://api.github.com/repos/compound-finance/comet/contents/deployments/arbitrum',
    'euler': 'https://app.euler.finance/api/public/metadata?chainId=42161',
    'venus': 'https://raw.githubusercontent.com/VenusProtocol/isolated-pools/develop/deployments/arbitrumone_addresses.json',
    'fluid-factory': 'https://raw.githubusercontent.com/Instadapp/fluid-contracts-public/main/deployments/arbitrum/LendingFactory.json',
    'fToken_fUSDC': 'https://raw.githubusercontent.com/Instadapp/fluid-contracts-public/main/deployments/arbitrum/fToken_fUSDC.json',
    'fToken_fUSDT': 'https://raw.githubusercontent.com/Instadapp/fluid-contracts-public/main/deployments/arbitrum/fToken_fUSDT.json',
    'fToken_fWETH': 'https://raw.githubusercontent.com/Instadapp/fluid-contracts-public/main/deployments/arbitrum/fToken_fWETH.json',
    'morpho-v1': 'https://api.morpho.org/v0/vaults-v1?chain_ids=42161&limit=1000',
    'morpho-v2': 'https://api.morpho.org/v0/vaults-v2?chain_ids=42161&limit=1000',
    'morpho-all-vaults-v1': 'https://api.morpho.org/graphql',
    'morpho-all-vaults-v2': 'https://api.morpho.org/graphql',
    'morpho-blue-all': 'https://api.morpho.org/graphql',
}
QUERIES = {
    'morpho-all-vaults-v1': '{ vaults(first: 1000, where: {chainId_in: [42161]}) {items {address name asset {address symbol} listed state {totalAssets}} pageInfo {count countTotal}} }',
    'morpho-all-vaults-v2': '{ vaultV2s(first: 1000, where: {chainId_in: [42161]}) {items {address name asset {address symbol}} pageInfo {count countTotal}} }',
    'morpho-blue-all': '{ markets(first: 1000, where: {chainId_in: [42161]}) {items {marketId loanAsset {address symbol} collateralAsset {address symbol}} pageInfo {count countTotal}} }',
}

def fetch(item):
    name, url = item
    try:
        body=json.dumps({'query':QUERIES[name]}).encode() if name in QUERIES else None
        req = urllib.request.Request(url, data=body, headers={'User-Agent': 'LendingCompatibilityAudit/1.0','Content-Type':'application/json'})
        raw = urllib.request.urlopen(req, timeout=45).read()
        data = json.loads(raw)
        if name in QUERIES:
            result=next(iter(data['data'].values()))
            assert result['pageInfo']['count']==result['pageInfo']['countTotal'], 'Incomplete GraphQL pagination'
        OUT.mkdir(parents=True, exist_ok=True)
        (OUT / (name + '.json')).write_bytes(raw)
        return {'name': name, 'source': url, 'sha256': hashlib.sha256(raw).hexdigest(), 'status': 'FETCHED', 'data': data}
    except Exception as exc:
        return {'name': name, 'source': url, 'status': 'UNRESOLVED', 'errorType': type(exc).__name__}

if __name__ == '__main__':
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(fetch, SOURCES.items()))
    for r in results:
        data = r.pop('data', {})
        if r['name'].startswith('comet'):
            print(r['name'], json.dumps(data)[:900])
        elif r['name'] == 'euler':
            for address, meta in data.items():
                if isinstance(meta, dict) and (meta.get('asset') or {}).get('symbol') in ('USDC', 'USDT', 'USDT0', 'WETH', 'WBTC'):
                    print('euler', address, meta.get('name'), meta.get('asset'), 'deprecated', meta.get('deprecated'))
        else:
            print(r['name'], list(data)[:12] if isinstance(data, dict) else 'array')
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'sources.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
    print(json.dumps(results, indent=2))
