// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

/// @notice Keeper-fed liquidity rate provider for Aave v3-style adapters.
/// @dev    Uses AccessControl with PARAM_ROLE — same pattern as DolomiteUsdcMultiMarket
///         and other lending adapters. DEFAULT_ADMIN_ROLE = Timelock, PARAM_ROLE = StrategyUpkeep.
///         Matches the IAaveRateProvider expected by the Aave adapter:
///         getLiquidityRateRay(asset) -> liquidityRate in ray (1e27) as APR.
///         FIX P1.L1 (quant audit): added `getLiquidityRateRayWithTs` returning
///         (rate, lastUpdateTs) so the adapter can implement hybrid keeper+staleness
///         pattern with direct on-chain fallback.
contract AaveLiquidityRateProvider is AccessControl {
    bytes32 public constant PARAM_ROLE = keccak256("PARAM_ROLE");

    // asset => liquidityRateRay (APR in ray 1e27)
    mapping(address => uint256) private _rateRay;
    // FIX P1.L1: track last update timestamp per asset for staleness detection.
    mapping(address => uint64) private _lastUpdateTs;

    event LiquidityRateUpdated(address indexed asset, uint256 rateRay);

    /// @param admin DEFAULT_ADMIN_ROLE holder (Timelock) — can grant/revoke PARAM_ROLE
    /// @param keeper Initial PARAM_ROLE holder (StrategyUpkeep) — can write rates
    constructor(address admin, address keeper) {
        require(admin != address(0), "admin=0");
        require(keeper != address(0), "keeper=0");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PARAM_ROLE, keeper);
    }

    /// @notice Set current liquidity rate (APR) in ray (1e27) for an asset.
    /// @dev Only callable by PARAM_ROLE (StrategyUpkeep).
    function setLiquidityRateRay(address asset, uint256 rateRay) external onlyRole(PARAM_ROLE) {
        require(asset != address(0), "asset=0");
        _rateRay[asset] = rateRay;
        _lastUpdateTs[asset] = uint64(block.timestamp);
        emit LiquidityRateUpdated(asset, rateRay);
    }

    /// @notice Returns the current liquidity rate (APR) in ray (1e27) for `asset`.
    function getLiquidityRateRay(address asset) external view returns (uint256) {
        return _rateRay[asset];
    }

    /// @notice FIX P1.L1: returns (rate, lastUpdateTs) for staleness check (hybrid pattern).
    /// @dev    lastUpdateTs is uint64 (block.timestamp). Returns (0, 0) if asset never set.
    function getLiquidityRateRayWithTs(address asset)
        external view returns (uint256 rateRay, uint64 lastUpdateTs)
    {
        return (_rateRay[asset], _lastUpdateTs[asset]);
    }
}
