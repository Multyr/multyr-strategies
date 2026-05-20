# USDC Lending Strategy - Gas Optimization Guide

## Overview

This document outlines gas optimization strategies, profiling methods, and implementation guidelines for the USDC Lending Strategy. The strategy focuses on multi-protocol USDC lending with dynamic allocation based on scoring, making gas efficiency critical for profitable rebalancing operations.

---

## Current State Analysis

### Gas Profile Baseline

| Operation | Current Est. | Target | Status |
|-----------|--------------|--------|--------|
| `deposit()` | 150-250k gas | <150k | ⏳ To measure |
| `withdraw()` | 100-200k gas | <100k | ⏳ To measure |
| `rebalance()` | 300-500k gas | <250k | ⏳ To measure |
| `harvest()` | 100-150k gas/adapter | <80k | ⏳ To measure |
| `calculateScores()` | ~50k gas | <30k | ⏳ To measure |

### Optimization Score: **7/10**

**Already Optimized:**
- ✅ Custom errors used (15+ error types)
- ✅ Immutable variables (`ASSET`, `core`)
- ✅ ReentrancyGuard present
- ✅ SafeERC20 for safe transfers

**Needs Optimization:**
- ⚠️ Storage packing (11+ slots can be reduced to 3-4)
- ⚠️ No `unchecked` arithmetic in loops
- ⚠️ `memory` instead of `calldata` in some functions
- ⚠️ Multiple storage reads without caching
- ⚠️ One string error instead of custom error

---

## Optimization Strategies

### 1. Storage Packing (Priority: HIGH)

#### Current Implementation (Lines 72-106)
```solidity
// BEFORE: 11 separate storage slots (~220k gas SSTORE cost)
uint16 public maxAdaptersPerAllocation;      // Slot 0
uint16 public minAdaptersActive;             // Slot 1
uint16 public rebalanceMinMoveBps;           // Slot 2
uint32 public minSecondsBetweenRebalances;   // Slot 3
uint16 public driftToleranceBps;             // Slot 4
uint16 public wAPY;                          // Slot 5
uint16 public wLiq;                          // Slot 6
uint16 public wRisk;                         // Slot 7
uint16 public wStability;                    // Slot 8
uint16 public wIncentive;                    // Slot 9
uint32 public incentiveDecayHalfLife;        // Slot 10
// ... and more
```

#### Optimized Implementation
```solidity
// AFTER: Packed into 3-4 slots (~60-80k gas SSTORE cost)

// Slot 0: Allocation Parameters (128 bits)
struct AllocationParams {
    uint16 maxAdaptersPerAllocation;  // 16 bits
    uint16 minAdaptersActive;         // 16 bits
    uint16 rebalanceMinMoveBps;       // 16 bits
    uint32 minSecondsBetweenRebalances; // 32 bits
    uint16 driftToleranceBps;         // 16 bits
    uint16 adapterMaxExposureBps;     // 16 bits
    uint16 newAdapterRampBps;         // 16 bits
}
AllocationParams public allocationParams;

// Slot 1: Scoring Weights (80 bits)
struct ScoringWeights {
    uint16 wAPY;                      // 16 bits
    uint16 wLiq;                      // 16 bits
    uint16 wRisk;                     // 16 bits
    uint16 wStability;                // 16 bits
    uint16 wIncentive;                // 16 bits
}
ScoringWeights public scoringWeights;

// Slot 2: Gate Parameters (192 bits + 64 bits padding)
struct GateParams {
    uint16 gateHorizonDays;           // 16 bits
    uint16 gateMinNetBenefitBps;      // 16 bits
    uint16 slippageBpsEstimate;       // 16 bits
    uint16 withdrawalSpreadBpsEstimate; // 16 bits
    uint128 gasCostUSDC;              // 128 bits (enough for USDC 6 decimals)
}
GateParams public gateParams;

// Slot 3: Harvest + State (128 bits)
struct HarvestParams {
    uint16 harvestThresholdBps;       // 16 bits
    uint32 minSecondsBetweenHarvests; // 32 bits
    uint64 lastHarvestTs;             // 64 bits (combined with state)
    uint16 stabilityEMAPeriod;        // 16 bits
}
HarvestParams public harvestParams;

// Slot 4: State flags + timestamps (128 bits)
struct StateFlags {
    bool rolesFrozen;                 // 8 bits
    bool paramsFinalized;             // 8 bits
    uint64 lastRebalanceTs;           // 64 bits
    uint32 incentiveDecayHalfLife;    // 32 bits
    uint16 __padding;                 // 16 bits padding
}
StateFlags public stateFlags;
```

