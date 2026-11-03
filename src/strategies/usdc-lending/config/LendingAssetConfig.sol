// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Candidate market identities. Operational support requires the pinned fork gates.
/// @dev Unlisted adapter protocols are disabled, never populated with placeholder addresses.
library LendingAssetConfig {
    struct Market {
        uint256 chainId;
        address asset;
        uint8 decimals;
        address aavePool;
        address aToken;
    }
    error UnsupportedAssetChain(uint256 chainId, bool weth);

    function get(uint256 chainId, bool weth) internal pure returns (Market memory m) {
        m.chainId = chainId;
        m.decimals = weth ? 18 : 6;
        if (chainId == 42161) {
            m.asset = weth ? 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1 : 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
            m.aavePool = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
            m.aToken = weth ? 0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8 : 0x724dc807b04555b71ed48a6896b6F41593b8C637;
        } else if (chainId == 8453) {
            m.asset = weth ? 0x4200000000000000000000000000000000000006 : 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
            m.aavePool = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
            m.aToken = weth ? 0xD4a0e0b9149BCee3C920d2E00b5dE09138fd8bb7 : 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
        } else revert UnsupportedAssetChain(chainId, weth);
    }
}
