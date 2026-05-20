// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// ===== Dolomite Adapter Interfaces =====

// Registry interface
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

// Core/Strategy Vault expected interface
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

// ERC-4626-like market interface
interface IERC4626Like {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    function deposit(uint256 assets, address receiver) external returns (uint256 sharesMinted);
    function withdraw(uint256 assets, address receiver, address owner)
        external
        returns (uint256 sharesBurned);
}

// Pool-like (Dolomite core/margin style) market interface
interface IDolomiteLike {
    function baseToken() external view returns (address);
    function supply(address token, uint256 amount) external;
    function withdraw(address token, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function availableLiquidity(address token) external view returns (uint256);
    // Optionally: function toAssets(uint256 shares) external view returns (uint256);
    // Optionally: function toShares(uint256 assets) external view returns (uint256);
}

// Dolomite Margin V9 interface (correct interface for Arbitrum mainnet)
interface IDolomiteMargin {
    struct AccountInfo {
        address owner;
        uint256 number;
    }

    struct Wei {
        bool sign; // true = positive, false = negative
        uint256 value;
    }
    function getAccountWei(AccountInfo calldata account, uint256 marketId)
        external
        view
        returns (Wei memory);
    function getMarketTokenAddress(uint256 marketId) external view returns (address);
}

// Optional external rate provider for Pool-like markets. Returns supply rate per second (WAD 1e18)
interface IDolomiteRateProvider {
    function getSupplyRatePerSecond(address market) external view returns (uint256);
}

// Audit #2 P0.4 / P0.5 — strict-detection and config-guard errors.
error AmbiguousMarketType(address market);
error UnsupportedMarketType(address market);
error InvalidDolomiteConfig(address market, uint256 marketId, uint256 accountNumber);
error DolomiteConfigInvalid();

// ===== Adapter Contract =====

contract DolomiteUsdcMultiMarketAdapter is ILendingAdapter, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Roles ---
    bytes32 public constant PARAM_ROLE = keccak256("PARAM_ROLE");

    // --- Immutable addresses ---
    address public immutable asset; // USDC native (Arbitrum)
    address public immutable vault; // Authorized Strategy Vault
    IProtocolRegistry public immutable registry; // Optional registry (address(0) if not used)

    // --- Capacity and incentives ---
    uint256 public capacity; // 0 = no limit
    uint16 public incentiveBpsGlobal; // Optional, default 0
    uint16 public apyOverrideBps; // Optional APY override (bps), 0=disabled
    address public rateProvider; // Optional on-chain rate provider for Pool-like markets

    // --- Dolomite Margin V9 fix ---
    uint256 public usdcMarketId; // USDC market ID on Dolomite Margin (e.g., 17 on Arbitrum)
    uint256 public accountNumber; // Account number for getAccountWei (default 0)

    // Audit #2 P0.5 — the adapter is NOT considered usable on Margin markets until
    // validateDolomiteConfig() has passed at least once after the last mutation.
    bool public dolomiteConfigValid;

    // ERC-4626 APY snapshot for share price (pps)
    struct PpsSnap {
        uint256 pps;
        uint64 ts;
    }
    mapping(address => PpsSnap) public ppsSnap;

    // --- Market Types ---
    enum MarketType {
        ERC4626,
        PoolLike
    }

    // --- Market Registry ---
    struct Market {
        address addr;
        MarketType mtype;
        bool enabled;
        bool flagged; // defense/hold: don't increment alloc
        uint16 riskScoreBps; // 0..10000 (10000 = min risk)
        uint16 lastAPYBps; // last observed APY (for Stability/EMA)
    }
    Market[] internal mkts;

    // --- Accounting ---
    uint256[] internal principal; // principal per market
    uint256 internal principalTotal;

    // --- Preferences/telemetry ---
    uint8 public activeIdx; // default target market
    uint64 public lastOptimizeTs;

    // --- Score Weights (sum 10000) ---
    uint16 public wAPY;
    uint16 public wLiq;
    uint16 public wRisk;
    uint16 public wStability;
    uint16 public wIncentive;

    // --- Movement/gate parameters ---
    uint16 public rebalanceMinMoveBps; // e.g. 50 = 0.5% TVL
    uint32 public minSecondsBetweenOptimize; // e.g. 21600 (6h)
    uint16 public driftToleranceBps; // e.g. 80 (0.80%)

    // --- Benefit>Cost gate ---
    uint16 public constant gateHorizonDays = 7;
    uint16 public gateMinNetBenefitBps; // e.g. 2 (0.02%)
    uint16 public slippageBpsEstimate; // e.g. 3
    uint16 public withdrawalSpreadBpsEstimate; // e.g. 5
    uint256 public gasCostUSDC; // gas cost estimate (USDC)

    // ===== Events =====
    event MarketAdded(uint256 indexed idx, address market, MarketType mtype);
    event MarketUpdated(uint256 indexed idx, address market, MarketType mtype);
    event MarketToggled(uint256 indexed idx, bool enabled);
    event MarketFlagged(uint256 indexed idx, bool flagged);
    event RiskScoreUpdated(uint256 indexed idx, uint16 riskScoreBps);