**Savings:**
- Deploy: ~140k gas (7 slots saved × 20k gas SSTORE)
- Parameter updates: ~40-60k gas per update
- Total annual savings (10 param updates): ~500k gas = $1.50-2.50

---

### 2. Unchecked Arithmetic (Priority: HIGH)

#### Scoring Loop Optimization

**BEFORE:**
```solidity
function _calculateScores() internal view returns (uint256[] memory) {
    uint256[] memory scores = new uint256[](adapters.length);
    for (uint256 i = 0; i < adapters.length; i++) {
        // Multiplication and division with checked arithmetic
        uint256 apyScore = (apyBps * wAPY) / 10000;
        uint256 liqScore = (liqBps * wLiq) / 10000;
        scores[i] = apyScore + liqScore + riskScore + stabilityScore + incentiveScore;
    }
    return scores;
}
```

**AFTER:**
```solidity
function _calculateScores() internal view returns (uint256[] memory) {
    uint256[] memory scores = new uint256[](adapters.length);
    uint256 len = adapters.length; // Cache length

    unchecked {
        for (uint256 i = 0; i < len; ++i) { // Use ++i instead of i++
            // Safe: scores are bps (max 10000), cannot overflow uint256
            uint256 apyScore = (apyBps * wAPY) / 10000;
            uint256 liqScore = (liqBps * wLiq) / 10000;
            scores[i] = apyScore + liqScore + riskScore + stabilityScore + incentiveScore;
        }
    }
    return scores;
}
```

**Savings:**
- Per adapter in loop: ~30-40 gas
- Typical rebalance (7 adapters): ~210-280 gas
- Annual (100 rebalances): ~21-28k gas = $0.06-0.08

---

### 3. Storage Read Caching (Priority: MEDIUM)

#### Rebalance Function Optimization

**BEFORE (Multiple SLOAD operations):**
```solidity
function rebalance() external {
    if (block.timestamp < lastRebalanceTs + minSecondsBetweenRebalances) {
        revert RebalanceCooldown();
    }

    // ... logic using wAPY, wLiq, wRisk multiple times
    uint256 score1 = calculateScore(adapter1, wAPY, wLiq, wRisk);
    uint256 score2 = calculateScore(adapter2, wAPY, wLiq, wRisk);
    // Each access = 2.1k gas SLOAD
}
```

**AFTER (Cached in memory):**
```solidity
function rebalance() external {
    // Cache state variables (1x SLOAD each)
    uint64 _lastRebalance = lastRebalanceTs;
    uint32 _cooldown = minSecondsBetweenRebalances;
    uint16 _wAPY = wAPY;
    uint16 _wLiq = wLiq;
    uint16 _wRisk = wRisk;

    if (block.timestamp < _lastRebalance + _cooldown) {
        revert RebalanceCooldown();
    }

    // Use cached variables (0 gas MLOAD)
    uint256 score1 = calculateScore(adapter1, _wAPY, _wLiq, _wRisk);
    uint256 score2 = calculateScore(adapter2, _wAPY, _wLiq, _wRisk);
}
```

**Savings:**
- Per avoided SLOAD: ~2.1k gas
- Typical rebalance (5-10 avoided SLOADs): ~10-20k gas
- Annual (100 rebalances): ~1-2M gas = $3-6

---

### 4. Calldata Instead of Memory (Priority: MEDIUM)

#### Constructor Optimization

**BEFORE (Line 196):**
```solidity
constructor(
    address asset_,
    address _core,
    StrategyInitParams memory params  // Copies to memory
) {
    _setStrategyParams(params);
}
```

**AFTER:**
```solidity
constructor(
    address asset_,
    address _core,
    StrategyInitParams calldata params  // Reads directly from calldata
) {
    _setStrategyParams(params);
}
```

**Savings:**
- Per struct field: ~3 gas per byte
- StrategyInitParams (19 fields × 32 bytes): ~1.8k gas
- One-time savings at deploy

---

### 5. Custom Error for String Revert (Priority: LOW)

#### NoCashInvariant Fix

**BEFORE (Line 179):**
```solidity
if (idle > dustTolerance) revert("NoCashInvariant");
```

**AFTER:**
```solidity
error NoCashInvariant(uint256 idle, uint256 dustTolerance);

if (idle > dustTolerance) revert NoCashInvariant(idle, dustTolerance);
```

