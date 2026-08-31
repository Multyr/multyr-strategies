// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ===== OpenZeppelin imports =====
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

// ===== Minimal ERC-4626 interface for Fluid fToken =====
interface IERC4626 {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 sharesBurned);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assetsOut);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function maxWithdraw(address owner) external view returns (uint256);
    function maxDeposit(address receiver) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

// ===== ILendingAdapter interface =====
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

/// @title FluidUsdcMultiMarketAdapter
/// @notice Lending adapter for Fluid fUSDC (ERC-4626) on Arbitrum.
/// @dev Single-market initially; can be extended to multi-market pattern later.
///      PULL mode: adapter calls transferFrom() to pull USDC from strategy during deposit().
///      APY: PPS-snapshot-based (pokeAPYSnapshots stores share price, currentAPYBps computes delta).
contract FluidUsdcMultiMarketAdapter is ILendingAdapter, AccessControl, ReentrancyGuard, Initializable {
    using SafeERC20 for IERC20;

    // ===== Roles =====
    bytes32 public constant PARAM_ROLE = keccak256("PARAM_ROLE");

    // ===== Immutable Storage =====
    // --- V10 Storage (was immutable in V9.x; logically immutable post-initialize) ---
    address public asset;       // USDC
    address public vault;       // Strategy vault
    IERC4626 public fToken;     // Fluid fUSDC

    // ===== Configurable Storage =====
    uint256 public capacity;              // Deposit cap (0 = unlimited)
    uint16  public incentiveBps;          // Optional incentive APY in bps
    uint16  public apyOverrideBps;        // Manual APY override (0 = disabled)

    // ===== APY Snapshot Storage =====
    uint256 internal lastSnapshotPPS;     // Share price at last poke (1e18 scale)
    uint64  internal lastSnapshotTs;      // Timestamp of last poke

    // ===== Events =====
    event Deposited(uint256 assets, uint256 shares);
    event Withdrawn(uint256 assets, address receiver);
    event CapacityUpdated(uint256 newCap);
    event IncentiveBpsUpdated(uint16 newBps);
    event APYOverrideUpdated(uint16 newBps);
    event APYSnapshotPoked(uint256 pps, uint64 ts);
    event IdleAssetSwept(uint256 amount);
    event EmergencyPullExecuted(uint256 amount);
    /// @dev SLITHER-FIX-4: emit captured assetsOut from fToken.redeem return for incident-response visibility.
    event EmergencyFluidRedeemed(uint256 shares, uint256 assetsOut);

    // ===== Modifiers =====
    modifier onlyVault() {
        require(msg.sender == vault, "not vault");
        _;
    }

    modifier onlyParamRole() {
        require(hasRole(PARAM_ROLE, msg.sender), "not param role");
        _;
    }

    // ===== Constructor =====

    /// @notice One-shot initialization called atomically by AdapterFactory.
    function initialize(
        address usdc_,
        address admin_,
        address vault_,
        uint256 capacity_,
        address fToken_
    ) external initializer {
        require(
            usdc_ != address(0) && admin_ != address(0)
                && vault_ != address(0) && fToken_ != address(0),
            "zero"
        );
        require(IERC4626(fToken_).asset() == usdc_, "fToken/asset mismatch");

        asset = usdc_;
        vault = vault_;
        fToken = IERC4626(fToken_);
        capacity = capacity_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(PARAM_ROLE, admin_);

        // Initialize APY snapshot
        lastSnapshotPPS = IERC4626(fToken_).convertToAssets(1e18);
        lastSnapshotTs = uint64(block.timestamp);
    }

    // ===== ILendingAdapter: Metadata =====

    function name() external pure override returns (string memory) {
        return "Fluid_USDC_Adapter_Arbitrum";
    }

    function underlying() external view override returns (address) {
        return asset;
    }

    /// @notice PULL mode: adapter calls transferFrom() on strategy during deposit()
    function isPushMode() external pure override returns (bool) {
        return false;
    }

    // ===== ILendingAdapter: Accounting =====

    /// @notice Raw USDC balance held locally (not invested in Fluid)
    function idleAssetBalance() public view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    /// @notice USDC value of fToken shares held by this adapter
    function investedAssets() public view override returns (uint256) {
        uint256 shares = fToken.balanceOf(address(this));
        if (shares < 1) return 0;
        return fToken.convertToAssets(shares);
    }

    /// @notice Total USDC controlled by adapter = invested + idle
    function totalAssets() public view override returns (uint256) {
        return investedAssets() + idleAssetBalance();
    }

    /// @notice Conservative withdrawable amount using maxWithdraw
    function withdrawableAssets() public view override returns (uint256) {
        return fToken.maxWithdraw(address(this));
    }

    // ===== ILendingAdapter: Lifecycle =====

    /// @notice Pull USDC from strategy and deposit into Fluid fToken
    function deposit(uint256 assets) external override nonReentrant onlyVault {
        require(assets > 0, "ZERO_ASSETS");
        if (capacity > 0) require(totalAssets() + assets <= capacity, "CAP");

        // Gas: cache `asset`/`fToken` locally -- both set once in initialize()
        // with no setter, avoids re-reading storage across the
        // transferFrom/approve/deposit/revoke sequence below.
        address asset_ = asset;
        IERC4626 fToken_ = fToken;

        // Pull USDC from strategy
        IERC20(asset_).safeTransferFrom(msg.sender, address(this), assets);

        // Just-in-time approval
        IERC20(asset_).forceApprove(address(fToken_), assets);

        // Deposit into Fluid fToken
        uint256 shares = fToken_.deposit(assets, address(this));

        // Revoke approval
        IERC20(asset_).forceApprove(address(fToken_), 0);

        emit Deposited(assets, shares);
    }

    /// @notice Withdraw USDC from Fluid fToken and send to vault
    /// @dev Uses actual received amount (Fluid docs note small differences possible)
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

        // Clamp to withdrawable
        uint256 maxOut = withdrawableAssets();
        uint256 want = assets > maxOut ? maxOut : assets;
        if (want == 0) return 0;

        // Gas: cache `asset` locally -- set once in initialize(), no setter.
        IERC20 assetToken = IERC20(asset);

        // Record balance before to measure actual received
        uint256 balBefore = assetToken.balanceOf(address(this));

        // Withdraw from fToken to this adapter
        fToken.withdraw(want, address(this), address(this));

        // Measure actual received (Fluid may have small differences)
        uint256 balAfter = assetToken.balanceOf(address(this));
        withdrawn = balAfter - balBefore;

        // Transfer actual received to vault
        if (withdrawn > 0) {
            assetToken.safeTransfer(vault, withdrawn);
        }

        emit Withdrawn(withdrawn, vault);
    }

    // ===== ILendingAdapter: Yield =====

    /// @notice APY in basis points computed from PPS snapshot delta
    function currentAPYBps() external view override returns (uint16) {
        // Manual override takes priority
        if (apyOverrideBps != 0) return apyOverrideBps;

        // Snapshot-based APY
        if (lastSnapshotTs == 0 || lastSnapshotPPS == 0) return 0;

        uint256 currentPPS = fToken.convertToAssets(1e18);
        uint256 elapsed = block.timestamp - lastSnapshotTs;
        if (elapsed == 0) return 0;

        uint256 delta = currentPPS > lastSnapshotPPS ? currentPPS - lastSnapshotPPS : 0;
        if (delta == 0) return 0;

        // annualize: (delta / lastPPS) * (365 days / elapsed) * 10000
        uint256 annualBps = (delta * 365 days * 10_000) / (lastSnapshotPPS * elapsed);
        return annualBps > type(uint16).max ? type(uint16).max : uint16(annualBps);
    }

    function incentiveAPYBps() external view override returns (uint16) {
        return incentiveBps;
    }

    /// @notice No reward claiming in v1
    function harvestableProfit() external pure override returns (uint256) {
        return 0;
    }

    /// @notice No reward claiming in v1
    function harvest(address) external pure override returns (uint256 realized) {
        return 0;
    }

    // ===== ILendingAdapter: Limits =====

    function maxCapacity() external view override returns (uint256) {
        return capacity;
    }

    // ===== ILendingAdapter: External Market TVL =====

    /// @notice Returns total USDC deposited in the Fluid fToken vault
    function externalMarketTVL() external view override returns (uint256) {
        try fToken.totalAssets() returns (uint256 total) {
            return total;
        } catch {
            return 0;
        }
    }

    // ===== Idle Asset & Emergency Recovery =====

    /// @notice Transfer all idle USDC back to vault (does NOT touch invested)
    function sweepIdleAssetToVault() external override nonReentrant onlyVault {
        uint256 idle = IERC20(asset).balanceOf(address(this));
        require(idle > 0, "no idle");
        IERC20(asset).safeTransfer(vault, idle);
        emit IdleAssetSwept(idle);
    }

    /// @notice Emergency: redeem ALL fToken shares + sweep all USDC to vault
    function emergencyPullAllToVault() external override nonReentrant onlyVault {
        // Redeem all invested shares
        uint256 shares = fToken.balanceOf(address(this));
        if (shares > 0) {
            try fToken.redeem(shares, address(this), address(this)) returns (uint256 _assetsOut) {
                emit EmergencyFluidRedeemed(shares, _assetsOut);
            }
            catch {
                emit EmergencyFluidRedeemed(shares, 0);
            }
        }

        // Transfer FULL USDC balance (redeemed + any pre-existing idle) to vault
        uint256 fullBalance = IERC20(asset).balanceOf(address(this));
        if (fullBalance > 0) {
            IERC20(asset).safeTransfer(vault, fullBalance);
        }
        emit EmergencyPullExecuted(fullBalance);
    }

    // ===== Admin Functions (PARAM_ROLE) =====

    /// @notice Store current share price for APY calculation
    function pokeAPYSnapshots() external onlyParamRole {
        uint256 pps = fToken.convertToAssets(1e18);
        uint64 nowTs = uint64(block.timestamp);
        lastSnapshotPPS = pps;
        lastSnapshotTs = nowTs;
        emit APYSnapshotPoked(pps, nowTs);
    }

    function setCapacity(uint256 newCap) external onlyRole(PARAM_ROLE) {
        capacity = newCap;
        emit CapacityUpdated(newCap);
    }

    function setIncentiveBps(uint16 bps) external onlyRole(PARAM_ROLE) {
        require(bps <= 10_000, "bps>10000");
        incentiveBps = bps;
        emit IncentiveBpsUpdated(bps);
    }

    function setAPYOverrideBps(uint16 bps) external onlyRole(PARAM_ROLE) {
        require(bps <= 10_000, "bps>10000");
        apyOverrideBps = bps;
        emit APYOverrideUpdated(bps);
    }

    // ===== View Helpers =====

    /// @notice Returns last APY snapshot data for monitoring
    function getAPYSnapshot() external view returns (uint256 pps, uint64 ts) {
        return (lastSnapshotPPS, lastSnapshotTs);
    }

    /// @notice Returns fToken share balance held by this adapter
    function shareBalance() external view returns (uint256) {
        return fToken.balanceOf(address(this));
    }

    // ===== Fallbacks disabled =====
    receive() external payable {
        revert("NO_RECEIVE");
    }

    fallback() external payable {
        revert("NO_FALLBACK");
    }
}
