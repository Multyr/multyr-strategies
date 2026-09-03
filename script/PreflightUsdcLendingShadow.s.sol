// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UsdcLendingShadowPreflight} from "./lib/UsdcLendingShadowPreflight.sol";

/**
 * @title PreflightUsdcLendingShadow
 * @notice Standalone, read-only Shadow pre-deployment check. Runs the exact
 *         same `_preflight` the deploy script runs as its Phase 0, but on its
 *         own so operators can validate a Shadow environment without touching
 *         the deploy flow.
 *
 * Run:
 *   ./script/deploy-usdc-lending-shadow.sh --preflight
 *   # or directly:
 *   DEPLOY_ENV=shadow forge script script/PreflightUsdcLendingShadow.s.sol \
 *     --rpc-url "$SHADOW_RPC_URL" -vvv
 *
 * Never broadcasts. Exits non-zero on the first inconsistency.
 */
contract PreflightUsdcLendingShadow is UsdcLendingShadowPreflight {
    function run() external view {
        _preflight(_loadShadowInputs({checkPredictedAddresses: true}));
    }

    /// @notice Run the preflight against caller-supplied inputs. Used by the
    ///         Shadow lifecycle fork tests to exercise the negative paths.
    function checkInputs(PreflightInputs calldata p) external view {
        _preflight(p);
    }
}
