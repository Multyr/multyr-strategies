// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// --- OpenZeppelin imports ---
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

// --- Venus vToken minimal interface ---
interface IVToken {
    function underlying() external view returns (address);
    function mint(uint256 mintAmount) external returns (uint256); // 0 = success
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256); // 0 = success
    function redeem(uint256 redeemTokens) external returns (uint256); // 0 = success
    function balanceOf(address owner) external view returns (uint256);
    function exchangeRateCurrent() external returns (uint256); // NOT view - accrues interest
    function exchangeRateStored() external view returns (uint256); // view version
    function supplyRatePerBlock() external view returns (uint256);
    function getCash() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
}

// --- Venus Comptroller (claim XVS rewards) ---
interface IVenusComptroller {
    function claimVenus(address holder, address[] calldata vTokens) external;
}

// --- RewardSwapHelper interface (Step 4 reward pipeline) ---
interface IRewardSwapHelper {
    function canSwap(address rewardToken) external view returns (bool);
    function previewExpectedOut(address rewardToken, uint256 amountIn) external view returns (uint256);
    function swapToUSDC(address rewardToken, uint256 amountIn, address receiver) external returns (uint256);
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
    function isPushMode() external pure returns (bool);
    function idleAssetBalance() external view returns (uint256);
    function investedAssets() external view returns (uint256);
    function sweepIdleAssetToVault() external;
    function emergencyPullAllToVault() external;
}

