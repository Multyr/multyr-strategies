// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UsdcMultiLendingVault as Strategy} from "../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";

/// @notice Deployment-only copier. Uses existing public setters, never storage writes.
/// @dev Called before handoff, with deployer ADMIN/PARAM/temporary KEEPER roles.
/// A missing getter, rejected value, adapter-order mismatch or parity failure aborts simulation.
/// Positions, caches, measurements, timestamps and pending plans are deliberately not imported.
library StrategySettingsCopy {
    error ReadFailed(address target, string getter);
    error WriteFailed(string setter, bytes reason);
    error ParityFailed(string getter);

    function read(address target, string memory getter) internal view returns (bytes memory data) {
        bool ok;
        (ok, data) = target.staticcall(abi.encodeWithSignature(getter));
        if (!ok || data.length != 32) revert ReadFailed(target, getter);
    }

    function initParams(address source) internal view returns (Strategy.StrategyInitParams memory p) {
        Strategy old = Strategy(payable(source));
        p.maxAdaptersPerAllocation = old.maxAdaptersPerAllocation();
        p.minAdaptersActive = old.minAdaptersActive();
        p.rebalanceMinMoveBps = old.rebalanceMinMoveBps();
        p.minSecondsBetweenRebalances = old.minSecondsBetweenRebalances();
        p.driftToleranceBps = old.driftToleranceBps();
        p.wAPY = old.wAPY();
        p.wLiq = old.wLiq();
        p.wRisk = old.wRisk();
        p.wStability = old.wStability();
        p.wIncentive = old.wIncentive();
        p.incentiveDecayHalfLife = old.incentiveDecayHalfLife();
        p.adapterMaxExposureBps = old.adapterMaxExposureBps();
        p.newAdapterRampBps = old.newAdapterRampBps();
        p.gateHorizonDays = old.gateHorizonDays();
        p.gateMinNetBenefitBps = old.gateMinNetBenefitBps();
        p.slippageBpsEstimate = old.slippageBpsEstimate();
        p.withdrawalSpreadBpsEstimate = old.withdrawalSpreadBpsEstimate();
        p.gasCostUSDC = old.gasCostUSDC();
        p.harvestThresholdBps = old.harvestThresholdBps();
        p.minSecondsBetweenHarvests = old.minSecondsBetweenHarvests();
        p.dustTolerance = old.dustTolerance();
        p.stabilityEMAPeriod = old.stabilityEMAPeriod();
        p.minNewAdapterSeed = old.minNewAdapterSeed();
        p.newAdapterRampDuration = old.newAdapterRampDuration();
        p.maxIdleAfterDepositBps = old.maxIdleAfterDepositBps();
        p.maxIdleBootstrapBps = old.maxIdleBootstrapBps();
        p.degradedViewThresholdBps = old.degradedViewThresholdBps();
        p.failureDecaySeconds = old.failureDecaySeconds();
        p.minSecondsBetweenDeployIdle = old.minSecondsBetweenDeployIdle();
        p.maxRelativeExposureBps = old.maxRelativeExposureBps();
        p.externalTVLStalenessSeconds = old.externalTVLStalenessSeconds();
        uint64 end = old.bootstrapEndsAt();
        // Preserve remaining bootstrap relief, never restart an expired bootstrap period.
        p.bootstrapDuration = end > block.timestamp ? end - uint64(block.timestamp) : 0;
    }

    function copyGroup(address source, address target, string memory setter, string[] memory getters, bool writeSettings)
        internal returns (bytes32 digest)
    {
        bytes memory args;
        bytes memory current;
        for (uint256 i; i < getters.length; ++i) {
            args = bytes.concat(args, read(source, getters[i]));
            if (target != address(0)) current = bytes.concat(current, read(target, getters[i]));
        }
        digest = keccak256(abi.encode(setter, args));
        if (target == address(0) || keccak256(args) == keccak256(current)) return digest;
        if (!writeSettings) revert ParityFailed(setter);
        (bool ok, bytes memory reason) = target.call(bytes.concat(bytes4(keccak256(bytes(setter))), args));
        if (!ok) revert WriteFailed(setter, reason);
        for (uint256 i; i < getters.length; ++i) {
            if (keccak256(read(source, getters[i])) != keccak256(read(target, getters[i]))) {
                revert ParityFailed(getters[i]);
            }
        }
    }

    function globals(address source, address target, bool writeSettings) internal returns (bytes32 digest) {
        string[] memory g;
        g = new string[](1);
        g[0] = "withdrawalLockSeconds()";
        digest = keccak256(abi.encode(digest, copyGroup(source, target, "setWithdrawalLockSeconds(uint64)", g, writeSettings)));
        g = new string[](1);
        g[0] = "adapterQuarantineThreshold()";
        digest = keccak256(abi.encode(digest, copyGroup(source, target, "setQuarantineThreshold(uint8)", g, writeSettings)));
        g = new string[](1);
        g[0] = "minSecondsBetweenSync()";
        digest = keccak256(abi.encode(digest, copyGroup(source, target, "setSyncInterval(uint32)", g, writeSettings)));
        g = new string[](1);
        g[0] = "liquidityStalenessSeconds()";
        digest = keccak256(abi.encode(digest, copyGroup(source, target, "setLiquidityStalenessSeconds(uint32)", g, writeSettings)));
        g = new string[](1);
        g[0] = "maxRebalanceActionsPerTx()";
        digest = keccak256(abi.encode(digest, copyGroup(source, target, "setMaxRebalanceActionsPerTx(uint8)", g, writeSettings)));
        g = new string[](1);
        g[0] = "rebalancePlanMaxAge()";
        digest = keccak256(abi.encode(digest, copyGroup(source, target, "setRebalancePlanMaxAge(uint32)", g, writeSettings)));
        g = new string[](1);
        g[0] = "rebalancePlanMinDrift()";
        digest = keccak256(abi.encode(digest, copyGroup(source, target, "setRebalancePlanMinDrift(uint256)", g, writeSettings)));
        g = new string[](3);
        g[0] = "apyFloorBps()";
        g[1] = "minStabilityUpdateInterval()";
        g[2] = "stabilityEMAPeriod()";
        digest = keccak256(abi.encode(digest, copyGroup(source, target, "setStabilityParams(uint16,uint32,uint16)", g, writeSettings)));
        g = new string[](1);
        g[0] = "gasEmaSmoothingBps()";
        digest = keccak256(abi.encode(digest, copyGroup(source, target, "setGasEmaParams(uint16)", g, writeSettings)));
        g = new string[](4);
        g[0] = "minBenefitCostRatioBps()";
        g[1] = "entryDriftBps()";
        g[2] = "exitDriftBps()";
        g[3] = "minMoveUsd()";
        digest = keccak256(abi.encode(digest, copyGroup(source, target, "setHysteresisParams(uint16,uint16,uint16,uint256)", g, writeSettings)));
        g = new string[](3);
        g[0] = "recentRebalancePenaltyBps()";
        g[1] = "recentRebalanceWindowSeconds()";
        g[2] = "minLiquidityReadinessBps()";
        digest = keccak256(abi.encode(digest, copyGroup(source, target, "setCoordinationParams(uint16,uint32,uint16)", g, writeSettings)));
        g = new string[](1);
        g[0] = "currentRegime()";
        digest = keccak256(abi.encode(digest, copyGroup(source, target, "setRegime(uint8)", g, writeSettings)));
        g = new string[](5);
        g[0] = "currentRegime()";
        g[1] = "regimeHysteresisMultBps()";
        g[2] = "regimeBudgetMultBps()";
        g[3] = "regimeHorizonDays()";
        g[4] = "regimeConfidenceMultBps()";
        digest = keccak256(abi.encode(digest, copyGroup(source, target, "setRegimeParams(uint8,uint16,uint16,uint16,uint16)", g, writeSettings)));
        g = new string[](1);
        g[0] = "overCapRiskPremiumBps()";
        digest = keccak256(abi.encode(digest, copyGroup(source, target, "setOverCapRiskPremium(uint16)", g, writeSettings)));
        g = new string[](2);
        g[0] = "stabilityEMAStalenessSeconds()";
        g[1] = "riskScoreStalenessSeconds()";
        digest = keccak256(abi.encode(digest, copyGroup(source, target, "setScoringStalenessParams(uint32,uint32)", g, writeSettings)));
        g = new string[](1);
        g[0] = "rebalancePlanBackoffThreshold()";
        digest = keccak256(abi.encode(digest, copyGroup(source, target, "setRebalancePlanBackoffThreshold(uint8)", g, writeSettings)));
        g = new string[](1);
        g[0] = "capDriftToleranceBps()";
        digest = keccak256(abi.encode(digest, copyGroup(source, target, "setCapDriftTolerance(uint16)", g, writeSettings)));
        g = new string[](1);
        g[0] = "maxIdleBps()";
        digest = keccak256(abi.encode(digest, copyGroup(source, target, "setMaxIdleBps(uint16)", g, writeSettings)));
        g = new string[](1);
        g[0] = "targetSafetyMarginBps()";
        digest = keccak256(abi.encode(digest, copyGroup(source, target, "setTargetSafetyMargin(uint16)", g, writeSettings)));
        g = new string[](1);
        g[0] = "mandateRedeployCooldownSeconds()";
        digest = keccak256(abi.encode(digest, copyGroup(source, target, "setMandateRedeployCooldown(uint32)", g, writeSettings)));
        g = new string[](1);
        g[0] = "depositsDisabled()";
        digest = keccak256(abi.encode(digest, copyGroup(source, target, "setDepositsDisabled(bool)", g, writeSettings)));
    }

    function copyAdapters(address source, address target) internal {
        Strategy old = Strategy(payable(source));
        Strategy next = Strategy(payable(target));
        uint256 count = old.adapterCount();
        require(count == next.adapterCount(), "ADAPTER_COUNT_CHANGED");
        require(uint256(bytes32(read(target, "safetyFallbackAdaptersLength()"))) == 0, "TARGET_FALLBACKS_NOT_EMPTY");
        for (uint256 i; i < count; ++i) {
            address a = old.adapters(i);
            address b = next.adapters(i);
            (bool okA, bytes memory nameA) = a.staticcall(abi.encodeWithSignature("name()"));
            (bool okB, bytes memory nameB) = b.staticcall(abi.encodeWithSignature("name()"));
            require(okA && okB && nameA.length > 0 && keccak256(nameA) == keccak256(nameB), "ADAPTER_ORDER_OR_TYPE_CHANGED");
            require(old.depositModeKnown(a) == next.depositModeKnown(b), "DEPOSIT_MODE_UNKNOWN");
            _write(target, "setAdapterDepositMode(address,bool)", abi.encode(b, old.pushDepositMode(a)));
            _write(target, "setAdapterAbsCapOverride(address,uint16)", abi.encode(b, old.adapterAbsCapOverrideBps(a)));
            // Do not silently refresh a timestamped risk assessment during migration.
            require(old.riskScoreStalenessSeconds() == 0, "RISK_REATTESTATION_REQUIRED");
            _write(target, "setRiskScore(address,uint16)", abi.encode(b, old.riskScoreBps(a)));
        }
        uint256 fallbackCount = uint256(bytes32(read(source, "safetyFallbackAdaptersLength()")));
        for (uint256 i; i < fallbackCount; ++i) {
            address a = old.safetyFallbackAdapters(i);
            address b;
            for (uint256 j; j < count; ++j) if (old.adapters(j) == a) b = next.adapters(j);
            require(b != address(0), "UNMAPPED_SAFETY_ADAPTER");
            (uint16 absCap, uint16 relCap) = old.safetyFallback(a);
            _write(target, "addSafetyFallbackAdapter(address,uint16,uint16)", abi.encode(b, absCap, relCap));
        }
        // Restore disabling/quarantine AFTER adding safety fallbacks (whose setter requires enabled).
        for (uint256 i; i < count; ++i) {
            address a = old.adapters(i);
            address b = next.adapters(i);
            next.toggleAdapter(b, old.enabled(a));
            _write(target, "setFlaggedAdapter(address,bool)", abi.encode(b, old.flagged(a)));
            _write(target, "setQuarantined(address,bool)", abi.encode(b, old.quarantined(a)));
            _write(target, "whitelistAdapter(address,bool)", abi.encode(b, old.whitelistedAdapters(a)));
        }
        verifyAdapters(source, target);
    }

    function verifyAdapters(address source, address target) internal view {
        Strategy old = Strategy(payable(source));
        Strategy next = Strategy(payable(target));
        require(old.adapterCount() == next.adapterCount(), "ADAPTER_COUNT_CHANGED");
        for (uint256 i; i < old.adapterCount(); ++i) {
            address a = old.adapters(i);
            address b = next.adapters(i);
            require(old.enabled(a) == next.enabled(b) && old.flagged(a) == next.flagged(b)
                && old.quarantined(a) == next.quarantined(b)
                && old.whitelistedAdapters(a) == next.whitelistedAdapters(b)
                && old.depositModeKnown(a) == next.depositModeKnown(b)
                && old.pushDepositMode(a) == next.pushDepositMode(b)
                && old.adapterAbsCapOverrideBps(a) == next.adapterAbsCapOverrideBps(b)
                && old.riskScoreBps(a) == next.riskScoreBps(b), "ADAPTER_SETTINGS_MISMATCH");
            (uint16 absA, uint16 relA) = old.safetyFallback(a);
            (uint16 absB, uint16 relB) = next.safetyFallback(b);
            require(absA == absB && relA == relB, "SAFETY_CAP_MISMATCH");
        }
        require(uint256(bytes32(read(source, "safetyFallbackAdaptersLength()"))) == uint256(bytes32(read(target, "safetyFallbackAdaptersLength()"))), "SAFETY_COUNT_MISMATCH");
        for (uint256 i; i < uint256(bytes32(read(source, "safetyFallbackAdaptersLength()"))); ++i) {
            for (uint256 j; j < old.adapterCount(); ++j) {
                if (old.adapters(j) == old.safetyFallbackAdapters(i)) {
                    require(next.adapters(j) == next.safetyFallbackAdapters(i), "SAFETY_ORDER_MISMATCH");
                }
            }
        }
    }

    function verifyInit(address source, address target) internal view {
        Strategy.StrategyInitParams memory a = initParams(source);
        Strategy.StrategyInitParams memory b = initParams(target);
        require(keccak256(abi.encode(a)) == keccak256(abi.encode(b)), "INIT_SETTINGS_MISMATCH");
    }

    function _write(address target, string memory setter, bytes memory args) private {
        (bool ok, bytes memory reason) = target.call(bytes.concat(bytes4(keccak256(bytes(setter))), args));
        if (!ok) revert WriteFailed(setter, reason);
    }
}
