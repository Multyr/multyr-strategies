// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// --- OpenZeppelin imports ---
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

// --- Aave v3 minimal interfaces ---
interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    /// @notice FIX P1.L1: Aave V3 ReserveData getter — used as direct on-chain
    ///         fallback in the hybrid rate pattern. Returns currentLiquidityRate
    ///         in ray (1e27) at index 2 of the tuple. `currentLiquidityRate`
    ///         updates only on pool activity (supply/borrow/withdraw/repay),
    ///         so it can be stale on low-activity days; the keeper-pushed cache
    ///         is preferred when fresh, with this as the fallback.
    function getReserveData(address asset) external view returns (
        uint256 configuration,
        uint128 liquidityIndex,
        uint128 currentLiquidityRate,
        uint128 variableBorrowIndex,
        uint128 currentVariableBorrowRate,
        uint128 currentStableBorrowRate,
        uint40 lastUpdateTimestamp,
        uint16 id,
        address aTokenAddress,
        address stableDebtTokenAddress,
        address variableDebtTokenAddress,
        address interestRateStrategyAddress,
        uint128 accruedToTreasury,
        uint128 unbacked,
        uint128 isolationModeTotalDebt
    );
}

interface IAToken {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
    function balanceOf(address user) external view returns (uint256);
}

// --- Optional minimal Rate Provider interface (can wrap Aave Data Provider) ---
interface IAaveRateProvider {
    // Returns current liquidity rate for `asset` in ray (1e27)
    function getLiquidityRateRay(address asset) external view returns (uint256);

    /// @dev FIX P1.L1: rate + timestamp for staleness check (hybrid pattern).
    function getLiquidityRateRayWithTs(address asset) external view returns (uint256 rateRay, uint64 lastUpdateTs);
}

// --- ILendingAdapter interface ---
interface ILendingAdapter {
    function name() external view returns (string memory);
    function underlying() external view returns (address);

    function totalAssets() external view returns (uint256);
    function withdrawableAssets() external view returns (uint256);

    function deposit(uint256 assets) external;
    function withdraw(uint256 assets, address receiver) external returns (uint256 withdrawn);

    function currentAPYBps() external view returns (uint16);
    function incentiveAPYBps() external view returns (uint16);
    function harvestableProfit() external view returns (uint256);
    function harvest(address receiver) external returns (uint256 realized);

    function maxCapacity() external view returns (uint256);
    function externalMarketTVL() external view returns (uint256);
}

// --- Adapter Contract ---
interface IAaveRewardsController {
    function claimRewardsToSelf(address[] calldata assets, uint256 amount, address reward)
        external returns (uint256);
}

interface ISwapHelper {
    function canSwap(address token) external view returns (bool);
    function previewExpectedOut(address token, uint256 amountIn) external view returns (uint256);
    function swapToUSDC(address token, uint256 amountIn, address receiver) external returns (uint256);
}

