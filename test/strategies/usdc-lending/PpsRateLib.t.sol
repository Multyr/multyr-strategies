// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import { Test } from "forge-std/Test.sol";
import { PpsRateLib } from "../../../src/strategies/usdc-lending/adapters/lending/PpsRateLib.sol";
contract PpsRateLibTest is Test {
    PpsRateLib.Sample private sample;
    function testRefreshPreservesMeasuredRateAndExpires() public {
        vm.warp(100_000);
        PpsRateLib.update(sample, 1e18);
        vm.warp(block.timestamp + 1 days);
        uint256 pps = 1e18 + 1e14;
        assertEq(PpsRateLib.read(sample, pps), 365);
        PpsRateLib.update(sample, pps);
        assertEq(PpsRateLib.read(sample, pps), 365);
        vm.warp(block.timestamp + 2 days + 1);
        assertEq(PpsRateLib.read(sample, pps), 0);
        PpsRateLib.update(sample, pps);
        assertEq(PpsRateLib.read(sample, pps), 0);
    }
    function testFrequentPokesCannotStarveMeasurement() public {
        vm.warp(100_000);
        PpsRateLib.update(sample, 1e18);
        for (uint256 i=1;i<6;i++) {
            vm.warp(100_000 + i * 600);
            PpsRateLib.update(sample, 1e18 + i * 1e12);
            assertEq(sample.ts, 100_000);
        }
        vm.warp(103_600);
        PpsRateLib.update(sample, 1e18 + 6e12);
        assertGt(sample.rate, 0);
    }
    function testLossInvalidatesRateImmediately() public {
        vm.warp(100_000);
        PpsRateLib.update(sample, 1e18);
        vm.warp(block.timestamp + 1 days);
        PpsRateLib.update(sample, 1e18 + 1e14);
        assertEq(PpsRateLib.read(sample, 1e18), 0);
        PpsRateLib.update(sample, 1e18);
        assertEq(sample.rate, 0);
    }
    function testFlatWindowDoesNotRetainOldYield() public {
        vm.warp(100_000);
        PpsRateLib.update(sample, 1e18);
        vm.warp(block.timestamp + 1 days);
        PpsRateLib.update(sample, 1e18 + 1e14);
        vm.warp(block.timestamp + 1 hours);
        assertEq(PpsRateLib.read(sample, 1e18 + 1e14), 0);
    }
}
