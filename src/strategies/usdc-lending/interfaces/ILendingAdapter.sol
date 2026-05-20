// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Lending adapter interface. Asset must be USDC.
interface ILendingAdapter {
    function name() external view returns (string memory);
    function underlying() external view returns (address);
    function totalAssets() external view returns (uint256);
    function withdrawableAssets() external view returns (uint256);
    function deposit(uint256 assets) external;
    function withdraw(uint256 assets, address receiver) external returns (uint256 withdrawn);
    function currentAPYBps() external view returns (uint16);
    function incentiveAPYBps() external view returns (uint16);
    function harvestableProfit() external view returns (uint256);
    function harvest(address receiver) external returns (uint256 realized);
    function maxCapacity() external view returns (uint256);

    /// @notice Returns true if adapter uses PUSH deposit pattern (funds pre-transferred).
    /// @dev PUSH: Strategy transfers USDC to adapter before calling deposit().
    ///      PULL: Adapter calls transferFrom() to pull USDC from strategy.
    ///      Most adapters use PULL. Only Euler uses PUSH.
    function isPushMode() external pure returns (bool);

    // ═══ V7 FIX: idle asset accounting + emergency recovery ═══

    /// @notice Raw underlying balance held locally (NOT invested in protocol).
    /// @dev Push-mode adapters may hold idle balance after failed deposits.
    function idleAssetBalance() external view returns (uint256);

    /// @notice Assets invested in the protocol (shares-based value).
    function investedAssets() external view returns (uint256);

    /// @notice Transfer all idle underlying back to vault (strategy).
    /// @dev Only callable by vault (strategy). Does NOT touch invested assets.
    function sweepIdleAssetToVault() external;

    /// @notice Emergency: withdraw all invested + sweep all idle to vault.
    /// @dev Only callable by vault (strategy). Transfers FULL balance.
    function emergencyPullAllToVault() external;

    // ═══ V9.1: External market TVL for confidence scoring ═══

    /// @notice Total USDC already present in the external vault/market/pool.
    /// @dev Used as a confidence signal for risk scoring and relative exposure cap.
    ///      For multi-market adapters, returns the sum across active markets.
    ///      Reverts are handled by the caller (fallback to lowest confidence band).
    function externalMarketTVL() external view returns (uint256);
}

/// @notice Emergency dispatch interface for strategy → adapter calls.
interface IAdapterEmergency {
    function sweepIdleAssetToVault() external;
    function emergencyPullAllToVault() external;
}