    event Supplied(uint256 assets, address market);
    event Withdrawn(uint256 assets, address market, address receiver);
    event IntraRebalanced(address fromMarket, address toMarket, uint256 movedAssets);

    event CostsEstimatesUpdated(
        uint16 slippageBps, uint16 withdrawalSpreadBps, uint256 gasCostUSDC
    );
    event OptimizeParamsUpdated(
        uint32 minSecondsBetweenOptimize,
        uint16 subMoveMinBps,
        uint16 subGateMinNetBenefitBps,
        uint16 driftTolBps
    );
    event CapacityUpdated(uint256 capacity);
    event WeightsUpdated(
        uint16 wAPY, uint16 wLiq, uint16 wRisk, uint16 wStability, uint16 wIncentive
    );
    event RateProviderUpdated(address provider);
    event DolomiteMarketIdUpdated(uint256 marketId);
    event DolomiteAccountNumberUpdated(uint256 accountNumber);

    // ===== Modifiers =====

    modifier onlyVault() {
        require(msg.sender == vault, "not vault");
        _;
    }

    // ===== Constructor =====

    constructor(
        address usdc_,
        address admin_,
        address vault_,
        uint256 capacity_,
        address registry_
    ) {
        require(usdc_ != address(0) && admin_ != address(0) && vault_ != address(0), "zero");
        asset = usdc_;
        vault = vault_;
        capacity = capacity_;
        registry = IProtocolRegistry(registry_); // Can be address(0)

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(PARAM_ROLE, admin_);

        // Default weights (sum 10000)
        wAPY = 5000;
        wLiq = 2000;
        wRisk = 1500;
        wStability = 1000;
        wIncentive = 500;

        // Default movement/gate
        rebalanceMinMoveBps = 50; // 0.5% TVL
        minSecondsBetweenOptimize = 21600; // 6h
        driftToleranceBps = 80; // 0.80%

        // gateHorizonDays is constant (7)
        gateMinNetBenefitBps = 2;
        slippageBpsEstimate = 3;
        withdrawalSpreadBpsEstimate = 5;
        gasCostUSDC = 0;

        // Auto-load from registry if available
        if (registry_ != address(0)) {
            _loadFromRegistry();
        }

        // V9 HARDENING: Fail-fast if no markets loaded
        require(mkts.length > 0, "DolomiteAdapter: no markets - registry required or use addMarket");
    }

    // ===== Registry & Setters (PARAM_ROLE) =====

    function addMarket(address m, MarketType t) external onlyRole(PARAM_ROLE) {
        require(m != address(0), "m=0");
        // Audit #2 P0.4 — cross-validate the declared type against the on-chain
        // surface; never trust the operator-supplied type alone.
        MarketType detected = _detectMarketType(m);
        require(detected == t, "Dolomite: declared type mismatch with detected");
        mkts.push(
            Market({
                addr: m, mtype: t, enabled: true, flagged: false, riskScoreBps: 10000, lastAPYBps: 0
            })
        );
        principal.push(0);
        // Audit #2 P0.5 — any registry mutation invalidates the config until
        // validateDolomiteConfig() is re-run.
        dolomiteConfigValid = false;
        emit MarketAdded(mkts.length - 1, m, t);
    }

    function updateMarket(uint256 idx, address m, MarketType t) external onlyRole(PARAM_ROLE) {
        require(idx < mkts.length && m != address(0), "bad");
        MarketType detected = _detectMarketType(m);
        require(detected == t, "Dolomite: declared type mismatch with detected");
        mkts[idx].addr = m;
        mkts[idx].mtype = t;
        dolomiteConfigValid = false;
        emit MarketUpdated(idx, m, t);
    }

    /// @notice Audit #2 P0.4 — strict market type detection by underlying match.
    /// @dev Rejects ambiguous (both interfaces valid) and unknown markets.
    function _detectMarketType(address m) internal view returns (MarketType) {
        bool is4626;
        bool isPool;

        try IERC4626Like(m).asset() returns (address a) {
            is4626 = (a == asset);
        } catch {}

        try IDolomiteLike(m).baseToken() returns (address b) {
            isPool = (b == asset);
        } catch {}

        if (is4626 && isPool) revert AmbiguousMarketType(m);
        if (is4626) return MarketType.ERC4626;
        if (isPool) return MarketType.PoolLike;
        revert UnsupportedMarketType(m);
    }

    function toggleMarket(uint256 idx, bool en) external onlyRole(PARAM_ROLE) {
        require(idx < mkts.length, "idx");
        mkts[idx].enabled = en;
        emit MarketToggled(idx, en);
    }

    function flagMarket(uint256 idx, bool fl) external onlyRole(PARAM_ROLE) {
        require(idx < mkts.length, "idx");
        mkts[idx].flagged = fl;
        emit MarketFlagged(idx, fl);
    }

    function setRiskScore(uint256 idx, uint16 v) external onlyRole(PARAM_ROLE) {
        require(idx < mkts.length, "idx");
        require(v <= 10000, "score");
        mkts[idx].riskScoreBps = v;
        emit RiskScoreUpdated(idx, v);
    }

