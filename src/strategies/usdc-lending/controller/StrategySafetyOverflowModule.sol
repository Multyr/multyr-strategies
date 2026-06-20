// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// =============================================================================
// StrategySafetyOverflowModule -- delegatecall module for safety-overflow routing
// =============================================================================
// Extracted from StrategyScoringModule for EIP-170 compliance (F-SIZE-01).
// All functions operate on the strategy's storage via delegatecall.
// Direct calls are forbidden via the onlyDelegateCall guard.
// =============================================================================

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ILendingAdapter } from "../interfaces/ILendingAdapter.sol";
import {
    StrategyStorageLayout
} from "./StrategyStorageLayout.sol";

contract StrategySafetyOverflowModule is StrategyStorageLayout {

    address private immutable _self;

    bytes4 private constant SAFE_DEPOSIT_SEL = bytes4(keccak256("safeAdapterDeposit(address,uint256)"));

    constructor(address asset_, address _core, address _paramsModule, address _scoringModule, address _adapterOpsModule)
        StrategyStorageLayout(asset_, _core, _paramsModule, _scoringModule, _adapterOpsModule)
    {
        _self = address(this);
    }

    modifier onlyDelegateCall() {
        require(address(this) != _self, "DIRECT_CALL_FORBIDDEN");
        _;
    }

    // ── Safety overflow routing (P0.7) ───────────────────────────────────────

    /// @notice Route excess idle USDC into ordered safety-fallback adapters.
    /// @dev    Best-effort: each deposit goes through safeAdapterDeposit (in AdapterOpsModule).
    ///         Respects fallbackAbsCap and fallbackRelCap per adapter -- never normal abs/rel cap.
    ///         Skips adapters that are disabled, flagged, quarantined, or below extTVL MICRO band.
    function executeSafetyOverflow() external onlyDelegateCall {
        uint16 maxIdleBpsLocal = maxIdleBps;
        if (maxIdleBpsLocal == 0) return;
        uint256 nSafety = safetyFallbackAdapters.length;
        if (nSafety == 0) return;

        uint256 tvl = _tvl();
        if (tvl < 1) return;
        uint256 maxIdleAmt = (tvl * uint256(maxIdleBpsLocal)) / 1e4;
        uint256 idleBalance = ASSET.balanceOf(address(this));
        if (idleBalance <= maxIdleAmt) return;
        uint256 remaining = idleBalance - maxIdleAmt;
        uint256 _dust = dustTolerance;
        uint256 marginBps = uint256(targetSafetyMarginBps);
        uint256 safetyMult = 10_000 - marginBps;

        for (uint256 i = 0; i < nSafety && remaining > _dust;) {
            address a = safetyFallbackAdapters[i];
            unchecked { ++i; }

            if (!enabled[a]) continue;
            if (flagged[a]) continue;
            if (quarantined[a]) continue;

            uint256 extTVL = cachedExternalTVL[a];
            if (extTVL < 500_000e6) continue;

            SafetyFallback memory sf = safetyFallback[a];
            if (sf.absCapBps == 0) continue;
            uint256 fbCeiling = (uint256(sf.absCapBps) * tvl) / 1e4;
            if (sf.relCapBps > 0) {
                uint256 fbRelCeiling = (uint256(sf.relCapBps) * extTVL) / 1e4;
                if (fbRelCeiling < fbCeiling) fbCeiling = fbRelCeiling;
            }

            uint256 fbCeilingNet = (fbCeiling * safetyMult) / 10_000;
            uint256 current = positionAssets[a];
            if (current >= fbCeilingNet) continue;
            uint256 room = fbCeilingNet - current;
            uint256 toDeposit = remaining < room ? remaining : room;
            if (toDeposit < _dust) continue;

            uint256 idleBefore = ASSET.balanceOf(address(this));
            bool ok = _safeAdapterDeposit(a, toDeposit);
            if (!ok) continue;
            uint256 idleAfter = ASSET.balanceOf(address(this));
            uint256 actualDeposited = idleBefore - idleAfter;
            positionAssets[a] = current + actualDeposited;
            remaining -= actualDeposited;
            emit SafetyOverflowDeployed(a, toDeposit, idleBefore, idleAfter);
        }
    }

    /// @notice Emit AdapterSkippedLowConfidence for enabled adapters excluded due to CONFIDENCE_ZERO.
    /// @dev    AllocCalcModule is view-only and cannot emit events; ScoringModule delegates here.
    function emitLowConfidenceSkips(address[] memory selected, uint256 selCount) external onlyDelegateCall {
        address[] memory enabledList = _enabledAdapters();
        for (uint256 i = 0; i < enabledList.length;) {
            address a = enabledList[i];
            bool inPlan = false;
            for (uint256 j = 0; j < selCount;) {
                if (selected[j] == a) { inPlan = true; break; }
                unchecked { ++j; }
            }
            if (!inPlan && _tvlConfidence(a) == CONFIDENCE_ZERO) {
                uint256 extTVL = cachedExternalTVL[a];
                emit AdapterSkippedLowConfidence(a, extTVL, CONFIDENCE_ZERO);
            }
            unchecked { ++i; }
        }
    }

    // ── Private helpers ──────────────────────────────────────────────────────

    function _safeAdapterDeposit(address adapter, uint256 amount) private returns (bool) {
        if (amount == 0) return true;
        (bool ok, bytes memory res) = adapterOpsModule.delegatecall(
            abi.encodeWithSelector(SAFE_DEPOSIT_SEL, adapter, amount)
        );
        if (!ok) return false;
        if (res.length == 0) return ok;
        return abi.decode(res, (bool));
    }

    // ── Degraded-view checks (F-SIZE-02) ─────────────────────────────────────

    /// @notice Emit telemetry + return degraded flag. Called via delegatecall from deposit/harvest.
    function checkAndEmitDegradedViews() external onlyDelegateCall returns (bool degraded, uint16 bps) {
        (degraded, bps) = _checkDegradedAdapterViews();
        if (bps >= 100) emit DegradedViewsObserved(bps);
    }

    function _checkDegradedAdapterViews() private view returns (bool, uint16) {
        uint256 n = adapters.length;
        uint256 healthyAssets;
        uint256 fallbackAssets;
        for (uint256 i = 0; i < n; ++i) {
            address a = adapters[i];
            if (!enabled[a] || quarantined[a]) continue;
            try ILendingAdapter(a).totalAssets() returns (uint256 val) {
                healthyAssets += val;
            } catch {
                fallbackAssets += positionAssets[a];
            }
        }
        uint256 total = healthyAssets + fallbackAssets;
        if (total == 0) return (false, 0);
        uint16 bps = uint16((fallbackAssets * 1e4) / total);
        return (bps > degradedViewThresholdBps, bps);
    }

    /// @notice Inline degraded mode detection. Read-only; called via delegatecall from deposit().
    function checkDegradedModeLocally() external view onlyDelegateCall returns (string memory) {
        address[] memory _enabled = _enabledAdapters();
        uint16 enabledCount = uint16(_enabled.length);
        if (enabledCount == 0) return "";
        uint16 eligibleCount = 0;
        uint16 recentFailures = 0;
        for (uint256 i = 0; i < _enabled.length; ) {
            address a = _enabled[i];
            if (!quarantined[a] && cachedLiquidityBps[a] >= 100) { unchecked { ++eligibleCount; } }
            uint64 lastFail = adapterLastFailureTs[a];
            if (lastFail > 0 && block.timestamp - lastFail < 1 hours) { unchecked { ++recentFailures; } }
            unchecked { ++i; }
        }
        if (eligibleCount * 2 < enabledCount) return "MAJORITY_INELIGIBLE";
        if (recentFailures >= 2) return "FAILURE_VELOCITY";
        for (uint256 i = 0; i < _enabled.length; ) {
            address a = _enabled[i];
            uint256 snapshot = lastExtTVLSnapshot[a];
            uint256 current  = cachedExternalTVL[a];
            if (snapshot > 0 && current < snapshot) {
                uint256 dropBps = ((snapshot - current) * 10_000) / snapshot;
                if (dropBps >= EXT_TVL_PANIC_DROP_BPS) return "EXT_TVL_PANIC";
            }
            unchecked { ++i; }
        }
        return "";
    }
}
