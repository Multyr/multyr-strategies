# docs/audit — Audit Evidence Index

This folder contains audit-submission evidence for the USDC Lending Strategy V10.

## Structure

```
docs/audit/
├── README.md                    (this file)
├── HALMOS_METHODOLOGY.md        (Halmos symbolic execution methodology)
├── WAVE1_2_SUMMARY.md           (executive summary: Wave 1+2 fixes + evidence)
├── refactor/                    (Wave 1+2 fix logs, one file per task)
│   ├── F_SIZE_01_REFACTOR.md    (StrategyScoringModule EIP-170 refactor)
│   ├── F_SIZE_02_REFACTOR.md    (UsdcMultiLendingVault EIP-170 refactor)
│   ├── F_SCORING_INV2_TRIAGE.md (cap consistency fix + triage evidence)
│   ├── ALLOCCALC_TRIAGE.md      (StrategyAllocCalcModule residual fix)
│   ├── REWARDSWAP_FIX.md        (RewardSwapHelper slippage + KEEPER_ROLE)
│   └── WAVE2_TASKS123.md        (Wave 2 verification: Echidna 1M + foundry.toml + Compound III)
├── verification/                (formal verification evidence)
│   ├── ECHIDNA_RESULTS_SUMMARY.md  (fuzzing campaign summary)
│   └── ECHIDNA_1M_EVIDENCE.txt    (full 1M baseline run log)
└── sizes/                       (bytecode size analysis)
    └── CONTRACT_SIZES.md        (all production contracts, post Wave 2)
```

## Quick reference

| Claim | Evidence |
|---|---|
| 2,354 tests passing, 0 failures | `forge test --match-path "test/strategies/usdc-lending/**"` |
| Echidna: 15/15 invariants, 1M sequences | `verification/ECHIDNA_RESULTS_SUMMARY.md` |
| Halmos: 23/23 symbolic proofs | `HALMOS_METHODOLOGY.md` |
| 0 EIP-170 violations | `sizes/CONTRACT_SIZES.md` |
| Wave 1+2 fix log | `WAVE1_2_SUMMARY.md` |
| Open findings | `outputs/NEW_FINDINGS.md` (repo root `outputs/`) |
