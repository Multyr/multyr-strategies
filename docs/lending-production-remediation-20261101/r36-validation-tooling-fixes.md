# Final validation tooling corrections

- Linux endpoint reuse now distinguishes TIME_WAIT from a live listener. A live foreign listener remains untouched; an owned child is force-killed and reaped before its handle is cleared. Three Linux real-socket/process tests and three native Linux Anvil fork restarts pass. The independent proposal's swallowed second timeout was rejected.
- Native USDT0/Aave qualification uses the real Arbitrum USDT0 contract and its own Aave receipt token. Holder funds, token supply, Core credit, genuine Nitro fees, ordinary withdrawal EMA and full recall are checked without financial-state mocks. Default USDC seven-family behavior is preserved and separately revalidated.
- Independent review found the checkpoint projection guard still inspected the USDC aToken. The corrected guard selects the active profile's aToken. A real local-fork Aave supply of 1,000,000 USDT0 base units to an owned fixture contract reproduced the omission: the old receipt check accepted it; the corrected check rejects it. See `r35-receipt-guard.json`.

Receipt-guard reproduction: restore the source-derived, unfunded `usdt0-aave` checkpoint on an owned local Arbitrum fork at its canonical sample block; impersonate the recorded genuine holder, approve zero and then 1,000,000 units to the actual Aave pool, and call `supply(USDT0, 1000000, coreFixture, 0)`. Assert the fixture underlying balance is zero and its actual USDT0 aToken balance is positive. `owned_accounts()` must reject with `Owned contract has receipt-token balance`. The public endpoint is read-only; all transaction writes target the owned local fork.

These checks qualify only the listed token/chain/market rows. Core, main and shadow remain frozen; deployment authorization is separate from code qualification.
