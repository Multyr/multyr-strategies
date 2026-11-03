// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IFeeInfo} from "./ReadOnlyGasEstimator.sol";

interface IOPGasPriceOracle {
    function getL1FeeUpperBound(uint256 unsignedTxSize) external view returns (uint256);
    function getOperatorFee(uint256 gasUsed) external view returns (uint256);
}

/// @notice OP Stack fee source for the lending estimator. Each transaction is priced
///         using the oracle's size-based L1 model for the entire reviewed byte bound.
/// @dev This is an estimate, not a guarantee: OP's upper-bound API documents 99.99% coverage.
contract OPStackFeeInfo is IFeeInfo {
    IOPGasPriceOracle public immutable oracle;
    uint256 public immutable chainId;
    uint256 public immutable maxCalldataBytes;
    uint256 public immutable priorityFeeWei;

    constructor(IOPGasPriceOracle oracle_, uint256 maxBytes_, uint256 priorityFeeWei_) {
        require(address(oracle_).code.length > 0, "ORACLE_CODE");
        require(maxBytes_ >= 512 && maxBytes_ <= 65535, "TX_SIZE_BOUND");
        require(priorityFeeWei_ > 0 && priorityFeeWei_ <= 100 gwei, "PRIORITY_BOUND");
        oracle = oracle_;
        chainId = block.chainid;
        maxCalldataBytes = maxBytes_;
        priorityFeeWei = priorityFeeWei_;
    }

    function getPricesInWei() external view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        require(block.chainid == chainId, "FEE_CHAIN");
        uint256 constantFee = oracle.getOperatorFee(0);
        uint256 sampledFee = oracle.getOperatorFee(1_000_000);
        require(sampledFee >= constantFee, "OPERATOR_FEE");
        uint256 operatorPerGas = Math.ceilDiv(sampledFee - constantFee, 1_000_000);
        // Include RLP envelope overhead beyond the configured wrapper calldata length.
        uint256 poster = oracle.getL1FeeUpperBound(maxCalldataBytes + 256) + constantFee;
        // A one-wei per-byte term retains the estimator ABI and only increases the quote.
        return (poster, 1, 0, 0, 0, block.basefee + priorityFeeWei + operatorPerGas);
    }
}