contract AaveV3USDCAdapter is ILendingAdapter, AccessControl, ReentrancyGuard, Initializable {
    using SafeERC20 for IERC20;

    // --- Roles ---
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    // --- V10 Storage (was immutable in V9.x; logically immutable post-initialize) ---
    // V10 BREAKING CHANGE: storage variables enable byte-identical multi-chain deployment.
    // Set ONCE in initialize() and never reassigned (no setter functions exist).
    address public asset; // USDC token
    IPool public pool; // Aave v3 Pool
    address public aToken; // aUSDC v3
    address public vault; // Authorized Strategy Vault

    // --- Configurable Storage ---
    uint256 public maxCap; // Deposit cap (0 = unlimited)
    uint16 public incentiveBps; // Optional incentive APY in bps
    uint16 public apyOverrideBps; // Optional APY override (bps), 0 = disabled
    address public rateProvider; // Optional external on-chain rate provider

    /// @notice FIX P1.L1: max staleness for keeper-pushed cache. Past this
    ///         threshold, the adapter falls back to direct on-chain read from
    ///         Pool.getReserveData. Default 24h (rateProvider keeper expected
    ///         to poke every 1-6h). Range enforced [1h, 30d] in setter.
    /// @dev OPERATIONAL_AUDIT: heartbeat USDC/USD su Arbitrum e' 86400s (24h).
    ///      Default 90_000s = heartbeat + 1h buffer per evitare cache-miss su edge timing
    ///      (keeper push leggermente in ritardo non triggera fallback inutile a direct read).
    ///      Range [3600s, 30 days] enforced in setMaxRateStalenessSec.
    uint32 public maxRateStalenessSec = 90_000;

    // --- Events ---
    event Supplied(uint256 assets);
    event Withdrawn(uint256 assets, address receiver);
    event MaxCapUpdated(uint256 newCap);
    event IncentiveBpsUpdated(uint16 newBps);
    event APYOverrideUpdated(uint16 newBps);
    event RateProviderUpdated(address provider);
    // ─── Reward pipeline v1 (M1 canSwap gate + M2 graceful) ──────────────
    address public rewardsController;
    address public swapHelper;
    address[] private _rewardTokens;
    mapping(address => bool) public isRewardWhitelisted;
    uint16 public incentiveHaircutBps = 7500; // default 75% retain 25%
    uint16 public realizedRewardAPRBps; // off-chain measured realized reward APR (bps)

    event RewardConfigInitialized(address rewardsController, address swapHelper, address[] tokens);
    event RewardTokenAdded(address indexed token);
    event RewardTokenRemoved(address indexed token);
    event IncentiveHaircutUpdated(uint16 bps);
    event RealizedRewardAPRUpdated(uint16 bps);
    event SwapHelperUpdated(address helper);
    event Harvested(address indexed receiver, uint256 totalRealized);
    /// @dev SLITHER-FIX-1: emit per-token claimed amount captured from claimRewardsToSelf return.
    event RewardClaimed(address indexed token, uint256 amount);

    event MaxRateStalenessUpdated(uint32 secs);

    // --- Modifiers ---
    modifier onlyVault() {
        require(msg.sender == vault, "not vault");
        _;
    }

    // --- V10 Constructor (locked) ---

    // --- V10 Initialization (one-shot, gated by OZ initializer modifier) ---
    /// @notice One-shot initialization called atomically by AdapterFactory.
    /// @dev Reverts on second call via OZ initializer modifier.
    function initialize(
        address asset_,
        address pool_,
        address aToken_,
        address admin_,
        address vault_,
        uint256 maxCap_
    ) external initializer {
        require(
            asset_ != address(0) && pool_ != address(0) && aToken_ != address(0)
                && admin_ != address(0) && vault_ != address(0),
            "zero"
        );
        require(IAToken(aToken_).UNDERLYING_ASSET_ADDRESS() == asset_, "aToken/asset mismatch");
        asset = asset_;
        pool = IPool(pool_);
        aToken = aToken_;
        vault = vault_;
        maxCap = maxCap_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(VAULT_ROLE, vault_);
    }

    // --- ILendingAdapter: Metadata ---
    function name() external pure override returns (string memory) {
        return "AaveV3_USDC_Adapter_Arbitrum";
    }

    /// @notice Returns false because Aave uses PULL deposit pattern
    /// @dev Adapter calls transferFrom() to pull USDC from Strategy during deposit()
    function isPushMode() external pure returns (bool) {
        return false;
    }

    function underlying() external view override returns (address) {
        return asset;
    }

    // --- ILendingAdapter: Accounting ---
    function idleAssetBalance() public view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function investedAssets() public view returns (uint256) {
        // aToken is 1:1 with USDC, grows with interest
        return IAToken(aToken).balanceOf(address(this));
    }

    function totalAssets() public view override returns (uint256) {
        return investedAssets() + idleAssetBalance();
    }

    function withdrawableAssets() public view override returns (uint256) {
        // Conservative: min(aToken balance, pool liquidity).
        // In Aave V3, USDC is held by the aToken contract (not the Pool proxy),
        // so liquidity must be checked against aToken's underlying balance.
        uint256 bal = IAToken(aToken).balanceOf(address(this));
        uint256 liq = IERC20(asset).balanceOf(aToken);
        return bal < liq ? bal : liq;
    }

    // --- ILendingAdapter: Lifecycle ---
    function deposit(uint256 assets) external override nonReentrant onlyVault {
        require(assets > 0, "ZERO_ASSETS");
        if (maxCap > 0) require(totalAssets() + assets <= maxCap, "CAP");

        // Gas: cache `asset`/`pool` locally -- both are set once in
        // initialize() with no setter, so they cannot change mid-call. Avoids
        // repeated warm SLOADs across the transferFrom/approve/supply/revoke
        // sequence below.
        address asset_ = asset;
        IPool pool_ = pool;

        IERC20(asset_).safeTransferFrom(msg.sender, address(this), assets);

        // Just-in-time approval for exact amount (security best practice)
        IERC20(asset_).forceApprove(address(pool_), assets);

        pool_.supply(asset_, assets, address(this), 0);

        // Revoke approval after operation
        IERC20(asset_).forceApprove(address(pool_), 0);

        emit Supplied(assets);
    }

    // Receiver forced: always sends to vault, ignores 'receiver' param
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
        require(assets > 0, "ZERO_ASSETS");
        uint256 want = assets;
        uint256 maxOut = withdrawableAssets();
        if (want > maxOut) want = maxOut;

        address vault_ = vault; // read once, used twice below
        withdrawn = pool.withdraw(asset, want, vault_); // Always to vault
        emit Withdrawn(withdrawn, vault_);
    }

    // --- ILendingAdapter: Yield ---
    /// @notice Returns current supply APY in bps.
    /// @dev FIX P1.L1 (quant audit verified, hybrid pattern A2):
    ///      1) Admin override (apyOverrideBps) — escape hatch
    ///      2) Keeper-pushed cache + staleness check (preferred when fresh)
    ///      3) Direct on-chain read from Pool.getReserveData (fallback)
    ///      4) Return 0 (no source available)
    ///
    ///      The keeper cache is PRIMARY because Aave V3 `currentLiquidityRate`
    ///      updates only on pool activity (lazy). Direct on-chain read is no
    ///      stricter-fresher: it returns the same value last written by activity.
    ///      Hybrid gives best of both: fresh keeper snapshot when available,
    ///      direct fallback when cache stale.
    function currentAPYBps() external view override returns (uint16) {
        // (1) Admin override
        if (apyOverrideBps != 0) return apyOverrideBps;

        // (2) Keeper-pushed cache with staleness check
        if (rateProvider != address(0)) {
            try IAaveRateProvider(rateProvider).getLiquidityRateRayWithTs(asset)
                returns (uint256 rateRay, uint64 ts)
            {
                if (ts > 0 && rateRay > 0) {
                    uint256 age = block.timestamp - uint256(ts);
                    if (age <= uint256(maxRateStalenessSec)) {
                        return _rateRayToBps(rateRay);
                    }
                }
                // Cache stale or empty — fall through to direct read.
            } catch {
                // Provider doesn't support new ABI — fall through.
            }
        }

        // (3) Direct on-chain read fallback
        try IPool(pool).getReserveData(asset) returns (
            uint256, uint128, uint128 currentLiquidityRate,
            uint128, uint128, uint128, uint40, uint16,
            address, address, address, address,
            uint128, uint128, uint128
        ) {
            if (currentLiquidityRate > 0) {
                return _rateRayToBps(uint256(currentLiquidityRate));
            }
        } catch {}

        // (4) No source available
        return 0;
    }

    /// @dev Convert ray (1e27) APR to bps (1e4). bps = rateRay / 1e23.
    function _rateRayToBps(uint256 rateRay) internal pure returns (uint16) {
        uint256 bps = rateRay / 1e23;
        if (bps > type(uint16).max) return type(uint16).max;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(bps);
    }

    function incentiveAPYBps() external view override returns (uint16) {
        // realized takes priority over legacy incentiveBps; haircut applied to retain 25% of realized.
        uint256 raw = realizedRewardAPRBps != 0 ? realizedRewardAPRBps : incentiveBps;
        if (raw == 0) return 0;
        uint256 retain = 10_000 - uint256(incentiveHaircutBps);
        uint256 result = (raw * retain) / 10_000;
        if (result > type(uint16).max) return type(uint16).max;
        return uint16(result);
    }

    function setIncentiveBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        incentiveBps = bps;
        emit IncentiveBpsUpdated(bps);
    }

    function setAPYOverrideBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        apyOverrideBps = bps;
        emit APYOverrideUpdated(bps);
    }

    function setRateProvider(address provider) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(provider != address(0), "zero address");
        rateProvider = provider;
        emit RateProviderUpdated(provider);
    }

    /// @notice FIX P1.L1: configure max age for keeper-pushed rate cache.
    ///         Past this threshold, fall back to direct on-chain read.
    /// @param secs new staleness threshold in seconds (1h-30d range)
    function setMaxRateStalenessSec(uint32 secs) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(secs >= 3_600 && secs <= 30 days, "staleness-range");
        maxRateStalenessSec = secs;
        emit MaxRateStalenessUpdated(secs);
    }

    function harvestableProfit() external view override returns (uint256) {
        if (swapHelper == address(0)) return 0;
        uint256 n = _rewardTokens.length;
        if (n == 0) return 0;
        uint256 sum = 0;
        ISwapHelper sh = ISwapHelper(swapHelper);
        for (uint256 i = 0; i < n; ) {
            address tok = _rewardTokens[i];
            uint256 bal = IERC20(tok).balanceOf(address(this));
            if (bal == 0) { unchecked { ++i; } continue; }
            // M1 pre-flight: skip tokens whose oracle is stale to avoid LINK burn
            if (!sh.canSwap(tok)) { unchecked { ++i; } continue; }
            try sh.previewExpectedOut(tok, bal) returns (uint256 q) { sum += q; } catch {}
            unchecked { ++i; }
        }
        return sum;
    }

    function harvest(address receiver) external override nonReentrant returns (uint256 realized) {
        require(msg.sender == vault, "not vault");
        uint256 n = _rewardTokens.length;
        if (n == 0) return 0;
        address rc = rewardsController;
        address sh = swapHelper;
        address[] memory emptyAssets = new address[](0);
        uint256 total = 0;
        for (uint256 i = 0; i < n; ) {
            address tok = _rewardTokens[i];
            // (1) try claim — never propagate revert (M2 graceful)
            // SLITHER-FIX-1: capture claimed amount + emit per-token event for observability.
            if (rc != address(0)) {
                try IAaveRewardsController(rc).claimRewardsToSelf(emptyAssets, type(uint256).max, tok) returns (uint256 _claimed) {
                    if (_claimed > 0) emit RewardClaimed(tok, _claimed);
                } catch {}
            }
            uint256 bal = IERC20(tok).balanceOf(address(this));
            if (bal == 0) { unchecked { ++i; } continue; }
            if (sh == address(0)) { unchecked { ++i; } continue; }
            // (2) M1 pre-flight: defer if oracle stale (no LINK burn on doomed swap)
            try ISwapHelper(sh).canSwap(tok) returns (bool ok) {
                if (!ok) { unchecked { ++i; } continue; }
            } catch { unchecked { ++i; } continue; }
            // (3) M2 swap — approve, attempt, reset approval regardless of outcome
            IERC20(tok).safeApprove(sh, 0);
            IERC20(tok).safeApprove(sh, bal);
            try ISwapHelper(sh).swapToUSDC(tok, bal, receiver) returns (uint256 out) {
                total += out;
            } catch {}
            IERC20(tok).safeApprove(sh, 0);
            unchecked { ++i; }
        }
        emit Harvested(receiver, total);
        return total;
    }

    // --- ILendingAdapter: Limits ---
    function maxCapacity() external view override returns (uint256) {
        return maxCap;
    }

    function setMaxCap(uint256 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxCap = newCap;
        emit MaxCapUpdated(newCap);
    }

    // --- ILendingAdapter: External Market TVL ---
    /// @notice Returns total USDC deposited in the Aave V3 pool (aToken totalSupply)
    function externalMarketTVL() external view override returns (uint256) {
        try IERC20(aToken).totalSupply() returns (uint256 supply) {
            return supply;
        } catch {
            return 0;
        }
    }

    // --- Idle Asset & Emergency Recovery ---
    event IdleAssetSwept(uint256 amount);
    event EmergencyPullExecuted(uint256 amount);
    /// @dev SLITHER-FIX-2: emit captured withdrawn amount from pool.withdraw return.
    event EmergencyAavePoolWithdrawn(uint256 requested, uint256 withdrawn);

    function sweepIdleAssetToVault() external nonReentrant onlyVault {
        uint256 idle = IERC20(asset).balanceOf(address(this));
        require(idle > 0, "no idle");
        IERC20(asset).safeTransfer(vault, idle);
        emit IdleAssetSwept(idle);
    }

    function emergencyPullAllToVault() external nonReentrant onlyVault {
        // Withdraw all invested from Aave
        uint256 invested = IAToken(aToken).balanceOf(address(this));
        if (invested > 0) {
            // SLITHER-FIX-2: capture withdrawn amount from pool.withdraw return + emit
            // detailed event. Aave returns the actual amount withdrawn (may differ from
            // requested in edge cases — e.g., utilization-bounded withdrawal).
            try pool.withdraw(asset, invested, address(this)) returns (uint256 _withdrawn) {
                emit EmergencyAavePoolWithdrawn(invested, _withdrawn);
            } catch {
                // Withdraw failed - still sweep whatever is available; emit zero to signal failure
                emit EmergencyAavePoolWithdrawn(invested, 0);
            }
        }
        // Transfer FULL balance (withdrawn + any pre-existing idle) to vault
        uint256 fullBalance = IERC20(asset).balanceOf(address(this));
        if (fullBalance > 0) {
            IERC20(asset).safeTransfer(vault, fullBalance);
        }
        emit EmergencyPullExecuted(fullBalance);
    }

    // --- Fallbacks disabled ---

    // ─── Reward config admin ─────────────────────────────────────────────

    function initRewardConfig(address[] calldata tokens, address rc, address sh) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(rewardsController == address(0) && swapHelper == address(0), "already-init");
        require(tokens.length > 0, "empty-tokens");
        require(rc != address(0) && sh != address(0), "zero");
        for (uint256 i = 0; i < tokens.length; ) {
            address tok = tokens[i];
            require(tok != address(0), "zero-token");
            require(!isRewardWhitelisted[tok], "duplicate");
            isRewardWhitelisted[tok] = true;
            _rewardTokens.push(tok);
            unchecked { ++i; }
        }
        rewardsController = rc;
        swapHelper = sh;
        emit RewardConfigInitialized(rc, sh, tokens);
    }

    function addRewardToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0), "zero");
        require(!isRewardWhitelisted[token], "already-whitelisted");
        isRewardWhitelisted[token] = true;
        _rewardTokens.push(token);
        emit RewardTokenAdded(token);
    }

    function removeRewardToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(isRewardWhitelisted[token], "not-whitelisted");
        isRewardWhitelisted[token] = false;
        // O(n) compact-remove from array
        uint256 n = _rewardTokens.length;
        for (uint256 i = 0; i < n; ) {
            if (_rewardTokens[i] == token) {
                _rewardTokens[i] = _rewardTokens[n - 1];
                _rewardTokens.pop();
                break;
            }
            unchecked { ++i; }
        }
        emit RewardTokenRemoved(token);
    }

    function setSwapHelper(address sh) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // allow set to zero (emergency disable harvest pipeline)
        swapHelper = sh;
        emit SwapHelperUpdated(sh);
    }

    function setIncentiveHaircutBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(bps <= 10_000, "bps>10000");
        incentiveHaircutBps = bps;
        emit IncentiveHaircutUpdated(bps);
    }

    function setRealizedRewardAPRBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        realizedRewardAPRBps = bps;
        emit RealizedRewardAPRUpdated(bps);
    }

    function rewardTokens() external view returns (address[] memory) {
        return _rewardTokens;
    }

    function rewardTokensCount() external view returns (uint256) {
        return _rewardTokens.length;
    }

    function pendingRewardBalance(address token) external view returns (uint256) {
        if (!isRewardWhitelisted[token]) return 0;
        return IERC20(token).balanceOf(address(this));
    }

    receive() external payable {
        revert("NO_RECEIVE");
    }

    fallback() external payable {
        revert("NO_FALLBACK");
    }
}