**Savings:**
- Per revert: ~50 gas (smaller bytecode)
- Bytecode size reduction: ~100-200 bytes

---

### 6. Array Length Caching (Priority: MEDIUM)

#### Adapter Iteration Optimization

**BEFORE:**
```solidity
function _processAllAdapters() internal {
    for (uint256 i = 0; i < adapters.length; i++) {
        // adapters.length is read every iteration (SLOAD)
        _processAdapter(adapters[i]);
    }
}
```

**AFTER:**
```solidity
function _processAllAdapters() internal {
    uint256 len = adapters.length; // Cache once
    unchecked {
        for (uint256 i = 0; i < len; ++i) { // Use cached length + ++i
            _processAdapter(adapters[i]);
        }
    }
}
```

**Savings:**
- Per iteration: ~100 gas (avoid SLOAD)
- Typical harvest (7 adapters): ~700 gas
- Annual (200 harvests): ~140k gas = $0.40

---

### 7. Short-Circuit Logic (Priority: LOW)

#### Access Control Optimization

**BEFORE:**
```solidity
modifier onlyKeeperOrCore() {
    if (!hasRole(KEEPER_ROLE, msg.sender) && !hasRole(CORE_ROLE, msg.sender)) {
        revert Unauthorized();
    }
    _;
}
```

**AFTER:**
```solidity
modifier onlyKeeperOrCore() {
    // Short-circuit: if first check passes, skip second
    if (!hasRole(KEEPER_ROLE, msg.sender)) {
        if (!hasRole(CORE_ROLE, msg.sender)) {
            revert Unauthorized();
        }
    }
    _;
}
```

**Savings:**
- Per successful keeper call: ~300 gas (skip CORE_ROLE check)
- Annual (300 keeper actions): ~90k gas = $0.27

---

## Gas Profiling Commands

### 1. Generate Gas Report
```bash
forge test --match-path "test/strategies/usdc-lending/**/*.t.sol" --gas-report
```

### 2. Create Gas Snapshot
```bash
forge snapshot --match-path "test/strategies/usdc-lending/**/*.t.sol"
```

### 3. Compare Before/After Optimization
```bash
# Before optimization
forge snapshot --snap .gas-snapshot-baseline

# Apply optimizations...

# After optimization
forge snapshot --diff .gas-snapshot-baseline
```

### 4. Specific Function Gas Analysis
```bash
forge test --match-test test_Rebalance --gas-report -vvv
```

---

## Expected Gas Savings Summary

| Optimization | One-Time Savings | Per Operation | Annual Savings (Est.) | Cost (USD/year) |
|--------------|------------------|---------------|----------------------|-----------------|
| Storage Packing | 140k gas (deploy) | 40-60k gas/update | ~500k gas | $1.50-2.50 |
| Unchecked Loops | N/A | ~210-280 gas/rebalance | ~21-28k gas | $0.06-0.08 |
| Storage Caching | N/A | ~10-20k gas/rebalance | ~1-2M gas | $3-6 |
| Calldata Params | 1.8k gas (deploy) | N/A | N/A | N/A |
| Custom Errors | 200 bytes bytecode | ~50 gas/revert | Minimal | <$0.10 |
| Array Length Cache | N/A | ~700 gas/harvest | ~140k gas | $0.40 |
| Short-Circuit Logic | N/A | ~300 gas/keeper call | ~90k gas | $0.27 |
| **TOTAL** | **~142k gas** | **~51-81k gas** | **~1.75-2.75M gas** | **$5.23-8.41** |

*Based on Arbitrum gas price: 0.1 gwei, ETH: $3,000*

---

## Optimization Checklist

Before deploying optimized version:

- [ ] Storage variables packed into structs (3-4 slots total)
- [ ] All loops use `unchecked` where safe
- [ ] All external functions use `calldata` instead of `memory`
- [ ] Storage reads cached in local variables
- [ ] All errors are custom errors (no string reverts)
- [ ] Array lengths cached before loops
- [ ] Use `++i` instead of `i++` in loops
- [ ] Short-circuit logic in modifiers
- [ ] Immutable used for all contract references
- [ ] Gas snapshots generated and compared
- [ ] Gas benchmarks meet targets (<250k for rebalance)

---

## Implementation Plan

### Phase 1: Non-Breaking Optimizations (Low Risk)
1. Add `unchecked` blocks in loops
2. Cache array lengths
3. Replace string error with custom error
4. Use `calldata` in constructor
5. Cache storage reads in functions

