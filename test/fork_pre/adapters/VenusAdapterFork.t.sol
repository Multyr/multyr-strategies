// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ═══════════════════════════════════════════════════════════════════════════
// VenusAdapterFork.t.sol — Phase F1: Venus adapter (DISABLED — Arbitrum)
// ───────────────────────────────────────────────────────────────────────────
// SKIP REASON: Venus Finance (VToken/Comptroller) is BSC-native.
// No Venus USDC market exists on Arbitrum mainnet at block 472761449.
// Adapter deploy date set to 2099-01-01 in config (deliberately disabled).
//
// If Venus deploys to Arbitrum in the future:
//  1. Set VENUS_VUSDC env var to the vUSDC contract address on Arbitrum
//  2. Update ForkTestBase.sol with the canonical address
//  3. Remove the unconditional vm.skip(true) below and write real tests
// ═══════════════════════════════════════════════════════════════════════════

import {ForkTestBase} from "../helpers/ForkTestBase.sol";

contract VenusAdapterFork is ForkTestBase {
    function setUp() public {
        // Venus is not deployed on Arbitrum — skip all tests in this file.
        vm.skip(true);
    }

    function test_F1_Venus_deposit_placeholder() public {
        // Never reached — setUp() skips.
        assertTrue(false, "Venus not on Arbitrum");
    }

    function test_F1_Venus_withdraw_placeholder() public {
        // Never reached — setUp() skips.
        assertTrue(false, "Venus not on Arbitrum");
    }
}
