// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
interface IAdapterSwapAssetView { function totalAssets() external view returns(uint256); }
/// @notice Stateless assertions used by an atomic governance adapter-swap batch.
contract AdapterSwapGuard {
    // AdapterFactory atomically invokes this after CREATE2 deployment.
    function initialize() external pure {}
    function assertDrained(address[] calldata adapters, uint256 maxResidual) external view {
        for(uint256 i; i<adapters.length; ++i) {
            require(adapters[i].code.length != 0, "MISSING_ADAPTER");
            require(IAdapterSwapAssetView(adapters[i]).totalAssets() <= maxResidual, "ADAPTER_NOT_DRAINED");
        }
    }
}