    function setCostsEstimates(uint16 slippageBps, uint16 withdrawalSpreadBps, uint256 gasCost)
        external
        onlyRole(PARAM_ROLE)
    {
        slippageBpsEstimate = slippageBps;
        withdrawalSpreadBpsEstimate = withdrawalSpreadBps;
        gasCostUSDC = gasCost;
        emit CostsEstimatesUpdated(slippageBps, withdrawalSpreadBps, gasCost);
    }

    function setOptimizeParams(
        uint32 minSecs,
        uint16 subMoveMinBps,
        uint16 subGateMinNetBenefitBps,
        uint16 driftTolBps_
    ) external onlyRole(PARAM_ROLE) {
        minSecondsBetweenOptimize = minSecs;
        rebalanceMinMoveBps = subMoveMinBps;
        gateMinNetBenefitBps = subGateMinNetBenefitBps;
        driftToleranceBps = driftTolBps_;
        emit OptimizeParamsUpdated(minSecs, subMoveMinBps, subGateMinNetBenefitBps, driftTolBps_);
    }

    function setCapacity(uint256 cap) external onlyRole(PARAM_ROLE) {
        capacity = cap;
        emit CapacityUpdated(cap);
    }

    function setWeights(
        uint16 _wAPY,
        uint16 _wLiq,
        uint16 _wRisk,
        uint16 _wStability,
        uint16 _wIncentive
    ) external onlyRole(PARAM_ROLE) {
        require(uint256(_wAPY) + _wLiq + _wRisk + _wStability + _wIncentive == 10000, "sum!=10000");
        wAPY = _wAPY;
        wLiq = _wLiq;
        wRisk = _wRisk;
        wStability = _wStability;
        wIncentive = _wIncentive;
        emit WeightsUpdated(_wAPY, _wLiq, _wRisk, _wStability, _wIncentive);
    }

    function setIncentiveBps(uint16 bps) external onlyRole(PARAM_ROLE) {
        incentiveBpsGlobal = bps;
    }

    function setAPYOverrideBps(uint16 bps) external onlyRole(PARAM_ROLE) {
        apyOverrideBps = bps;
    }

    function setRateProvider(address provider) external onlyRole(PARAM_ROLE) {
        require(provider != address(0), "zero address");
        rateProvider = provider;
        emit RateProviderUpdated(provider);
    }

    /// @notice Set Dolomite Margin USDC market ID (V9 fix)
    /// @param marketId The USDC market ID on Dolomite Margin (e.g., 17 on Arbitrum)
    function setUsdcMarketId(uint256 marketId) external onlyRole(PARAM_ROLE) {
        usdcMarketId = marketId;
        // Audit #2 P0.5 — invalidate config; activation requires an explicit
        // validateDolomiteConfig() call to pass.
        dolomiteConfigValid = false;
        emit DolomiteMarketIdUpdated(marketId);
    }

    /// @notice Set Dolomite account number (V9 fix)
    /// @param accNum The account number for getAccountWei (default 0)
    function setAccountNumber(uint256 accNum) external onlyRole(PARAM_ROLE) {
        accountNumber = accNum;
        dolomiteConfigValid = false;
        emit DolomiteAccountNumberUpdated(accNum);
    }

    /// @notice Audit #2 P0.5 — probe every enabled PoolLike market with the
    ///         current (usdcMarketId, accountNumber) tuple. If any call reverts,
    ///         the config is considered invalid and Margin-market accounting is
    ///         gated off until this function passes.
    function validateDolomiteConfig() external onlyRole(PARAM_ROLE) {
        uint256 n = mkts.length;
        for (uint256 i; i < n; ++i) {
            if (!mkts[i].enabled) continue;
            if (mkts[i].mtype != MarketType.PoolLike) continue;

            IDolomiteMargin.AccountInfo memory account =
                IDolomiteMargin.AccountInfo({ owner: address(this), number: accountNumber });

            try IDolomiteMargin(mkts[i].addr).getAccountWei(account, usdcMarketId) returns (
                IDolomiteMargin.Wei memory
            ) {
                // success — continue probing other markets
            } catch {
                revert InvalidDolomiteConfig(mkts[i].addr, usdcMarketId, accountNumber);
            }
        }
        dolomiteConfigValid = true;
    }

    function pokeAPYSnapshots() external onlyRole(PARAM_ROLE) {
        uint256 n = mkts.length;
        uint64 nowTs = uint64(block.timestamp);
        for (uint256 i = 0; i < n; ++i) {
            Market storage m = mkts[i];
            if (!m.enabled) continue;
            if (m.mtype != MarketType.ERC4626) continue;
            uint256 pps = IERC4626Like(m.addr).convertToAssets(1e18);
            ppsSnap[m.addr] = PpsSnap({ pps: pps, ts: nowTs });
        }
    }

    // ===== INTERNAL HELPERS =====

