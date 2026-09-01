# deployments/

Reproducibility records for non-production deployments.

## `deployments/shadow/<deployment-id>/`

Written by `script/deploy-usdc-lending-shadow.sh` (via
`DeployUsdcLendingStrategy._writeShadowManifest`). One directory per Shadow run,
`<deployment-id>` = `<utc-timestamp>-<git-sha>` unless pinned via
`SHADOW_DEPLOYMENT_ID`.

| File | Contents |
|---|---|
| `manifest.json` | provenance (env, git commit, chain id, source block), governance/operator addresses, deployed contract addresses + runtime code hashes, forked-in core addresses, a role/ownership snapshot, and config parameters |
| `addresses.json` | flat address book (same shape as `broadcast/strategy-addresses.json`) |

These files are committed as evidence. Forge's own `run-*.json` broadcast logs
under this path are gitignored.

Production Arbitrum deployments are **not** recorded here — they go through
`script/deploy-usdc-lending.sh` and `broadcast/`.
