// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { UsdcLendingChainConfig } from "./UsdcLendingChainConfig.sol";

/// @dev Chain config for Ethereum mainnet (chain id 1). Placeholder — fill before deploy.
library UsdcLendingConfigEthereum {
    // Ethereum L1: ~12 s blocks → 365.25d × 86400s / 12s = 2,628,000 blocks/year
    uint256 internal constant BLOCKS_PER_YEAR = 2_628_000;

    function get() internal pure returns (UsdcLendingChainConfig memory cfg) {
        // USDC on Ethereum mainnet
        cfg.usdc          = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

        cfg.aavePool      = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2; // Aave V3 Mainnet
        cfg.aaveAUsdc     = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c; // aUSDC on Mainnet

        cfg.cometUsdcV3   = 0xc3d688B66703497DAA19211EEdff47f25384cdc3; // Compound III Mainnet

        // Dolomite: not deployed on Ethereum mainnet — leave zero
        cfg.dolomiteDUsdc = address(0);

        // Euler V2: TBD on Ethereum
        cfg.eulerVault1   = address(0);
        cfg.eulerVault2   = address(0);
        cfg.eulerVault3   = address(0);
        cfg.eulerVault4   = address(0);

        // Fluid: TBD on Ethereum
        cfg.fluidFUsdc    = address(0);

        // Morpho: TBD on Ethereum
        cfg.morphoVault1  = address(0);
        cfg.morphoVault2  = address(0);
        cfg.morphoVault4  = address(0);
        cfg.morphoVault6  = address(0);
        cfg.morphoVault8  = address(0);

        // Venus: not on Ethereum — disabled (venusBlocksPerYear=0)
        cfg.venusVToken        = address(0);
        cfg.venusBlocksPerYear = 0;

        cfg.governanceMultisig = address(0); // Ethereum L1 multisig — set before deploy
        cfg.deploySalt = keccak256(abi.encode("UsdcLendingV10", uint256(1))); // chain-id 1
        cfg.permit2    = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    }
}
