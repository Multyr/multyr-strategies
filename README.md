# Arbitrum USDC strategy new-20261017

Reconstructed on 2026-10-18 from public Arbiscan verified source. This is a deployment source snapshot, not the original deployment-time commit. Deployment used an uncommitted working tree based on 0b804f294b2fe07565a520aabd5ec4c4b73a1582.

The strategy creation bytecode was reproduced with Solidity 0.8.28+commit.7893614a and matched exactly to the recorded creation transaction, including constructor arguments. See deployment-proof.json.

Reproduce: `solc --standard-json < compiler-input.json > output.json`. Extract contracts[source][UsdcMultiLendingVault].evm.bytecode.object and append constructorArguments from deployment-proof.json to compare with the transaction input. All compiler settings and source content are embedded.

The full-deployment compilation input preserves the original compilation context needed to reproduce the allocation module. All 24 new contracts have separate Arbiscan verification confirmations.
