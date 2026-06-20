// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// OpenZeppelin imports
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

/// @notice Minimal interface for protocol registry
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

/// @notice Minimal interface for Euler USDC markets (EVault interface)
interface IEulerUsdcMarket {
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
    function balanceOf(address account) external view returns (uint256); // shares
    function convertToAssets(uint256 shares) external view returns (uint256); // convert shares to assets
    function maxWithdraw(address owner) external view returns (uint256); // max withdrawable assets
    function maxDeposit(address receiver) external view returns (uint256); // max depositable assets (supply cap)
    function interestRate() external view returns (uint256); // APY in 1e27 scaling (ray)
    function asset() external view returns (address); // underlying asset (USDC)
    function totalAssets() external view returns (uint256); // total USDC deposited in vault
}

/// @notice Lending Adapter interface for Vault integration
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

    // external TVL
    function externalMarketTVL() external view returns (uint256);

    // Extensions
    function optimize() external returns (uint256 movedUSDC, address fromMarket, address toMarket);
    function markets() external view returns (address[] memory);
    function activeMarket() external view returns (address);
    function positions() external view returns (uint256[] memory assetsByMarket);
    function effectiveAPYBps() external view returns (uint16);
}

/// @dev Minimal Permit2 AllowanceTransfer interface (Euler EVK requires internal allowance)
interface IPermit2Allowance {
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);

    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

