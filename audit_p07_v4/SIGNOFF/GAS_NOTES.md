# Gas / Design Trade-offs — P0.7 Notes for Auditor

This document discloses deliberate design trade-offs in the P0.7 changeset that affect gas profile. These are noted pre-engagement to streamline INFORMATIONAL findings during audit.

## 1. Delegate-call module pattern

**Design**: Each of the 7 controller modules is invoked via `delegatecall` against a shared `StrategyStorageLayout`. All modules share the same storage slots; the dispatch is via a registry-style mapping in the proxy.

**Gas cost**: ~700-2400 gas per cross-module call (delegate-call overhead + storage layout pointer resolution).

**Rationale**:
- Bytecode size limit (24 KB) for the controller would be exceeded if all logic were inlined
- Module-level upgradability (per-module implementation pointer) supports surgical hotfix without full deployment
- Separation of concerns (settings vs rebalance plan vs gate vs alloc-calc) aids code review

**Alternative considered**: Library pattern with `using ... for ...`. Rejected because library code is `internal` and would still hit bytecode limit when consumed by all controllers.

**Trade-off accepted**: Each delegate-call adds modest gas vs inline. Quantified impact at production setpoint (424 rebalances/year, ~3 cross-module calls per rebalance) is ~750k gas/year = ~$0.30 of gas at Arbitrum prices. Justified by upgradability + bytecode budget.

## 2. Linear scan over `safetyFallbackAdapters` array

**Design**: `_executeSafetyOverflow` loops over `safetyFallbackAdapters` in priority order, attempting deposit at each until idle is below threshold.

**Gas cost**: O(N) where N = number of safety adapters configured. At current production setpoint (N=2: Aave, Compound), this is trivial. The implementation has a hard cap `MAX_SAFETY_ADAPTERS = 10` (verified by Echidna I09 invariant).

**Rationale**:
- Priority order MATTERS — Aave gets overflow before Compound. A heap/queue would lose this guarantee.
- Read access pattern (storage array vs mapping) is cache-friendly for short arrays.
- Low expected N (≤5 in production).

**Trade-off accepted**: Linear scan is the simplest correct implementation. If N grows beyond 5 in future, would warrant re-evaluation.

## 3. Packed storage slot 78 (capDrift + maxIdle + margin + cooldown)

**Design**: Compiler packs 4 P0.7-related fields into a single 256-bit slot:
- `capDriftToleranceBps` (uint16) at offset 0
- `maxIdleBps` (uint16) at offset 2 bytes
- `targetSafetyMarginBps` (uint16) at offset 4 bytes
- `mandateRedeployCooldownSeconds` (uint32) at offset 6 bytes
- Total: 80 bits used, 176 bits unused

**Gas cost**: 1 SSTORE per multi-field update (vs 4 SSTORE if separate slots). Saves ~60k gas per multi-field governance call.

**Rationale**: Governance setters often update multiple fields in sequence (e.g., during onboarding or parameter tuning). Packing them in one slot allows efficient bulk updates.

**Trade-off accepted**: Each individual setter does a read-modify-write on the slot (additional ~5k gas per single-field update). Net positive for typical usage pattern.

**Verified**: `forge inspect ... :storageLayout` snapshot in `STORAGE/p07-storage-layout.json` confirms compiler-determined packing matches Solidity declarations.

## 4. Per-adapter cooldown timestamp in mapping (slot 81)

**Design**: `lastRelCapMandateTs[adapter]` is a mapping from address to uint64. Each storage write is a fresh 32-byte SSTORE.

**Gas cost**: 20k gas (cold storage slot init) on first mandate, 5k gas on subsequent updates.

**Rationale**:
- Per-adapter granularity is required for the safety semantics (cooldown is per-adapter, not global)
- Mapping is more storage-efficient than array for sparse adapters
- uint64 is sufficient: timestamps at second granularity to year 2554

**Trade-off accepted**: Mapping read costs ~2.1k gas per access. The rebalance gate reads this for each safety adapter on every plan generation; at N=2 safety adapters, this is ~4k gas/plan. Negligible.

## 5. Multiple storage reads in `prepareRebalance`

**Design**: `prepareRebalance` reads multiple storage fields (extTVL cache, current positions, scoring, cap tolerances, fallback caps) to compute the rebalance plan.

**Gas cost**: ~70-200 cold SLOADs per rebalance plan computation. At Arbitrum prices: $0.05-0.20 per plan.

