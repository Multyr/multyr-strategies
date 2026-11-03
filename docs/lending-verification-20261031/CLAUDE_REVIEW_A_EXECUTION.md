The `F_SCORING_INV2_CapFix.t.sol` suite completed: **exit code 0, no failures printed** (forge `-q` mode only prints failures; zero output + zero exit = all tests passed). Compilation took 232s — 88 files compiled with solc 0.8.28. The broader non-fork regression is still running.

**Update to the Commands section of review-A.md:**

| Command | Scope | Exit | Passed | Failed | Skipped | Unexecuted |
|---|---|---|---|---|---|---|
| `forge test --match-path "test/strategies/usdc-lending/F_SCORING_INV2_CapFix.t.sol" -q` | Scoring cap invariant fix tests | **0** | All (count not captured by tail) | **0** | 0 | 0 |
| `forge test --match-path "test/strategies/usdc-lending/*" --no-match-test "fork\|Fork\|FORK" -q` | Non-fork lending regression | Still running | — | — | — | Pending |
| Fork tests / live matrix / oracle edge cases | Required by user gate | NOT STARTED | — | — | — | All |

The scoring invariant suite passing at exit 0 confirms that the A-2 scoring fix is already in the candidate source and the related invariant tests agree with it. **However, A-2 is still present** — the `F_SCORING_INV2` tests cover the *scoring normalization* fix (the `effectiveAbsCapBps` calculation path in `StrategyScoringModule`), not the safety overflow deployment path or the gate module's cap drift mandate. The two confirmed-broken lines in `StrategySafetyOverflowModule:74` and `StrategyRebalanceGateModule:386` are separate code paths that the scoring invariant tests do not exercise.

The finding, severity, and proposed patches in the report above stand unchanged. The live-chain fork gate remains open.
