// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Minimal keeper-fed supply rate provider for Dolomite-like pool markets.
/// @dev    Matches the IDolomiteRateProvider expected by the Dolomite adapter:
///         getSupplyRatePerSecond(market) -> rate per second in WAD (1e18).
contract DolomiteSupplyRateProvider is Ownable {
    // market => supplyRatePerSecond (WAD 1e18)
    mapping(address => uint256) private _ratePerSecWad;

    event SupplyRateUpdated(address indexed market, uint256 ratePerSecWad);

    constructor(address initialOwner) {
        if (initialOwner != address(0) && initialOwner != msg.sender) {
            _transferOwnership(initialOwner);
        }
    }

    /// @notice Keeper/admin sets current supply rate per second in WAD (1e18) for a market.
    function setSupplyRatePerSecond(address market, uint256 ratePerSecWad) external onlyOwner {
        require(market != address(0), "market=0");
        _ratePerSecWad[market] = ratePerSecWad;
        emit SupplyRateUpdated(market, ratePerSecWad);
    }

    /// @notice Returns current supply rate per second in WAD (1e18) for `market`.
    function getSupplyRatePerSecond(address market) external view returns (uint256) {
        return _ratePerSecWad[market];
    }
}
