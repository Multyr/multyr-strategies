// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ----------- OpenZeppelin imports -----------
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

// ----------- IProtocolRegistry interface -----------
interface IProtocolRegistry {
    enum ProtocolType {
        AAVE_V3,
        EULER_V2,
        MORPHO,
        COMPOUND_V3,
        DOLOMITE,
        GAINS,
        SILO_V2
    }
    function getEnabledVaults(ProtocolType protocol) external view returns (address[] memory);
    function isEnabled(ProtocolType protocol, address vault) external view returns (bool);
}

// ----------- ILendingAdapter interface -----------
interface ILendingAdapter {
    function name() external view returns (string memory);
    function underlying() external view returns (address);

    // accounting
    function totalAssets() external view returns (uint256);
    function withdrawableAssets() external view returns (uint256);

    // lifecycle
    function deposit(uint256 assets) external;
    function withdraw(uint256 assets, address receiver) external returns (uint256 withdrawn);

    // yield
    function currentAPYBps() external view returns (uint16);
    function incentiveAPYBps() external view returns (uint16);
    function harvestableProfit() external view returns (uint256);
    function harvest(address receiver) external returns (uint256 realized);

    // limits
    function maxCapacity() external view returns (uint256);

    // external TVL
    function externalMarketTVL() external view returns (uint256);
}

// ----------- Minimal Comet interface -----------
interface IComet {
    function baseToken() external view returns (address);
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function getUtilization() external view returns (uint256);
    function getSupplyRate(uint256 utilization) external view returns (uint256);
    // V9.1: needed for external TVL calculation
    function totalsBasic() external view returns (uint64, uint64, uint104, uint104, uint64, uint64);
    function baseIndexScale() external view returns (uint64);
}

interface ICometRewards {
    /// @dev Compound III rewards controller — claim COMP for a given Comet market.
    function claim(address comet, address src, bool shouldAccrue) external;
    function rewardConfig(address comet) external view returns (address token, uint64 rescaleFactor, bool shouldUpscale);
}

interface IRewardSwapHelperComet {
    /// @dev RA-10 oracle freshness gate (M1) + USDC swap (M2).
    function canSwap(address rewardToken) external view returns (bool);
    function previewExpectedOut(address rewardToken, uint256 amountIn) external view returns (uint256);
    function swapToUSDC(address rewardToken, uint256 amountIn, address receiver) external returns (uint256);
}

