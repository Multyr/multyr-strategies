// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title StrategyUpkeep
/// @notice Chainlink Automation coordinator for multiple Strategy Vaults (e.g., UsdcMultiLendingVault).
/// @dev Non-upgradeable, Ownable. Performs at most one HARVEST or REBALANCE per upkeep, with HARVEST priority.
///      Uses round-robin selection to avoid starvation. Supports forced actions via performData.
///      This contract does not manage keeper roles on the strategies: each strategy must grant KEEPER_ROLE to this contract.
import {
    AutomationCompatibleInterface
} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Minimal interface for a Strategy Vault compatible with StrategyUpkeep.
interface IStrategyVault {
    // View (no side-effect)
    function canHarvest()
        external
        view
        returns (bool ok, uint256 sumHarvestable, uint64 sinceLastHarvest);
    function canRebalance()
        external
        view
        returns (bool ok, uint256 movedEstimateUSDC, int256 netBenefitBps);

    // Actions (must do all in a single tx)
    function harvest() external;
    function rebalance() external;
}

/// @notice Emitted when a new strategy is added.
event StrategyAdded(address indexed strategy);

/// @notice Emitted when a strategy is removed.
event StrategyRemoved(address indexed strategy);

/// @notice Emitted when a strategy is enabled/disabled.
event StrategyToggled(address indexed strategy, bool enabled);

/// @notice Emitted at the end of checkUpkeep.
/// @param startIndex The index used as starting point for round-robin.
/// @param selectedStrategy The selected strategy (or address(0) if none selected).
/// @param selectedOp 0=NONE, 1=HARVEST, 2=REBALANCE
/// @param anyHarvestable True if any strategy is harvestable in this round.
/// @param anyRebalanceable True if any strategy is rebalanceable in this round.
event UpkeepChecked(
    uint256 indexed startIndex,
    address selectedStrategy,
    uint8 selectedOp,
    bool anyHarvestable,
    bool anyRebalanceable
);

/// @notice Emitted after a successful performUpkeep.
/// @param op 1=HARVEST, 2=REBALANCE
/// @param strategy The strategy operated on.
/// @param timestamp Block timestamp of execution.
event UpkeepPerformed(uint8 indexed op, address indexed strategy, uint256 timestamp);

/// @notice Emitted if performUpkeep fails (via try/catch).
/// @param op 1=HARVEST, 2=REBALANCE
/// @param strategy The strategy attempted.
/// @param reason Error data.
event UpkeepErrored(uint8 indexed op, address indexed strategy, bytes reason);

/// @notice Emitted when Aave liquidity rate is pushed to the rate provider.
event AaveRatePushed(uint256 rateRay);

/// @notice Emitted when an adapter snapshot is successfully poked.
event SnapshotPoked(address indexed target);

/// @notice Emitted when an adapter snapshot poke fails.
event SnapshotPokeFailed(address indexed target, bytes reason);

/// @notice V9.1: Emitted when external TVL cache is refreshed on a strategy.
event ExternalTVLPoked(address indexed strategy);

/// @notice V9.1: Emitted when external TVL poke fails (with reason).
event ExternalTVLPokeFailed(address indexed strategy, bytes reason);

/// @notice Emitted when a poke target is added.
event PokeTargetAdded(address indexed target);

/// @notice Emitted when a poke target is removed.
event PokeTargetRemoved(address indexed target);

/// @notice Emitted when the poke interval is updated.
event PokeIntervalUpdated(uint64 oldInterval, uint64 newInterval);

/// @notice Emitted when Aave config is updated.
event AaveConfigUpdated(address aavePool, address rateProvider, address usdc);

/// @notice Thrown if a strategy is not valid or not enabled.
error InvalidStrategy();
/// @notice Audit #2 P0.2 — cooldown enforced in performUpkeep too.
error HarvestCooldown();
error RebalanceCooldown();
error DeployIdleCooldown();

/// @notice Thrown if an unknown operation code is provided.
error UnknownOperation();

/// @notice Thrown if a strategy index is out of bounds.
error IndexOutOfBounds();

/// @notice Thrown if a zero address is provided.
error ZeroAddress();

/// @notice Thrown if a strategy does not implement IStrategyVault.
error NotIStrategyVault();

