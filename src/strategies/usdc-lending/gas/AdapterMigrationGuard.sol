// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
interface IRetiredAdapter {
    function totalAssets() external view returns (uint256);
    function underlying() external view returns (address);
    function vToken() external view returns (address);
}
interface IMigrationBalance { function balanceOf(address) external view returns (uint256); }
/// @notice Atomic Safe assertion for retiring a Venus adapter after best-effort recall.
contract AdapterMigrationGuard {
    /// @dev Allows atomic deployment through the existing AdapterFactory.
    function initialize() external pure {}
    function assertVenusDrained(address adapter) external view {
        IRetiredAdapter a = IRetiredAdapter(adapter);
        require(a.totalAssets() == 0, "ADAPTER_NAV_REMAINS");
        require(IMigrationBalance(a.underlying()).balanceOf(adapter) == 0, "ADAPTER_IDLE_REMAINS");
        require(IMigrationBalance(a.vToken()).balanceOf(adapter) == 0, "VENUS_SHARES_REMAIN");
    }
}
