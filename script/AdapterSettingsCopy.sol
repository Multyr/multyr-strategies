// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Vm} from "forge-std/Vm.sol";
import {StrategySettingsCopy as Copy} from "./StrategySettingsCopy.sol";

/// @dev Deployment-only. Internal market slots are inspected only when old/new
/// runtime hashes match. Slots/packing are verified by solc storage-layout and fork tests.
library AdapterSettingsCopy {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    function copy(address source, address target, uint256 kind) internal {
        require(source.codehash == target.codehash, "ADAPTER_CODE_CHANGED_REVIEW_LAYOUT");
        string[] memory g;
        if (kind == 0) {
            g = new string[](1);
            g[0] = "maxCap()";
            Copy.copyGroup(source, target, "setMaxCap(uint256)", g, true);
            g = new string[](1);
            g[0] = "incentiveBps()";
            Copy.copyGroup(source, target, "setIncentiveBps(uint16)", g, true);
            g = new string[](1);
            g[0] = "apyOverrideBps()";
            Copy.copyGroup(source, target, "setAPYOverrideBps(uint16)", g, true);
            g = new string[](1);
            g[0] = "maxRateStalenessSec()";
            Copy.copyGroup(source, target, "setMaxRateStalenessSec(uint32)", g, true);
            g = new string[](1);
            g[0] = "incentiveHaircutBps()";
            Copy.copyGroup(source, target, "setIncentiveHaircutBps(uint16)", g, true);
        }
        if (kind == 1) {
            g = new string[](1);
            g[0] = "capacity()";
            Copy.copyGroup(source, target, "setCapacity(uint256)", g, true);
            g = new string[](1);
            g[0] = "incentiveBpsGlobal()";
            Copy.copyGroup(source, target, "setIncentiveBpsGlobal(uint16)", g, true);
            g = new string[](1);
            g[0] = "marketFailureDecaySeconds()";
            Copy.copyGroup(source, target, "setMarketFailureDecaySeconds(uint32)", g, true);
            g = new string[](1);
            g[0] = "apyOverrideBps()";
            Copy.copyGroup(source, target, "setAPYOverrideBps(uint16)", g, true);
            g = new string[](3);
            g[0] = "slippageBpsEstimate()";
            g[1] = "withdrawalSpreadBpsEstimate()";
            g[2] = "gasCostUSDC()";
            Copy.copyGroup(source, target, "setCostsEstimates(uint16,uint16,uint256)", g, true);
            g = new string[](3);
            g[0] = "minSecondsBetweenOptimize()";
            g[1] = "rebalanceMinMoveBps()";
            g[2] = "gateMinNetBenefitBps()";
            Copy.copyGroup(source, target, "setOptimizeParams(uint32,uint16,uint16)", g, true);
        }
        if (kind == 2) {
            g = new string[](1);
            g[0] = "capacity()";
            Copy.copyGroup(source, target, "setCapacity(uint256)", g, true);
            g = new string[](1);
            g[0] = "incentiveBpsGlobal()";
            Copy.copyGroup(source, target, "setIncentiveBps(uint16)", g, true);
            g = new string[](1);
            g[0] = "incentiveHaircutBps()";
            Copy.copyGroup(source, target, "setIncentiveHaircutBps(uint16)", g, true);
            g = new string[](3);
            g[0] = "slippageBpsEstimate()";
            g[1] = "withdrawalSpreadBpsEstimate()";
            g[2] = "gasCostUSDC()";
            Copy.copyGroup(source, target, "setCostsEstimates(uint16,uint16,uint256)", g, true);
            g = new string[](3);
            g[0] = "minSecondsBetweenOptimize()";
            g[1] = "rebalanceMinMoveBps()";
            g[2] = "gateMinNetBenefitBps()";
            Copy.copyGroup(source, target, "setOptimizeParams(uint32,uint16,uint16)", g, true);
        }
        if (kind == 3) {
            g = new string[](1);
            g[0] = "capacity()";
            Copy.copyGroup(source, target, "setCapacity(uint256)", g, true);
            g = new string[](1);
            g[0] = "minMarketCapacity()";
            Copy.copyGroup(source, target, "setMinMarketCapacity(uint256)", g, true);
            g = new string[](3);
            g[0] = "slippageBpsEstimate()";
            g[1] = "withdrawalSpreadBpsEstimate()";
            g[2] = "gasCostUSDC()";
            Copy.copyGroup(source, target, "setCostsEstimates(uint16,uint16,uint256)", g, true);
            g = new string[](3);
            g[0] = "minSecondsBetweenOptimize()";
            g[1] = "subMoveMinBps()";
            g[2] = "subGateMinNetBenefitBps()";
            Copy.copyGroup(source, target, "setOptimizeParams(uint32,uint16,uint16)", g, true);
        }
        if (kind == 4) {
            g = new string[](1);
            g[0] = "capacity()";
            Copy.copyGroup(source, target, "setCapacity(uint256)", g, true);
            g = new string[](5);
            g[0] = "wAPY()";
            g[1] = "wLiq()";
            g[2] = "wRisk()";
            g[3] = "wStability()";
            g[4] = "wIncentive()";
            Copy.copyGroup(source, target, "setWeights(uint16,uint16,uint16,uint16,uint16)", g, true);
            g = new string[](1);
            g[0] = "incentiveBpsGlobal()";
            Copy.copyGroup(source, target, "setIncentiveBps(uint16)", g, true);
            g = new string[](1);
            g[0] = "apyOverrideBps()";
            Copy.copyGroup(source, target, "setAPYOverrideBps(uint16)", g, true);
            g = new string[](1);
            g[0] = "usdcMarketId()";
            Copy.copyGroup(source, target, "setUsdcMarketId(uint256)", g, true);
            g = new string[](1);
            g[0] = "accountNumber()";
            Copy.copyGroup(source, target, "setAccountNumber(uint256)", g, true);
            g = new string[](3);
            g[0] = "slippageBpsEstimate()";
            g[1] = "withdrawalSpreadBpsEstimate()";
            g[2] = "gasCostUSDC()";
            Copy.copyGroup(source, target, "setCostsEstimates(uint16,uint16,uint256)", g, true);
            g = new string[](4);
            g[0] = "minSecondsBetweenOptimize()";
            g[1] = "rebalanceMinMoveBps()";
            g[2] = "gateMinNetBenefitBps()";
            g[3] = "driftToleranceBps()";
            Copy.copyGroup(source, target, "setOptimizeParams(uint32,uint16,uint16,uint16)", g, true);
        }
        if (kind == 5) {
            g = new string[](1);
            g[0] = "capacity()";
            Copy.copyGroup(source, target, "setCapacity(uint256)", g, true);
            g = new string[](1);
            g[0] = "incentiveBps()";
            Copy.copyGroup(source, target, "setIncentiveBps(uint16)", g, true);
            g = new string[](1);
            g[0] = "apyOverrideBps()";
            Copy.copyGroup(source, target, "setAPYOverrideBps(uint16)", g, true);
        }
        if (kind == 6) {
            g = new string[](1);
            g[0] = "capacity()";
            Copy.copyGroup(source, target, "setCapacity(uint256)", g, true);
            g = new string[](1);
            g[0] = "incentiveHaircutBps()";
            Copy.copyGroup(source, target, "setIncentiveHaircutBps(uint16)", g, true);
        }
        // Protocol/reward destinations must match. Nondefault reward routing needs
        // explicit mapping, not accidental trust of a helper bound to the old vault.
        if (kind == 0) { same(source,target,"pool()"); same(source,target,"aToken()"); same(source,target,"rewardsController()"); same(source,target,"swapHelper()"); same(source,target,"rewardTokens()"); }
        if (kind == 2) { same(source,target,"rewardToken()"); same(source,target,"rewardsController()"); same(source,target,"swapHelper()"); }
        if (kind == 5) same(source,target,"fToken()");
        if (kind == 6) { same(source,target,"vToken()"); same(source,target,"blocksPerYear()"); same(source,target,"rewardToken()"); same(source,target,"comptroller()"); same(source,target,"swapHelper()"); }
        if (kind >= 1 && kind <= 4) _markets(source, target, kind);
    }
    function same(address source, address target, string memory getter) internal view {
        (bool a, bytes memory x) = source.staticcall(abi.encodeWithSignature(getter));
        (bool b, bytes memory y) = target.staticcall(abi.encodeWithSignature(getter));
        require(a && b && x.length > 0 && keccak256(x) == keccak256(y), string.concat("ADAPTER_PARITY: ",getter));
    }
    function _write(address target, bytes memory data) private {
        (bool ok, bytes memory reason) = target.call(data);
        if (!ok) assembly { revert(add(reason,32),mload(reason)) }
    }
    function _markets(address source, address target, uint256 kind) private {
        same(source,target,"markets()");
        uint256 slot = kind == 4 ? 11 : 5;
        uint256 count = uint256(vm.load(source, bytes32(slot)));
        require(count == uint256(vm.load(target, bytes32(slot))) && count <= 32, "MARKET_COUNT");
        uint256 base = uint256(keccak256(abi.encode(slot)));
        uint256 shift = kind == 4 ? 168 : 160;
        for (uint256 i; i < count; ++i) {
            uint256 old = uint256(vm.load(source, bytes32(base+i)));
            uint256 next = uint256(vm.load(target, bytes32(base+i)));
            require(address(uint160(old)) == address(uint160(next)), "MARKET_IDENTITY");
            if (kind == 4) require(uint8(old >> 160) == uint8(next >> 160), "MARKET_TYPE");
            bool enabled = uint8(old >> shift) != 0;
            bool flagged = uint8(old >> (shift+8)) != 0;
            uint16 risk = uint16(old >> (shift+16));
            if (kind == 3) _write(target, abi.encodeWithSignature("toggleMarket(uint256,bool,bool)",i,enabled,flagged));
            else {
                _write(target, abi.encodeWithSignature("toggleMarket(uint256,bool)",i,enabled));
                _write(target, abi.encodeWithSignature("flagMarket(uint256,bool)",i,flagged));
            }
            _write(target, abi.encodeWithSignature("setRiskScore(uint256,uint16)",i,risk));
            next = uint256(vm.load(target, bytes32(base+i)));
            // Exclude Dolomite's measured APY history above the configuration bits.
            uint256 mask = (uint256(1) << (shift+32))-1;
            require((old & mask) == (next & mask), "MARKET_CONFIG_PARITY");
        }
    }
}
