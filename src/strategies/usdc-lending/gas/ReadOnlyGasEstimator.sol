// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IFeeInfo {
    function getPricesInWei()
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256);
}

interface IFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IMeasurements {
    function emaDepositGas(address) external view returns (uint64);
    function emaWithdrawGas(address) external view returns (uint64);
    function depositGasObservation(address) external view returns (uint32 count, uint64 updatedAt);
    function withdrawGasObservation(address) external view returns (uint32 count, uint64 updatedAt);
}

/// @notice Read-only plan cost model. Governance calibration writes are separate.
/// @dev Cost model, not an RPC simulator or a proven upper bound on Nitro fees.
contract ReadOnlyGasEstimator {
    struct Action {
        address adapter;
        uint256 amount;
        bool deposit;
    }

    struct Config {
        uint32 prepareGas; // excluding adapter calls, including estimator overhead
        uint32 stepGas; // per execution transaction, INCLUDING revalidation, excluding adapter calls
        uint32 finalizeGas; // final snapshot and accounting; no unpriced redeployment
        uint32 defaultDepositGas;
        uint32 defaultWithdrawGas;
        uint32 intrinsicGas; // L2-only; NOT eth_estimateGas, which includes poster fees
        uint16 calldataBytes; // exact wrapper calldata length for this prototype
        uint16 marginBps;
        uint32 maxPriceAge; // ETH/USD heartbeat tolerance
        uint32 usdcMaxPriceAge; // USDC/USD may have a different heartbeat
        uint32 sequencerGrace;
        uint256 fallbackUSDC;
    }

    struct Quote {
        bytes32 actionsHash;
        uint256 costUSDC;
        uint256 l2Gas;
        uint256 posterWei;
        uint256 executionWei;
        uint256 txCount;
        bool reliable;
        bool usedDefaults;
    }
    IFeeInfo public immutable feeInfo;
    IFeed public immutable ethUSD;
    IFeed public immutable usdcUSD;
    IFeed public immutable sequencer;
    Config public config;
    address public calibrator;
    address public pendingCalibrator;
    event ConfigUpdated();
    event CalibratorProposed(address indexed next);
    event CalibratorAccepted(address indexed next);

    function proposeCalibrator(address next) external {
        require(msg.sender == calibrator && next != address(0), "unauthorized");
        pendingCalibrator = next;
        emit CalibratorProposed(next);
    }

    function acceptCalibrator() external {
        require(msg.sender == pendingCalibrator, "unauthorized");
        calibrator = msg.sender;
        pendingCalibrator = address(0);
        emit CalibratorAccepted(msg.sender);
    }

    function setConfig(Config memory c) external {
        require(msg.sender == calibrator, "unauthorized");
        _validate(c);
        config = c;
        emit ConfigUpdated();
    }
    mapping(address => uint32) public depositFloor;
    mapping(address => uint32) public withdrawFloor;
    event AdapterFloorsSet(address indexed adapter, uint32 depositGas, uint32 withdrawGas);

    /// @dev Calibration/governance change, NOT a per-rebalance quote publication.
    function setAdapterFloors(address adapter, uint32 depositGas, uint32 withdrawGas) external {
        require(msg.sender == calibrator, "unauthorized");
        require(
            adapter != address(0) && depositGas >= 21000 && withdrawGas >= 21000, "invalid floor"
        );
        depositFloor[adapter] = depositGas;
        withdrawFloor[adapter] = withdrawGas;
        emit AdapterFloorsSet(adapter, depositGas, withdrawGas);
    }
    // Defaults are cold-start values; the legacy floor ABI is retained for governance tooling.
    uint32 public constant MIN_EMA_SAMPLES = 3;
    uint32 public constant MAX_EMA_AGE = 7 days;
    struct PathOverhead { uint32 preparation; uint32 withdrawalStep; uint32 depositStep; uint32 mixedStep; uint32 finalization; }
    PathOverhead public pathOverhead;
    event PathOverheadUpdated();
    function setPathOverhead(PathOverhead calldata p) external {
        require(msg.sender == calibrator, "unauthorized");
        require(p.preparation > 0 && p.withdrawalStep > 0 && p.depositStep > 0
            && p.mixedStep > 0 && p.finalization > 0, "invalid overhead");
        pathOverhead = p;
        emit PathOverheadUpdated();
    }

    function _sampleReliable(IMeasurements measurements, Action memory a, uint256 sample) internal view returns (bool) {
        if (sample < 21000) return false;
        uint32 count;
        uint64 updated;
        if (a.deposit) {
            try measurements.depositGasObservation(a.adapter) returns (uint32 c, uint64 t) { count = c; updated = t; } catch { return false; }
        } else {
            try measurements.withdrawGasObservation(a.adapter) returns (uint32 c, uint64 t) { count = c; updated = t; } catch { return false; }
        }
        return count >= MIN_EMA_SAMPLES && updated > 0 && updated <= block.timestamp
            && block.timestamp - updated <= MAX_EMA_AGE;
    }

    error InvalidConfig();
    error InvalidPlan();

    constructor(IFeeInfo f, IFeed e, IFeed u, IFeed s, Config memory c) {
        require(
            address(f) != address(0) && address(e).code.length > 0 && address(u).code.length > 0
                && address(s).code.length > 0,
            "dependency"
        );
        _validate(c);
        calibrator = msg.sender;
        feeInfo = f;
        ethUSD = e;
        usdcUSD = u;
        sequencer = s;
        config = c;
    }

    function _validate(Config memory c) internal pure {
        if (
            c.marginBps < 1000 || c.marginBps > 10000 || c.prepareGas == 0 || c.stepGas == 0
                || c.finalizeGas == 0 || c.defaultDepositGas < 21000 || c.defaultWithdrawGas < 21000
                || c.maxPriceAge == 0 || c.maxPriceAge > 7 days || c.usdcMaxPriceAge == 0
                || c.usdcMaxPriceAge > 7 days || c.sequencerGrace < 1 hours || c.fallbackUSDC == 0
                || c.intrinsicGas < 21000 || c.calldataBytes < 4
        ) revert InvalidConfig();
    }

    // Validated USD price in 18 decimals; conservative operational sanity bands.
    function _price(IFeed feed, uint256 low, uint256 high, uint32 maxAge)
        internal
        view
        returns (uint256)
    {
        try feed.decimals() returns (uint8 d) {
            if (d > 18) return 0;
            try feed.latestRoundData() returns (
                uint80 round, int256 answer, uint256, uint256 updated, uint80 answered
            ) {
                if (
                    answer <= 0 || round == 0 || answered < round || updated == 0
                        || updated > block.timestamp || block.timestamp - updated > maxAge
                ) return 0;
                if (uint256(answer) > high / (10 ** (18 - d))) return 0;
                uint256 normalized = uint256(answer) * 10 ** (18 - d);
                return normalized < low ? 0 : normalized;
            } catch {
                return 0;
            }
        } catch {
            return 0;
        }
    }

    function _sequencerUp() internal view returns (bool) {
        try sequencer.latestRoundData() returns (
            uint80, int256 answer, uint256 started, uint256, uint80
        ) {
            return answer == 0 && started != 0 && started <= block.timestamp
                && block.timestamp - started > config.sequencerGrace;
        } catch {
            return false;
        }
    }

    /// @notice Validated conversion inputs for receipt reconciliation at an explicit block.
    function validatedPrices() external view returns (bool valid, uint256 eth, uint256 usdc) {
        if (!_sequencerUp()) return (false, 0, 0);
        eth = _price(ethUSD, 100e18, 100000e18, config.maxPriceAge);
        usdc = _price(usdcUSD, 0.8e18, 1.2e18, config.usdcMaxPriceAge);
        valid = eth > 0 && usdc > 0;
    }

    function estimate(
        address strategy,
        Action[] memory actions,
        uint8 actionsPerTx,
        bool includePreparation
    ) external view returns (Quote memory q) {
        if (actionsPerTx == 0 || actionsPerTx > 10 || strategy.code.length == 0) revert InvalidPlan();
        IMeasurements measurements = IMeasurements(strategy);
        if (actions.length == 0 || actions.length > 10) revert InvalidPlan();
        q.actionsHash = keccak256(
            abi.encode(
                block.chainid, address(measurements), actions, actionsPerTx, includePreparation
            )
        );
        q.costUSDC = config.fallbackUSDC;
        uint256 steps = (actions.length + actionsPerTx - 1) / actionsPerTx;
        q.txCount = (includePreparation ? 1 : 0) + steps;
        PathOverhead memory p = pathOverhead;
        q.l2Gas = (includePreparation ? uint256(p.preparation == 0 ? config.prepareGas : p.preparation) : 0)
            + q.txCount * config.intrinsicGas + (p.finalization == 0 ? config.finalizeGas : p.finalization);
        for (uint256 start; start < actions.length; start += actionsPerTx) {
            bool deposits; bool withdrawals;
            uint256 end = Math.min(start + actionsPerTx, actions.length);
            for (uint256 j = start; j < end; ++j) {
                if (actions[j].deposit) deposits = true; else withdrawals = true;
            }
            uint32 overhead = deposits && withdrawals ? p.mixedStep : deposits ? p.depositStep : p.withdrawalStep;
            q.l2Gas += overhead == 0 ? config.stepGas : overhead;
        }
        for (uint256 i; i < actions.length; i++) {
            Action memory a = actions[i];
            if (a.adapter == address(0) || a.amount == 0) revert InvalidPlan();
            uint256 sample;
            if (a.deposit) {
                try measurements.emaDepositGas(a.adapter) returns (uint64 v) {
                    sample = v;
                } catch {}
            } else {
                try measurements.emaWithdrawGas(a.adapter) returns (uint64 v) {
                    sample = v;
                } catch {}
            }
            uint256 floor = a.deposit ? depositFloor[a.adapter] : withdrawFloor[a.adapter];
            if (floor == 0) {
                floor = a.deposit ? config.defaultDepositGas : config.defaultWithdrawGas;
            }
            // Reliable EMA is primary, even below the cold-start default.
            if (!_sampleReliable(measurements, a, sample)) {
                sample = floor;
                q.usedDefaults = true;
            }
            q.l2Gas += sample;
        }
        if (!_sequencerUp()) return q;
        uint256 eth = _price(ethUSD, 100e18, 100000e18, config.maxPriceAge);
        uint256 usdc = _price(usdcUSD, 0.8e18, 1.2e18, config.usdcMaxPriceAge);
        if (eth == 0 || usdc == 0) return q;
        try feeInfo.getPricesInWei() returns (
            uint256 perTx, uint256 perByte, uint256, uint256, uint256, uint256 l2Price
        ) {
            // Operational bounds prevent overflow/unusable estimates; no clipping downward.
            if (
                l2Price == 0 || perByte == 0 || l2Price > 1000 gwei || perByte > 1e15
                    || perTx > 1 ether
            ) return q;
            // eth_call usually supplies zero; on-chain include any higher transaction gas price.
            uint256 executionPrice = tx.gasprice > l2Price ? tx.gasprice : l2Price;
            if (executionPrice > 1000 gwei) return q;
            q.executionWei = q.l2Gas * executionPrice;
            // Dynamic poster pricing × uncompressed wrapper bytes + per-tx charge.
            // Compression/serialization must be calibrated against NodeInterface off-chain.
            q.posterWei = q.txCount * (perTx + uint256(config.calldataBytes) * perByte);
            uint256 usdWei = Math.mulDiv(q.executionWei + q.posterWei, eth, usdc, Math.Rounding.Up);
            uint256 usdc6 = Math.ceilDiv(usdWei, 1e12);
            q.costUSDC = Math.mulDiv(usdc6, 10000 + config.marginBps, 10000, Math.Rounding.Up);
            q.reliable = true;
        } catch {}
    }
}
