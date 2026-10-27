// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {GovernedReadOnlyGasEstimator} from "../src/strategies/usdc-lending/gas/GovernedReadOnlyGasEstimator.sol";
import {Script} from "forge-std/Script.sol";
import {
    ReadOnlyGasEstimator as E,
    IFeeInfo,
    IFeed
} from "../src/strategies/usdc-lending/gas/ReadOnlyGasEstimator.sol";

/// @notice Explicit calibration inputs; no assumed production defaults. Review before broadcast.
contract DeployReadOnlyGasEstimator is Script {
    function bounded32(string memory key) internal view returns (uint32) {
        uint256 n = vm.envUint(key);
        require(n <= type(uint32).max, "uint32");
        return uint32(n);
    }

    function bounded16(string memory key) internal view returns (uint16) {
        uint256 n = vm.envUint(key);
        require(n <= type(uint16).max, "uint16");
        return uint16(n);
    }

    function run() external returns (E estimator) {
        require(block.chainid == 42161, "ARBITRUM_ONLY");
        E.Config memory c = E.Config({
            prepareGas: bounded32("GAS_PREPARE"),
            stepGas: bounded32("GAS_STEP"),
            finalizeGas: bounded32("GAS_FINALIZE"),
            defaultDepositGas: bounded32("GAS_DEPOSIT_FLOOR"),
            defaultWithdrawGas: bounded32("GAS_WITHDRAW_FLOOR"),
            intrinsicGas: bounded32("GAS_INTRINSIC"),
            calldataBytes: bounded16("GAS_CALLDATA_BYTES"),
            marginBps: bounded16("GAS_MARGIN_BPS"),
            maxPriceAge: bounded32("GAS_ETH_MAX_AGE"),
            usdcMaxPriceAge: bounded32("GAS_USDC_MAX_AGE"),
            sequencerGrace: bounded32("GAS_SEQUENCER_GRACE"),
            fallbackUSDC: vm.envUint("GAS_FALLBACK_USDC")
        });
        address eth = vm.envAddress("GAS_ETH_USD_FEED");
        address usdc = vm.envAddress("GAS_USDC_USD_FEED");
        address sequencer = vm.envAddress("GAS_SEQUENCER_FEED");
        address governance = vm.envAddress("GAS_GOVERNANCE");
        require(governance != address(0), "governance");
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        estimator = new GovernedReadOnlyGasEstimator(IFeeInfo(address(0x6c)), IFeed(eth), IFeed(usdc), IFeed(sequencer), c, governance);
        vm.stopBroadcast();
        require(estimator.calibrator() == governance && estimator.pendingCalibrator() == address(0), "handoff");
    }
}
