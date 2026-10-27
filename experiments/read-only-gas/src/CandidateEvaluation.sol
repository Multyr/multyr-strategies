// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {ReadOnlyGasEstimator as E} from "./ReadOnlyGasEstimator.sol";
import {CandidateActions} from "./CandidateActions.sol";

/// @notice Prototype only. Production must obtain inputs from its own scoring state.
/// Existing caps, health, cooldown, min-move and execution invalidation stay mandatory.
library CandidateEvaluation {
    struct Inputs {
        address[] adapters;
        uint256[] current;
        uint256[] target;
        uint256[] scores;
        uint16[] apys;
        uint256 minDelta;
        uint16 horizonDays;
        uint16 spreadBps;
        uint16 minBenefitBps;
    }

    function evaluate(E estimator, Inputs memory p)
        internal
        view
        returns (E.Action[] memory actions, E.Quote memory quote, int256 benefitUSDC, bool pass)
    {
        require(p.apys.length == p.adapters.length && p.horizonDays > 0, "inputs");
        actions = CandidateActions.build(p.adapters, p.current, p.target, p.scores, p.minDelta);
        if (actions.length == 0) return (actions, quote, 0, false);
        quote = estimator.estimate(actions);
        int256 annualDelta;
        uint256 turnover;
        for (uint256 i; i < actions.length; i++) {
            E.Action memory a = actions[i];
            turnover += a.amount;
            for (uint256 j; j < p.adapters.length; j++) {
                if (p.adapters[j] == a.adapter) {
                    uint256 weighted = a.amount * p.apys[j];
                    require(weighted <= uint256(type(int256).max), "overflow");
                    annualDelta += a.deposit ? int256(weighted) : -int256(weighted);
                }
            }
        }
        // Use filtered actions, not an unexecutable all-adapter target distribution.
        benefitUSDC = annualDelta * int256(uint256(p.horizonDays)) / int256(10000 * 365);
        uint256 costs = quote.costUSDC + turnover * p.spreadBps / 10000;
        require(costs <= uint256(type(int256).max), "overflow");
        benefitUSDC -= int256(costs);
        // Fail closed for economic moves. Safety recalls need their own policy.
        pass = quote.reliable && benefitUSDC > 0 && uint256(benefitUSDC) >= turnover * p.minBenefitBps / 10000;
    }
}