/// @title VenusUsdcMultiMarketAdapter
/// @notice Lending adapter for Venus vUSDC_Core on Arbitrum.
/// @dev Raw vToken interface (Compound-fork semantics): mint/redeem, not deposit/withdraw.
///      Single-market adapter targeting vUSDC_Core only.
///      Mode: PULL (approve underlying then mint).
contract VenusUsdcMultiMarketAdapter is ILendingAdapter, AccessControl, ReentrancyGuard, Initializable {
    using SafeERC20 for IERC20;

    // --- Roles ---
    bytes32 public constant PARAM_ROLE = keccak256("PARAM_ROLE");

    // --- Constants ---
    /// @dev Arbitrum One chain ID (informational; chain guard removed in V10 for portability).
    uint256 public constant ARBITRUM_CHAIN_ID = 42161;

    // --- Immutable Storage ---
    // --- V10 Storage (was immutable in V9.x; logically immutable post-initialize) ---
    address public override underlying; // USDC
    address public vault;               // Strategy (no-custody)
    address public vToken;              // Venus vUSDC_Core

    // --- Configurable Storage ---
    uint256 public capacity; // Deposit cap (0 = unlimited)

    // --- Reward Pipeline v1 (Phase 4 Step 4.3) ---
    /// @notice Reward token (typically XVS). address(0) = pipeline disabled.
    address public rewardToken;
    /// @notice Venus Comptroller for claimVenus call.
    address public comptroller;
    /// @notice Configurable swap helper.
    address public swapHelper;
    /// @notice Realized reward APR in bps (gov-set from off-chain measurement).
    uint16 public realizedRewardAPRBps;
    /// @notice Haircut applied to realized reward APR. LOSS percentage in bps.
    ///         Default 7500 = 75% loss -> retain 25%. Range [0, 10000].
    uint16 public incentiveHaircutBps = 7500;

    /// @notice Blocks per year for this chain, set at initialize(). Range (0, 200_000_000].
    ///         Arbitrum: 126_144_000 (0.25s), Optimism/Base: 15_768_000 (2s), BNB: 10_512_000 (3s).
    uint256 public blocksPerYear;

    // --- Events ---
    event Supplied(uint256 assets);
    event Withdrawn(uint256 assets, address receiver);
    event CapacityUpdated(uint256 capacity);
    event IdleAssetSwept(uint256 amount);
    event EmergencyPullExecuted(uint256 amount);

    // --- Reward Pipeline Events ---
    event RewardConfigInitialized(address rewardToken, address comptroller, address swapHelper);
    event SwapHelperUpdated(address swapHelper);
    event RealizedRewardAPRUpdated(uint16 bps);
    event IncentiveHaircutUpdated(uint16 bps);
    event RewardsClaimed(uint256 amount);
    event HarvestExecuted(address rewardToken, uint256 amountIn, uint256 usdcOut, address receiver);
    event SwapDeferred(address rewardToken, uint256 pendingBalance, string reason);

    // --- Modifiers ---
    modifier onlyVault() {
        require(msg.sender == vault, "NotVault");
        _;
    }

    // --- Constructor ---

    /// @notice One-shot initialization called atomically by AdapterFactory.
    /// @dev chain-id check removed per V10 chain-portability goal; deploy script must target correct chain.
    function initialize(
        address usdc_,
        address admin_,
        address vault_,
        uint256 capacity_,
        address vToken_,
        uint256 blocksPerYear_
    ) external initializer {
        require(
            usdc_ != address(0) && admin_ != address(0)
                && vault_ != address(0) && vToken_ != address(0),
            "zero"
        );
        require(IVToken(vToken_).underlying() == usdc_, "vToken/asset mismatch");
        require(blocksPerYear_ > 0 && blocksPerYear_ <= 200_000_000, "blocksPerYear");

        underlying = usdc_;
        vault = vault_;
        vToken = vToken_;
        capacity = capacity_;
        blocksPerYear = blocksPerYear_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(PARAM_ROLE, admin_);
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════

    /// @notice Sets just-in-time approval for exact amount
    /// @dev Prevents unlimited protocol exposure if Venus is compromised
    function _approveVToken(uint256 amount) internal {
        IERC20(underlying).forceApprove(vToken, amount);
    }

    /// @notice Resets vToken approval to zero
    function _revokeVTokenApproval() internal {
        IERC20(underlying).forceApprove(vToken, 0);
    }

    /// @notice Converts vToken balance to underlying using stored exchange rate
    /// @dev exchangeRateStored is view-safe (does NOT accrue interest)
    ///      exchangeRate is scaled by 1e(18 - 8 + underlyingDecimals) = 1e(18 - 8 + 6) = 1e16
    ///      investedAssets = vTokenBal * exchangeRate / 1e18
    function _vTokenToUnderlying(uint256 vTokenBal) internal view returns (uint256) {
        if (vTokenBal == 0) return 0;
        uint256 rate = IVToken(vToken).exchangeRateStored();
        return (vTokenBal * rate) / 1e18;
    }

    // ═══════════════════════════════════════════════════════════
    //  ILendingAdapter: METADATA
    // ═══════════════════════════════════════════════════════════

    function name() external pure override returns (string memory) {
        return "Venus_USDC_Core_Adapter_Arbitrum";
    }

    /// @notice Returns false — Venus uses PULL deposit pattern
    function isPushMode() external pure override returns (bool) {
        return false;
    }

    // ═══════════════════════════════════════════════════════════
    //  ILendingAdapter: ACCOUNTING
    // ═══════════════════════════════════════════════════════════

    function idleAssetBalance() public view override returns (uint256) {
        return IERC20(underlying).balanceOf(address(this));
    }

    /// @notice Assets invested in Venus = vToken balance * exchangeRateStored / 1e18
    function investedAssets() public view override returns (uint256) {
        uint256 vBal = IVToken(vToken).balanceOf(address(this));
        return _vTokenToUnderlying(vBal);
    }

    function totalAssets() public view override returns (uint256) {
        return investedAssets() + idleAssetBalance();
    }

    /// @notice Withdrawable limited by pool liquidity (getCash)
    function withdrawableAssets() public view override returns (uint256) {
        uint256 invested = investedAssets();
        uint256 cash = IVToken(vToken).getCash();
        return invested < cash ? invested : cash;
    }

    // ═══════════════════════════════════════════════════════════
    //  ILendingAdapter: LIFECYCLE
    // ═══════════════════════════════════════════════════════════

    function deposit(uint256 assets) external override nonReentrant onlyVault {
        require(assets > 0, "ZERO_ASSETS");
        if (capacity > 0) require(totalAssets() + assets <= capacity, "CAP");

        // PULL pattern: transfer USDC from strategy to adapter
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), assets);

        // Just-in-time approval
        _approveVToken(assets);

        // Venus mint: returns 0 on success
        uint256 err = IVToken(vToken).mint(assets);
        require(err == 0, "Venus:mint failed");

        // Revoke approval
        _revokeVTokenApproval();

        emit Supplied(assets);
    }

    /// @dev Receiver forced: always sends to vault, ignores 'receiver' param
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
        require(want > 0, "nothing withdrawable");

        // Venus redeemUnderlying: returns 0 on success
        uint256 err = IVToken(vToken).redeemUnderlying(want);
        require(err == 0, "Venus:redeem failed");

        // Transfer redeemed USDC to vault
        IERC20(underlying).safeTransfer(vault, want);
        withdrawn = want;

        emit Withdrawn(withdrawn, vault);
    }

    // ═══════════════════════════════════════════════════════════
    //  ILendingAdapter: YIELD
    // ═══════════════════════════════════════════════════════════

    /// @notice APY from supplyRatePerBlock annualized (simple, not compound)
    /// @dev rate * blocksPerYear / 1e14 → bps
    function currentAPYBps() external view override returns (uint16) {
        uint256 rate = IVToken(vToken).supplyRatePerBlock();
        uint256 apyWad = rate * blocksPerYear; // 1e18 scale
        uint256 bps = apyWad / 1e14;             // 1e18 → 1e4 (bps)
        // casting to uint16 is safe because overflow is checked with ternary
        // forge-lint: disable-next-line(unsafe-typecast)
        return bps > type(uint16).max ? type(uint16).max : uint16(bps);
    }

    /// @notice Effective incentive APY in bps after haircut.
    function incentiveAPYBps() external view override returns (uint16) {
        if (realizedRewardAPRBps == 0) return 0;
        uint256 net = (uint256(realizedRewardAPRBps) * (10_000 - uint256(incentiveHaircutBps))) / 10_000;
        return net > type(uint16).max ? type(uint16).max : uint16(net);
    }

    /// @notice USDC-equivalent of pending raw reward tokens (M1 pre-flight gate).
    function harvestableProfit() external view override returns (uint256) {
        if (rewardToken == address(0)) return 0;
        uint256 bal = IERC20(rewardToken).balanceOf(address(this));
        if (bal == 0) return 0;
        if (swapHelper == address(0)) return 0;
        try IRewardSwapHelper(swapHelper).canSwap(rewardToken) returns (bool ok) {
            if (!ok) return 0;
        } catch { return 0; }
        try IRewardSwapHelper(swapHelper).previewExpectedOut(rewardToken, bal) returns (uint256 e) {
            return e;
        } catch { return 0; }
    }

    /// @notice Claim XVS via comptroller, then swap to USDC if oracle fresh (M2).
    function harvest(address receiver) external override nonReentrant onlyVault returns (uint256 realized) {
        if (rewardToken == address(0) || comptroller == address(0)) return 0;

        // 1. Claim from Comptroller
        address[] memory vTokens = new address[](1);
        vTokens[0] = vToken;
        try IVenusComptroller(comptroller).claimVenus(address(this), vTokens) {} catch {}

        uint256 bal = IERC20(rewardToken).balanceOf(address(this));
        if (bal > 0) emit RewardsClaimed(bal);
        if (bal == 0) return 0;

        // 2. M2 graceful swap
        if (swapHelper == address(0)) {
            emit SwapDeferred(rewardToken, bal, "no-helper");
            return 0;
        }
        bool ok;
        try IRewardSwapHelper(swapHelper).canSwap(rewardToken) returns (bool v) { ok = v; }
        catch { ok = false; }
        if (!ok) {
            emit SwapDeferred(rewardToken, bal, "oracle-stale");
            return 0;
        }

        IERC20(rewardToken).forceApprove(swapHelper, bal);
        try IRewardSwapHelper(swapHelper).swapToUSDC(rewardToken, bal, receiver) returns (uint256 out) {
            realized = out;
            emit HarvestExecuted(rewardToken, bal, out, receiver);
        } catch {
            emit SwapDeferred(rewardToken, bal, "swap-revert");
            realized = 0;
        }
        IERC20(rewardToken).forceApprove(swapHelper, 0);
    }

    // ═══════════════════════════════════════════════════════════
    //  ILendingAdapter: LIMITS
    // ═══════════════════════════════════════════════════════════

    function maxCapacity() external view override returns (uint256) {
        return capacity;
    }

    function setCapacity(uint256 capacity_) external onlyRole(PARAM_ROLE) {
        capacity = capacity_;
        emit CapacityUpdated(capacity_);
    }

    // --- Reward Pipeline Admin (Step 4.3) ---

    /// @notice One-shot wiring of reward pipeline. Write-once for token+comptroller.
    function initRewardConfig(
        address rewardToken_,
        address comptroller_,
        address swapHelper_
    ) external onlyRole(PARAM_ROLE) {
        require(rewardToken == address(0) && comptroller == address(0), "already-init");
        require(rewardToken_ != address(0) && comptroller_ != address(0), "zero");
        rewardToken = rewardToken_;
        comptroller = comptroller_;
        swapHelper = swapHelper_;
        emit RewardConfigInitialized(rewardToken_, comptroller_, swapHelper_);
    }

    function setSwapHelper(address swapHelper_) external onlyRole(PARAM_ROLE) {
        swapHelper = swapHelper_;
        emit SwapHelperUpdated(swapHelper_);
    }

    function setRealizedRewardAPRBps(uint16 bps) external onlyRole(PARAM_ROLE) {
        realizedRewardAPRBps = bps;
        emit RealizedRewardAPRUpdated(bps);
    }

    function setIncentiveHaircutBps(uint16 bps) external onlyRole(PARAM_ROLE) {
        require(bps <= 10_000, "bps>10000");
        incentiveHaircutBps = bps;
        emit IncentiveHaircutUpdated(bps);
    }

    function pendingRewardBalance() external view returns (uint256) {
        if (rewardToken == address(0)) return 0;
        return IERC20(rewardToken).balanceOf(address(this));
    }

    // ═══════════════════════════════════════════════════════════
    //  ILendingAdapter: EXTERNAL MARKET TVL
    // ═══════════════════════════════════════════════════════════

    /// @notice Returns total USDC supplied to Venus = getCash + totalBorrows
    /// @dev Conservative: returns getCash only if totalBorrows reverts
    function externalMarketTVL() external view override returns (uint256) {
        uint256 cash;
        uint256 borrows;
        try IVToken(vToken).getCash() returns (uint256 c) {
            cash = c;
        } catch {
            return 0;
        }
        try IVToken(vToken).totalBorrows() returns (uint256 b) {
            borrows = b;
        } catch {
            borrows = 0;
        }
        return cash + borrows;
    }

    // ═══════════════════════════════════════════════════════════
    //  IDLE ASSET & EMERGENCY RECOVERY
    // ═══════════════════════════════════════════════════════════

    function sweepIdleAssetToVault() external override nonReentrant onlyVault {
        uint256 idle = IERC20(underlying).balanceOf(address(this));
        require(idle > 0, "no idle");
        IERC20(underlying).safeTransfer(vault, idle);
        emit IdleAssetSwept(idle);
    }

    function emergencyPullAllToVault() external override nonReentrant onlyVault {
        uint256 vBal = IVToken(vToken).balanceOf(address(this));
        if (vBal > 0) {
            try IVToken(vToken).redeem(vBal) returns (uint256 err) {
                require(err == 0, "Venus:emergency redeem failed");
            } catch {
                // Redeem failed - still sweep whatever idle exists
            }
        }
        uint256 fullBalance = IERC20(underlying).balanceOf(address(this));
        if (fullBalance > 0) {
            IERC20(underlying).safeTransfer(vault, fullBalance);
        }
        emit EmergencyPullExecuted(fullBalance);
    }

    // ═══════════════════════════════════════════════════════════
    //  SWEEP PROTECTION
    // ═══════════════════════════════════════════════════════════

    receive() external payable {
        revert("NO_RECEIVE");
    }

    fallback() external payable {
        revert("NO_FALLBACK");
    }
}
