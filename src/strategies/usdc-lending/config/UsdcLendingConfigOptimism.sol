// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { UsdcLendingChainConfig } from "./UsdcLendingChainConfig.sol";

/// @dev Chain config for Optimism (chain id 10). Addresses TBD — fill before deploy.
library UsdcLendingConfigOptimism {
    // Optimism: ~2 s blocks → 365.25d × 86400s / 2s = 15,768,000 blocks/year
    uint256 internal constant BLOCKS_PER_YEAR = 15_768_000;

    function get() internal pure returns (UsdcLendingChainConfig memory cfg) {
        // Native USDC (Circle CCTP) on Optimism
        cfg.usdc          = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

        cfg.aavePool      = 0x794a61358D6845594F94dc1DB02A252b5b4814aD; // same proxy on OP
        cfg.aaveAUsdc     = address(0); // aUSDC on OP — TBD, verify before deploy

        cfg.cometUsdcV3   = 0x2e44e174f7D53F0212823acC11C01A11d58c5bCB; // Compound III OP

        // Dolomite: not deployed on Optimism — leave zero
        cfg.dolomiteDUsdc = address(0);

        // Euler V2: may not be on Optimism — leave zero until confirmed
        cfg.eulerVault1   = address(0);
        cfg.eulerVault2   = address(0);
        cfg.eulerVault3   = address(0);
        cfg.eulerVault4   = address(0);

        // Fluid: TBD on Optimism
        cfg.fluidFUsdc    = address(0);

        // Morpho: TBD on Optimism
        cfg.morphoVault1  = address(0);
        cfg.morphoVault2  = address(0);
        cfg.morphoVault4  = address(0);
        cfg.morphoVault6  = address(0);
        cfg.morphoVault8  = address(0);

        // Venus: not deployed on Optimism — disabled (venusBlocksPerYear=0)
        cfg.venusVToken        = address(0);
        cfg.venusBlocksPerYear = 0;
    }
}