**Rationale**:
- Plan computation requires global state visibility — there's no way around this
- Most reads are warm in the same transaction (e.g., score for an adapter is read multiple times during plan optimisation)
- Computation is deterministic and cached in `rebalancePlanPhase` once computed

**Trade-off accepted**: SLOAD is necessary cost of correct plan computation. Alternative (Merkle proofs of off-chain plan) was rejected because keeper-side computation is not auditable on-chain.

## 6. Loop in `_targetAllocations` over all adapters

**Design**: `_targetAllocations` iterates over all 7 enabled adapters to compute proportional target allocations.

**Gas cost**: O(K) where K = enabled adapters. At K=7, this is ~30k gas of computation per call.

**Rationale**:
- Proportional allocation requires score normalisation across all adapters
- Score is computed per-adapter (each adapter has its own cap, extTVL, score factors)
- K is bounded by `MAX_ADAPTERS = 10` constant

**Trade-off accepted**: Linear scan is the natural algorithm. Sorting (for top-k allocation) would add complexity without meaningful gas saving at K=7.

## 7. No transient storage (TSTORE / TLOAD)

**Design**: P0.7 does not use EIP-1153 transient storage (introduced in Cancun).

**Rationale**: Current target is `evm_version = "paris"` for compatibility with broader EVM ecosystem. Cancun upgrade to enable TSTORE would require validation across all underlying protocols' compatibility (e.g., older Aave / Compound deployments).

**Trade-off accepted**: ~3-5k gas saving per rebalance from TSTORE not pursued. Future upgrade (V9.3) can consider Cancun target with associated re-verification.

## 8. `via_ir = true` for compilation

**Design**: Compilation uses Yul IR pipeline (`via_ir = true`, `optimizer_runs = 200`).

**Gas cost**: Yul IR optimisation produces tighter bytecode than legacy pipeline; gas savings of 5-15% observed on lending operations.

**Trade-off accepted**: Compilation is slower (~30% longer build time). Acceptable for production deployment.

**Lens limitation note**: Pre-S2.4-bis refactor, `StrategyExplainabilityLens` could not be compiled with `--ir-minimum` due to Yul stack-too-deep. Refactor split a 30+ local variable function into 6 helpers, bringing it within Yul's 16-slot stack window.

## 9. Selective coverage instrumentation exclusion

**Design**: Forge coverage uses `--no-match-coverage "(StrategyExplainabilityLens|QueueModule)"` to exclude two files from instrumentation.

**Gas cost**: None at runtime. Coverage instrumentation is a build-time concern only.

**Rationale**:
- `QueueModule` (lib/multyr-core) is upstream library, separate audit perimeter
- `StrategyExplainabilityLens` is read-only off-chain observability, post S2.4-bis refactor is now instrumentable but historically required exclusion

**Documented**: `EVIDENCE/coverage/COVERAGE_EXCLUSIONS.md` provides full rationale.

## 10. Per-adapter `pokeExternalTVL` vs batch

**Design**: `pokeExternalTVL` accepts a single adapter address per call. Batch updates are achieved by sequential keeper calls.

**Gas cost**: Per-call overhead (calldata, entry function) repeated per adapter. ~30k gas overhead × 7 adapters = ~210k gas/cycle.

**Rationale**:
- Batch poke would require dynamic-length array calldata, adding parse complexity
- Per-call granularity allows keeper to skip adapters whose extTVL change is small
- Chainlink Automation upkeeps are billed per call, so batching saves no cost there

**Trade-off accepted**: Modest overhead in exchange for simpler keeper logic.

## Auditor observations expected

The following will likely surface as INFORMATIONAL findings during audit. Pre-disclosure here speeds resolution:

1. Delegate-call gas overhead in `_executeSafetyOverflow` — answered by §1
2. Linear scan optimisation opportunity for `safetyFallbackAdapters` — answered by §2
3. Storage slot packing comment in `StrategyStorageLayout.sol` claims 4 slots; actual is 3 (capDrift packed with P0.7 vars in slot 78) — known and intentional, documented in `STORAGE/STORAGE_LAYOUT_DIFF.md`
4. `safetyFallback` mapping packing opportunity (combine `absCapBps` + `relCapBps` into single uint32) — considered but rejected for ABI clarity (separate uint16 fields are self-documenting)
