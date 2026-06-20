// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { UsdcLendingChainConfig } from "./UsdcLendingChainConfig.sol";

/// @dev Chain config for Base (chain id 8453). Addresses TBD — fill before deploy.
library UsdcLendingConfigBase {
    // Base: ~2 s blocks → 365.25d × 86400s / 2s = 15,768,000 blocks/year
    uint256 internal constant BLOCKS_PER_YEAR = 15_768_000;

    function get() internal pure returns (UsdcLendingChainConfig memory cfg) {
        // Native USDC (Circle CCTP) on Base
        cfg.usdc          = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

        cfg.aavePool      = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5; // Aave V3 Base
        cfg.aaveAUsdc     = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB; // aUSDC on Base

        cfg.cometUsdcV3   = address(0); // Compound III Base — TBD, verify before deploy

        // Dolomite: not deployed on Base — leave zero
        cfg.dolomiteDUsdc = address(0);

        // Euler V2: TBD on Base
        cfg.eulerVault1   = address(0);
        cfg.eulerVault2   = address(0);
        cfg.eulerVault3   = address(0);
        cfg.eulerVault4   = address(0);

        // Fluid: TBD on Base
        cfg.fluidFUsdc    = address(0);

        // Morpho: TBD on Base
        cfg.morphoVault1  = address(0);
        cfg.morphoVault2  = address(0);
        cfg.morphoVault4  = address(0);
        cfg.morphoVault6  = address(0);
        cfg.morphoVault8  = address(0);

        // Venus: not deployed on Base — disabled (venusBlocksPerYear=0)
        cfg.venusVToken        = address(0);
        cfg.venusBlocksPerYear = 0;
    }
}
