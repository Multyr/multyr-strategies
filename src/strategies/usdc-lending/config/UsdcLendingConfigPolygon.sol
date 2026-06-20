// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { UsdcLendingChainConfig } from "./UsdcLendingChainConfig.sol";

/// @dev Chain config for Polygon PoS (chain id 137). Placeholder — fill before deploy.
library UsdcLendingConfigPolygon {
    // Polygon PoS: ~2.12 s avg blocks → 365.25d × 86400s / 2.12s ≈ 14,891,802 blocks/year
    uint256 internal constant BLOCKS_PER_YEAR = 14_891_802;

    function get() internal pure returns (UsdcLendingChainConfig memory cfg) {
        // Native USDC (Circle CCTP) on Polygon
        cfg.usdc          = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;

        cfg.aavePool      = 0x794a61358D6845594F94dc1DB02A252b5b4814aD; // Aave V3 Polygon
        cfg.aaveAUsdc     = 0xA4D94019934D8333Ef880ABFFbF2FDd611C762BD; // aUSDC on Polygon

        cfg.cometUsdcV3   = 0xF25212E676D1F7F89Cd72fFEe66158f541246445; // Compound III Polygon

        // Dolomite: not deployed on Polygon — leave zero
        cfg.dolomiteDUsdc = address(0);

        // Euler V2: TBD on Polygon
        cfg.eulerVault1   = address(0);
        cfg.eulerVault2   = address(0);
        cfg.eulerVault3   = address(0);
        cfg.eulerVault4   = address(0);

        // Fluid: TBD on Polygon
        cfg.fluidFUsdc    = address(0);

        // Morpho: TBD on Polygon
        cfg.morphoVault1  = address(0);
        cfg.morphoVault2  = address(0);
        cfg.morphoVault4  = address(0);
        cfg.morphoVault6  = address(0);
        cfg.morphoVault8  = address(0);

        // Venus: not on Polygon PoS — disabled (venusBlocksPerYear=0)
        cfg.venusVToken        = address(0);
        cfg.venusBlocksPerYear = 0;

        cfg.governanceMultisig = address(0); // Polygon PoS multisig — set before deploy
        cfg.deploySalt = keccak256(abi.encode("UsdcLendingV10", uint256(137))); // chain-id 137
        cfg.permit2    = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    }
}
