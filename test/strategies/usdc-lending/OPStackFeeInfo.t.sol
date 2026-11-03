// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OPStackFeeInfo, IOPGasPriceOracle} from "../../../src/strategies/usdc-lending/gas/OPStackFeeInfo.sol";

contract OPStackFeeInfoTest is Test {
    address constant ORACLE = address(0xFEE);
    OPStackFeeInfo source;

    function setUp() public {
        vm.chainId(8453);
        vm.fee(2 gwei);
        vm.etch(ORACLE, hex"00");
        vm.mockCall(ORACLE, abi.encodeCall(IOPGasPriceOracle.getOperatorFee, (0)), abi.encode(uint256(1000)));
        vm.mockCall(ORACLE, abi.encodeCall(IOPGasPriceOracle.getOperatorFee, (1_000_000)), abi.encode(uint256(2_001_000)));
        vm.mockCall(ORACLE, abi.encodeCall(IOPGasPriceOracle.getL1FeeUpperBound, (4352)), abi.encode(uint256(9000)));
        source = new OPStackFeeInfo(IOPGasPriceOracle(ORACLE), 4096, 1 gwei);
    }

    function test_pricesIncludeEnvelopeOperatorAndPriority() public view {
        (uint256 fixedWei, uint256 byteWei,,,, uint256 gasWei) = source.getPricesInWei();
        assertEq(fixedWei, 10000);
        assertEq(byteWei, 1);
        assertEq(gasWei, 3 gwei + 2);
        assertEq(source.maxCalldataBytes(), 4096);
    }

    function test_rejectsAnotherChain() public {
        vm.chainId(42161);
        vm.expectRevert("FEE_CHAIN");
        source.getPricesInWei();
    }

    function test_oracleFailurePropagates() public {
        vm.mockCallRevert(ORACLE, abi.encodeCall(IOPGasPriceOracle.getL1FeeUpperBound, (4352)), bytes("offline"));
        vm.expectRevert(bytes("offline"));
        source.getPricesInWei();
    }

    function test_fractionalOperatorCostRoundsUp() public {
        vm.mockCall(ORACLE, abi.encodeCall(IOPGasPriceOracle.getOperatorFee, (1_000_000)), abi.encode(uint256(1001)));
        (,,,,, uint256 gasWei) = source.getPricesInWei();
        assertEq(gasWei, 3 gwei + 1);
    }
}