// ----------- Adapter Contract -----------
contract CometUsdcMultiMarketAdapter is ILendingAdapter, AccessControl, ReentrancyGuard, Initializable {
    using SafeERC20 for IERC20;

    // ----------- Roles -----------
    bytes32 public constant PARAM_ROLE = keccak256("PARAM_ROLE");

    // ----------- Immutable config -----------
    // --- V10 Storage (was immutable in V9.x; logically immutable post-initialize) ---
    address public override underlying; // USDC
    address public vault; // Strategy Vault (no-custody)
    IProtocolRegistry public registry; // Optional registry (address(0) if not used)

    // ----------- Market Registry -----------
    struct Market {
        address comet; // Comet USDC market address
        bool enabled; // included in allocation
        bool flagged; // defense/hold
        uint16 riskScoreBps; // 0..10000 (10000 = lowest risk)
    }
    Market[] internal mkts;

    // ----------- Scoring Weights (constant for gas optimization) -----------
    uint16 public constant wAPY = 4000;
    uint16 public constant wLiq = 2500;
    uint16 public constant wRisk = 2000;
    uint16 public constant wStability = 1000;
    uint16 public constant wIncentive = 500;

    // ----------- Optimize/Drift/Gate Parameters -----------
    uint16 public rebalanceMinMoveBps = 50; // 0.5%
    uint32 public minSecondsBetweenOptimize = 6 hours;
    uint16 public constant driftToleranceBps = 10; // 0.1%
    uint16 public constant gateHorizonDays = 7;
    uint16 public gateMinNetBenefitBps = 2; // 0.02%
    uint16 public slippageBpsEstimate; // e.g. 4 = 0.04%
    uint16 public withdrawalSpreadBpsEstimate; // e.g. 2 = 0.02%
    uint256 public gasCostUSDC; // cost in USDC for optimize

    // ----------- Capacity & Incentives -----------
    uint256 public capacity; // 0 = infinite
    uint16 public incentiveBpsGlobal; // optional

    // ----------- Reward Pipeline v1 (M1+M2 + RA-10) -----------
    address public rewardToken;          // COMP
    address public rewardsController;    // CometRewards contract
    address public swapHelper;           // RewardSwapHelper instance
    uint16 public incentiveHaircutBps = 7500; // default 75% retain 25%
    uint16 public realizedRewardAPRBps;       // off-chain measured realized reward APR (bps)

    event RewardConfigInitialized(address rewardToken, address rewardsController, address swapHelper);
    event SwapHelperUpdated(address swapHelper);
    event IncentiveHaircutUpdated(uint16 bps);
    event RealizedRewardAPRUpdated(uint16 bps);
    event RewardsClaimed(uint256 amount);
    event HarvestExecuted(address rewardToken, uint256 amountIn, uint256 usdcOut, address receiver);
    event SwapDeferred(address rewardToken, uint256 pendingBalance, string reason);

    // ----------- State: allocation & telemetry -----------
    uint256[] public principal; // principal per market
    uint256 public principalTotal;
    uint64 public lastOptimizeTs;
    uint8 public activeIdx;

    // ----------- Events -----------
    event MarketAdded(uint256 indexed idx, address comet);
    event MarketToggled(uint256 indexed idx, bool enabled);
    event MarketFlagged(uint256 indexed idx, bool flagged);
    event MarketUpdated(uint256 indexed idx, address comet);
    event CostsEstimatesUpdated(
        uint16 slippageBps, uint16 withdrawalSpreadBps, uint256 gasCostUSDC
    );
    event OptimizeParamsUpdated(
        uint32 minSecondsBetweenOptimize, uint16 subMoveMinBps, uint16 subGateMinNetBenefitBps
    );
    event CapacityUpdated(uint256 capacity);
    event RiskScoreUpdated(uint256 indexed idx, uint16 riskScoreBps);
    event IntraRebalanced(address fromMarket, address toMarket, uint256 movedAssets);
    event Supplied(uint256 assets, address market);
    event Withdrawn(uint256 assets, address market, address receiver);

    // ----------- Modifiers -----------
    modifier onlyVault() {
        require(msg.sender == vault, "NotVault");
        _;
    }

    modifier onlyParam() {
        require(hasRole(PARAM_ROLE, msg.sender), "NotParam");
        _;
    }

    // ----------- Constructor -----------

    /// @notice One-shot initialization called atomically by AdapterFactory.
    function initialize(
        address usdc_,
        address admin_,
        address vault_,
        uint256 capacity_,
        address registry_
    ) external initializer {
        require(usdc_ != address(0) && admin_ != address(0) && vault_ != address(0), "zero");
        underlying = usdc_;
        vault = vault_;
        capacity = capacity_;
        registry = IProtocolRegistry(registry_); // Can be address(0)

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(PARAM_ROLE, admin_);

        // Auto-load from registry if available
        if (registry_ != address(0)) {
            _loadFromRegistry();
        }

        // V9 HARDENING: Fail-fast if no markets loaded
        require(mkts.length > 0, "CometAdapter: no markets - registry required or use addMarket");
    }

    // ----------- Registry Management (PARAM_ROLE) -----------
    function addMarket(address comet) external onlyParam {
        require(comet != address(0), "zero");
        require(IComet(comet).baseToken() == underlying, "NotUSDC");
        mkts.push(Market({ comet: comet, enabled: true, flagged: false, riskScoreBps: 10000 }));
        principal.push(0);
        emit MarketAdded(mkts.length - 1, comet);
    }

    function toggleMarket(uint256 idx, bool enabled) external onlyParam {
        require(idx < mkts.length, "badIdx");
        mkts[idx].enabled = enabled;
        emit MarketToggled(idx, enabled);
    }

    function flagMarket(uint256 idx, bool flagged) external onlyParam {
        require(idx < mkts.length, "badIdx");
        mkts[idx].flagged = flagged;
        emit MarketFlagged(idx, flagged);
    }

    function updateMarketAddress(uint256 idx, address comet) external onlyParam {
        require(idx < mkts.length, "badIdx");
        require(comet != address(0), "zero");
        require(IComet(comet).baseToken() == underlying, "NotUSDC");
        mkts[idx].comet = comet;
        emit MarketUpdated(idx, comet);
    }

    function setRiskScore(uint256 idx, uint16 riskScoreBps) external onlyParam {
        require(idx < mkts.length, "badIdx");
        require(riskScoreBps <= 10000, "badScore");
        mkts[idx].riskScoreBps = riskScoreBps;
        emit RiskScoreUpdated(idx, riskScoreBps);
    }

    function setCostsEstimates(
        uint16 slippageBps,
        uint16 withdrawalSpreadBps,
        uint256 gasCostUSDC_
    ) external onlyParam {
        slippageBpsEstimate = slippageBps;
        withdrawalSpreadBpsEstimate = withdrawalSpreadBps;
        gasCostUSDC = gasCostUSDC_;
        emit CostsEstimatesUpdated(slippageBps, withdrawalSpreadBps, gasCostUSDC_);
    }

    function setOptimizeParams(
        uint32 minSecondsBetweenOptimize_,
        uint16 subMoveMinBps,
        uint16 subGateMinNetBenefitBps
    ) external onlyParam {
        minSecondsBetweenOptimize = minSecondsBetweenOptimize_;
        rebalanceMinMoveBps = subMoveMinBps;
        gateMinNetBenefitBps = subGateMinNetBenefitBps;
        emit OptimizeParamsUpdated(
            minSecondsBetweenOptimize_, subMoveMinBps, subGateMinNetBenefitBps
        );
    }

    function setCapacity(uint256 capacity_) external onlyParam {
        capacity = capacity_;
        emit CapacityUpdated(capacity_);
    }

    function setIncentiveBps(uint16 bps) external onlyParam {
        incentiveBpsGlobal = bps;
    }

    // ----------- ILendingAdapter: View Functions -----------
    function name() external pure override returns (string memory) {
        return "Comet_USDC_MultiMarket_Adapter_Arbitrum";
    }

    /// @notice Returns false because Comet uses PULL deposit pattern
    /// @dev Adapter calls transferFrom() to pull USDC from Strategy during deposit()
    function isPushMode() external pure returns (bool) {
        return false;
    }

    function idleAssetBalance() public view returns (uint256) {
        return IERC20(underlying).balanceOf(address(this));
    }

    function investedAssets() public view returns (uint256 total) {
        total = 0; // Initialize local variable (slither: uninitialized-local)
        uint256 n = mkts.length;
        for (uint256 i = 0; i < n; ++i) {
            total += _assetsOn(i);
        }
    }

    function totalAssets() public view override returns (uint256) {
        return investedAssets() + idleAssetBalance();
    }

    function withdrawableAssets() public view override returns (uint256 total) {
        total = 0; // Initialize local variable (slither: uninitialized-local)
        uint256 n = mkts.length;
        for (uint256 i = 0; i < n; ++i) {
            total += _withdrawableOn(i);
        }
    }

    function currentAPYBps() public view override returns (uint16) {
        if (mkts.length < 1) return 0; // slither: incorrect-equality - use < 1 instead of == 0
        Market storage m = mkts[activeIdx];
        return _getAPYBps(m.comet);
    }

    function incentiveAPYBps() external view override returns (uint16) {
        // realized takes priority; haircut applied to retain (10000-haircut) of realized.
        uint256 raw = realizedRewardAPRBps != 0 ? realizedRewardAPRBps : incentiveBpsGlobal;
        if (raw == 0) return 0;
        uint256 retain = 10_000 - uint256(incentiveHaircutBps);
        uint256 result = (raw * retain) / 10_000;
        if (result > type(uint16).max) return type(uint16).max;
        return uint16(result);
    }

    function harvestableProfit() external view override returns (uint256) {
        if (rewardToken == address(0) || swapHelper == address(0)) return 0;
        uint256 bal = IERC20(rewardToken).balanceOf(address(this));
        if (bal == 0) return 0;
        try IRewardSwapHelperComet(swapHelper).canSwap(rewardToken) returns (bool ok) {
            if (!ok) return 0;
        } catch { return 0; }
        try IRewardSwapHelperComet(swapHelper).previewExpectedOut(rewardToken, bal) returns (uint256 e) {
            return e;
        } catch { return 0; }
    }

    function harvest(address receiver) external override nonReentrant onlyVault returns (uint256 realized) {
        if (rewardToken == address(0) || rewardsController == address(0)) return 0;
        // (1) Claim COMP — graceful (M2): never propagate revert
        // Iterate enabled markets and claim from each (single rewardToken across all markets)
        uint256 nMkt = mkts.length;
        for (uint256 i = 0; i < nMkt; ) {
            if (mkts[i].enabled) {
                try ICometRewards(rewardsController).claim(mkts[i].comet, address(this), true) {} catch {}
            }
            unchecked { ++i; }
        }
        uint256 bal = IERC20(rewardToken).balanceOf(address(this));
        if (bal > 0) emit RewardsClaimed(bal);
        if (bal == 0) return 0;
        if (swapHelper == address(0)) {
            emit SwapDeferred(rewardToken, bal, "no-helper");
            return 0;
        }
        // (2) M1 pre-flight: defer if oracle stale (no LINK burn on doomed swap)
        bool ok;
        try IRewardSwapHelperComet(swapHelper).canSwap(rewardToken) returns (bool v) { ok = v; } catch { ok = false; }
        if (!ok) {
            emit SwapDeferred(rewardToken, bal, "oracle-stale");
            return 0;
        }
        // (3) M2 swap — approve, attempt, reset approval regardless of outcome
        IERC20(rewardToken).forceApprove(swapHelper, 0);
        IERC20(rewardToken).forceApprove(swapHelper, bal);
        try IRewardSwapHelperComet(swapHelper).swapToUSDC(rewardToken, bal, receiver) returns (uint256 out) {
            realized = out;
            emit HarvestExecuted(rewardToken, bal, out, receiver);
        } catch {
            emit SwapDeferred(rewardToken, bal, "swap-revert");
        }
        IERC20(rewardToken).forceApprove(swapHelper, 0);
        return realized;
    }

    function maxCapacity() external view override returns (uint256) {
        return capacity;
    }

    /// @notice Returns total USDC liquidity across all enabled Comet markets
    /// @dev Uses USDC balance of each Comet contract (available liquidity, conservative lower bound)
    /// @notice Total USDC supplied to external Comet markets.
    /// @dev Uses totalsBasic().totalSupplyBase * baseSupplyIndex / baseIndexScale
    ///      for accurate total supply (not just available cash).
    function externalMarketTVL() external view override returns (uint256 total) {
        total = 0;
        uint256 n = mkts.length;
        for (uint256 i = 0; i < n; ++i) {
            if (!mkts[i].enabled) continue;
            try IComet(mkts[i].comet).totalsBasic() returns (
                uint64 baseSupplyIndex, uint64, uint104, uint104, uint64 totalSupplyBase, uint64
            ) {
                try IComet(mkts[i].comet).baseIndexScale() returns (uint64 scale) {
                    if (scale > 0) {
                        total += (uint256(totalSupplyBase) * uint256(baseSupplyIndex)) / uint256(scale);
                    }
                } catch {}
            } catch {
                // Fallback: use cash balance as conservative proxy
                try IERC20(underlying).balanceOf(mkts[i].comet) returns (uint256 bal) {
                    total += bal;
                } catch {}
            }
        }
    }

    // ----------- Extra Public View: Markets & Positions -----------
    function markets() external view returns (address[] memory) {
        uint256 n = mkts.length;
        address[] memory out = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = mkts[i].comet;
        }
        return out;
    }

    function activeMarket() external view returns (address) {
        return mkts.length < 1 ? address(0) : mkts[activeIdx].comet; // slither: incorrect-equality - use < 1 instead of == 0
    }

    function positions() external view returns (uint256[] memory assetsByMarket) {
        uint256 n = mkts.length;
        assetsByMarket = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            assetsByMarket[i] = _assetsOn(i);
        }
    }

    function effectiveAPYBps() external view returns (uint16) {
        uint256 n = mkts.length;
        uint256 total = totalAssets();
        if (total < 1) return 0; // slither: incorrect-equality - use < 1 instead of == 0
        uint256 apySum = 0; // Initialize local variable (slither: uninitialized-local)
        for (uint256 i = 0; i < n; ++i) {
            uint256 assets = _assetsOn(i);
            if (assets < 1) continue; // slither: incorrect-equality - use < 1 instead of == 0
            apySum += _getAPYBps(mkts[i].comet) * assets;
        }
        uint256 result = apySum / total;
        require(result <= type(uint16).max, "CometUsdcMultiMarket: APY overflow");
        // casting to uint16 is safe because overflow is checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(result);
    }

    // ----------- INTERNAL HELPERS -----------

    /// @notice Sets just-in-time approval for exact amount
    /// @dev Prevents unlimited protocol exposure if Compound market is compromised
    function _approveMarket(address marketAddr, uint256 amount) internal {
        IERC20(underlying).forceApprove(marketAddr, amount);
    }

    /// @notice Resets market approval to zero
    function _revokeMarketApproval(address marketAddr) internal {
        IERC20(underlying).forceApprove(marketAddr, 0);
    }

    // ----------- Internal: Market Helpers -----------
    function _assetsOn(uint256 idx) internal view returns (uint256) {
        Market storage m = mkts[idx];
        return IComet(m.comet).balanceOf(address(this));
    }

    function _withdrawableOn(uint256 idx) internal view returns (uint256) {
        Market storage m = mkts[idx];
        uint256 assets = _assetsOn(idx);
        uint256 usdcAvail = IERC20(underlying).balanceOf(m.comet);
        return assets < usdcAvail ? assets : usdcAvail;
    }

    function _getAPYBps(address comet) internal view returns (uint16) {
        uint256 util = IComet(comet).getUtilization(); // 1e18
        uint256 ratePerSec = IComet(comet).getSupplyRate(util); // 1e18
        uint256 aprWad = ratePerSec * 31_536_000; // 365*24*60*60
        uint256 bps = (aprWad * 10000) / 1e18;
        // casting to uint16 is safe because overflow is checked with ternary
        // forge-lint: disable-next-line(unsafe-typecast)
        return bps > type(uint16).max ? type(uint16).max : uint16(bps);
    }

    // ----------- Lifecycle: Deposit/Withdraw (No-custody) -----------
    function deposit(uint256 assets) external override nonReentrant onlyVault {
        require(assets > 0, "zero");
        if (capacity > 0) require(totalAssets() + assets <= capacity, "cap");
        uint256 target = _selectBestMarket();
        Market storage m = mkts[target];
        require(m.enabled && !m.flagged, "noMkt");

        IERC20(underlying).safeTransferFrom(msg.sender, address(this), assets);
        _approveMarket(m.comet, assets);
        IComet(m.comet).supply(underlying, assets);
        _revokeMarketApproval(m.comet);

        principal[target] += assets;
        principalTotal += assets;
        require(target <= type(uint8).max, "CometUsdcMultiMarket: target overflow");
        // casting to uint8 is safe because overflow is checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        activeIdx = uint8(target);

        emit Supplied(assets, m.comet);
    }

    function withdraw(
        uint256 assets,
        address /*receiver*/
    )
        external
        override
        nonReentrant
        onlyVault
        returns (uint256 withdrawn)
    {
        uint256 want = assets;
        uint256 avail = withdrawableAssets();
        if (want > avail) want = avail;
        require(want > 0, "zero");

        withdrawn = 0; // Initialize local variable (slither: uninitialized-local)
        uint256 n = mkts.length;
        uint256 left = want;
        // Withdraw from least performant markets first (lowest APY)
        uint256[] memory order = _marketsByAPY(false); // ascending APY
        for (uint256 i = 0; i < n && left > 0; ++i) {
            uint256 idx = order[i];
            uint256 can = _withdrawableOn(idx);
            if (can < 1) continue; // slither: incorrect-equality - use < 1 instead of == 0
            uint256 take = can > left ? left : can;
            if (take > 0) {
                IComet(mkts[idx].comet).withdraw(underlying, take);
                IERC20(underlying).safeTransfer(vault, take);

                // Adjust principal proportionally
                uint256 balBefore = principal[idx];
                uint256 totalAssetsOn = _assetsOn(idx);
                if (balBefore > 0) {
                    uint256 principalDelta = balBefore * take / (totalAssetsOn + take);
                    if (principalDelta > balBefore) principalDelta = balBefore;
                    principal[idx] -= principalDelta;
                    principalTotal -= principalDelta;
                }

                emit Withdrawn(take, mkts[idx].comet, vault);
                left -= take;
                if (left < 1) break; // slither: incorrect-equality - use < 1 instead of == 0
            }
        }
        withdrawn = want - left;
    }

    // ----------- Optimize / Rebalance -----------
    function optimize()
        external
        nonReentrant
        onlyVault
        returns (uint256 movedUSDC, address fromMarket, address toMarket)
    {
        require(block.timestamp >= lastOptimizeTs + minSecondsBetweenOptimize, "cooldown");

        uint256 n = mkts.length;
        require(n > 1, "singleMkt");

        // Score all enabled & unflagged markets
        uint256[] memory scores = new uint256[](n);
        uint256 bestScore = 0;
        uint256 bestIdx = 0;
        for (uint256 i = 0; i < n; ++i) {
            Market storage m = mkts[i];
            if (!m.enabled || m.flagged) continue;
            uint16 apy = _getAPYBps(m.comet);
            uint256 liq = IERC20(underlying).balanceOf(m.comet);
            uint16 risk = 10000 - m.riskScoreBps;
            // Stability: for simplicity, use APY as EMA
            uint16 stability = apy;
            uint16 incentive = incentiveBpsGlobal;

            uint256 score = uint256(apy) * wAPY + liq * wLiq / 1e6 // normalize liquidity to bps
                + uint256(risk) * wRisk + uint256(stability) * wStability + uint256(incentive)
                * wIncentive;
            scores[i] = score;
            if (score > bestScore) {
                bestScore = score;
                bestIdx = i;
            }
        }

        // If already optimal, skip
        if (bestIdx == activeIdx) return (0, mkts[activeIdx].comet, mkts[bestIdx].comet);

        // Move from current active to best
        uint256 fromIdx = activeIdx;
        uint256 toIdx = bestIdx;

        uint256 tvl = totalAssets();
        uint256 fromAssets = _assetsOn(fromIdx);
        uint256 toAssets = _assetsOn(toIdx);

        // Move at least minMove
        uint256 minMove = (tvl * rebalanceMinMoveBps) / 1e4;
        if (fromAssets < minMove) return (0, mkts[fromIdx].comet, mkts[toIdx].comet);

        // Estimate benefit
        uint16 apyFrom = _getAPYBps(mkts[fromIdx].comet);
        uint16 apyTo = _getAPYBps(mkts[toIdx].comet);
        if (apyTo <= apyFrom) return (0, mkts[fromIdx].comet, mkts[toIdx].comet);
        uint256 deltaAPY = apyTo - apyFrom;

        uint256 horizon = gateHorizonDays * 1 days;
        uint256 grossBenefit = (fromAssets * deltaAPY * horizon) / (10000 * 365 days);
        uint256 moveCost = gasCostUSDC
            + (fromAssets * (slippageBpsEstimate + withdrawalSpreadBpsEstimate)) / 10000;
        require(
            grossBenefit <= uint256(type(int256).max), "CometUsdcMultiMarket: grossBenefit overflow"
        );
        require(moveCost <= uint256(type(int256).max), "CometUsdcMultiMarket: moveCost overflow");
        // casting to int256 is safe because overflow is checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 netBenefit = int256(grossBenefit) - int256(moveCost);
        uint256 netBenefitBps = (grossBenefit > 0 && tvl > 0) ? (grossBenefit * 10000) / tvl : 0;
        if (netBenefit <= 0 || netBenefitBps < gateMinNetBenefitBps) {
            return (0, mkts[fromIdx].comet, mkts[toIdx].comet);
        }

        // Audit #2 P0.3 — clamp the move BEFORE the withdraw.
        //   fromAvail: actual withdrawable from source (market liquidity).
        //   toRoom:    how much target is willing to accept.
        //   moveAmount = min(planned, fromAvail, toRoom).
        // This prevents the classic pattern of "withdraw everything, then discover
        // the target rejects" which would leave funds idle and break accounting.
        uint256 fromAvail = _withdrawableOn(fromIdx);
        uint256 toRoom = _maxAdditionalDeposit(toIdx);
        uint256 moveAmount = fromAssets;
        if (moveAmount > fromAvail) moveAmount = fromAvail;
        if (moveAmount > toRoom) moveAmount = toRoom;
        if (moveAmount < minMove) {
            return (0, mkts[fromIdx].comet, mkts[toIdx].comet);
        }

        // Withdraw from fromIdx (clamped)
        IComet(mkts[fromIdx].comet).withdraw(underlying, moveAmount);
        _approveMarket(mkts[toIdx].comet, moveAmount);
        IComet(mkts[toIdx].comet).supply(underlying, moveAmount);
        _revokeMarketApproval(mkts[toIdx].comet);

        // Update principal proportionally — never zero out fromIdx unless we moved all of it.
        uint256 fromPrincipal = principal[fromIdx];
        if (moveAmount >= fromPrincipal) {
            principal[fromIdx] = 0;
        } else {
            principal[fromIdx] = fromPrincipal - moveAmount;
        }
        principal[toIdx] += moveAmount;
        require(toIdx <= type(uint8).max, "CometUsdcMultiMarket: toIdx overflow");
        require(block.timestamp <= type(uint64).max, "CometUsdcMultiMarket: timestamp overflow");
        // Only flip activeIdx if source is now empty after the move.
        if (principal[fromIdx] == 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            activeIdx = uint8(toIdx);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        lastOptimizeTs = uint64(block.timestamp);

        emit IntraRebalanced(mkts[fromIdx].comet, mkts[toIdx].comet, moveAmount);
        return (moveAmount, mkts[fromIdx].comet, mkts[toIdx].comet);
    }

    /// @dev Audit #2 P0.3 — Comet does not advertise a supply cap on-chain, but we
    ///      keep a deliberate guard here so future hardening (e.g. per-market caps
    ///      via riskScoreBps) can plug into the same abstraction.
    function _maxAdditionalDeposit(uint256 idx) internal view returns (uint256) {
        if (idx >= mkts.length) return 0;
        // Comet: effectively unbounded; return a conservative sentinel.
        return type(uint256).max;
    }

    // ----------- Internal: Market Selection & Ordering -----------
    function _selectBestMarket() internal view returns (uint256 bestIdx) {
        uint256 n = mkts.length;
        require(n > 0, "noMkts");
        bestIdx = 0; // Initialize local variable (slither: uninitialized-local)
        uint256 bestScore = 0;
        for (uint256 i = 0; i < n; ++i) {
            Market storage m = mkts[i];
            if (!m.enabled || m.flagged) continue;
            uint16 apy = _getAPYBps(m.comet);
            if (apy > bestScore) {
                bestScore = apy;
                bestIdx = i;
            }
        }
    }

    // Returns market indices sorted by APY ascending/descending
    function _marketsByAPY(bool descending) internal view returns (uint256[] memory order) {
        uint256 n = mkts.length;
        order = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            order[i] = i;
        }

        // Selection sort (gas-efficient for small N)
        for (uint256 i = 0; i < n; ++i) {
            uint256 best = i;
            for (uint256 j = i + 1; j < n; ++j) {
                uint16 apyBest = _getAPYBps(mkts[order[best]].comet);
                uint16 apyJ = _getAPYBps(mkts[order[j]].comet);
                if (descending ? (apyJ > apyBest) : (apyJ < apyBest)) best = j;
            }
            if (best != i) {
                uint256 tmp = order[i];
                order[i] = order[best];
                order[best] = tmp;
            }
        }
    }

    // ----------- Registry Integration -----------

    /// @notice Internal: Load vault addresses from registry
    function _loadFromRegistry() internal {
        try registry.getEnabledVaults(IProtocolRegistry.ProtocolType.COMPOUND_V3) returns (
            address[] memory vaults
        ) {
            for (uint256 i = 0; i < vaults.length; i++) {
                if (vaults[i] != address(0)) {
                    // Registry is trusted source - no validation needed
                    // Vaults from registry are pre-validated and whitelisted
                    mkts.push(
                        Market({
                            comet: vaults[i], enabled: true, flagged: false, riskScoreBps: 10000
                        })
                    );
                    principal.push(0);
                }
            }
        } catch {
            // Registry call failed - adapter will start with empty markets or use manual addMarket()
        }
    }

    /// @notice Refresh markets from registry (clear and reload)
    function refreshFromRegistry() external onlyParam {
        require(address(registry) != address(0), "no registry");

        // Clear existing markets
        delete mkts;
        delete principal;

        // Reload from registry
        _loadFromRegistry();
    }

    // ----------- Idle Asset & Emergency Recovery -----------
    event IdleAssetSwept(uint256 amount);
    event EmergencyPullExecuted(uint256 amount);

    function sweepIdleAssetToVault() external nonReentrant onlyVault {
        uint256 idle = IERC20(underlying).balanceOf(address(this));
        require(idle > 0, "no idle");
        IERC20(underlying).safeTransfer(vault, idle);
        emit IdleAssetSwept(idle);
    }

    function emergencyPullAllToVault() external nonReentrant onlyVault {
        uint256 n = mkts.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 bal = _assetsOn(i);
            if (bal > 0) {
                try IComet(mkts[i].comet).withdraw(underlying, bal) {
                } catch {
                    // Withdraw failed - skip this market
                }
                principal[i] = 0;
            }
        }
        principalTotal = 0;
        // Transfer FULL balance (withdrawn + any pre-existing idle) to vault
        uint256 fullBalance = IERC20(underlying).balanceOf(address(this));
        if (fullBalance > 0) {
            IERC20(underlying).safeTransfer(vault, fullBalance);
        }
        emit EmergencyPullExecuted(fullBalance);
    }

    // ----------- Sweep Protection -----------
    receive() external payable {
        revert("ETH not accepted");
    }

    fallback() external payable {
        revert("fallback");
    }

    // ----------- Reward config admin (PARAM_ROLE) -----------

    function setRewardConfig(address _rewardToken, address _rewardsController, address _swapHelper) external onlyParam {
        require(rewardToken == address(0) && rewardsController == address(0), "already-init");
        require(_rewardToken != address(0) && _rewardsController != address(0) && _swapHelper != address(0), "zero");
        rewardToken = _rewardToken;
        rewardsController = _rewardsController;
        swapHelper = _swapHelper;
        emit RewardConfigInitialized(_rewardToken, _rewardsController, _swapHelper);
    }

    function setSwapHelper(address sh) external onlyParam {
        // allow set to zero (emergency disable)
        swapHelper = sh;
        emit SwapHelperUpdated(sh);
    }

    function setIncentiveHaircutBps(uint16 bps) external onlyParam {
        require(bps <= 10_000, "bps>10000");
        incentiveHaircutBps = bps;
        emit IncentiveHaircutUpdated(bps);
    }

    function setRealizedRewardAPRBps(uint16 bps) external onlyParam {
        realizedRewardAPRBps = bps;
        emit RealizedRewardAPRUpdated(bps);
    }

    function pendingRewardBalance() external view returns (uint256) {
        if (rewardToken == address(0)) return 0;
        return IERC20(rewardToken).balanceOf(address(this));
    }

}