/// @dev HARVEST opcode
uint8 constant OP_HARVEST = 1;
/// @dev REBALANCE opcode (legacy — kept for backward compat, maps to prepare)
uint8 constant OP_REBALANCE = 2;
/// @dev POKE_APY opcode — refresh adapter rate/snapshot data
uint8 constant OP_POKE_APY = 3;
/// @dev DEPLOY_IDLE opcode — deploy idle cash to adapters
uint8 constant OP_DEPLOY_IDLE = 4;
/// @dev PREPARE_REBALANCE opcode — build rebalance plan (phase 1)
uint8 constant OP_PREPARE_REBALANCE = 5;
/// @dev EXECUTE_REBALANCE_STEP opcode — execute N actions from plan (phase 2)
uint8 constant OP_EXECUTE_REBALANCE_STEP = 6;

/// @notice Minimal Aave v3 Pool interface for reading reserve data.
interface IAavePoolForPoke {
    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    function getReserveData(address asset) external view returns (ReserveData memory);
}

/// @notice Writer interface for AaveLiquidityRateProvider.
interface IAaveRateProviderWriter {
    function setLiquidityRateRay(address asset, uint256 rateRay) external;
}

/// @notice Interface for adapters that support APY snapshot poking.
interface IPokeable {
    function pokeAPYSnapshots() external;
}

/// @notice V9.1: Interface for strategies that support external TVL cache refresh.
interface IStrategyPokeTVL {
    function pokeExternalTVL() external;
}

/// @notice V9.1: Interface for multi-step rebalance.
interface IMultiStepRebalance {
    function prepareRebalance() external;
    function executeRebalanceStep() external;
    function cancelRebalancePlan() external;
    function rebalancePlanPhase() external view returns (uint8);
    function rebalancePlanNextAction() external view returns (uint8);
    function rebalancePlanTotalActions() external view returns (uint8);
    function lastRebalanceTs() external view returns (uint64);
    function minSecondsBetweenRebalances() external view returns (uint32);
}

/// @notice Interface for strategies with harvest cooldown metadata (audit P0.2).
interface IStrategyWithHarvestCooldown {
    function lastHarvestTs() external view returns (uint64);
    function minSecondsBetweenHarvests() external view returns (uint32);
}

/// @notice Interface for strategies with idle cash deployment.
interface IStrategyWithIdle {
    function idleCash() external view returns (uint256);
    function dustTolerance() external view returns (uint256);
    function idleDeployThreshold() external view returns (uint256);
    function lastDeployIdleTs() external view returns (uint64);
    function minSecondsBetweenDeployIdle() external view returns (uint32);
    function deployIdle() external;
}

/**
 * @title StrategyUpkeep
 * @notice Chainlink Automation coordinator for multiple Strategy Vaults.
 *         Admin can add/remove/toggle strategies. Upkeep will pick one action per round (HARVEST > REBALANCE),
 *         using round-robin to avoid starvation. Forced actions via performData are supported.
 * @dev Ownable for admin, non-upgradeable. Ensure this contract has KEEPER_ROLE on all managed strategies.
 */
