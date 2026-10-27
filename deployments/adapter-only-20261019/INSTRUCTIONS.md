# Superseded by completed deployments

Do not execute this folder’s deployment/activation JSONs. The deployer has now deployed new adapter addresses. Use `../adapter-live-20261019/01-activate-adapter-fixes.safe.json` after reviewing its final validation status.

# Adapter-only repair — allocation policy unchanged

These files retain strategy 0xa9E676D15976A1332905238ca609Dff9A484Efe0, upkeep 0xbcaC314E7237b14E11644FC6Ba73675c8c0612DF, Core and Router. They do not remove the small-vault tier or introduce an exposure percentage. At the pinned preflight the governance cap is zero, so 100% normal allocation remains possible until a separate policy change is approved and applied.

Do not execute the earlier replacement-strategy migration JSONs or activate arbitrum-one.next.json for this path.

Safe: 0x70ef444799D6FBbE0865bA598Bee6795e064a326. Network: Arbitrum One (42161).

Execute the numbered files in order. Each file must execute successfully on-chain, not merely be signed, before proceeding. There is no Router allowlist timelock because the strategy address is unchanged.

- 00 deploys a stateless drain assertion contract.
- 01 deploys the corrected Venus adapter.
- 02 deploys and initializes the corrected Morpho adapter.
- 03 deploys and initializes the corrected Dolomite adapter.
- 04 deploys and initializes the corrected Fluid adapter.
- 05 performs all adapter-swap calls together as one atomic Safe batch. Do not split this file. It checks that no rebalance plan is active, disables upkeep/deposits within the transaction, recalls the four affected adapters into the current strategy, checks each old adapter holds at most 0.0001 USDC, synchronizes bookkeeping, disables and removes old adapter whitelist entries, registers replacements, updates APY-poke targets and the Fluid safety address, fixes Euler's explicit capacity, calibrates gas floors and refreshes data, then restores deposits/upkeep. Any revert rolls back the complete file-05 batch.

The first five files deploy contracts with the Safe as admin; they do not move existing vault funds. Addresses in manifest.json are deterministic predictions, not claims of mainnet deployment. Creation bytecode comes from the preserved Oct19 audited/tested adapter artifacts, with initialization bound to the existing strategy and existing protocol registry/market settings. Explorer verification follows deployment.

Four historical adapters remain in the append-only registry disabled; the keeper filters them out. Seven adapters remain enabled. Aave, Comet and Euler are retained. Euler's explicit capacity is set to the same 50M-USDC ceiling used by the other adapters instead of its broken zero sentinel.

Safety fallback settings and allocation settings are preserved; this includes the current elevated Fluid fallback cap. No claim of a strict portfolio exposure ceiling is made by this package.

Keeper: retain /app/config/arbitrum-one.json. No AWS retarget is required for this adapter-only change. The on-chain upkeep targets are changed in file 05. Verify current ECS config independently, and record the first subsequent keeper deployment receipt. W4/W6 schedules are unchanged.

Before signing, refresh live state and simulate every file. Stop if a rebalance plan is active or the strategy has already migrated. Check the rehearsal result and package status in manifest.json. New PPS adapters start with conservative observations and need a valid observation window before reporting annualised PPS rates.

Validation: the final exact Safe calldata passed on a pinned Arbitrum fork at block 516204716, including NAV preservation, drained old adapters, new ownership/vault bindings, APY upkeep PARAM_ROLE and actual poke calls, positive Euler capacity and a successful keeper deployIdle call. Three guard unit tests and 32 keeper tests passed; TypeScript checks passed. This is not mainnet execution or proof that the current AWS task is healthy.
