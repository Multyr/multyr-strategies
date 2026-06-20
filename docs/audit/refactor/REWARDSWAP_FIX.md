# HIGH-R1 + HIGH-R2 -- RewardSwapHelper Slippage Cap + KEEPER_ROLE

*Promoted from outputs/R12_RESULT.md -- Wave 1 fix log.*

# HIGH-R1 + HIGH-R2 RESULT — RewardSwapHelper slippage cap + KEEPER_ROLE

## Gate
- PRE: baseline after HIGH-V1 commit `292ac27` → **2189 passed, 0 failed** (outputs/V1_post_test.txt)
- POST: `outputs/R12_post_test.txt` → **2250 passed, 0 failed** (+61 tests)
- Gate: POST ≥ PRE ✓ | POST_FAIL == 0 ✓

## Fixes

### HIGH-R1 — Slippage cap tightened to 5%
`src/strategies/usdc-lending/swap/RewardSwapHelper.sol`

Old: `if (slippageBps > 1000)` — allowed up to 10% slippage in `setRewardConfig()`
New: `if (slippageBps > 500)` — hard cap at 5% (500 bps)

Rationale: RewardSwapHelper already uses Chainlink `latestRoundData()` as oracle anchor.
Allowing 10% slippage on top of oracle-anchored minOut opened a 5% MEV window over
the oracle. Tightening to 500 bps aligns with standard audit expectations for keeper-driven
reward swaps.

### HIGH-R2 — KEEPER_ROLE access control on swapToUSDC()
`src/strategies/usdc-lending/swap/RewardSwapHelper.sol`

- Added: `bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");`
- Changed: `swapToUSDC() external nonReentrant` → `external nonReentrant onlyRole(KEEPER_ROLE)`
- Modifier order: `nonReentrant` fires before `onlyRole` — reentrant calls blocked by lock first.
- Integration: adapters/keepers must be granted KEEPER_ROLE post-deploy via `grantRole(KEEPER_ROLE, adapter)`.

## Source files changed
| File | Change |
|------|--------|
| `src/strategies/usdc-lending/swap/RewardSwapHelper.sol` | KEEPER_ROLE constant + modifier on swapToUSDC(); slippage cap 1000→500 |
| `test/strategies/usdc-lending/swap/RewardSwapHelper.t.sol` | grant KEEPER_ROLE to alice in setUp; fix test_setRewardConfig_acceptsSlippageAtCap (500); 4 new R1+R2 tests |
| `test/strategies/usdc-lending/replay-defense/LendingReplayDefense.t.sol` | grant KEEPER_ROLE to alice in setUp (4 RA tests previously blocked by AccessControl) |

## New tests (RewardSwapHelper.t.sol — RewardSwapHelper_R1R2_Test)
1. `test_setRewardConfig_revertsOnSlippage_501_above_new_cap` — 501 bps reverts
2. `test_setRewardConfig_accepts_exactly_500_bps` — boundary at 500 accepted
3. `test_swapToUSDC_reverts_without_keeper_role` — unauthorized caller blocked
4. `test_swapToUSDC_succeeds_with_keeper_role` — authorized keeper succeeds

## Identity
Author: multyr-infra <multyr-infra@users.noreply.github.com> — no co-author, no trailer