contract StrategyUpkeep is AutomationCompatibleInterface, Ownable {
    /// @notice List of strategy vaults under management
    IStrategyVault[] public strategies;
    /// @notice Deduplication mapping: true if address is a managed strategy
    mapping(address => bool) public isStrategy;
    /// @notice Per-strategy enabled flag
    mapping(address => bool) public enabled;
    /// @notice Round-robin index for selection
    uint256 public rrIndex;

    // ===== POKE_APY state =====

    /// @notice Adapter addresses that support pokeAPYSnapshots()
    address[] public pokeTargets;
    /// @notice Deduplication mapping for poke targets
    mapping(address => bool) public isPokeTarget;
    /// @notice Aave v3 Pool for reading on-chain liquidity rate
    IAavePoolForPoke public aavePool;
    /// @notice Aave rate provider to push liquidity rate to
    IAaveRateProviderWriter public aaveRateProvider;
    /// @notice USDC address for Aave rate lookup
    address public usdc;
    /// @notice Minimum seconds between POKE_APY operations (default 86400 = 24h)
    uint64 public pokeInterval;
    /// @notice Timestamp of last POKE_APY execution
    uint64 public lastPokeTs;

    /**
     * @notice Constructor: optionally initializes with a list of strategies.
     * @param initialStrategies List of strategy addresses to add at deployment.
     */
    constructor(address[] memory initialStrategies) {
        uint256 len = initialStrategies.length;
        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                address s = initialStrategies[i];
                if (s == address(0)) revert ZeroAddress();
                if (isStrategy[s]) revert InvalidStrategy();

                // Check that the address responds to canHarvest()
                (bool ok,) =
                    s.staticcall(abi.encodeWithSelector(IStrategyVault.canHarvest.selector));
                if (!ok) revert NotIStrategyVault();

                isStrategy[s] = true;
                enabled[s] = true;
                strategies.push(IStrategyVault(s));
                emit StrategyAdded(s);
            }
        }
    }

    // ===== Admin functions (Ownable) =====

    /**
     * @notice Add a new strategy to the list.
     * @param s Address of the strategy to add.
     * @dev Only owner. Checks for nonzero, not already present, and canHarvest() compliance.
     */
    function addStrategy(address s) external onlyOwner {
        if (s == address(0)) revert ZeroAddress();
        if (isStrategy[s]) revert InvalidStrategy();
        (bool ok,) = s.staticcall(abi.encodeWithSelector(IStrategyVault.canHarvest.selector));
        if (!ok) revert NotIStrategyVault();
        isStrategy[s] = true;
        enabled[s] = true;
        strategies.push(IStrategyVault(s));
        emit StrategyAdded(s);
    }

    /**
     * @notice Remove a strategy by index (swap & pop).
     * @param index Index in the strategies array.
     * @dev Only owner. Updates mappings and emits event.
     */
    function removeStrategy(uint256 index) external onlyOwner {
        uint256 len = strategies.length;
        if (index >= len) revert IndexOutOfBounds();
        address s = address(strategies[index]);
        isStrategy[s] = false;
        enabled[s] = false;

        // Swap & pop
        if (index != len - 1) {
            strategies[index] = strategies[len - 1];
        }
        strategies.pop();

        // Adjust rrIndex if needed
        if (rrIndex >= len - 1 && rrIndex > 0) {
            rrIndex = 0;
        }

        emit StrategyRemoved(s);
    }

    /**
     * @notice Enable or disable a strategy.
     * @param s Address of the strategy.
     * @param on True to enable, false to disable.
     * @dev Only owner. Strategy must exist.
     */
    function toggleStrategy(address s, bool on) external onlyOwner {
        if (!isStrategy[s]) revert InvalidStrategy();
        enabled[s] = on;
        emit StrategyToggled(s, on);
    }

    // ===== POKE_APY Admin (Ownable) =====

    /// @notice Configure Aave Pool and rate provider for POKE_APY.
    function setAaveConfig(address pool, address provider, address usdc_) external onlyOwner {
        aavePool = IAavePoolForPoke(pool);
        aaveRateProvider = IAaveRateProviderWriter(provider);
        usdc = usdc_;
        emit AaveConfigUpdated(pool, provider, usdc_);
    }

    /// @notice Add an adapter that supports pokeAPYSnapshots().
    function addPokeTarget(address target) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        require(!isPokeTarget[target], "already added");
        pokeTargets.push(target);
        isPokeTarget[target] = true;
        emit PokeTargetAdded(target);
    }

    /// @notice Remove a poke target (swap & pop).
    function removePokeTarget(address target) external onlyOwner {
        require(isPokeTarget[target], "not found");
        isPokeTarget[target] = false;
        uint256 len = pokeTargets.length;
        for (uint256 i = 0; i < len; i++) {
            if (pokeTargets[i] == target) {
                pokeTargets[i] = pokeTargets[len - 1];
                pokeTargets.pop();
                break;
            }
        }
        emit PokeTargetRemoved(target);
    }

    /// @notice Set the minimum interval between POKE_APY operations.
    function setPokeInterval(uint64 newInterval) external onlyOwner {
        emit PokeIntervalUpdated(pokeInterval, newInterval);
        pokeInterval = newInterval;
    }

    /// @notice Returns all poke target addresses.
    function getPokeTargets() external view returns (address[] memory) {
        return pokeTargets;
    }

    // ===== Getters =====

    /**
     * @notice Returns the number of strategies managed.
     */
    function strategiesLength() external view returns (uint256) {
        return strategies.length;
    }

    /**
     * @notice Returns the strategy address at a given index.
     * @param index Index in the strategies array.
     */
    function getStrategy(uint256 index) external view returns (address) {
        if (index >= strategies.length) revert IndexOutOfBounds();
        return address(strategies[index]);
    }

    // ===== Chainlink Automation logic =====

    /**
     * @notice Chainlink checkUpkeep: selects at most one action (HARVEST or REBALANCE) with HARVEST priority, using round-robin.
     * @dev Does not update state. Emits UpkeepChecked with selection details.
     * @param checkData Not used (future extension).
     * @return upkeepNeeded True if an action should be performed.
     * @return performData Encoded (op, index) for performUpkeep.
     */
    /// @param checkData Not used (reserved for future extensions).
    /// @dev Optimized: 2 loops max (HARVEST priority, then REBALANCE). Early return on match.
    function checkUpkeep(bytes calldata checkData)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        // Pass 0: POKE_APY — only when data is stale or uninitialized
        if (address(aavePool) != address(0) || pokeTargets.length > 0) {
            uint64 last = lastPokeTs;
            if (last == 0 || block.timestamp >= uint256(last) + pokeInterval) {
                return (true, abi.encode(OP_POKE_APY, uint256(0)));
            }
        }

        // Cache storage to memory for gas efficiency
        IStrategyVault[] memory _strategies = strategies;
        uint256 N = _strategies.length;
        if (N < 1) return (false, ""); // slither: incorrect-equality - use < 1 instead of == 0

        // Pass 0.5: DEPLOY_IDLE — check if any strategy has idle cash to deploy
        // V9.1 CTO: also check cooldown to prevent LINK burn loop
        unchecked {
            for (uint256 i = 0; i < N; ++i) {
                address sAddr = address(_strategies[i]);
                if (!enabled[sAddr]) continue;
                try IStrategyWithIdle(sAddr).idleCash() returns (uint256 idle) {
                    try IStrategyWithIdle(sAddr).idleDeployThreshold() returns (uint256 threshold) {
                        if (idle > threshold) {
                            // Check deploy cooldown to avoid LINK burn on DeployIdleCooldown revert
                            try IStrategyWithIdle(sAddr).lastDeployIdleTs() returns (uint64 lastDeploy) {
                                try IStrategyWithIdle(sAddr).minSecondsBetweenDeployIdle() returns (uint32 cooldown) {
                                    if (block.timestamp >= uint256(lastDeploy) + cooldown) {
                                        return (true, abi.encode(OP_DEPLOY_IDLE, i));
                                    }
                                } catch {
                                    return (true, abi.encode(OP_DEPLOY_IDLE, i));
                                }
                            } catch {
                                return (true, abi.encode(OP_DEPLOY_IDLE, i));
                            }
                        }
                    } catch {}
                } catch {}
            }
        }

        uint256 start = rrIndex;
        uint8 op = 0; // Initialize local variable (slither: uninitialized-local)
        uint256 selIndex = 0; // Initialize local variable (slither: uninitialized-local)

        // Pass 1: HARVEST priority - find first harvestable strategy
        unchecked {
            for (uint256 i = 0; i < N; ++i) {
                uint256 idx = (start + i) % N;
                address sAddr = address(_strategies[idx]);
                if (!enabled[sAddr]) continue;

                (bool canH,,) = _strategies[idx].canHarvest();
                if (canH) {
                    return (true, abi.encode(OP_HARVEST, idx));
                }
            }
        }

        // Pass 2: REBALANCE (multi-step) — execute active plan first, then prepare new
        unchecked {
            for (uint256 i = 0; i < N; ++i) {
                uint256 idx = (start + i) % N;
                address sAddr = address(_strategies[idx]);
                if (!enabled[sAddr]) continue;

                // Check if active plan needs execution
                try IMultiStepRebalance(sAddr).rebalancePlanPhase() returns (uint8 phase) {
                    if (phase > 0) {
                        try IMultiStepRebalance(sAddr).rebalancePlanNextAction() returns (uint8 next) {
                            try IMultiStepRebalance(sAddr).rebalancePlanTotalActions() returns (uint8 total) {
                                if (next < total) {
                                    return (true, abi.encode(OP_EXECUTE_REBALANCE_STEP, idx));
                                }
                            } catch {}
                        } catch {}
                    }
                } catch {}

                // No active plan — check if new rebalance needed
                (bool canR,,) = _strategies[idx].canRebalance();
                if (canR) {
                    return (true, abi.encode(OP_PREPARE_REBALANCE, idx));
                }
            }
        }

        return (false, "");
    }

    /**
     * @notice Chainlink performUpkeep: decodes performData, validates, and performs a single action (HARVEST or REBALANCE).
     * @dev Advances rrIndex only after a successful action. Uses try/catch for resilience (no revert-stuck).
     * @param performData Encoded operation and index, or single byte opcode.
     */
    function performUpkeep(bytes calldata performData) external override {
        uint8 op = 0; // Initialize local variable (slither: uninitialized-local)
        uint256 index = 0; // Initialize local variable (slither: uninitialized-local)
        if (performData.length == 1) {
            // casting to bytes1/uint8 is safe because performData.length == 1
            // forge-lint: disable-next-line(unsafe-typecast)
            op = uint8(bytes1(performData));
            index = rrIndex; // Default: use rrIndex if no index provided
        } else if (performData.length >= 64) {
            (op, index) = abi.decode(performData, (uint8, uint256));
        } else {
            revert UnknownOperation();
        }

        // POKE_APY is handled separately — no strategy index validation needed
        if (op == OP_POKE_APY) {
            _performPokeAPY();
            return;
        }

        if (index >= strategies.length) revert IndexOutOfBounds();
        IStrategyVault target = strategies[index];
        if (!enabled[address(target)]) revert InvalidStrategy();

        // Audit #2 P0.2: cooldown enforcement in performUpkeep. checkUpkeep() only
        // *suggests* an action — any caller can hit performUpkeep with crafted
        // performData and bypass the policy otherwise.
        _enforceOpCooldown(op, address(target));

        // Audit #2 P0.1: rrIndex must advance even when the action fails, otherwise
        // a single reverting strategy can starve the whole round-robin. Exception:
        // OP_EXECUTE_REBALANCE_STEP with a multi-step plan still in progress
        // (phase != 0) — keep the cursor on the same strategy so the next upkeep
        // continues that plan.
        bool shouldAdvance = false;

        if (op == OP_HARVEST) {
            try target.harvest() {
                emit UpkeepPerformed(op, address(target), block.timestamp);
            } catch (bytes memory reason) {
                emit UpkeepErrored(op, address(target), reason);
            }
            shouldAdvance = true;
        } else if (op == OP_REBALANCE || op == OP_PREPARE_REBALANCE) {
            try IMultiStepRebalance(address(target)).prepareRebalance() {
                emit UpkeepPerformed(op, address(target), block.timestamp);
            } catch (bytes memory reason) {
                emit UpkeepErrored(op, address(target), reason);
            }
            shouldAdvance = true;
        } else if (op == OP_EXECUTE_REBALANCE_STEP) {
            try IMultiStepRebalance(address(target)).executeRebalanceStep() {
                emit UpkeepPerformed(op, address(target), block.timestamp);
                // Keep the cursor on this strategy only while the plan is still active.
                try IMultiStepRebalance(address(target)).rebalancePlanPhase() returns (uint8 phase) {
                    if (phase == 0) shouldAdvance = true;
                } catch {
                    // fail-safe: never get stuck forever if phase() is unreadable.
                    shouldAdvance = true;
                }
            } catch (bytes memory reason) {
                emit UpkeepErrored(op, address(target), reason);
                // Terminal failure of the step → advance so other strategies can run.
                shouldAdvance = true;
            }
        } else if (op == OP_DEPLOY_IDLE) {
            try IStrategyWithIdle(address(target)).deployIdle() {
                emit UpkeepPerformed(op, address(target), block.timestamp);
            } catch (bytes memory reason) {
                emit UpkeepErrored(op, address(target), reason);
            }
            shouldAdvance = true;
        } else {
            revert UnknownOperation();
        }

        if (shouldAdvance && strategies.length > 0) {
            rrIndex = (index + 1) % strategies.length;
        }
    }

    /// @notice Audit #2 P0.2 — cooldown gate re-applied in performUpkeep.
    /// @dev Reads the same clocks as checkUpkeep. If the target does not expose
    ///      the cooldown interface (legacy strategies) the call is a no-op.
    function _enforceOpCooldown(uint8 op, address target) internal view {
        if (op == OP_HARVEST) {
            try IStrategyWithHarvestCooldown(target).lastHarvestTs() returns (uint64 last) {
                try IStrategyWithHarvestCooldown(target).minSecondsBetweenHarvests() returns (uint32 cd) {
                    if (cd > 0 && last != 0 && block.timestamp < uint256(last) + cd) {
                        revert HarvestCooldown();
                    }
                } catch {}
            } catch {}
        } else if (op == OP_REBALANCE || op == OP_PREPARE_REBALANCE) {
            try IMultiStepRebalance(target).lastRebalanceTs() returns (uint64 last) {
                try IMultiStepRebalance(target).minSecondsBetweenRebalances() returns (uint32 cd) {
                    if (cd > 0 && last != 0 && block.timestamp < uint256(last) + cd) {
                        revert RebalanceCooldown();
                    }
                } catch {}
            } catch {}
        } else if (op == OP_EXECUTE_REBALANCE_STEP) {
            // executeRebalanceStep does NOT consult the cooldown clock because a
            // plan that was prepared earlier must always be finishable. The
            // strategy itself enforces that phase != 0 before allowing a step.
        } else if (op == OP_DEPLOY_IDLE) {
            try IStrategyWithIdle(target).lastDeployIdleTs() returns (uint64 last) {
                try IStrategyWithIdle(target).minSecondsBetweenDeployIdle() returns (uint32 cd) {
                    if (cd > 0 && last != 0 && block.timestamp < uint256(last) + cd) {
                        revert DeployIdleCooldown();
                    }
                } catch {}
            } catch {}
        }
    }

    // ===== POKE_APY internal =====

    /// @dev Refreshes adapter APY data: pushes Aave rate + pokes snapshot targets.
    ///      Safe-idempotent: silent return if within cooldown. All external calls
    ///      wrapped in try/catch so a single failure never blocks others.
    function _performPokeAPY() internal {
        // Safe-idempotent: re-check cooldown
        uint64 last = lastPokeTs;
        if (last != 0 && block.timestamp < uint256(last) + pokeInterval) return;

        // 1. Push Aave liquidity rate from on-chain Pool data
        if (address(aavePool) != address(0) && address(aaveRateProvider) != address(0)) {
            try aavePool.getReserveData(usdc) returns (IAavePoolForPoke.ReserveData memory data) {
                try aaveRateProvider.setLiquidityRateRay(usdc, uint256(data.currentLiquidityRate)) {
                    emit AaveRatePushed(uint256(data.currentLiquidityRate));
                } catch {}
            } catch {}
        }

        // 2. Poke all snapshot targets (Dolomite, Morpho, Gains)
        uint256 len = pokeTargets.length;
        for (uint256 i = 0; i < len; i++) {
            try IPokeable(pokeTargets[i]).pokeAPYSnapshots() {
                emit SnapshotPoked(pokeTargets[i]);
            } catch (bytes memory reason) {
                emit SnapshotPokeFailed(pokeTargets[i], reason);
            }
        }

        // 3. V9.1: Poke external TVL cache on all strategies
        //    Each strategy.pokeExternalTVL() refreshes cached market depth for scoring.
        //    Requires KEEPER_ROLE on the strategy (granted during deploy wiring).
        uint256 sLen = strategies.length;
        for (uint256 i = 0; i < sLen; i++) {
            try IStrategyPokeTVL(address(strategies[i])).pokeExternalTVL() {
                emit ExternalTVLPoked(address(strategies[i]));
            } catch (bytes memory reason) {
                emit ExternalTVLPokeFailed(address(strategies[i]), reason);
            }
        }

        lastPokeTs = uint64(block.timestamp);
        emit UpkeepPerformed(OP_POKE_APY, address(0), block.timestamp);
        // No rrIndex advance — POKE_APY is not strategy-specific
    }
}
