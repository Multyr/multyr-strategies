// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
interface IMigrationStrategy {
    function totalAssets() external view returns (uint256);
    function adapterCount() external view returns (uint256);
    function adapters(uint256) external view returns (address);
    function rebalancePlanPhase() external view returns (uint8);
}
/// @notice Read-only assertions for an atomic Safe migration batch.
/// @dev Reverts the whole batch if a best-effort recall leaves meaningful assets.
contract StrategyMigrationGuard {
    function assertNoPlan(address strategy) external view {
        require(IMigrationStrategy(strategy).rebalancePlanPhase() == 0, "ACTIVE_REBALANCE_PLAN");
    }
    function assertDrained(address strategy, uint256 maxResidual) external view {
        IMigrationStrategy s = IMigrationStrategy(strategy);
        require(s.totalAssets() <= maxResidual, "STRATEGY_NOT_DRAINED");
        for (uint256 i; i < s.adapterCount(); ++i) {
            require(IMigrationStrategy(s.adapters(i)).totalAssets() <= maxResidual, "ADAPTER_NOT_DRAINED");
        }
    }
}