**Risk:** Very Low
**Testing:** Standard unit tests
**Estimated Savings:** ~1-1.5M gas/year

### Phase 2: Storage Packing (Medium Risk)
1. Create packed structs for parameters
2. Update all getter/setter functions
3. Update constructor and initialization
4. Migrate tests to use new structs

**Risk:** Medium (requires thorough testing)
**Testing:** Full unit + fork tests
**Estimated Savings:** ~500k-1M gas/year

### Phase 3: Advanced Optimizations (High Risk)
1. Assembly for critical paths (if needed)
2. Bitmap flags for boolean storage
3. Custom memory allocation

**Risk:** High (only if Phase 1+2 insufficient)
**Testing:** Extensive fuzzing + audit
**Estimated Savings:** ~200-500k gas/year

---

## Testing Strategy

### 1. Pre-Optimization Baseline
```bash
# Generate baseline gas snapshot
forge snapshot --snap .gas-snapshot-before

# Run full test suite
forge test --match-path "test/strategies/usdc-lending/**/*.t.sol"
```

### 2. Apply Optimizations Incrementally
Apply one optimization at a time, test after each:
```bash
# After each optimization
forge test --match-path "test/strategies/usdc-lending/**/*.t.sol" --gas-report
forge snapshot --diff .gas-snapshot-before
```

### 3. Fork Testing
Test on Arbitrum fork with real protocol interactions:
```bash
# Set fork URL in .env
ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc

# Run fork tests
forge test --fork-url $ARBITRUM_RPC_URL --match-path "test/strategies/usdc-lending/**/*.t.sol"
```

### 4. Stress Testing
Test with maximum values to ensure no overflow:
```bash
forge test --match-test test_StressTest -vvv
```

---

## L2-Specific Optimizations (Arbitrum)

### Calldata Compression
Arbitrum charges for calldata size:
- Minimize calldata in frequently-called functions
- Use `bytes32` for identifiers instead of `string`
- Pack multiple parameters into single `bytes` argument if needed

### Example:
```solidity
// BEFORE (larger calldata)
function setParams(
    uint16 param1,
    uint16 param2,
    uint16 param3,
    uint16 param4
) external {
    // ...
}

// AFTER (packed into single uint64)
function setParams(uint64 packedParams) external {
    uint16 param1 = uint16(packedParams);
    uint16 param2 = uint16(packedParams >> 16);
    uint16 param3 = uint16(packedParams >> 32);
    uint16 param4 = uint16(packedParams >> 48);
    // ...
}
```

---

## Continuous Monitoring

### CI/CD Integration
Add gas report to GitHub Actions:
```yaml
name: Gas Report

on: [pull_request]

jobs:
  gas-report:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
        with:
          fetch-depth: 2
      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1
      - name: Run gas comparison
        run: |
          git checkout HEAD^
          forge snapshot --snap .gas-snapshot-base
          git checkout -
          forge snapshot --diff .gas-snapshot-base --check
```

### Gas Regression Prevention
- Fail CI if gas increases >5% without justification
- Require gas benchmark updates in PR description
- Monthly gas cost review

---

## Tools

### Foundry Tools
- `forge test --gas-report` - Gas usage report
- `forge snapshot` - Gas snapshots
- `forge coverage` - Code coverage
- `forge inspect` - Bytecode inspection

### External Tools
- **Slither** - Static analysis for gas issues
  ```bash
  slither src/strategies/usdc-lending/ --detect costly-loop,cache-array-length
  ```

- **Echidna** - Property-based fuzzing
  ```bash
  echidna-test . --contract UsdcMultiLendingVault --config echidna.yaml
  ```

---

## References

- [Solidity Gas Optimization Tips](https://gist.github.com/hrkrshnn/ee8fabd532058307229d65dcd5836ddc)
- [Foundry Book - Gas Tracking](https://book.getfoundry.sh/forge/gas-tracking)
- [Arbitrum Gas Documentation](https://docs.arbitrum.io/arbos/gas)
- [EVM Codes - Gas Costs](https://www.evm.codes/)
- [OpenZeppelin Gas Optimization Patterns](https://blog.openzeppelin.com/solidity-gas-optimization)

---

## Document Metadata

**Version:** 1.0.0
**Last Updated:** 2025-01-24
**Author:** Development Team
**Status:** Active
**Next Review:** 2025-02-24