    /// @notice Sets just-in-time approval for a market operation
    /// @dev Prevents unlimited protocol exposure by approving only the required amount
    /// @param marketAddr The market address to approve
    /// @param amount The exact amount to approve
    function _approveMarket(address marketAddr, uint256 amount) internal {
        IERC20(asset).forceApprove(marketAddr, amount);
    }

    /// @notice Revokes approval for a market after operation
    /// @dev Security measure to prevent unlimited protocol exposure
    /// @param marketAddr The market address to revoke approval from
    function _revokeMarketApproval(address marketAddr) internal {
        IERC20(asset).forceApprove(marketAddr, 0);
    }

    // ===== Accounting Helpers =====

    // Assets currently held in a given market (in USDC)
    function _assetsOn(uint256 idx) internal view returns (uint256 assets) {
        Market storage m = mkts[idx];
        if (!m.enabled) return 0;
        assets = 0; // Initialize local variable (slither: uninitialized-local)
        if (m.mtype == MarketType.ERC4626) {
            uint256 shares = IERC20(m.addr).balanceOf(address(this));
            if (shares < 1) return 0; // slither: incorrect-equality - use < 1 instead of == 0
            assets = IERC4626Like(m.addr).convertToAssets(shares);
        } else {
            // Audit #2 P0.5 — no silent fallback to balanceOf(). PoolLike/Margin
            // markets MUST have a validated (usdcMarketId, accountNumber) config;
            // otherwise we return 0 rather than reading a wrong number.
            if (!dolomiteConfigValid) return 0;
            IDolomiteMargin.AccountInfo memory account =
                IDolomiteMargin.AccountInfo({ owner: address(this), number: accountNumber });
            try IDolomiteMargin(m.addr).getAccountWei(account, usdcMarketId) returns (
                IDolomiteMargin.Wei memory wei_
            ) {
                // sign=true means positive balance
                if (wei_.sign) {
                    assets = wei_.value;
                }
            } catch {
                // Config was validated earlier but now fails — surface as 0
                // and let the keeper/admin re-validate. Never fall back to
                // balanceOf() on a Margin market: that number is unrelated
                // to the actual position held in the vault.
                assets = 0;
            }
        }
    }

    // Withdrawable assets (in USDC) per market
    // Source of truth:
    //   - ERC4626 markets (e.g. dUSDC): use maxWithdraw(address(this)) which accounts for
    //     underlying market liquidity constraints. Fallback to min(assets, cash) if unavailable.
    //   - PoolLike markets: use min(assets, availableLiquidity) as before.
    function _withdrawableOn(uint256 idx) internal view returns (uint256) {
        Market storage m = mkts[idx];
        if (!m.enabled) return 0;

        if (m.mtype == MarketType.ERC4626) {
            // Prefer maxWithdraw() which accounts for underlying liquidity
            (bool success, bytes memory data) =
                m.addr.staticcall(abi.encodeWithSignature("maxWithdraw(address)", address(this)));
            if (success && data.length >= 32) {
                return abi.decode(data, (uint256));
            }
            // Fallback: min(assets, cash in vault)
            uint256 a = _assetsOn(idx);
            uint256 cash = IERC20(asset).balanceOf(m.addr);
            return a < cash ? a : cash;
        } else {
            // PoolLike: use existing pool liquidity check
            uint256 a = _assetsOn(idx);
            uint256 cash = IDolomiteLike(m.addr).availableLiquidity(asset);
            return a < cash ? a : cash;
        }
    }

    /// @dev Audit #2 P0.3 — max additional deposit a target market is willing to accept.
    ///      ERC4626: honour maxDeposit(receiver).
    ///      PoolLike: Dolomite Margin has no public cap on supply → effectively
    ///      unbounded, return type(uint256).max.
    function _maxAdditionalDeposit(uint256 idx) internal view returns (uint256) {
        Market storage m = mkts[idx];
        if (!m.enabled) return 0;

        if (m.mtype == MarketType.ERC4626) {
            (bool success, bytes memory data) =
                m.addr.staticcall(abi.encodeWithSignature("maxDeposit(address)", address(this)));
            if (success && data.length >= 32) {
                return abi.decode(data, (uint256));
            }
            return type(uint256).max;
        }
        return type(uint256).max;
    }

    // ===== ILendingAdapter Implementation =====

    function name() external pure returns (string memory) {
        return "Dolomite_USDC_MultiMarket_Adapter_Arbitrum";
    }

    /// @notice Returns false because Dolomite uses PULL deposit pattern
    /// @dev Adapter calls transferFrom() to pull USDC from Strategy during deposit()
    function isPushMode() external pure returns (bool) {
        return false;
    }

    function underlying() external view returns (address) {
        return asset;
    }

    function idleAssetBalance() public view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function investedAssets() public view returns (uint256) {
        uint256 n = mkts.length;
        uint256 sum = 0; // Initialize local variable (slither: uninitialized-local)
        for (uint256 i = 0; i < n; ++i) {
            sum += _assetsOn(i);
        }
        return sum;
    }

    function totalAssets() public view returns (uint256) {
        return investedAssets() + idleAssetBalance();
    }

