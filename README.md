# Arbitrum USDC strategy old-20261009

Reconstructed on 2026-10-18 from public Arbiscan verified source. This is a deployment source snapshot, not the original deployment-time commit. Deployment used an uncommitted working tree based on 467c0efee1c43039c23203ef58b20a5c5d36ed36.

The strategy creation bytecode was reproduced with Solidity 0.8.28+commit.7893614a and matched exactly to the recorded creation transaction, including constructor arguments. See deployment-proof.json.

Reproduce: `solc --standard-json < compiler-input.json > output.json`. Extract contracts[source][UsdcMultiLendingVault].evm.bytecode.object and append constructorArguments from deployment-proof.json to compare with the transaction input. All compiler settings and source content are embedded.
