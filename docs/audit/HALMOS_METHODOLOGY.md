# Halmos Formal Verification Methodology — P0.7 Safety Adapter Cap Tier

**File:** `test/strategies/usdc-lending/halmos/HalmosSafetyAdapterCapTier.t.sol`  
**Tool:** Halmos 0.2.0 / z3 QF_NIA  
**Result:** 23/23 PASS, 0 FAIL, 0 TIMEOUT  
**Evidence:** `outputs/S21_halmos_run.txt`, `test/strategies/usdc-lending/halmos/results/halmos-evidence.json`

---

## Parameter domains (from on-chain setters)

| Parameter | Source | Domain |
|-----------|--------|--------|
| `absCapBps` | `addSafetyFallbackAdapter` / `updateSafetyFallbackCaps` (StrategySettingsModule.sol:567) | **[1, 8000]** — continuous arbitrary uint16 |
| `relCapBps` | same setters (line 568) | [0, 10000] — continuous |
| `tolBps` (`capDriftToleranceBps`) | `setCapDriftTolerance` (line 372) | **[0, 2000]** — continuous arbitrary uint16 |
| `tvl`, `extTVL`, `curr` | runtime state | uint256 (bounded to uint64 in harness) |

**Note:** Neither `absCapBps` nor `tolBps` is an enum or whitelist. The case-split selects
representative values; completeness for the continuous domain rests on the monotonicity
arguments below.

---

## Proof strategy

### Group A — fully symbolic (6 properties)

Properties P1, P2a, P2b, P4, P5, P6 are proved with ALL parameters symbolic.
z3 explores the complete input domain simultaneously. No auxiliary argument needed.

### Group B — case-split + monotonicity (3 property groups, 17 checks)

**Why case-split?** z3 QF_NIA cannot decide `(symbolic_a * symbolic_b) R (symbolic_c * symbolic_d)`
in bounded time for large bitvectors. Fixing one factor to a concrete value makes the
product `concrete * symbolic` linear, which is decidable in milliseconds.

**P2c** — governance bound: `fbCeiling <= ABS_CAP_MAX * tvl / BPS`

Case-split on `absCapBps` ∈ {4000, 5000, 6000, 7500, 8000}. Each check fixes absCapBps;
relCapBps, tvl, extTVL remain symbolic.

Completeness for the continuous domain [1, 8000]:
- P2a (Group A, fully symbolic) proves: `fbCeiling <= absCapBps * tvl / BPS` for ALL absCapBps.
- Setter enforces: `absCapBps <= ABS_CAP_MAX = 8000`.
- Floor-division monotonicity: `absCapBps <= ABS_CAP_MAX => (absCapBps * tvl) / BPS <= (ABS_CAP_MAX * tvl) / BPS`.
- By transitivity: `fbCeiling <= govBound` for all admissible absCapBps. **QED.**
- The 5 case-split checks provide direct z3 evidence at key config points.

**P3a** — mandate ceiling monotone: `mandateHard(fb) >= mandateHard(n)` when `fb >= n`

Case-split on (fbAbsCapBps, normalAbsCapBps, tolBps) triples:

| Check | fb | n | tol | Description |
|-------|----|---|-----|-------------|
| fb4000_n4000_tol0 | 4000 | 4000 | 0 | equality boundary |
| fb8000_n4000_tol0 | 8000 | 4000 | 0 | max spread, zero tol |
| fb8000_n4000_tol1000 | 8000 | 4000 | 1000 | max spread, max tol |
| fb8000_n8000_tol500 | 8000 | 8000 | 500 | upper equality boundary |
| fb6000_n4000_tol500 | 6000 | 4000 | 500 | mid-range, typical |
| fb7500_n6000_tol0 | 7500 | 6000 | 0 | upper range |

With all three concrete, only tvl is symbolic. All products are `concrete * tvl` (linear).

Completeness for continuous domain (fb, n) ∈ [1, 8000]^2 and tol ∈ [0, 2000]:

  Let `A = (fb * tvl) / BPS`, `B = (n * tvl) / BPS`.
  1. `fb >= n AND tvl >= 0` => `fb * tvl >= n * tvl` => `A >= B` (floor-div monotone).
  2. `safetyHard = (A * (BPS + tol)) / BPS`, `normalHard = (B * (BPS + tol)) / BPS`.
  3. `A >= B AND (BPS + tol) >= 0` => `A * (BPS + tol) >= B * (BPS + tol)` => `safetyHard >= normalHard`.
  4. Step 3 holds for ANY tol ∈ [0, 2000] because the factor `(BPS + tol)` is IDENTICAL
     for both safetyHard and normalHard — tol cancels from the comparison.

The 6 case-split checks confirm the claim at key (fb, n, tol) points; the algebraic argument
above establishes it for the full continuous domain.

**P3b** — safety firing implies normal firing: corollary of P3a.

Same 6 case-split triples as P3a. Additional `curr` parameter remains fully symbolic.
Correctness by P3a: `curr > safetyHard AND safetyHard >= normalHard => curr > normalHard`.

---

## Reproducing the run

```bash
# From multyr-strategies repo root, branch feature/p0.7-safety-adapter-tier:
halmos --contract HalmosSafetyAdapterCapTier --loop 8 --solver-timeout-assertion 60000

# Expected output:
# Symbolic test result: 23 passed; 0 failed; time: ~100s

# Check for any non-PASS in evidence JSON:
jq '.proofs[] | select(.status != "PASS")' \
  test/strategies/usdc-lending/halmos/results/halmos-evidence.json
# Expected: empty output
```

---

## Slowest checks

| Check | Time (s) | Why |
|-------|----------|-----|
| check_P3a_mandate_monotone_fb7500_n6000_tol0 | 15.82 | largest asymmetric spread with non-trivial integer remainder |
| check_P3b_safety_fire_implies_normal_fire_fb7500_n6000_tol0 | 14.98 | same arithmetic + curr branch |
| check_P3a_mandate_monotone_fb6000_n4000_tol500 | 12.54 | mid-range with non-zero tol |

All within the 60s solver timeout with 4x headroom on the worst case.
