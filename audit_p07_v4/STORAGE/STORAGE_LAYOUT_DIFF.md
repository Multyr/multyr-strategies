# Storage Layout Diff — P0.7 Safety Adapter Cap Tier

**Branch:** `feature/p0.7-safety-adapter-tier` vs `origin/main`  
**Contract:** `StrategyStorageLayout.sol`  
**Date:** 2026-06-13  
**Method:** `forge inspect StrategyStorageLayout storage-layout` + `git show origin/main:src/...`

---

## Executive Summary

P0.7 introduces the Safety Fallback Adapter Cap Tier. Four storage slots are consumed from
`StrategyStorageLayout`'s reserved `__gap` budget (reduced from `[6]` to `[2]`). Three new
variables are packed into an existing slot's free space (no net new slot). Three new standalone
slots are added ahead of the pre-existing `lastSnapshot*` group, which shifts that group by
+3 slots. The `__gap` reduction is the canonical upgrade-safety indicator: 4 slots consumed,
2 slots remain for future P0.x additions.

---

## Slot-by-Slot Comparison

### Slot 78 — `capDriftToleranceBps` group

| Field | Offset | Size | Base (origin/main) | Head (P0.7) |
|---|---|---|---|---|
| `capDriftToleranceBps` | 0 | 2 B | present | present (unchanged) |
| `maxIdleBps` | 2 | 2 B | — | **NEW** — packed into slot 78 free space |
| `targetSafetyMarginBps` | 4 | 2 B | — | **NEW** — packed into slot 78 free space |
| `mandateRedeployCooldownSeconds` | 6 | 4 B | — | **NEW** — packed into slot 78 free space |
| (free) | 10 | 22 B | 30 B free | 22 B free |

> These three new fields fit in slot 78's previously-unused bytes. **No new slot consumed.**
> Packing note: `uint16 + uint16 + uint16 + uint32 = 10 bytes total`, well within the 30 B slack.

### Slots 79–81 — NEW Safety Fallback variables

| Slot | Field | Type | Base | Head (P0.7) |
|---|---|---|---|---|
| 79 | `safetyFallbackAdapters` | `address[]` (array head) | **displaced** (was `lastSnapshot*`) | **NEW** |
| 80 | `safetyFallback` | `mapping(address → SafetyFallback)` (head) | — | **NEW** |
| 81 | `lastRelCapMandateTs` | `mapping(address → uint64)` (head) | — | **NEW** |

> These three standalone slots are inserted *before* the pre-existing `lastSnapshot*` group.
> `safetyFallbackAdapters` occupies what was formerly slot 79 (lastSnapshotTotalAssets);
> that group is displaced to slot 82.

### Slot 82 — `lastSnapshot*` group (displaced, content unchanged)

| Field | Offset | Size | Base slot | Head slot |
|---|---|---|---|---|
| `lastSnapshotTotalAssets` | 0 | 16 B | **79** | **82** (+3) |
| `lastSnapshotTs` | 16 | 8 B | **79** | **82** (+3) |
| `lastSnapshotPredictedAPYBps` | 24 | 2 B | **79** | **82** (+3) |

> Content is identical. The +3 displacement is caused by the three new slots inserted above.
> **Upgrade safety:** this displacement is safe for a fresh deployment. If this contract were ever
> upgraded in place on existing storage, a migration script would be required.

### Slot 83+ — `__gap`

| | Base (origin/main) | Head (P0.7) |
|---|---|---|
| `__gap` declaration | `uint256[6]` | `uint256[2]` |
| Slots covered | 80–85 | 83–84 |
| Gap budget remaining | 6 slots | 2 slots |
| Consumed by P0.7 | — | 4 slots |

**Gap consumption breakdown (4 slots):**

| Consumed slot | Reason |
|---|---|
| Former gap slot 0 (→ slot 80) | `safetyFallback` mapping head |
| Former gap slot 1 (→ slot 81) | `lastRelCapMandateTs` mapping head |
| Former gap slot 2 (→ slot 82) | `lastSnapshotTotalAssets` group displaced here |
| Former gap slot 3 (→ no new use) | Retired: gap shrank from [6] to [2]; this slot is the net reduction |

---

## New Types Introduced

### `SafetyFallback` struct (stored per adapter in `safetyFallback` mapping)

```solidity
struct SafetyFallback {
    uint16  absCapBps;         // absolute exposure cap as % of vault TVL (basis points)
    uint16  relCapBps;         // relative exposure cap as % of external market TVL (bps)
    uint32  lastDeployedTs;    // timestamp of last overflow deploy to this adapter
}
```

Stored at mapping slots derived from `keccak256(abi.encode(adapter, 80))` (slot 80 is the
mapping's base slot on head).

---

## New Events / Functions (not storage, for reference)

- `event SafetyOverflowDeployed(address indexed adapter, uint256 amount, uint256 idleBefore, uint256 idleAfter)`
- `event SafetyFallbackAdapterAdded(address indexed adapter, uint16 absCapBps, uint16 relCapBps)`
- `event SafetyFallbackAdapterRemoved(address indexed adapter)`
- `event MaxIdleBpsUpdated(uint16 maxIdleBps)`

---

## Verification

Verified by `forge inspect` on P0.7 HEAD:

```
| capDriftToleranceBps             | uint16     | 78 | 0  | 2  | 78 |
| maxIdleBps                       | uint16     | 78 | 2  | 2  | 78 |
| targetSafetyMarginBps            | uint16     | 78 | 4  | 2  | 78 |
| mandateRedeployCooldownSeconds   | uint32     | 78 | 6  | 4  | 78 |
| safetyFallbackAdapters           | address[]  | 79 | 0  | 32 | 79 |
| safetyFallback                   | mapping    | 80 | 0  | 32 | 80 |
| lastRelCapMandateTs              | mapping    | 81 | 0  | 32 | 81 |
| lastSnapshotTotalAssets          | uint128    | 82 | 0  | 16 | 82 |
| lastSnapshotTs                   | uint64     | 82 | 16 | 8  | 82 |
| lastSnapshotPredictedAPYBps      | uint16     | 82 | 24 | 2  | 82 |
| __gap                            | uint256[2] | 83 | 0  | 64 | 83 |
```

Origin/main confirmed via `git show origin/main:...StrategyStorageLayout.sol`:
- Slot 78: `capDriftToleranceBps` (2 B used, 30 B free)
- Slot 79: `lastSnapshotTotalAssets` + `lastSnapshotTs` + `lastSnapshotPredictedAPYBps` (packed)
- Slots 80–85: `uint256[6] private __gap`
- No `maxIdleBps`, `targetSafetyMarginBps`, `mandateRedeployCooldownSeconds`, `safetyFallbackAdapters`, `safetyFallback`, or `lastRelCapMandateTs` in base
