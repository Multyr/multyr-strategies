// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IFeeInfo {
    function getPricesInWei() external view returns (uint256, uint256, uint256, uint256, uint256, uint256);
}

interface IFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IMeasurements {
    function emaDepositGas(address) external view returns (uint64);
    function emaWithdrawGas(address) external view returns (uint64);
}

/// @notice EXPERIMENTAL: no storage writes, no deployment authorization.
/// @dev Cost model, not an RPC simulator or a proven upper bound on Nitro fees.
contract ReadOnlyGasEstimator {
    struct Action {
        address adapter;
        uint256 amount;
        bool deposit;
    }

    struct Config {
        uint32 prepareGas; // excluding adapter calls, including estimator overhead
        uint32 stepGas; // per execution transaction, excluding adapter calls
        uint32 defaultDepositGas;
        uint32 defaultWithdrawGas;
        uint32 intrinsicGas; // L2-only; NOT eth_estimateGas, which includes poster fees
        uint16 actionsPerTx;
        uint16 calldataBytes; // exact wrapper calldata length for this prototype
        uint16 marginBps;
        uint32 maxPriceAge;
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
    IMeasurements public immutable measurements;
    IFeeInfo public immutable feeInfo;
    IFeed public immutable ethUSD;
    IFeed public immutable usdcUSD;
    IFeed public immutable sequencer;
    Config public config;
    address public immutable calibrator;
    mapping(address => uint32) public depositFloor;
    mapping(address => uint32) public withdrawFloor;
    event AdapterFloorsSet(address indexed adapter, uint32 depositGas, uint32 withdrawGas);

    /// @dev Calibration/governance change, NOT a per-rebalance quote publication.
    function setAdapterFloors(address adapter, uint32 depositGas, uint32 withdrawGas) external {
        require(msg.sender == calibrator, "unauthorized");
        require(adapter != address(0) && depositGas >= 21000 && withdrawGas >= 21000, "invalid floor");
        depositFloor[adapter] = depositGas;
        withdrawFloor[adapter] = withdrawGas;
        emit AdapterFloorsSet(adapter, depositGas, withdrawGas);
    }
    error InvalidConfig();
    error InvalidPlan();

    constructor(IMeasurements m, IFeeInfo f, IFeed e, IFeed u, IFeed s, Config memory c) {
        if (
            c.actionsPerTx == 0 || c.actionsPerTx > 10 || c.marginBps < 1000 || c.marginBps > 10000 || c.prepareGas == 0
                || c.stepGas == 0 || c.defaultDepositGas == 0 || c.defaultWithdrawGas == 0 || c.maxPriceAge == 0
                || c.fallbackUSDC == 0 || c.intrinsicGas < 21000 || c.calldataBytes < 4
        ) revert InvalidConfig();
        calibrator = msg.sender;
        measurements = m;
        feeInfo = f;
        ethUSD = e;
        usdcUSD = u;
        sequencer = s;
        config = c;
    }

    // Validated USD price in 18 decimals; conservative operational sanity bands.
    function _price(IFeed feed, uint256 low, uint256 high) internal view returns (uint256) {
        try feed.decimals() returns (uint8 d) {
            if (d > 18) return 0;
            try feed.latestRoundData() returns (
                uint80 round, int256 answer, uint256, uint256 updated, uint80 answered
            ) {
                if (
                    answer <= 0 || round == 0 || answered < round || updated == 0 || updated > block.timestamp
                        || block.timestamp - updated > config.maxPriceAge
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
        try sequencer.latestRoundData() returns (uint80, int256 answer, uint256 started, uint256, uint80) {
            return answer == 0 && started != 0 && started <= block.timestamp
                && block.timestamp - started > config.sequencerGrace;
        } catch {
            return false;
        }
    }

    function estimate(Action[] memory actions) external view returns (Quote memory q) {
        if (actions.length == 0 || actions.length > 10) revert InvalidPlan();
        q.actionsHash = keccak256(abi.encode(block.chainid, address(measurements), actions, config.actionsPerTx));
        q.costUSDC = config.fallbackUSDC;
        q.txCount = 1 + (actions.length + config.actionsPerTx - 1) / config.actionsPerTx;
        q.l2Gas = uint256(config.prepareGas) + (q.txCount - 1) * config.stepGas + q.txCount * config.intrinsicGas;
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
            if (floor == 0) floor = a.deposit ? config.defaultDepositGas : config.defaultWithdrawGas;
            // A small or missing EMA cannot drag the estimate below the tested floor.
            if (sample < floor) {
                sample = floor;
                q.usedDefaults = true;
            }
            q.l2Gas += sample;
        }
        if (!_sequencerUp()) return q;
        uint256 eth = _price(ethUSD, 100e18, 100000e18);
        uint256 usdc = _price(usdcUSD, 0.8e18, 1.2e18);
        if (eth == 0 || usdc == 0) return q;
        try feeInfo.getPricesInWei() returns (
            uint256 perTx, uint256 perByte, uint256, uint256, uint256, uint256 l2Price
        ) {
            // Operational bounds prevent overflow/unusable estimates; no clipping downward.
            if (l2Price == 0 || l2Price > 1000 gwei || perByte > 1e15 || perTx > 1 ether) return q;
            q.executionWei = q.l2Gas * l2Price;
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