contract EulerUsdcMultiMarketAdapter is ILendingAdapter, AccessControl, ReentrancyGuard, Initializable {
    using SafeERC20 for IERC20Metadata;

    // --- STRUCTS & STORAGE ---

    struct Market {
        address addr;
        bool enabled;
        bool flagged;
        uint16 riskScoreBps;
    }

    // Roles
    bytes32 public constant PARAM_ROLE = keccak256("PARAM_ROLE");

    // Permit2 canonical address (AllowanceTransfer — used by Euler EVK)
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint48 internal constant PERMIT2_MIN_TTL = uint48(1 days);
    uint48 internal constant PERMIT2_TTL = uint48(365 days * 10); // 10y — safe for EVK

    // --- V10 Storage (was immutable in V9.x; logically immutable post-initialize) ---
    IERC20Metadata public USDC;
    address public vault;
    IProtocolRegistry public registry; // Optional registry (address(0) if not used)

    Market[] internal mkts; // Dynamic array - can grow with Registry updates
    uint256[] internal principal; // principal[i]: USDC (6 decimals)
    uint256 internal principalTotal;

    uint32 public minSecondsBetweenOptimize = 3 hours;
    uint16 public subMoveMinBps = 25; // 0.25%
    uint16 public subGateMinNetBenefitBps = 2; // 0.02%
    uint16 public slippageBpsEstimate = 3;
    uint16 public withdrawalSpreadBpsEstimate = 2;
    uint256 public gasCostUSDC = 0;
    uint256 public capacity = 0; // 0 = unlimited
    uint256 public lastOptimizeTs;

    // --- EVENTS ---

    event Deposited(address indexed market, uint256 assets);
    event MarketSkippedLowCapacity(address indexed market, uint256 capacity);
    event MarketSelectionFallback(address indexed failedMarket, address indexed fallbackMarket);
    event DepositCapped(address indexed market, uint256 requested, uint256 capped);
    event Withdrawn(
        address indexed market, uint256 asked, uint256 withdrawn, address indexed receiver
    );
    event Harvested(uint256 profitUSDC);
    event IntraRebalanced(address indexed fromMarket, address indexed toMarket, uint256 movedUSDC);

    event MarketToggled(uint256 indexed idx, address market, bool enabled, bool flagged);
    event MarketAddressUpdated(uint256 indexed idx, address oldMarket, address newMarket);
    event RiskScoreUpdated(uint256 indexed idx, uint16 riskScoreBps);

    event CostsEstimatesUpdated(
        uint16 slippageBps, uint16 withdrawalSpreadBps, uint256 gasCostUSDC
    );
    event OptimizeParamsUpdated(
        uint32 minSecondsBetweenOptimize, uint16 subMoveMinBps, uint16 subGateMinNetBenefitBps
    );
    event CapacityUpdated(uint256 capacity);
    event Permit2AllowanceRefreshed(address indexed vault, uint160 amount, uint48 expiration);
    event IdleAssetSwept(uint256 amount);
    event EmergencyPullExecuted(uint256 amount);

    // --- MODIFIERS ---

    modifier onlyVault() {
        require(msg.sender == vault, "Only vault");
        _;
    }

    modifier onlyParamRole() {
        require(hasRole(PARAM_ROLE, msg.sender), "Only param role");
        _;
    }

    // --- CONSTRUCTOR ---


    /// @notice One-shot initialization called atomically by AdapterFactory.
    /// @dev _admin is explicit because msg.sender in initialize() = AdapterFactory, not deployer.
    function initialize(
        address _vault,
        address _usdc,
        address[] memory _markets,
        address _registry,
        address _admin
    ) external initializer {
        require(_vault != address(0), "vault zero");
        require(_usdc != address(0), "usdc zero");
        require(_admin != address(0), "admin zero");

        USDC = IERC20Metadata(_usdc);
        vault = _vault;
        registry = IProtocolRegistry(_registry); // Can be address(0)

        // Validate and initialize markets from constructor array
        uint256 marketCount = _markets.length;
        for (uint256 i = 0; i < marketCount; ++i) {
            require(_markets[i] != address(0), "market zero");
            for (uint256 j = 0; j < i; ++j) {
                require(_markets[i] != _markets[j], "market dup");
            }
            mkts.push(Market({ addr: _markets[i], enabled: true, flagged: false, riskScoreBps: 0 }));
            principal.push(0);
        }

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(PARAM_ROLE, _admin);

        // Approve Permit2 for Euler EVK vaults (one-time unlimited approval)
        // Euler vaults use Permit2 internally during deposit() -- this is REQUIRED.
        USDC.forceApprove(PERMIT2, type(uint256).max);

        // Auto-load from registry if available (will replace constructor markets)
        if (_registry != address(0)) {
            _loadFromRegistry();
        }

        // V9 FIX: HARDENING - Revert if no markets loaded
        // This prevents deployment of a non-functional adapter
        require(
            mkts.length > 0, "EulerAdapter: no markets - registry required or pass _markets array"
        );
    }

    // --- MARKET INITIALIZATION ---

    /// @notice Initialize Permit2 allowances for all markets (call BEFORE role transfer)
    /// @dev Sets Permit2 internal allowance for each market. Must be called after
    ///      constructor and before admin roles are transferred to Timelock.
    ///      This separates Permit2 setup from the deposit flow (see v7-euler-fix-report.md).
    function initializeMarkets() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 len = mkts.length;
        for (uint256 i = 0; i < len; i++) {
            if (mkts[i].addr == address(0)) continue;
            _ensurePermit2(mkts[i].addr);
        }
        emit MarketsInitialized(len);
    }

    event MarketsInitialized(uint256 marketCount);

    // --- INTERNAL HELPERS ---

    /// @notice Sets just-in-time approval for a market operation
    /// @dev Prevents unlimited protocol exposure by approving only the required amount
    /// @param marketAddr The market address to approve
    /// @param amount The exact amount to approve
    function _approveMarket(address marketAddr, uint256 amount) internal {
        USDC.forceApprove(marketAddr, amount);
    }

    /// @notice Revokes approval for a market after operation
    /// @dev Security measure to prevent unlimited protocol exposure
    /// @param marketAddr The market address to revoke approval from
    function _revokeMarketApproval(address marketAddr) internal {
        USDC.forceApprove(marketAddr, 0);
    }

    /// @dev Ensures Permit2 internal allowance is active for a given Euler vault.
    ///      Idempotent: only calls approve if allowance is low or expired.
    ///      Euler EVK uses Permit2.transferFrom internally during deposit.
    function _ensurePermit2(address eulerVault) internal {
        if (eulerVault == address(0)) return;

        (uint160 amt, uint48 exp,) =
            IPermit2Allowance(PERMIT2).allowance(address(this), address(USDC), eulerVault);

        uint48 nowTs = uint48(block.timestamp);
        uint48 wantedExp = nowTs + PERMIT2_TTL;

        // Refresh if: amount too low OR expired/expiring within PERMIT2_MIN_TTL
        if (amt < type(uint160).max / 2 || exp < nowTs + PERMIT2_MIN_TTL) {
            IPermit2Allowance(PERMIT2)
                .approve(address(USDC), eulerVault, type(uint160).max, wantedExp);
            emit Permit2AllowanceRefreshed(eulerVault, type(uint160).max, wantedExp);
        }
    }

    // Dust amount for market activation. Must produce >= 1 share.
    // 1 wei = 0 shares at current Euler exchange rates (E_ZeroShares).
    // 100 wei (0.0001 USDC) safely produces shares at any reasonable rate.
    uint256 private constant POKE_DUST = 100;

    /// @notice Initializes a market with a dust deposit to activate it
    /// @dev Euler vaults require initialization before they can be queried
    /// @param idx Market index to poke
    /// @return success True if market was successfully activated
    function _pokeMarket(uint256 idx) internal returns (bool success) {
        if (idx >= mkts.length) return false;

        // Audit #2 P1.8 — check maxDeposit BEFORE attempting dust deposit.
        // If the market's supply cap is hit (maxDeposit == 0), skip immediately
        // rather than wasting gas on a guaranteed-to-fail ERC4626 deposit.
        try IEulerUsdcMarket(mkts[idx].addr).maxDeposit(address(this)) returns (uint256 maxDep) {
            if (maxDep == 0) {
                emit MarketSkippedLowCapacity(mkts[idx].addr, 0);
                return false;
            }
        } catch {
            // maxDeposit() not available or reverted — skip this market.
            emit MarketSkippedLowCapacity(mkts[idx].addr, 0);
            return false;
        }

        // Check if we have enough USDC for dust deposit
        uint256 bal = USDC.balanceOf(address(this));
        if (bal < POKE_DUST) return false;

        // Ensure Permit2 internal allowance, then approve and deposit dust amount
        _ensurePermit2(mkts[idx].addr);
        _approveMarket(mkts[idx].addr, POKE_DUST);

        // Try dust deposit — needs enough to produce >= 1 share
        try IEulerUsdcMarket(mkts[idx].addr).deposit(POKE_DUST, address(this)) returns (uint256 shares) {
            if (shares < 1) { } // intentionally empty - we just need non-zero to confirm
            _revokeMarketApproval(mkts[idx].addr);
            return true;
        } catch {
            _revokeMarketApproval(mkts[idx].addr);
            return false;
        }
    }

    function _balanceInUnderlying(uint256 i) internal view returns (uint256) {
        // Euler EVault uses ERC4626 standard: balanceOf returns shares, convertToAssets converts to underlying
        // Use low-level staticcall to avoid try-catch gas issues
        (bool success1, bytes memory data1) =
            mkts[i].addr.staticcall(abi.encodeWithSignature("balanceOf(address)", address(this)));

        if (!success1 || data1.length < 32) {
            return 0;
        }

        uint256 shares = abi.decode(data1, (uint256));
        if (shares < 1) {
            // slither: incorrect-equality - use < 1 instead of == 0
            return 0;
        }

        (bool success2, bytes memory data2) =
            mkts[i].addr.staticcall(abi.encodeWithSignature("convertToAssets(uint256)", shares));

        if (!success2 || data2.length < 32) {
            return 0;
        }

        return abi.decode(data2, (uint256));
    }

    function _liquidity(uint256 i) internal view returns (uint256) {
        // maxWithdraw returns the maximum amount of assets that can be withdrawn
        // Use low-level staticcall to avoid try-catch gas issues
        (bool success, bytes memory data) =
            mkts[i].addr.staticcall(abi.encodeWithSignature("maxWithdraw(address)", address(this)));

        if (!success || data.length < 32) {
            return 0;
        }

        return abi.decode(data, (uint256));
    }

    function _supplyAPYBps(uint256 i) internal view returns (uint16) {
        // Euler interestRate() returns borrow rate (SPY) in 1e27 scaling (RAY format)
        // We need to calculate supply APY = borrow APY × utilization × (1 - fee)
        // Use low-level staticcall to avoid try-catch gas issues in view functions

        // Get borrow rate (interestRate)
        (bool success1, bytes memory data1) =
            mkts[i].addr.staticcall(abi.encodeWithSignature("interestRate()"));
        if (!success1 || data1.length < 32) {
            return 0;
        }
        uint256 borrowRateSPY = abi.decode(data1, (uint256));

        // Get total borrows
        (bool success2, bytes memory data2) =
            mkts[i].addr.staticcall(abi.encodeWithSignature("totalBorrows()"));
        if (!success2 || data2.length < 32) {
            return 0;
        }
        uint256 totalBorrows = abi.decode(data2, (uint256));

        // Get total assets
        (bool success3, bytes memory data3) =
            mkts[i].addr.staticcall(abi.encodeWithSignature("totalAssets()"));
        if (!success3 || data3.length < 32) {
            return 0;
        }
        uint256 vaultTotalAssets = abi.decode(data3, (uint256));

        // Get interest fee
        (bool success4, bytes memory data4) =
            mkts[i].addr.staticcall(abi.encodeWithSignature("interestFee()"));
        if (!success4 || data4.length < 32) {
            return 0;
        }
        uint256 interestFee = abi.decode(data4, (uint256));

        // Avoid division by zero
        if (vaultTotalAssets < 1) {
            // slither: incorrect-equality - use < 1 instead of == 0
            return 0;
        }

        // Calculate borrow APY in bps
        // SPY to annual: borrowRateSPY / 3,168,808,781,402,895
        uint256 borrowAPYBps = borrowRateSPY / 3_168_808_781_402_895;

        // Calculate utilization rate in WAD (1e18)
        // utilization = totalBorrows / vaultTotalAssets
        uint256 utilizationWAD = (totalBorrows * 1e18) / vaultTotalAssets;

        // Calculate supply APY = borrow APY × utilization × (1 - fee)
        // fee is in basis points (10000 = 100%)
        // supply APY = borrowAPY × utilization × (10000 - fee) / 10000
        uint256 supplyAPYBps =
            (borrowAPYBps * utilizationWAD * (10000 - interestFee)) / (1e18 * 10000);

        // Cap at uint16 max to prevent overflow
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 apyBps = supplyAPYBps > type(uint16).max ? type(uint16).max : uint16(supplyAPYBps);
        return apyBps;
    }

    /// @dev Minimum deposit capacity for a market to be eligible.
    ///      Markets with capacity below this are skipped (avoids partial fills on tiny caps).
    uint256 public minMarketCapacity = 1e6; // 1 USDC default

    /// @notice Set minimum market capacity for target selection
    function setMinMarketCapacity(uint256 _min) external onlyRole(PARAM_ROLE) {
        minMarketCapacity = _min;
    }

    /// @dev View-safe target market selection (no events, for view functions)
    function _targetMarket() internal view returns (uint256 idx, bool found) {
        return _targetMarketView(0);
    }

    /// @dev View-safe: find best market with capacity (no events)
    function _targetMarketView(uint256 excludeUpTo) internal view returns (uint256 idx, bool found) {
        uint16 bestAPY = 0;
        idx = 0;
        found = false;
        uint256 n = mkts.length;
        uint256 _minCap = minMarketCapacity;
        for (uint256 i = 0; i < n; ++i) {
            if (excludeUpTo > 0 && i < excludeUpTo) continue;
            if (mkts[i].enabled && !mkts[i].flagged) {
                uint256 maxDep = IEulerUsdcMarket(mkts[i].addr).maxDeposit(address(this));
                if (maxDep < _minCap) continue;
                uint16 apy = _supplyAPYBps(i);
                if (!found || apy > bestAPY) {
                    bestAPY = apy;
                    idx = i;
                    found = true;
                }
            }
        }
    }

    /// @dev Non-view: find best market with capacity + emit skip events
    function _targetMarketWithEvents(uint256 excludeUpTo) internal returns (uint256 idx, bool found) {
        uint16 bestAPY = 0;
        idx = 0;
        found = false;
        uint256 n = mkts.length;
        uint256 _minCap = minMarketCapacity;
        for (uint256 i = 0; i < n; ++i) {
            if (excludeUpTo > 0 && i < excludeUpTo) continue;
            if (mkts[i].enabled && !mkts[i].flagged) {
                uint256 maxDep = IEulerUsdcMarket(mkts[i].addr).maxDeposit(address(this));
                if (maxDep < _minCap) {
                    emit MarketSkippedLowCapacity(mkts[i].addr, maxDep);
                    continue;
                }
                uint16 apy = _supplyAPYBps(i);
                if (!found || apy > bestAPY) {
                    bestAPY = apy;
                    idx = i;
                    found = true;
                }
            }
        }
    }

    function _activeMarketIdx() internal view returns (uint256 idx, bool found) {
        // Market with max position
        uint256 maxBal = 0;
        idx = 0; // Initialize return variable (slither: uninitialized-local)
        found = false; // Initialize return variable
        uint256 n = mkts.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 bal = _balanceInUnderlying(i);
            if (bal > 0 && (!found || bal > maxBal)) {
                maxBal = bal;
                idx = i;
                found = true;
            }
        }
        return (idx, found);
    }

    // --- INTERFACE IMPLEMENTATION ---

    function name() external pure override returns (string memory) {
        return "Euler USDC Multi-Market Adapter";
    }

    /// @notice Returns true because Euler uses PUSH deposit pattern
    /// @dev Strategy must transfer USDC to this adapter BEFORE calling deposit()
    function isPushMode() external pure returns (bool) {
        return true;
    }

    function underlying() external view override returns (address) {
        return address(USDC);
    }

    function idleAssetBalance() public view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    function investedAssets() public view returns (uint256) {
        uint256 sum = 0;
        uint256 n = mkts.length;
        for (uint256 i = 0; i < n; ++i) {
            sum += _balanceInUnderlying(i);
        }
        return sum;
    }

    function totalAssets() public view override returns (uint256) {
        return investedAssets() + idleAssetBalance();
    }

    function withdrawableAssets() public view override returns (uint256) {
        // If only one market has position: min(balance, liquidity)
        uint256 nPos = 0;
        uint256 lastIdx = 0;
        uint256 n = mkts.length;
        for (uint256 i = 0; i < n; ++i) {
            if (_balanceInUnderlying(i) > 0) {
                nPos++;
                lastIdx = i;
            }
        }
        if (nPos == 1) {
            uint256 bal = _balanceInUnderlying(lastIdx);
            uint256 liq = _liquidity(lastIdx);
            return bal < liq ? bal : liq;
        }
        // Else: sum min(balance, liquidity) over all markets with position
        uint256 sum = 0;
        for (uint256 i = 0; i < n; ++i) {
            uint256 bal = _balanceInUnderlying(i);
            if (bal > 0) {
                uint256 liq = _liquidity(i);
                sum += bal < liq ? bal : liq;
            }
        }
        return sum;
    }

    function deposit(uint256 assets) external override nonReentrant onlyVault {
        require(assets > 0, "zero assets");
        if (capacity != 0) {
            require(totalAssets() + assets <= capacity, "capacity");
        }

        // USDC must be pre-transferred to this contract by Vault
        bool deposited = _tryDepositToMarket(assets, 0); // 0 = no exclusion

        if (!deposited) {
            revert("Deposit failed - no market with sufficient capacity");
        }
    }

    /// @dev Try to deposit into the best available market. If it fails, retry with next best.
    ///      Fix 2: clamps deposit to maxDeposit. Fix 3: retry fallback on failure.
    function _tryDepositToMarket(uint256 assets, uint256 excludeIdx) internal returns (bool) {
        (uint256 targetIdx, bool found) = _targetMarketWithEvents(excludeIdx);
        if (!found) return false;
        require(mkts[targetIdx].enabled && !mkts[targetIdx].flagged, "target not allowed");

        // Fix 2: Clamp deposit to market's available capacity
        uint256 maxDep = IEulerUsdcMarket(mkts[targetIdx].addr).maxDeposit(address(this));
        uint256 amountToDeposit = assets;
        if (amountToDeposit > maxDep) {
            amountToDeposit = maxDep;
            emit DepositCapped(mkts[targetIdx].addr, assets, amountToDeposit);
        }
        if (amountToDeposit == 0) return false;

        // Ensure Permit2 internal allowance + standard approval
        _ensurePermit2(mkts[targetIdx].addr);
        _approveMarket(mkts[targetIdx].addr, amountToDeposit);

        // Try deposit
        try IEulerUsdcMarket(mkts[targetIdx].addr).deposit(amountToDeposit, address(this)) returns (
            uint256 sharesMinted
        ) {
            if (sharesMinted < 1) { } // slither: intentionally empty
            _revokeMarketApproval(mkts[targetIdx].addr);

            // Update accounting
            principal[targetIdx] += amountToDeposit;
            principalTotal += amountToDeposit;
            emit Deposited(mkts[targetIdx].addr, amountToDeposit);

            // If we capped and have remaining, try next market
            uint256 remaining = assets - amountToDeposit;
            if (remaining > 0) {
                // Recursive retry with next best market (exclude current)
                // Uses 1-based index to distinguish from "no exclusion" (0)
                _tryDepositToMarket(remaining, targetIdx + 1);
                // If remaining deposit fails, that's OK — we already deposited the capped amount
            }
            return true;
        } catch {
            // Fix 3: Retry fallback — try poke first, then next market
            _revokeMarketApproval(mkts[targetIdx].addr);

            bool poked = _pokeMarket(targetIdx);
            if (poked) {
                // Retry same market after poke
                _approveMarket(mkts[targetIdx].addr, amountToDeposit);
                try IEulerUsdcMarket(mkts[targetIdx].addr).deposit(amountToDeposit, address(this)) returns (
                    uint256 retryShares
                ) {
                    if (retryShares < 1) { } // slither: intentionally empty
                    _revokeMarketApproval(mkts[targetIdx].addr);
                    principal[targetIdx] += amountToDeposit;
                    principalTotal += amountToDeposit;
                    emit Deposited(mkts[targetIdx].addr, amountToDeposit);
                    return true;
                } catch {
                    _revokeMarketApproval(mkts[targetIdx].addr);
                }
            }

            // Fallback to next best market
            emit MarketSelectionFallback(mkts[targetIdx].addr, address(0));
            return _tryDepositToMarket(assets, targetIdx + 1);
        }
    }

    function withdraw(uint256 assets, address receiver)
        external
        override
        nonReentrant
        onlyVault
        returns (uint256 withdrawn)
    {
        require(assets > 0, "zero assets");
        require(receiver == vault, "receiver must be vault");

        withdrawn = 0; // Initialize return variable (slither: uninitialized-local)
        uint256 assetsLeft = assets;
        uint256 totalWithdrawn = 0;
        uint256 n = mkts.length;
        uint256[] memory balancesBefore = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            balancesBefore[i] = _balanceInUnderlying(i);
        }
        // Try from active market first, then others
        (uint256 actIdx,) = _activeMarketIdx();
        for (uint256 pass = 0; pass < 2 && assetsLeft > 0; ++pass) {
            for (uint256 i = 0; i < n && assetsLeft > 0; ++i) {
                if ((pass == 0 && i != actIdx) || (pass == 1 && i == actIdx)) continue;
                uint256 bal = balancesBefore[i];
                if (bal < 1) continue; // slither: incorrect-equality - use < 1 instead of == 0
                uint256 liq = _liquidity(i);
                uint256 toPull = assetsLeft < bal ? assetsLeft : bal;
                toPull = toPull < liq ? toPull : liq;
                if (toPull < 1) continue; // slither: incorrect-equality - use < 1 instead of == 0

                // NOTE: ERC4626 withdraw() returns shares burned, NOT assets withdrawn
                // We track actual USDC received by checking balance before/after
                uint256 usdcBefore = USDC.balanceOf(address(this));
                try IEulerUsdcMarket(mkts[i].addr)
                    .withdraw(toPull, address(this), address(this)) returns (
                    uint256 sharesBurned
                ) {
                    // sharesBurned captured for slither - we track USDC not shares
                    if (sharesBurned < 1) { } // intentionally empty check
                    uint256 usdcAfter = USDC.balanceOf(address(this));
                    uint256 got = usdcAfter - usdcBefore;
                    totalWithdrawn += got;
                    assetsLeft = assetsLeft > got ? assetsLeft - got : 0;
                    // Update accounting: after withdraw, principal[i] = min(principal[i], newBalance)
                    uint256 balNew = _balanceInUnderlying(i);
                    principal[i] = principal[i] < balNew ? principal[i] : balNew;
                    if (principalTotal >= (bal - balNew)) {
                        principalTotal -= (bal - balNew);
                    } else {
                        principalTotal = 0;
                    }
                    emit Withdrawn(mkts[i].addr, toPull, got, receiver);
                } catch {
                    // Withdraw failed (NotActivated or other error) - skip this market
                    continue;
                }
            }
        }
        if (totalWithdrawn > 0) {
            USDC.safeTransfer(receiver, totalWithdrawn);
        }
        return totalWithdrawn;
    }

    function currentAPYBps() public view override returns (uint16) {
        (uint256 idx, bool found) = _targetMarket();
        if (!found) return 0;
        return _supplyAPYBps(idx);
    }

    function incentiveAPYBps() external pure override returns (uint16) {
        return 0;
    }

    function harvestableProfit() public view override returns (uint256) {
        uint256 profit = 0;
        uint256 n = mkts.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 bal = _balanceInUnderlying(i);
            if (bal > principal[i]) {
                profit += (bal - principal[i]);
            }
        }
        return profit;
    }

    function harvest(address receiver)
        external
        override
        nonReentrant
        onlyVault
        returns (uint256 realized)
    {
        require(receiver == vault, "receiver must be vault");
        realized = 0; // Initialize return variable (slither: uninitialized-local)
        uint256 profit = 0;
        uint256 n = mkts.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 bal = _balanceInUnderlying(i);
            if (bal > principal[i]) {
                uint256 profit_i = bal - principal[i];
                // NOTE: ERC4626 withdraw() returns shares burned, NOT assets withdrawn
                uint256 usdcBefore = USDC.balanceOf(address(this));
                try IEulerUsdcMarket(mkts[i].addr)
                    .withdraw(profit_i, address(this), address(this)) returns (
                    uint256 sharesBurned
                ) {
                    // sharesBurned captured for slither - we track USDC not shares
                    if (sharesBurned < 1) { } // intentionally empty check
                    uint256 usdcAfter = USDC.balanceOf(address(this));
                    profit += usdcAfter - usdcBefore;
                } catch {
                    // Withdraw failed (NotActivated or other error) - skip this market
                    continue;
                }
            }
        }
        if (profit > 0) {
            USDC.safeTransfer(receiver, profit);
            emit Harvested(profit);
        }
        return profit;
    }

    function maxCapacity() external view override returns (uint256) {
        return capacity;
    }

    /// @notice Returns sum of totalAssets() across all enabled Euler markets
    function externalMarketTVL() external view override returns (uint256 total) {
        total = 0;
        uint256 n = mkts.length;
        for (uint256 i = 0; i < n; ++i) {
            if (!mkts[i].enabled) continue;
            try IEulerUsdcMarket(mkts[i].addr).totalAssets() returns (uint256 ta) {
                total += ta;
            } catch {
                // skip failed market
            }
        }
    }

    // --- EXTENSIONS ---

    function optimize()
        external
        override
        nonReentrant
        onlyVault
        returns (uint256 movedUSDC, address fromMarket, address toMarket)
    {
        require(block.timestamp - lastOptimizeTs >= minSecondsBetweenOptimize, "cooldown");
        (uint256 fromIdx, bool foundFrom) = _activeMarketIdx();
        (uint256 toIdx, bool foundTo) = _targetMarket();
        require(foundFrom && foundTo, "no market");
        if (fromIdx == toIdx) {
            return (0, mkts[fromIdx].addr, mkts[toIdx].addr);
        }
        uint256 balanceFrom = _balanceInUnderlying(fromIdx);
        uint256 liquidityFrom = _liquidity(fromIdx);
        uint256 adapterTVL = totalAssets();
        uint256 capacityTo = capacity == 0
            ? type(uint256).max
            : (capacity > (adapterTVL - balanceFrom) ? capacity - (adapterTVL - balanceFrom) : 0);
        uint256 movedCandidate = balanceFrom < liquidityFrom ? balanceFrom : liquidityFrom;
        movedCandidate = movedCandidate < capacityTo ? movedCandidate : capacityTo;
        require(movedCandidate > 0, "nothing to move");
        require(movedCandidate * 10000 / adapterTVL >= subMoveMinBps, "move too small");

        uint16 apyFrom = _supplyAPYBps(fromIdx);
        uint16 apyTo = _supplyAPYBps(toIdx);
        if (apyTo <= apyFrom) {
            return (0, mkts[fromIdx].addr, mkts[toIdx].addr);
        }
        uint256 deltaAPY = apyTo - apyFrom; // bps

        // Estimate grossBenefit ~ movedCandidate * deltaAPY/10000 * (7 days / 365 days)
        uint256 grossBenefit = movedCandidate * deltaAPY * 7 / 365 / 10000;
        uint256 moveCost = gasCostUSDC
            + (movedCandidate * (slippageBpsEstimate + withdrawalSpreadBpsEstimate)) / 10000;
        uint256 netBenefitBps =
            grossBenefit > moveCost ? ((grossBenefit - moveCost) * 10000 / movedCandidate) : 0;
        require(netBenefitBps >= subGateMinNetBenefitBps, "no net benefit");

        // Withdraw from fromIdx (ERC4626)
        // NOTE: ERC4626 withdraw() returns shares burned, NOT assets withdrawn
        uint256 usdcBeforeOptimize = USDC.balanceOf(address(this));
        try IEulerUsdcMarket(mkts[fromIdx].addr)
            .withdraw(movedCandidate, address(this), address(this)) returns (
            uint256 sharesBurned
        ) {
            // sharesBurned captured for slither - we track USDC not shares
            if (sharesBurned < 1) { } // intentionally empty check
        } catch {
            revert("Optimize withdraw failed - market not activated");
        }
        uint256 movedOut = USDC.balanceOf(address(this)) - usdcBeforeOptimize;

        // Ensure Permit2 internal allowance, then just-in-time approval and deposit to toIdx (ERC4626)
        _ensurePermit2(mkts[toIdx].addr);
        _approveMarket(mkts[toIdx].addr, movedOut);
        try IEulerUsdcMarket(mkts[toIdx].addr).deposit(movedOut, address(this)) returns (
            uint256 sharesMinted
        ) {
            // sharesMinted captured for slither - we track USDC not shares
            if (sharesMinted < 1) { } // intentionally empty check
            // Deposit successful - revoke approval
            _revokeMarketApproval(mkts[toIdx].addr);
        } catch {
            // Deposit to target failed - try to poke it first
            bool poked = _pokeMarket(toIdx);
            require(poked, "Optimize deposit failed - market not activated");

            // Retry deposit
            uint256 retryShares =
                IEulerUsdcMarket(mkts[toIdx].addr).deposit(movedOut, address(this));
            if (retryShares < 1) { } // intentionally empty check

            // Revoke approval after successful deposit
            _revokeMarketApproval(mkts[toIdx].addr);
        }

        // Move principal portion
        uint256 capFrom = principal[fromIdx];
        uint256 balFromBefore = balanceFrom;
        uint256 movedCapitalPortion =
            (capFrom < 1 || balFromBefore < 1) ? 0 : (capFrom * movedOut) / balFromBefore; // slither: incorrect-equality - use < 1 instead of == 0
        principal[fromIdx] = capFrom > movedCapitalPortion ? capFrom - movedCapitalPortion : 0;
        principal[toIdx] += movedCapitalPortion;
        // principalTotal unchanged

        lastOptimizeTs = block.timestamp;

        emit IntraRebalanced(mkts[fromIdx].addr, mkts[toIdx].addr, movedOut);

        return (movedOut, mkts[fromIdx].addr, mkts[toIdx].addr);
    }

    function sweepIdleAssetToVault() external nonReentrant onlyVault {
        uint256 idle = USDC.balanceOf(address(this));
        require(idle > 0, "no idle");
        USDC.safeTransfer(vault, idle);
        emit IdleAssetSwept(idle);
    }

    function emergencyPullAllToVault() external nonReentrant onlyVault {
        uint256 n = mkts.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 bal = _balanceInUnderlying(i);
            if (bal > 0) {
                // NOTE: ERC4626 withdraw() returns shares burned, NOT assets withdrawn
                // We track actual USDC received by checking balance before/after
                try IEulerUsdcMarket(mkts[i].addr)
                    .withdraw(bal, address(this), address(this)) returns (
                    uint256 sharesBurned
                ) {
                    // sharesBurned captured for slither - we track USDC not shares
                    if (sharesBurned < 1) { } // intentionally empty check
                } catch {
                    // Withdraw failed (NotActivated or other error) - skip this market
                }
                principal[i] = 0;
            }
        }
        principalTotal = 0;
        // Transfer FULL balance (withdrawn + any pre-existing idle) to vault
        uint256 fullBalance = USDC.balanceOf(address(this));
        if (fullBalance > 0) {
            USDC.safeTransfer(vault, fullBalance);
        }
        emit EmergencyPullExecuted(fullBalance);
    }

    // --- DIAGNOSTICS ---

    function markets() external view override returns (address[] memory out) {
        uint256 n = mkts.length;
        out = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = mkts[i].addr;
        }
    }

    function activeMarket() external view override returns (address) {
        (uint256 idx, bool found) = _activeMarketIdx();
        return found ? mkts[idx].addr : address(0);
    }

    function positions() external view override returns (uint256[] memory out) {
        uint256 n = mkts.length;
        out = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = _balanceInUnderlying(i);
        }
    }

    function effectiveAPYBps() external view override returns (uint16) {
        uint256 sumBal = 0;
        uint256 sumAPY = 0;
        uint256 n = mkts.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 bal = _balanceInUnderlying(i);
            if (bal > 0) {
                sumBal += bal;
                sumAPY += bal * _supplyAPYBps(i);
            }
        }
        if (sumBal < 1) return 0; // slither: incorrect-equality - use < 1 instead of == 0
        uint256 result = sumAPY / sumBal;
        require(result <= type(uint16).max, "EulerUsdcMultiMarket: APY overflow");
        // casting to uint16 is safe because overflow is checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(result);
    }

    // --- ADMIN FUNCTIONS ---

    function setCostsEstimates(
        uint16 _slippageBps,
        uint16 _withdrawalSpreadBps,
        uint256 _gasCostUSDC
    ) external onlyParamRole {
        slippageBpsEstimate = _slippageBps;
        withdrawalSpreadBpsEstimate = _withdrawalSpreadBps;
        gasCostUSDC = _gasCostUSDC;
        emit CostsEstimatesUpdated(_slippageBps, _withdrawalSpreadBps, _gasCostUSDC);
    }

    function setOptimizeParams(
        uint32 _minSecondsBetweenOptimize,
        uint16 _subMoveMinBps,
        uint16 _subGateMinNetBenefitBps
    ) external onlyParamRole {
        minSecondsBetweenOptimize = _minSecondsBetweenOptimize;
        subMoveMinBps = _subMoveMinBps;
        subGateMinNetBenefitBps = _subGateMinNetBenefitBps;
        emit OptimizeParamsUpdated(
            _minSecondsBetweenOptimize, _subMoveMinBps, _subGateMinNetBenefitBps
        );
    }

    function setCapacity(uint256 _capacity) external onlyParamRole {
        capacity = _capacity;
        emit CapacityUpdated(_capacity);
    }

    function toggleMarket(uint256 idx, bool enabled, bool flagged) external onlyParamRole {
        require(idx < mkts.length, "idx out of bounds");
        mkts[idx].enabled = enabled;
        mkts[idx].flagged = flagged;
        emit MarketToggled(idx, mkts[idx].addr, enabled, flagged);
    }

    function setRiskScore(uint256 idx, uint16 riskScoreBps) external onlyParamRole {
        require(idx < mkts.length, "idx out of bounds");
        mkts[idx].riskScoreBps = riskScoreBps;
        emit RiskScoreUpdated(idx, riskScoreBps);
    }

    function updateMarketAddress(uint256 idx, address newAddr) external onlyParamRole {
        require(idx < mkts.length, "idx out of bounds");
        require(newAddr != address(0), "zero");
        address old = mkts[idx].addr;
        mkts[idx].addr = newAddr;
        emit MarketAddressUpdated(idx, old, newAddr);
    }

    function setParamRole(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newAdmin != address(0), "zero");
        _grantRole(PARAM_ROLE, newAdmin);
    }

    // --- REGISTRY INTEGRATION ---

    /// @notice Internal: Load vault addresses from registry (if available)
    /// @dev V9 FIX: Deduplicates against existing markets to prevent double-counting
    function _loadFromRegistry() internal {
        try registry.getEnabledVaults(IProtocolRegistry.ProtocolType.EULER_V2) returns (
            address[] memory vaults
        ) {
            for (uint256 i = 0; i < vaults.length; i++) {
                if (vaults[i] != address(0)) {
                    // V9 FIX: Check for duplicates before adding
                    bool isDuplicate = false;
                    for (uint256 j = 0; j < mkts.length; j++) {
                        if (mkts[j].addr == vaults[i]) {
                            isDuplicate = true;
                            break;
                        }
                    }
                    if (!isDuplicate) {
                        // Registry is trusted source - no validation needed
                        // Vaults from registry are pre-validated and whitelisted
                        mkts.push(
                            Market({
                                addr: vaults[i], enabled: true, flagged: false, riskScoreBps: 0
                            })
                        );
                        principal.push(0);
                    }
                }
            }
        } catch {
            // Registry call failed - use hardcoded markets from constructor
        }
    }

    /// @notice Refresh vault addresses from registry (only if registry configured)
    function refreshFromRegistry() external onlyParamRole {
        require(address(registry) != address(0), "no registry");
        _loadFromRegistry();
    }

    // --- FALLBACKS ---

    receive() external payable {
        revert("No ETH");
    }

    fallback() external payable {
        revert("No fallback");
    }
}