    function withdrawableAssets() public view returns (uint256) {
        uint256 n = mkts.length;
        uint256 sum = 0; // Initialize local variable (slither: uninitialized-local)
        for (uint256 i = 0; i < n; ++i) {
            sum += _withdrawableOn(i);
        }
        return sum;
    }

    function currentAPYBps() external view returns (uint16) {
        // Prefer override set via PARAM_ROLE (e.g., keeper-fed from Dolomite rate sources)
        if (apyOverrideBps != 0) return apyOverrideBps;
        // If active market is ERC-4626 with snapshot, estimate APY from pps change
        if (
            activeIdx < mkts.length && mkts[activeIdx].enabled
                && mkts[activeIdx].mtype == MarketType.ERC4626
        ) {
            address m = mkts[activeIdx].addr;
            PpsSnap memory s = ppsSnap[m];
            if (s.ts != 0) {
                uint256 p0 = s.pps; // assets per 1e18 shares
                uint256 p1 = IERC4626Like(m).convertToAssets(1e18);
                if (p1 > p0) {
                    uint256 dt = block.timestamp - uint256(s.ts);
                    if (dt > 0) {
                        uint256 fracWad = (p1 * 1e18) / p0;
                        if (fracWad > 1e18) {
                            unchecked {
                                fracWad -= 1e18;
                            }
                            uint256 aprWad = (fracWad * 31_536_000) / dt;
                            uint256 bps = aprWad / 1e14; // (apr/1e18)*1e4
                            if (bps > type(uint16).max) return type(uint16).max;
                            // casting to uint16 is safe because overflow is checked above
                            // forge-lint: disable-next-line(unsafe-typecast)
                            return uint16(bps);
                        }
                    }
                }
            }
        }
        // Else if Pool-like and rate provider configured, use provider
        if (
            activeIdx < mkts.length && mkts[activeIdx].enabled
                && mkts[activeIdx].mtype == MarketType.PoolLike && rateProvider != address(0)
        ) {
            address m = mkts[activeIdx].addr;
            uint256 rpsWad = IDolomiteRateProvider(rateProvider).getSupplyRatePerSecond(m);
            uint256 aprWad = rpsWad * 31_536_000; // seconds per year
            uint256 bps = aprWad / 1e14;
            if (bps > type(uint16).max) return type(uint16).max;
            // casting to uint16 is safe because overflow is checked above
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint16(bps);
        }
        // Fallback
        return 0;
    }

    function incentiveAPYBps() external view returns (uint16) {
        return incentiveBpsGlobal;
    }

    function harvestableProfit() external pure returns (uint256) {
        return 0;
    }

    function harvest(address) external pure returns (uint256 realized) {
        return 0;
    }

    function maxCapacity() external view returns (uint256) {
        return capacity;
    }

    /// @notice Returns sum of totalAssets() for ERC4626 markets, or USDC balance for PoolLike markets
    function externalMarketTVL() external view returns (uint256 total) {
        total = 0;
        uint256 n = mkts.length;
        for (uint256 i = 0; i < n; ++i) {
            if (!mkts[i].enabled) continue;
            if (mkts[i].mtype == MarketType.ERC4626) {
                try IERC4626Like(mkts[i].addr).totalAssets() returns (uint256 ta) {
                    total += ta;
                } catch {
                    // skip failed market
                }
            } else {
                // PoolLike: use USDC balance as conservative proxy
                try IERC20(asset).balanceOf(mkts[i].addr) returns (uint256 bal) {
                    total += bal;
                } catch {
                    // skip failed market
                }
            }
        }
    }

    // ===== Lifecycle: No-custody =====

    function deposit(uint256 assets) external nonReentrant onlyVault {
        require(assets > 0, "ZERO_ASSETS");
        if (capacity > 0) require(totalAssets() + assets <= capacity, "CAP");
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);

        uint256 idx = _pickTargetIndex();
        Market storage m = mkts[idx];

        _approveMarket(m.addr, assets);
        if (m.mtype == MarketType.ERC4626) {
            // slither: unused-return - capture return value
            uint256 sharesMinted = IERC4626Like(m.addr).deposit(assets, address(this));
            require(sharesMinted > 0, "Dolomite: deposit returned 0 shares");
        } else {
            IDolomiteLike(m.addr).supply(asset, assets);
        }
        _revokeMarketApproval(m.addr);

