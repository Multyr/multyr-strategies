// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFeeInfo} from "./ReadOnlyGasEstimator.sol";

/// @notice Native execution fee source for Ethereum (1), BSC (56), and Polygon PoS (137).
/// @dev L1s carry no extrinsic L2 posting fee; perTx and perByte are always zero.
///      ReadOnlyGasEstimator already applies max(tx.gasprice, l2Price) so execution
///      cost reflects whichever is higher without any synthetic override here.
///      priorityFeeWei is a governance-calibrated floor — calibration required before
///      deployment; measure representative priority fees for the target network.
///      Native USD value (ETH, BNB, or POL) flows through the existing ethUSD feed on E.
///      Other chains require their own reviewed fee model.
contract NativeL1FeeInfo is IFeeInfo {
    uint256 public immutable chainId;
    uint256 public immutable maxCalldataBytes;
    uint256 public immutable priorityFeeWei;

    constructor(uint256 maxBytes, uint256 _priorityFeeWei) {
        uint256 id = block.chainid;
        require(id == 1 || id == 56 || id == 137, "unsupported chain");
        require(maxBytes >= 512 && maxBytes <= 65535, "invalid size");
        // Polygon (137) ceiling is 1000 gwei — compatibility ceiling for observed fee
        // spikes (public eth_feeHistory 90th-pct ~117 gwei), NOT production calibration;
        // measure representative priority fees before each deployment.
        // Ethereum (1) and BSC (56) retain the tighter 100 gwei governance bound.
        uint256 maxPriority = (id == 137) ? 1000 gwei : 100 gwei;
        require(_priorityFeeWei > 0 && _priorityFeeWei <= maxPriority, "invalid priority");
        chainId = id;
        maxCalldataBytes = maxBytes;
        priorityFeeWei = _priorityFeeWei;
    }

    /// @dev Returns (0, 0, 0, 0, 0, block.basefee + priorityFeeWei).
    ///      Reverts if block.chainid differs from the deployment chain to prevent
    ///      cross-chain replay from silently returning a stale or mismatched price.
    function getPricesInWei()
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        require(block.chainid == chainId, "chain mismatch");
        return (0, 0, 0, 0, 0, block.basefee + priorityFeeWei);
    }
}
