// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {ReadOnlyGasEstimator, IFeeInfo, IFeed} from "./ReadOnlyGasEstimator.sol";

/// @notice Deployment variant with governance assigned directly at construction.
/// @dev No temporary deployer control or pre-deployment Safe acceptance is needed.
contract GovernedReadOnlyGasEstimator is ReadOnlyGasEstimator {
    constructor(IFeeInfo f, IFeed e, IFeed u, IFeed s, Config memory c, address governance)
        ReadOnlyGasEstimator(f, e, u, s, c)
    {
        require(governance != address(0), "governance");
        calibrator = governance;
        emit CalibratorAccepted(governance);
    }
}