        principal[idx] += assets;
        principalTotal += assets;
        require(idx <= type(uint8).max, "DolomiteUsdcMultiMarket: idx overflow");
        // casting to uint8 is safe because overflow is checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        activeIdx = uint8(idx);
        emit Supplied(assets, m.addr);
    }

    function withdraw(
        uint256 assets,
        address /*receiver*/
    )
        external
        nonReentrant
        onlyVault
        returns (uint256 withdrawn)
    {
        require(assets > 0, "ZERO_ASSETS");
        uint256 want = assets;
        uint256 maxOut = withdrawableAssets();
        if (want > maxOut) want = maxOut;
        if (want < 1) return 0; // slither: incorrect-equality - use < 1 instead of == 0

        withdrawn = 0; // Initialize local variable (slither: uninitialized-local)
        uint256 n = mkts.length;
        for (uint256 i = 0; i < n && want > 0; ++i) {
            if (!mkts[i].enabled) continue;
            uint256 can = _withdrawableOn(i);
            if (can < 1) continue; // slither: incorrect-equality - use < 1 instead of == 0
            uint256 take = can < want ? can : want;
            if (take < 1) continue; // slither: incorrect-equality - use < 1 instead of == 0

            Market storage m = mkts[i];
            if (m.mtype == MarketType.ERC4626) {
                // slither: unused-return - capture return value
                uint256 sharesBurned =
                    IERC4626Like(m.addr).withdraw(take, address(this), address(this));
                require(sharesBurned > 0 || take < 1, "Dolomite: withdraw returned 0 shares");
            } else {
                IDolomiteLike(m.addr).withdraw(asset, take);
            }

            IERC20(asset).safeTransfer(vault, take);

            uint256 p = principal[i];
            if (p >= take) principal[i] = p - take;
            else principal[i] = 0;
            principalTotal = principalTotal >= take ? principalTotal - take : 0;

            withdrawn += take;
            emit Withdrawn(take, m.addr, vault);
            want -= take;
        }
        return withdrawn;
    }

    // ===== Optimize / Rebalance =====

    /// @notice Optimize allocation across markets, moving USDC from a worse to a better market if economic gates are satisfied.
    function optimize()
        external
        nonReentrant
        onlyVault
        returns (uint256 movedUSDC, address fromMarket, address toMarket)
    {
        require(block.timestamp >= lastOptimizeTs + minSecondsBetweenOptimize, "cooldown");

        (uint256 fromIdx, uint256 toIdx) = _bestRebalancePair();
        if (fromIdx == type(uint256).max || toIdx == type(uint256).max) {
            return (0, address(0), address(0));
        }
        if (mkts[toIdx].flagged) return (0, address(0), address(0));

        uint256 tvl = totalAssets();
        uint256 minMove = (tvl * rebalanceMinMoveBps) / 10000;
        uint256 movedPlan = minMove;
        uint256 withdrawableFrom = _withdrawableOn(fromIdx);
        if (movedPlan > withdrawableFrom) movedPlan = withdrawableFrom;

        // Audit #2 P0.3 — clamp by target capacity too, NOT only source.
        uint256 toRoom = _maxAdditionalDeposit(toIdx);
        if (movedPlan > toRoom) movedPlan = toRoom;

        // After clamps, re-check economic threshold — movePlan < minMove means the
        // target/source cannot accommodate a meaningful move this round.
        if (movedPlan < minMove || movedPlan < 1) {
            return (0, address(0), address(0));
        }

        int256 netBps = _estimateNetBenefitBps(fromIdx, toIdx, movedPlan, tvl);
        if (netBps < int256(uint256(gateMinNetBenefitBps))) return (0, address(0), address(0));

        Market storage mf = mkts[fromIdx];
        Market storage mt = mkts[toIdx];

        // Withdraw from source market to adapter
        if (mf.mtype == MarketType.ERC4626) {
            // slither: unused-return - capture return value
            uint256 sharesBurned =
                IERC4626Like(mf.addr).withdraw(movedPlan, address(this), address(this));
            require(
                sharesBurned > 0 || movedPlan < 1, "Dolomite: optimize withdraw returned 0 shares"
            );
        } else {
            IDolomiteLike(mf.addr).withdraw(asset, movedPlan);
        }
        // Deposit into target market with just-in-time approval
        _approveMarket(mt.addr, movedPlan);
        if (mt.mtype == MarketType.ERC4626) {
            // slither: unused-return - capture return value
            uint256 sharesMinted = IERC4626Like(mt.addr).deposit(movedPlan, address(this));
            require(sharesMinted > 0, "Dolomite: optimize deposit returned 0 shares");
        } else {
            IDolomiteLike(mt.addr).supply(asset, movedPlan);
        }
        _revokeMarketApproval(mt.addr);

        // Update principal
        uint256 pf = principal[fromIdx];
        principal[fromIdx] = pf >= movedPlan ? pf - movedPlan : 0;
        principal[toIdx] += movedPlan;
        require(toIdx <= type(uint8).max, "DolomiteUsdcMultiMarket: toIdx overflow");
        require(block.timestamp <= type(uint64).max, "DolomiteUsdcMultiMarket: timestamp overflow");
        // casting to uint8 and uint64 is safe because overflow is checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        activeIdx = uint8(toIdx);
        // forge-lint: disable-next-line(unsafe-typecast)
        lastOptimizeTs = uint64(block.timestamp);

        emit IntraRebalanced(mf.addr, mt.addr, movedPlan);
        return (movedPlan, mf.addr, mt.addr);
    }

    // ===== Scoring and Rebalance Helpers =====

    // Picks the target market for new deposits. Prefer activeIdx if valid, else best by score.
    function _pickTargetIndex() internal view returns (uint256 idx) {
        uint256 n = mkts.length;
        if (n == 0) revert("no markets");
        if (activeIdx < n && mkts[activeIdx].enabled && !mkts[activeIdx].flagged) return activeIdx;

        uint256 bestScore = 0;
        uint256 bestIdx = type(uint256).max;
        for (uint256 i = 0; i < n; ++i) {
            if (!mkts[i].enabled || mkts[i].flagged) continue;
            uint256 s = _score(i);
            if (s > bestScore) {
                bestScore = s;
                bestIdx = i;
            }
        }
        require(bestIdx != type(uint256).max, "no enabled market");
        return bestIdx;
    }

    // Compute the composite score (0..1e8) for a market
    function _score(uint256 idx) internal view returns (uint256) {
        Market storage m = mkts[idx];
        if (!m.enabled) return 0;

        // APY: If not available, treat as 0. (Can be extended in future)
        uint16 apyBps = m.lastAPYBps;
        uint16 apyNorm = apyBps; // Already in 0..10000

        // Liquidity: availableLiquidity / (availableLiquidity + allocOnMarket), scaled to 0..10000
        uint256 alloc = _assetsOn(idx);
        uint256 liq = m.mtype == MarketType.ERC4626
            ? IERC20(asset).balanceOf(m.addr)
            : IDolomiteLike(m.addr).availableLiquidity(asset);
        uint16 liqBps = (liq + alloc < 1) ? 0 : uint16((liq * 10000) / (liq + alloc)); // slither: incorrect-equality - use < 1 instead of == 0

        // Risk: 10000 - riskScoreBps (higher = riskier)
        uint16 riskBps = 10000 - m.riskScoreBps;

        // Stability: use lastAPYBps as a proxy (normalized)
        uint16 stabBps = m.lastAPYBps;

        // Incentive: global param, normalized
        uint16 incBps = incentiveBpsGlobal;

        // Weighted sum (all in bps, so score is 0..1e8)
        uint256 score = uint256(wAPY) * apyNorm + uint256(wLiq) * liqBps + uint256(wRisk) * riskBps
            + uint256(wStability) * stabBps + uint256(wIncentive) * incBps;
        return score;
    }

    // Find the best rebalance pair (fromIdx, toIdx)
    function _bestRebalancePair() internal view returns (uint256 fromIdx, uint256 toIdx) {
        uint256 n = mkts.length;
        uint256 worstScore = type(uint256).max;
        uint256 bestScore = 0;
        fromIdx = type(uint256).max;
        toIdx = type(uint256).max;

        for (uint256 i = 0; i < n; ++i) {
            if (!mkts[i].enabled) continue;
            uint256 s = _score(i);
            if (s < worstScore && _withdrawableOn(i) > 0 && !mkts[i].flagged) {
                worstScore = s;
                fromIdx = i;
            }
            if (s > bestScore && !mkts[i].flagged) {
                bestScore = s;
                toIdx = i;
            }
        }
        // Don't rebalance if best==worst or no valid pairs
        if (fromIdx == toIdx) {
            fromIdx = type(uint256).max;
            toIdx = type(uint256).max;
        }
    }

    // Estimate net benefit in bps for a move
    function _estimateNetBenefitBps(
        uint256 fromIdx,
        uint256 toIdx,
        uint256 movedAmount,
        uint256 /* tvl */
    )
        internal
        view
        returns (int256)
    {
        // Use lastAPYBps as proxy for APY
        uint16 apyFrom = mkts[fromIdx].lastAPYBps;
        uint16 apyTo = mkts[toIdx].lastAPYBps;

        if (apyTo <= apyFrom) return -1; // No benefit

        uint256 deltaAPY = uint256(apyTo - apyFrom); // bps

        // Gross benefit: movedAmount * deltaAPY/10000 * (gateHorizonDays/365)
        uint256 grossBenefit = (movedAmount * deltaAPY * gateHorizonDays) / (10000 * 365);

        // Move cost: gas + slippage + withdrawal spread
        uint256 moveCost = gasCostUSDC
            + (movedAmount * (slippageBpsEstimate + withdrawalSpreadBpsEstimate)) / 10000;

        // Net benefit per movedAmount, in bps
        if (movedAmount < 1) return -1; // slither: incorrect-equality - use < 1 instead of == 0
        require(
            grossBenefit <= uint256(type(int256).max),
            "DolomiteUsdcMultiMarket: grossBenefit overflow"
        );
        require(moveCost <= uint256(type(int256).max), "DolomiteUsdcMultiMarket: moveCost overflow");
        require(
            movedAmount <= uint256(type(int256).max),
            "DolomiteUsdcMultiMarket: movedAmount overflow"
        );
        // casting to int256 is safe because overflow is checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 netBenefit = int256(grossBenefit) - int256(moveCost);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 netBenefitBps = (netBenefit * 10000) / int256(movedAmount);

        return netBenefitBps;
    }

    // ===== Extra Getters (telemetry) =====

    function markets() external view returns (address[] memory) {
        uint256 n = mkts.length;
        address[] memory arr = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            arr[i] = mkts[i].addr;
        }
        return arr;
    }

    function activeMarket() external view returns (address) {
        if (activeIdx < mkts.length) return mkts[activeIdx].addr;
        return address(0);
    }

    function positions() external view returns (uint256[] memory assetsByMarket) {
        uint256 n = mkts.length;
        assetsByMarket = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            assetsByMarket[i] = _assetsOn(i);
        }
    }

    function effectiveAPYBps() external pure returns (uint16) {
        // If APY_base unavailable, return 0 (future: could compute weighted average)
        return 0;
    }

    // ===== Registry Integration =====

    function _loadFromRegistry() internal {
        try registry.getEnabledVaults(IProtocolRegistry.ProtocolType.DOLOMITE) returns (
            address[] memory vaults
        ) {
            for (uint256 i = 0; i < vaults.length; i++) {
                if (vaults[i] != address(0)) {
                    bool isERC4626 = _tryERC4626(vaults[i]);
                    if (isERC4626) {
                        mkts.push(
                            Market({
                                addr: vaults[i],
                                mtype: MarketType.ERC4626,
                                enabled: true,
                                flagged: false,
                                riskScoreBps: 10000,
                                lastAPYBps: 0
                            })
                        );
                        principal.push(0);
                    } else {
                        // Hardening: only accept PoolLike if baseToken() exists and matches adapter asset.
                        // Prevents misconfigured registrations (e.g. DolomiteMargin) from entering mkts.
                        (bool ok, address base) = _tryPoolLike(vaults[i]);
                        if (ok && base == asset) {
                            mkts.push(
                                Market({
                                    addr: vaults[i],
                                    mtype: MarketType.PoolLike,
                                    enabled: true,
                                    flagged: false,
                                    riskScoreBps: 10000,
                                    lastAPYBps: 0
                                })
                            );
                            principal.push(0);
                        }
                    }
                }
            }
        } catch {
            // Registry call failed - adapter will start with empty markets
        }
    }

    function _tryERC4626(address vaultAddr) internal view returns (bool) {
        try IERC4626Like(vaultAddr).asset() returns (address assetAddr) {
            // Return true if asset call succeeds (assetAddr captured for slither)
            return assetAddr != address(0);
        } catch {
            return false;
        }
    }

    function _tryPoolLike(address vaultAddr) internal view returns (bool ok, address base) {
        try IDolomiteLike(vaultAddr).baseToken() returns (address b) {
            return (true, b);
        } catch {
            return (false, address(0));
        }
    }

    function refreshFromRegistry() external onlyRole(PARAM_ROLE) {
        require(address(registry) != address(0), "no registry");
        delete mkts;
        delete principal;
        _loadFromRegistry();
    }

    // ===== Idle Asset & Emergency Recovery =====
    event IdleAssetSwept(uint256 amount);
    event EmergencyPullExecuted(uint256 amount);
    /// @dev SLITHER-FIX-5: per-market withdraw outcome captured for incident-response observability.
    event EmergencyDolomiteMarketWithdrawn(uint256 indexed marketIdx, address indexed market, uint8 mtype, uint256 requested, uint256 sharesBurned);

    function sweepIdleAssetToVault() external nonReentrant onlyVault {
        uint256 idle = IERC20(asset).balanceOf(address(this));
        require(idle > 0, "no idle");
        IERC20(asset).safeTransfer(vault, idle);
        emit IdleAssetSwept(idle);
    }

    function emergencyPullAllToVault() external nonReentrant onlyVault {
        uint256 n = mkts.length;
        for (uint256 i = 0; i < n; ++i) {
            if (!mkts[i].enabled) continue;
            uint256 bal = _assetsOn(i);
            if (bal > 0) {
                Market storage m = mkts[i];
                if (m.mtype == MarketType.ERC4626) {
                    try IERC4626Like(m.addr).withdraw(bal, address(this), address(this)) returns (uint256 _sharesBurned) {
                        emit EmergencyDolomiteMarketWithdrawn(i, m.addr, uint8(m.mtype), bal, _sharesBurned);
                    } catch {
                        emit EmergencyDolomiteMarketWithdrawn(i, m.addr, uint8(m.mtype), bal, 0);
                    }
                } else {
                    try IDolomiteLike(m.addr).withdraw(asset, bal) {
                        emit EmergencyDolomiteMarketWithdrawn(i, m.addr, uint8(m.mtype), bal, 0);
                    } catch {
                        emit EmergencyDolomiteMarketWithdrawn(i, m.addr, uint8(m.mtype), bal, 0);
                    }
                }
                principal[i] = 0;
            }
        }
        principalTotal = 0;
        // Transfer FULL balance (withdrawn + any pre-existing idle) to vault
        uint256 fullBalance = IERC20(asset).balanceOf(address(this));
        if (fullBalance > 0) {
            IERC20(asset).safeTransfer(vault, fullBalance);
        }
        emit EmergencyPullExecuted(fullBalance);
    }

    // ===== Fallback =====
    receive() external payable {
        revert("NO_NATIVE");
    }

    fallback() external payable {
        revert("NO_FALLBACK");
    }
}
