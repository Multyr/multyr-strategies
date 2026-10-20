# Exact October 17, 2026 active-strategy source snapshot

This is a reconstructed post-deployment provenance commit, not a claim that these contracts were deployed from this Git commit. It materializes all 123 source files from the recorded October 17 compilation input, byte-for-byte, including dependencies. Later October 19 changes are not substituted.

Active strategy: `0xa9E676D15976A1332905238ca609Dff9A484Efe0` on Arbitrum One.

The five previously missing readable modules are Scoring, RebalanceGate, RebalancePlan, SafetyOverflow and AllocCalc. See `module-bytecode-proofs.json` for full deployed addresses, creation transaction hashes, constructor arguments and runtime hashes. All five rebuilt creation bytecodes match their on-chain deployment inputs. Runtime comparisons match after masking the compiler-reported immutable slots; constructor arguments are recorded separately.

Compiler: Solidity 0.8.28+commit.7893614a. Reproduce with:

```
solc --standard-json < module-rebuild-input.json > module-rebuild-output.json
```

`module-rebuild-input.json` preserves the recorded compiler settings, changing only output selection to emit all five modules for verification. `full-deployment-compilation-input.json` is the original recorded input. `source-sha256.json` binds every materialized Solidity file to the recorded source content. `addresses.json`, `deployment-proof.json`, and `verified-contracts.json` retain the original snapshot evidence; the new module proof file is the explicit bytecode check performed on October 20.

This historical branch is not the current development branch and should not be merged as a new strategy implementation.
