// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { UsdcLendingChainConfig } from "./UsdcLendingChainConfig.sol";

/// @dev Chain config for Arbitrum One (chain id 42161). All addresses live + verified.
library UsdcLendingConfigArbitrum {
    // Arbitrum One: ~0.25 s blocks → 365.25d × 86400s / 0.25s = 126,144,000 blocks/year
    uint256 internal constant BLOCKS_PER_YEAR = 126_144_000;

    function get() internal pure returns (UsdcLendingChainConfig memory cfg) {
        cfg.usdc          = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

        cfg.aavePool      = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
        cfg.aaveAUsdc     = 0x724dc807b04555b71ed48a6896b6F41593b8C637;

        cfg.cometUsdcV3   = 0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf;

        cfg.dolomiteDUsdc = 0x444868B6e8079ac2c55eea115250f92C2b2c4D14;

        cfg.eulerVault1   = 0x6aFB8d3F6D4A34e9cB2f217317f4dc8e05Aa673b;
        cfg.eulerVault2   = 0x44C10DA836d2aBe881b77bbB0b3DCE5f85C0C1Cc;
        cfg.eulerVault3   = 0x05d28A86E057364F6ad1a88944297E58Fc6160b3;
        cfg.eulerVault4   = 0x0a1eCC5Fe8C9be3C809844fcBe615B46A869b899;

        cfg.fluidFUsdc    = 0x1A996cb54bb95462040408C06122D45D6Cdb6096;

        cfg.morphoVault1  = 0x7e97fa6893871A2751B5fE961978DCCb2c201E65;
        cfg.morphoVault2  = 0x4B6F1C9E5d470b97181786b26da0d0945A7cf027;
        cfg.morphoVault4  = 0x5c0C306Aaa9F877de636f4d5822cA9F2E81563BA;
        cfg.morphoVault6  = 0x7c574174DA4b2be3f705c6244B4BfA0815a8B3Ed;
        cfg.morphoVault8  = 0x36b69949d60d06ECcC14DE0Ae63f4E00cc2cd8B9;

        cfg.venusVToken        = 0x7D8609f8da70fF9027E9bc5229Af4F6727662707;
        cfg.venusBlocksPerYear = BLOCKS_PER_YEAR;
    }
}
