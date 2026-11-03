// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LendingEthereumAdditionalUnmockedE2EBase} from "./LendingEthereumAdditionalUnmockedE2E.t.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    ReadOnlyGasEstimator as GasEstimator,
    IFeeInfo,
    IFeed,
    IMeasurements
} from "@multyr-strategies/strategies/usdc-lending/gas/ReadOnlyGasEstimator.sol";
import {StrategySettingsModule as Settings} from "@multyr-strategies/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {StrategyScoringModule as Scoring} from "@multyr-strategies/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import {StrategyRebalanceGateModule as Gate} from "@multyr-strategies/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol";
import {StrategyRebalancePlanModule as Plan} from "@multyr-strategies/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol";
import {StrategyUpkeep} from "@multyr-strategies/strategies/usdc-lending/automation/LendingStrategyUpkeep.sol";

interface INativeAdapterAssets { function totalAssets() external view returns (uint256); function withdrawableAssets() external view returns(uint256); }

/// @notice Abstract base that adds a snapshot-isolated native L1 gas gate branch.
/// Derives shared fields (_new, strategy, market, oracle, rpcForkBlock, vm) from
/// LendingEthereumAdditionalUnmockedE2EBase. Existing ActualMultiAdapterScoringTest
/// switches to derive this base; all prior assertions are unaffected.
abstract contract ActualNativeGasGateReferenceBase is LendingEthereumAdditionalUnmockedE2EBase {
    using SafeERC20 for IERC20Metadata;

    struct NativeGateObs {
        uint256 prepareKeeperGas;
        uint256 maxStepKeeperGas;
        bool economicCancelled;
        uint256 surplusTransferred;
        uint256 moved;
        uint256 gross;
        uint256 costUSD6;
        uint256 costAsset;
        int256  netBps;
        bool    accepted;
        uint256 steps;
        bool    reliable;
        uint256 qCostUSD6;
        uint256 qTxCount;
        bool    qUsedDefaults;
    }

    // gasleft deltas include the real keeper wrapper but are not receipt gas.
    event ActualNativeKeeperObservation(address asset,uint256 rpcBlock,uint256 prepareGas,uint256 maxStepGas,uint256 calldataBytes);

    event ActualNativeGateObservation(
        address indexed asset,
        uint256 rpcBlock,
        uint256 moved,
        uint256 grossBenefit,
        uint256 costUSD6,
        uint256 costAsset,
        int256  netBenefitBps,
        bool    accepted,
        uint256 executedSteps,
        bool    quotedReliable,
        uint256 quotedCostUSD6,
        uint256 quotedTxCount,
        bool    quotedUsedDefaults,
        uint256 surplusTransferred,
        bool economicCancelled
    );

    // ── Snapshot wrapper called by exerciseActualYieldEconomics ──────────────

    function _assertActualNativeGateBranch() internal {
        for(uint256 variant;variant<2;++variant) {
            uint256 snap=vm.snapshotState();
            NativeGateObs memory obs=this.checkActualNativeGateBranch(variant==1);
            assertTrue(vm.revertToState(snap),"native branch must restore exact prior state");
            emit ActualNativeKeeperObservation(market.asset,rpcForkBlock,obs.prepareKeeperGas,obs.maxStepKeeperGas,132);
            emit ActualNativeGateObservation(market.asset,rpcForkBlock,obs.moved,obs.gross,obs.costUSD6,obs.costAsset,obs.netBps,obs.accepted,obs.steps,obs.reliable,obs.qCostUSD6,obs.qTxCount,obs.qUsedDefaults,obs.surplusTransferred,obs.economicCancelled);
        }
    }

    // ── External self-check — all state changes isolated inside snapshot ──────

    function checkActualNativeGateBranch(bool includeActualSurplus) external returns (NativeGateObs memory obs) {
        require(msg.sender == address(this), "self-only");

        assertEq(block.chainid, 1, "actual Ethereum native profile");
        assertEq(rpcForkBlock,26173000);
        // Independent public eth_feeHistory at this canonical block records this basefee.
        assertEq(block.basefee,58_155_032,"native basefee must match the real pinned header");
        assertEq(strategy.gateHorizonDays(), 7);
        // 1. Verify zero-state for all native gate preconditions.
        assertEq(strategy.rebalanceGasEstimator(),          address(0), "ng: estimator zero");
        assertEq(strategy.overCapRiskPremiumBps(),                    0, "ng: overCapRiskPremium zero");
        assertEq(strategy.capDriftToleranceBps(),                     0, "ng: capDriftTolerance zero");
        assertEq(strategy.regimeHorizonDays(),                        0, "ng: regimeHorizon zero");
        assertEq(strategy.regimeConfidenceMultBps(),                  0, "ng: confidenceMult zero");
        assertEq(strategy.recentRebalancePenaltyBps(),                0, "ng: recentPenalty zero");
        assertEq(strategy.entryDriftBps(),                            0, "ng: entryDrift zero");
        assertEq(strategy.minMoveUsd(),                               0, "ng: minMoveUsd zero");
        assertEq(strategy.minBenefitCostRatioBps(),                   0, "ng: minRatio zero");
        assertEq(strategy.slippageBpsEstimate(),                      0, "ng: slippage zero");
        assertEq(strategy.withdrawalSpreadBpsEstimate(),              0, "ng: spread zero");

        uint256 actualSurplus;
        if(includeActualSurplus) {
            // A separate, fully disclosed surplus-cash scenario. These are the
            // same genuine holder-funded tokens left in this harness after the
            // original deposit/swap. No mint, balance override or policy change.
            IERC20Metadata token=IERC20Metadata(market.asset);
            actualSurplus=token.balanceOf(address(this));assertGt(actualSurplus,0);
            uint256 strategyCash=token.balanceOf(address(strategy));uint256 supply=token.totalSupply();
            token.safeTransfer(address(strategy),actualSurplus);
            assertEq(token.balanceOf(address(this)),0);
            assertEq(token.balanceOf(address(strategy))-strategyCash,actualSurplus);
            assertEq(token.totalSupply(),supply);
        }

        // 2. Deploy actual NativeL1FeeInfo for Ethereum L1.
        //    Constructor(uint256 maxCalldataBytes, uint256 tip): (4096, 1 gwei).
        //    getPricesInWei() → (0, 0, 0, 0, 0, block.basefee + tip).
        //    NativeL1FeeInfo.sol must exist in project; missing artifact = verifiable gap.
        address feeInfoAddr = _new(
            "NativeL1FeeInfo.sol:NativeL1FeeInfo",
            abi.encode(uint256(4096), uint256(1 gwei))
        );

        // 3. Illustrative conservative config (benchmark values, not production calibration).
        GasEstimator.Config memory cfg = GasEstimator.Config({
            prepareGas:         2_000_000,
            stepGas:            1_000_000,
            finalizeGas:          500_000,
            defaultDepositGas:  1_500_000,
            defaultWithdrawGas: 2_000_000,
            intrinsicGas:          23_112,
            calldataBytes:            132,
            marginBps:              2_500,
            maxPriceAge:            3_600,
            usdcMaxPriceAge:        3_600,
            sequencerGrace:         3_600,
            fallbackUSDC:             1e6
        });

        // 4. Deploy ReadOnlyGasEstimator with actual Ethereum ETH/USD Chainlink feed.
        //    Ethereum L1: sequencer = address(0) valid; no USDC/USD feed needed.
        address ethUSDFeed = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
        address estimatorAddr = _new(
            "ReadOnlyGasEstimator.sol:ReadOnlyGasEstimator",
            abi.encode(
                IFeeInfo(feeInfoAddr),
                IFeed(ethUSDFeed),
                IFeed(address(0)),   // no USDC/USD required
                IFeed(address(0)),   // no sequencer on Ethereum mainnet (chain 1)
                cfg
            )
        );

        // 5. Wire estimator to strategy (write-once; reverted with snapshot).
        Settings(address(strategy)).setRebalanceGasEstimator(estimatorAddr);
        assertEq(strategy.rebalanceGasEstimator(), estimatorAddr, "ng: estimator wired");

        // 6. Actual scoring inputs.
        (
            uint16[]  memory apys,
            address[] memory list,
            ,
            uint256 tvl,
            ,
            uint256[] memory scores
        ) = Scoring(address(strategy)).computeRebalanceInputs();
        assertGt(list.length, 0, "ng: enabled adapters required");

        // 7. Candidate actions + quote from wired estimator.
        (
            GasEstimator.Action[] memory actions,
            GasEstimator.Quote  memory q
        ) = Gate(address(strategy)).previewRebalanceGas();
        require(actions.length > 0,
            "ng: nonempty candidate plan required at this fork point");

        // 8. Independent gas model (mirrors ReadOnlyGasEstimator.estimate logic).
        uint8 batch = strategy.maxRebalanceActionsPerTx();
        if (batch == 0) batch = 2;
        uint256 n        = actions.length;
        uint256 numSteps = (n + batch - 1) / batch;
        uint256 txCount  = 1 + numSteps;   // 1 prepare tx + numSteps execution txs

        // pathOverhead fields are zero on fresh estimator → all steps use config.stepGas.
        uint256 l2Gas =
            uint256(cfg.prepareGas)
            + uint256(cfg.finalizeGas)
            + txCount  * uint256(cfg.intrinsicGas)
            + numSteps * uint256(cfg.stepGas);

        bool indUsedDefaults;
        for (uint256 i; i < n; ++i) {
            GasEstimator.Action memory a = actions[i];
            uint64 ema;
            if (a.deposit) {
                try IMeasurements(address(strategy)).emaDepositGas(a.adapter)
                    returns (uint64 v) { ema = v; } catch {}
            } else {
                try IMeasurements(address(strategy)).emaWithdrawGas(a.adapter)
                    returns (uint64 v) { ema = v; } catch {}
            }
            bool reliable;
            if (ema >= 21_000) {
                uint32 cnt; uint64 upd;
                if (a.deposit) {
                    try IMeasurements(address(strategy)).depositGasObservation(a.adapter)
                        returns (uint32 c, uint64 t) { cnt = c; upd = t; } catch {}
                } else {
                    try IMeasurements(address(strategy)).withdrawGasObservation(a.adapter)
                        returns (uint32 c, uint64 t) { cnt = c; upd = t; } catch {}
                }
                reliable = cnt >= 3 && upd > 0 && upd <= block.timestamp
                    && block.timestamp - upd <= 7 days;
            }
            if (reliable) {
                l2Gas += ema;
            } else {
                l2Gas += a.deposit
                    ? uint256(cfg.defaultDepositGas)
                    : uint256(cfg.defaultWithdrawGas);
                indUsedDefaults = true;
            }
        }

        // Source price: external call forces fresh block.basefee read (avoids
        // optimizer caching across fork rolls); NativeL1FeeInfo returns
        // block.basefee + 1 gwei as the 6th return value.
        uint256 l2Price = block.basefee + 1 gwei;
        (uint256 sourcePerTx,uint256 sourcePerByte,,,,uint256 sourceExecutionPrice)=IFeeInfo(feeInfoAddr).getPricesInWei();
        assertEq(sourcePerTx,0);assertEq(sourcePerByte,0);assertEq(sourceExecutionPrice,l2Price);
        if(tx.gasprice>l2Price) l2Price=tx.gasprice;
        uint256 executionWei = l2Gas * l2Price;
        // posterWei = 0: Ethereum L1 has no L1 calldata surcharge.

        // Actual fresh ETH/USD round → nativeWAD (18-decimal price).
        uint256 nativeWAD;
        {
            IFeed ethFeed = IFeed(ethUSDFeed);
            uint8  d = ethFeed.decimals();
            (uint80 round, int256 answer, , uint256 updated, uint80 answered) = ethFeed.latestRoundData();
            assertGt(round,0);assertGe(answered,round);assertGt(updated,0);
            assertLe(updated,vm.getBlockTimestamp());assertLe(vm.getBlockTimestamp()-updated,3600);
            assertGt(answer, 0,  "ng: ETH/USD answer must be positive");
            assertLe(d,      18, "ng: ETH/USD decimals must be <= 18");
            nativeWAD = uint256(answer) * (10 ** (18 - uint256(d)));
        }

        // UP rounding: executionWei*nativeWAD/1e18 → ceil /1e12 → ceil *12500/10000.
        uint256 usdWei      = Math.mulDiv(executionWei, nativeWAD, 1e18, Math.Rounding.Up);
        uint256 usd6        = Math.ceilDiv(usdWei, 1e12);
        uint256 indCostUSD6 = Math.mulDiv(usd6, uint256(10_000) + cfg.marginBps, 10_000, Math.Rounding.Up);

        // 9. Assert all quote fields exactly.
        assertTrue(q.reliable,                           "ng: quote must be reliable on Ethereum L1");
        assertEq(q.usedDefaults,  indUsedDefaults,        "ng: usedDefaults flag");
        assertEq(q.l2Gas,         l2Gas,                  "ng: l2Gas exact");
        assertEq(q.posterWei,     0,                      "ng: posterWei zero on L1");
        assertEq(q.executionWei,  executionWei,           "ng: executionWei exact");
        assertEq(q.txCount,       txCount,                "ng: txCount exact");
        assertEq(q.costUSDC,      indCostUSD6,            "ng: costUSDC exact (USD6)");

        // 10. Independent economic inputs.
        //     Cached positions are the gate's authoritative source; assert within 2 raw of live.
        uint256[] memory currentPos = new uint256[](list.length);
        uint256[] memory targetPos  = new uint256[](list.length);
        bool[] memory actionSeen = new bool[](list.length);
        for (uint256 i; i < list.length; ++i) {
            currentPos[i] = strategy.positionAssets(list[i]);
            uint256 live = INativeAdapterAssets(list[i]).totalAssets();
            uint256 diff = live > currentPos[i] ? live - currentPos[i] : currentPos[i] - live;
            assertLe(diff, 2, "ng: cached position within 2 raw of live");
            targetPos[i] = currentPos[i];
        }

        // Apply actions to build post-execution target vector; sum moved.
        uint256 indMoved;
        uint256 cash=IERC20Metadata(market.asset).balanceOf(address(strategy));
        for (uint256 i; i < n; ++i) {
            GasEstimator.Action memory a = actions[i];
            indMoved += a.amount;
            bool found;
            for (uint256 j; j < list.length; ++j) {
                if (list[j] == a.adapter) {
                    found=true;
                    assertFalse(actionSeen[j],"candidate must have at most one net action per venue");actionSeen[j]=true;
                    if (a.deposit) {assertLe(a.amount,cash);targetPos[j]+=a.amount;cash-=a.amount;}
                    else {assertLe(a.amount,INativeAdapterAssets(a.adapter).withdrawableAssets());targetPos[j]-=a.amount;cash+=a.amount;}
                    break;
                }
            }
            assertTrue(found,"candidate action must name an enabled observed venue");
        }
        assertGe(cash,tvl*strategy.targetIdleBufferBps()/10000);
        assertGt(indMoved, 0, "ng: moved must be positive");

        // Annual delta formula (dynamic gate, NOT legacy weighted-delta*moved).
        int256 annualDelta;
        for (uint256 i; i < list.length; ++i) {
            int256 beforeYield = int256(currentPos[i] * uint256(apys[i]));
            int256 afterYield = int256(targetPos[i] * uint256(apys[i]));
            annualDelta += afterYield - beforeYield;
        }
        uint256 indGross = annualDelta > 0
            ? uint256(annualDelta) * 7 / (10_000 * 365)
            : 0;

        // Convert costUSD6 to asset units via actual oracle price.
        uint256 priceWAD    = oracle.getQuoteFresh(market.asset).price;
        uint256 indCostAsset = Math.mulDiv(
            indCostUSD6,
            (10 ** uint256(market.decimals)) * 1e12,
            priceWAD,
            Math.Rounding.Up
        );

        int256  indNet  = int256(indGross) - int256(indCostAsset);
        // With dynamic estimator: gate returns false when netBenefit <= 0 (strict).
        bool    indAccepted = indMoved > 0 && indNet > 0;
        int256  indNetBps;
        if (indAccepted) {
            indNetBps   = indNet * 10_000 / int256(indMoved);
            if (strategy.gateMinNetBenefitBps() > 0)
                indAccepted = indNetBps >= int256(uint256(strategy.gateMinNetBenefitBps()));
        }
        // minMoveBps (zero by default; computed when nonzero for completeness).
        if (indAccepted && strategy.rebalanceMinMoveBps() > 0) {
            uint256 tvlEnabled = IERC20Metadata(market.asset).balanceOf(address(strategy));
            for (uint256 i; i < list.length; ++i) tvlEnabled += currentPos[i];
            if (indMoved < uint256(strategy.rebalanceMinMoveBps()) * tvlEnabled / 10_000)
                indAccepted = false;
        }

        // 11. Compare Gate.canRebalance() against independent model.
        (bool gateOk, uint256 gateMoved, int256 gateBps) = Gate(address(strategy)).canRebalance();
        assertEq(gateMoved, indMoved,    "ng: canRebalance moved = sum actions");
        assertEq(gateOk,    indAccepted, "ng: acceptance matches independent economic model");
        if (gateOk) assertEq(gateBps, indNetBps, "ng: netBenefitBps matches");

        // 12. Execute natural plan if gate accepts; do not force acceptance.
        uint256 execSteps;
        bool economicCancelled;
        uint256 prepareKeeperGas;
        uint256 maxStepKeeperGas;
        if (gateOk) {
            address[] memory managed=new address[](1);managed[0]=address(strategy);
            StrategyUpkeep upkeep=StrategyUpkeep(_new("LendingStrategyUpkeep.sol:StrategyUpkeep",abi.encode(managed)));
            strategy.grantRole(keccak256("KEEPER_ROLE"),address(upkeep));
            {
                bytes memory payload=abi.encodeCall(StrategyUpkeep.performUpkeep,(abi.encode(uint8(5),uint256(0))));
                assertEq(payload.length,132,"actual keeper calldata bytes");uint256 beforeGas=gasleft();
                (bool ok,)=address(upkeep).call(payload);prepareKeeperGas=beforeGas-gasleft();assertTrue(ok,"keeper preparation call");
            }
            assertEq(strategy.rebalancePlanPhase(), 1, "ng: plan prepared");
            while (strategy.rebalancePlanPhase() != 0 && execSteps < n+2) {
                bool remainingAllowed=Gate(address(strategy)).checkRemainingPlan();
                uint256 cashBeforeStep=IERC20Metadata(market.asset).balanceOf(address(strategy));
                uint256 beforeFailureCount=strategy.rebalancePlanConsecutiveFailures();
                uint256[] memory beforePositions=new uint256[](list.length);
                for(uint256 k;k<list.length;++k) beforePositions[k]=INativeAdapterAssets(list[k]).totalAssets();
                bytes memory payload=abi.encodeCall(StrategyUpkeep.performUpkeep,(abi.encode(uint8(6),uint256(0))));assertEq(payload.length,132);
                uint256 beforeGas=gasleft();(bool sok,)=address(upkeep).call(payload);uint256 stepGas=beforeGas-gasleft();assertTrue(sok,"keeper step call");if(stepGas>maxStepKeeperGas)maxStepKeeperGas=stepGas;
                ++execSteps;
                if(!remainingAllowed) {
                    // Safe cancellation is required when the actual suffix no longer pays its native fees.
                    assertEq(strategy.rebalancePlanPhase(),0);
                    assertEq(strategy.rebalancePlanConsecutiveFailures(),beforeFailureCount+1);
                    assertEq(strategy.lastRebalanceTs(),vm.getBlockTimestamp());
                    assertEq(IERC20Metadata(market.asset).balanceOf(address(strategy)),cashBeforeStep);
                    for(uint256 k;k<list.length;++k) assertEq(INativeAdapterAssets(list[k]).totalAssets(),beforePositions[k]);
                    economicCancelled=true;break;
                }
                assertEq(strategy.rebalancePlanConsecutiveFailures(),beforeFailureCount,"no unexplained action failure");
            }
            assertEq(strategy.rebalancePlanPhase(),              0, "ng: plan must complete");
            if(!economicCancelled) {
                assertEq(strategy.rebalancePlanConsecutiveFailures(),0,"ng: clean completed native plan");
                assertEq(strategy.lastRebalanceTs(),vm.getBlockTimestamp());
            }
        }

        // 13. Return aggregate observation; caller emits after snapshot restore.
        obs = NativeGateObs({
            prepareKeeperGas:prepareKeeperGas,
            maxStepKeeperGas:maxStepKeeperGas,
            economicCancelled: economicCancelled,
            surplusTransferred: actualSurplus,
            moved:         indMoved,
            gross:         indGross,
            costUSD6:      indCostUSD6,
            costAsset:     indCostAsset,
            netBps:        indNetBps,
            accepted:      gateOk,
            steps:         execSteps,
            reliable:      q.reliable,
            qCostUSD6:     q.costUSDC,
            qTxCount:      q.txCount,
            qUsedDefaults: q.usedDefaults
        });
    }
}
