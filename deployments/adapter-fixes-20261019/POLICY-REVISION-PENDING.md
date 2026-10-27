# Migration superseded pending policy revision

Do not execute the existing migration JSONs for the revised policy. They activate the previously deployed 25% configuration, not the requested removal of the small-vault single-adapter exception.

Local source now applies the existing two-adapter tier below 250,000 USDC (55% structural base before overlays), including when the global ceiling is disabled. A manual one-slot selection limit does not restore the 100% cap. Explicit governance overrides and safety fallback settings remain separate policies.

These source changes are not deployed. Existing deployment receipts and provenance remain historical evidence of the prior deployment. Updated deployment/configuration and migration rehearsal are required before issuing replacement Safe files.
