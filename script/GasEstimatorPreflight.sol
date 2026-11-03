// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReadOnlyGasEstimator as E} from "../src/strategies/usdc-lending/gas/ReadOnlyGasEstimator.sol";

/// @dev Deployment-only checks. The expected hash is keccak256 of config() ABI returndata.
library GasEstimatorPreflight {
    function validate(address estimator, address governance, address eth, address usdc,
        address sequencer, bytes32 configHash) internal view
    {
        validateForSource(estimator, governance, eth, usdc, sequencer, configHash, address(0x6c));
    }

    function validateForSource(address estimator, address governance, address eth, address usdc,
        address sequencer, bytes32 configHash, address feeSource) internal view
    {
        require(estimator.code.length > 0, "GAS_ESTIMATOR_REQUIRED");
        E e = E(estimator);
        require(e.calibrator() == governance && e.pendingCalibrator() == address(0), "GAS_GOVERNANCE");
        require(feeSource != address(0) && address(e.feeInfo()) == feeSource, "GAS_FEE_SOURCE");
        require(e.quoteCurrency() == bytes32("USD6"), "GAS_QUOTE_UNIT");
        require(address(e.ethUSD()) == eth && address(e.usdcUSD()) == usdc
            && address(e.sequencer()) == sequencer, "GAS_FEEDS");
        (bool ok, bytes memory data) = estimator.staticcall(abi.encodeWithSignature("config()"));
        require(ok && configHash != bytes32(0) && keccak256(data) == configHash, "GAS_CONFIG");
        if (feeSource != address(0x6c)) {
            (bool sizeOk, bytes memory sizeData) = feeSource.staticcall(abi.encodeWithSignature("maxCalldataBytes()"));
            require(sizeOk && sizeData.length == 32, "GAS_SOURCE_SIZE_BOUND");
            E.Config memory c = abi.decode(data, (E.Config));
            require(c.calldataBytes <= abi.decode(sizeData, (uint256)), "GAS_SOURCE_SIZE_EXCEEDED");
            (bool chainOk, bytes memory chainData) = feeSource.staticcall(abi.encodeWithSignature("chainId()"));
            require(chainOk && chainData.length == 32 && abi.decode(chainData, (uint256)) == block.chainid, "GAS_SOURCE_CHAIN");
        }
        (bool valid,,) = e.validatedPrices();
        require(valid, "GAS_PRICES_INVALID");
        (uint256 perTx, uint256 perByte,,,, uint256 l2Price) = e.feeInfo().getPricesInWei();
        require(l2Price > 0 && l2Price <= 1000 gwei
            && perByte <= 1e15 && perTx <= 1 ether, "GAS_FEES_INVALID");
    }
}
