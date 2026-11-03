# Event units with the preserved original ABI

No existing event or argument name is renamed. Event signatures, indexed fields
and generated consumer bindings remain compatible with the original strategy.

| Event | Field | Unit |
| --- | --- | --- |
| RebalanceGasEvaluated | costUSDC | USD with six decimals, independent of underlying |
| RebalanceEconomicsEvaluated | movedUSDC | Raw underlying asset units |
| RebalanceEconomicsEvaluated | grossBenefitUSDC | Raw underlying asset units |
| RebalanceEconomicsEvaluated | gasCostUSDC | Raw underlying asset units after conversion from USD6 |
| RebalanceEconomicsEvaluated | netBenefitBps | Signed basis points |

The USDC suffix in the economics event's argument names is historical. Consumers
for WETH, WBTC and other instances must resolve the instance's underlying and
decimals. Convert to USD using the corresponding historical oracle observation
when needed; do not divide every economics amount by 1e6 or compare it directly
with the gas event's USD6 cost.

`native-suffix-event-proof.json` independently decodes the actual cold and
remaining-plan events for WETH, USDT0 and WBTC/Dolomite, pairs their gas quotes,
and verifies the round-up conversion against real canonical oracle responses.
The remaining gate executes before every step, including a first/only step.
