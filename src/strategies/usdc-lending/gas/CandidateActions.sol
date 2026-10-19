// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {ReadOnlyGasEstimator as E} from "./ReadOnlyGasEstimator.sol";

/// @dev Shared extraction of current plan module's dust filter, ordering and 10-action cap.
/// The replacement must use THIS SAME array for pricing, gate economics and execution.
library CandidateActions {
    function build(
        address[] memory adapters,
        uint256[] memory current,
        uint256[] memory target,
        uint256[] memory scores,
        uint256 minDelta
    ) internal pure returns (E.Action[] memory actions) {
        uint256 n = adapters.length;
        require(
            n > 0 && n <= 10 && current.length == n && target.length == n && scores.length == n,
            "length"
        );
        actions = new E.Action[](10);
        uint256 count;
        uint256[] memory order = new uint256[](n);
        uint256[] memory weighted = new uint256[](n);
        for (uint256 i; i < n; i++) {
            require(adapters[i] != address(0), "adapter");
            for (uint256 j; j < i; j++) {
                require(adapters[i] != adapters[j], "duplicate");
            }
            if (current[i] > target[i] && current[i] - target[i] >= minDelta) {
                actions[count++] = E.Action(adapters[i], current[i] - target[i], false);
            }
            order[i] = i;
            if (target[i] > current[i]) weighted[i] = (target[i] - current[i]) * scores[i];
        }
        for (uint256 i = 1; i < n; i++) {
            uint256 key = order[i];
            uint256 j = i;
            while (j > 0 && weighted[order[j - 1]] < weighted[key]) {
                order[j] = order[j - 1];
                j--;
            }
            order[j] = key;
        }
        for (uint256 k; k < n && count < 10; k++) {
            uint256 i = order[k];
            if (target[i] > current[i] && target[i] - current[i] >= minDelta) {
                actions[count++] = E.Action(adapters[i], target[i] - current[i], true);
            }
        }
        assembly { mstore(actions, count) }
    }
    /// @notice Keep the canonical priority order while making deposits fundable.
    /// @dev Safety-tranche preservation can make raw target allocations exceed TVL.
    ///      Dust-filtered withdrawals also cannot finance any deposit.
    function funded(E.Action[] memory actions, uint256 cash, uint256 minDelta)
        internal pure returns (E.Action[] memory)
    {
        uint256 count;
        for (uint256 i; i < actions.length; ++i) {
            E.Action memory action = actions[i];
            if (action.deposit) {
                if (action.amount > cash) action.amount = cash;
                if (action.amount == 0 || action.amount < minDelta) continue;
                cash -= action.amount;
            } else {
                cash += action.amount;
            }
            actions[count++] = action;
        }
        assembly ("memory-safe") { mstore(actions, count) }
        return actions;
    }
}
