# Activate deployed adapter corrections

Use only `01-activate-adapter-fixes.safe.json` from this folder. The earlier adapter deployment JSONs and full-strategy migration JSONs are superseded for this repair. All four adapters and the drain guard are already deployed on Arbitrum One; 35 deployment/setup/handover receipts succeeded.

Safe: `0x70ef444799D6FBbE0865bA598Bee6795e064a326`
Network: Arbitrum One, chain ID 42161.

Import the JSON in Safe Transaction Builder, simulate, then sign and execute all 51 calls together as one atomic batch. Do not split it. No five-minute allowlist wait is required: there is no strategy registration or Router migration.

The batch:
1. Requires no active rebalance plan and temporarily disables upkeep/deposits within the same transaction.
2. Recalls Venus, Morpho, Dolomite and Fluid into the SAME current strategy.
3. Requires each old adapter to hold at most 0.0001 USDC, then synchronizes accounting.
4. Disables the old four adapters and registers/enables the four deployed replacements.
5. Updates the existing upkeep's APY poke targets and preserves the Fluid safety-fallback settings using its new address.
6. Sets Euler's explicit 50M-USDC capacity (matching the other existing adapters) instead of the zero sentinel and applies calibrated per-adapter estimator floors.
7. Refreshes protocol TVL/liquidity data and restores deposits/upkeep.

Any failed call reverts the whole activation. Funds are not sent to the deployer or moved to a new strategy. Aave, Comet and Euler remain in place; user shares, Core and Router remain unchanged. The keeper can subsequently deploy recalled cash under the existing strategy rules.

IMPORTANT: allocation policy is unchanged. The current small-vault one-adapter tier and disabled global exposure cap still permit 100% concentration. This repair fixes adapter rates/capacity and gas calibration, not the requested separate removal of that strategy rule. No 25% limit is introduced.

AWS retains the current strategy `0xa9E676D15976A1332905238ca609Dff9A484Efe0` and upkeep `0xbcaC314E7237b14E11644FC6Ba73675c8c0612DF`, using `/app/config/arbitrum-one.json`. Do not activate `arbitrum-one.next.json`. The on-chain updater permissions are already granted, and the Safe batch switches its APY targets. W5 discovers enabled replacements dynamically. Live ECS/log verification requires AWS credentials; deployment of adapters does not itself change AWS.

Before execution refresh the Safe simulation; stop if the strategy has migrated or an active rebalance plan prevents the first assertion. After execution confirm old adapters disabled/drained, new adapters enabled, seven enabled adapters in total, and the first subsequent keeper deployment receipt. New PPS measurements need an observation window before yielding nonzero annualised rates.

See manifest.json for validation status, deployed-contracts.json for creation transactions, and verification/status.json for explorer verification results. No activation transaction has been executed by this task.

Final rehearsal passed at block 516215599 against the actual deployed addresses. It preserved 20.550044 USDC starting NAV and a subsequent keeper call deployed 20.552697 USDC into adapters (fork-only result). All four runtime bytecodes match the tested artifacts. Explorer verification is recorded separately; Arbiscan API errors do not change the confirmed deployment status.
