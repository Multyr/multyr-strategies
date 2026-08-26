// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ===== OpenZeppelin imports =====
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

// ===== ILendingAdapter interface (Euler pattern) =====
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

// ===== Minimal ERC-4626 interface for Morpho vaults =====
interface IERC4626Like {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner)
        external
        returns (uint256 sharesBurned);
    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assetsOut);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function totalAssets() external view returns (uint256);
}

// ===== Protocol Registry Interface =====
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

// ===== Adapter contract =====
contract MorphoUsdcMultiMarketAdapter is ILendingAdapter, AccessControl, ReentrancyGuard, Initializable {
    using SafeERC20 for IERC20;

    // ===== Roles =====
    bytes32 public constant PARAM_ROLE = keccak256("PARAM_ROLE");

    // ===== Custom Errors =====
    error AllMarketsFailed(uint256 assets);

    // ===== Constants =====
    uint16 public constant BPS_DENOM = 10000;
    uint8 public constant USDC_DECIMALS = 6;
    uint8 public constant MARKET_QUARANTINE_THRESHOLD = 3;
    uint64 public constant PPS_SNAP_TTL = uint64(2 days);

    // ===== State: Addresses =====
    // --- V10 Storage (was immutable in V9.x; logically immutable post-initialize) ---
    address public override underlying; // USDC
    address public vault; // Strategy Vault
    IProtocolRegistry public registry; // Optional registry (address(0) if not used)

    // ===== Market registry =====
    struct Market {
        address addr; // Morpho vault (ERC-4626-like)
        bool enabled; // included in allocation
        bool flagged; // defense/hold: do not increase allocation
        uint16 riskScoreBps; // 0..10000 (10000 = min risk)
    }
    Market[] internal mkts;

    // ===== Principal/accounting =====
    uint256[] public principal; // principal per market
    uint256 public principalTotal; // sum(principal)
    uint8 public activeIdx; // best market index
    uint64 public lastOptimizeTs; // last optimize timestamp

    // ===== Cached NAV per market (eliminates expensive view calls) =====
    mapping(uint256 => uint256) internal cachedMarketNav;

    // ===== CTO Hardening: per-market failure tracking =====
    mapping(address => uint8) public marketFailures;
    mapping(address => uint64) public marketLastFailureTs;
    uint32 public marketFailureDecaySeconds = 1 hours;

    // APY cached fallback (for rate provider revert resilience)
    mapping(address => uint16) public lastGoodApyBps;
    // Audit #2 P1.9 — APY cache staleness tracking (no auto-unflag).
    mapping(address => uint64) public lastApyUpdateTs;
    uint32 public apyStalenessSeconds = 1 days;

    // ===== Parameters =====
    // Scoring weights (sum = 10000) - constant for gas optimization
    uint16 public constant wAPY = 4000;
    uint16 public constant wLiq = 2000;
    uint16 public constant wRisk = 2000;
    uint16 public constant wStability = 1000;
    uint16 public constant wIncentive = 1000;

    // Rebalance/optimize params
    uint16 public rebalanceMinMoveBps = 50; // 0.5%
    uint32 public minSecondsBetweenOptimize = 6 hours;
    uint16 public constant driftToleranceBps = 10; // 0.1%
    uint16 public constant gateHorizonDays = 7;
    uint16 public gateMinNetBenefitBps = 2;
    uint16 public slippageBpsEstimate = 10;
    uint16 public withdrawalSpreadBpsEstimate = 10;
    uint256 public gasCostUSDC = 1e4; // in USDC (6 decimals)

    uint256 public capacity; // 0 = infinite

    // Global incentive APY fallback (bps)
    uint16 public incentiveBpsGlobal;

    // ===== Events =====
    event MarketAdded(uint256 indexed idx, address market);
    event MarketToggled(uint256 indexed idx, bool enabled);
    event MarketFlagged(uint256 indexed idx, bool flagged);
    event MarketUpdated(uint256 indexed idx, address market);
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
    // CTO Hardening events
    event MarketDepositFailed(address indexed market, uint256 assets, bytes reason);
    event MarketAutoFlagged(address indexed market, uint8 failures);
    event MarketApyFallbackUsed(address indexed market, uint16 cachedApy);
    event MarketApyUpdated(address indexed market, uint16 apy);
    event MarketFailureReset(address indexed market);

    // ===== Modifiers =====
    modifier onlyVault() {
        require(msg.sender == vault, "MorphoAdapter: not vault");
        _;
    }

    modifier onlyParam() {
        require(
            hasRole(PARAM_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "MorphoAdapter: not param"
        );
        _;
    }

    // ===== Constructor =====

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
        registry = IProtocolRegistry(registry_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(PARAM_ROLE, admin_);

        // Auto-load vaults from registry if available
        if (registry_ != address(0)) {
            _loadFromRegistry();
        }

        // V9 HARDENING: Fail-fast if no markets loaded
        // This prevents the V8 bug where adapter deployed with empty registry
        // would silently have mkts.length == 0 and panic on first deposit
        require(mkts.length > 0, "MorphoAdapter: no markets - registry required or use addMarket");
    }

    /// @notice Load vaults from protocol registry
    function _loadFromRegistry() internal {
        try registry.getEnabledVaults(IProtocolRegistry.ProtocolType.MORPHO) returns (
            address[] memory vaults
        ) {
            for (uint256 i = 0; i < vaults.length; i++) {
                if (vaults[i] != address(0)) {
                    // Registry is trusted source - no validation needed
                    // Vaults from registry are pre-validated and whitelisted
                    mkts.push(
                        Market({
                            addr: vaults[i], enabled: true, flagged: false, riskScoreBps: BPS_DENOM
                        })
                    );
                    principal.push(0);
                }
            }
        } catch {
            // Registry call failed - adapter will start with empty markets (use addMarket manually)
        }
    }

    // ===== Registry management (PARAM_ROLE) =====
    function addMarket(address market) external onlyParam {
        require(market != address(0), "zero");
        // Loop counters in getBestMarket()/getRebalancePlan()/sortMarketsByAPY()
        // are uint8; a 256th market would wrap the counter to 0 and infinite-loop
        // (OOG). Cap the registry well below that.
        require(mkts.length < 255, "too many markets");
        require(IERC4626Like(market).asset() == underlying, "wrong asset");
        mkts.push(Market({ addr: market, enabled: true, flagged: false, riskScoreBps: BPS_DENOM }));
        principal.push(0);
        emit MarketAdded(mkts.length - 1, market);
    }

    function toggleMarket(uint256 idx, bool enabled) external onlyParam {
        require(idx < mkts.length, "bad idx");
        mkts[idx].enabled = enabled;
        emit MarketToggled(idx, enabled);
    }

    function flagMarket(uint256 idx, bool flagged) external onlyParam {
        require(idx < mkts.length, "bad idx");
        mkts[idx].flagged = flagged;
        emit MarketFlagged(idx, flagged);
    }

    function updateMarketAddress(uint256 idx, address market) external onlyParam {
        require(idx < mkts.length, "bad idx");
        require(market != address(0), "zero");
        require(IERC4626Like(market).asset() == underlying, "wrong asset");
        mkts[idx].addr = market;
        emit MarketUpdated(idx, market);
    }

    /// @notice Refresh markets from registry (clear and reload)
    /// @dev Only works if registry was set in constructor
    function refreshFromRegistry() external onlyParam {
        require(address(registry) != address(0), "no registry");

        // Clear existing markets
        delete mkts;
        delete principal;

        // Reload from registry
        _loadFromRegistry();
    }

    function setRiskScore(uint256 idx, uint16 riskScoreBps) external onlyParam {
        require(idx < mkts.length, "bad idx");
        require(riskScoreBps <= BPS_DENOM, "bad risk");
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

    function setCapacity(uint256 cap) external onlyParam {
        capacity = cap;
        emit CapacityUpdated(cap);
    }

    function setIncentiveBpsGlobal(uint16 bps) external onlyParam {
        require(bps <= BPS_DENOM, "bad bps");
        incentiveBpsGlobal = bps;
    }

    function setParamRole(address account, bool enable) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (enable) _grantRole(PARAM_ROLE, account);
        else _revokeRole(PARAM_ROLE, account);
    }

    /// @dev Update market failure decay parameter
    function setMarketFailureDecaySeconds(uint32 _seconds) external onlyParam {
        marketFailureDecaySeconds = _seconds;
    }

    /// @dev Manual unflag a market (after human review)
    function unflagMarket(uint8 idx) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(idx < mkts.length, "bad idx");
        mkts[idx].flagged = false;
        marketFailures[mkts[idx].addr] = 0;
        emit MarketFlagged(idx, false);
    }

    // ===== Adapter interface: metadata =====
    function name() external pure override returns (string memory) {
        return "Morpho_USDC_MultiMarket_Adapter_Arbitrum";
    }

    /// @notice Returns false because Morpho uses PULL deposit pattern
    /// @dev Adapter calls transferFrom() to pull USDC from Strategy during deposit()
    function isPushMode() external pure returns (bool) {
        return false;
    }

    // underlying() auto-generated getter provided by the immutable state variable

    // ===== INTERNAL HELPERS =====

    /// @notice Sets just-in-time approval for exact amount
    /// @dev Prevents unlimited protocol exposure if Morpho market is compromised
    function _approveMarket(address marketAddr, uint256 amount) internal {
        IERC20(underlying).forceApprove(marketAddr, amount);
    }

    /// @notice Resets market approval to zero
    function _revokeMarketApproval(address marketAddr) internal {
        IERC20(underlying).forceApprove(marketAddr, 0);
    }

    // ===== CTO Hardening: Safe view helpers =====

    /// @dev Safe convertToAssets: staticcall, returns (false, 0) on revert.
    function _safeConvertToAssets(address market, uint256 shares)
        internal
        view
        returns (bool ok, uint256 assets)
    {
        (bool success, bytes memory data) =
            market.staticcall(abi.encodeWithSignature("convertToAssets(uint256)", shares));
        if (success && data.length >= 32) {
            assets = abi.decode(data, (uint256));
            return (true, assets);
        }
        return (false, 0);
    }

    /// @dev Decode uint256 APY to uint16, clamp if > type(uint16).max. Returns 0 on bad data.
    function _safeDecodeApyBps(bytes memory data) internal pure returns (uint16) {
        if (data.length < 32) return 0;
        uint256 x = abi.decode(data, (uint256));
        if (x > type(uint16).max) return type(uint16).max;
        return uint16(x);
    }

    /// @dev View-safe APY getter. Never reverts. Falls back to cached lastGoodApyBps.
    /// Audit #2 P1.9: if cache is stale (beyond apyStalenessSeconds), returns 0 so
    /// the scoring engine does not allocate based on outdated yield data.
    function _getAPYOnChainOrCached(address market) internal view returns (uint16) {
        uint64 ts = lastApyUpdateTs[market];
        if (ts == 0) return 0;
        if (apyStalenessSeconds > 0 && block.timestamp - ts > apyStalenessSeconds) return 0;
        return lastGoodApyBps[market];
    }

    /// @dev Non-view cache refresh. Safe: uses staticcall and clamps decode.
    ///      Called before every deposit attempt and in pokeAPYSnapshots.
    function _refreshApyCache(address market) internal {
        // MetaMorpho vaults: APY derived from PPS delta in pokeAPYSnapshots().
        // No on-chain getAPYBps() to call — use PPS snapshot path only.
        {
            uint16 cached = lastGoodApyBps[market];
            if (cached > 0) emit MarketApyFallbackUsed(market, cached);
        }
    }

    /// @dev Try deposit to a specific market. Returns true on success, false on failure.
    function _safeDepositToMarket(address market, uint256 assets) internal returns (bool) {
        _approveMarket(market, assets);
        try IERC4626Like(market).deposit(assets, address(this)) returns (uint256 shares) {
            _revokeMarketApproval(market);
            return shares > 0;
        } catch (bytes memory reason) {
            _revokeMarketApproval(market);
            emit MarketDepositFailed(market, assets, reason);
            return false;
        }
    }

    /// @dev Record market failure, auto-flag if threshold exceeded.
    function _recordMarketFailure(address market, uint256 idx) internal {
        // Temporal decay
        if (
            marketFailureDecaySeconds > 0 && marketLastFailureTs[market] > 0
                && block.timestamp - uint256(marketLastFailureTs[market])
                    > marketFailureDecaySeconds
        ) {
            marketFailures[market] = 0;
            emit MarketFailureReset(market);
        }
        marketLastFailureTs[market] = uint64(block.timestamp);

        uint8 failures;
        unchecked {
            failures = marketFailures[market] + 1;
        }
        marketFailures[market] = failures;

        if (failures >= MARKET_QUARANTINE_THRESHOLD && !mkts[idx].flagged) {
            mkts[idx].flagged = true;
            emit MarketAutoFlagged(market, failures);
            emit MarketFlagged(idx, true);
        }
    }

    /// @dev Reset market failure counter on success.
    function _recordMarketSuccess(address market) internal {
        if (marketFailures[market] != 0) {
            marketFailures[market] = 0;
            emit MarketFailureReset(market);
        }
        marketLastFailureTs[market] = uint64(block.timestamp);
    }

    // ===== Adapter interface: accounting =====
    function totalAssets() public view override returns (uint256) {
        return investedAssets() + idleAssetBalance();
    }

    function withdrawableAssets() public view override returns (uint256) {
        uint256 sum = 0;
        uint256 n = mkts.length;
        for (uint256 i = 0; i < n; ++i) {
            address m = mkts[i].addr;
            if (m == address(0)) continue;
            // For Morpho vaults: use maxWithdraw() which accounts for underlying market liquidity
            // Fallback to checking cash balance if maxWithdraw() is not available
            (bool success, bytes memory data) =
                m.staticcall(abi.encodeWithSignature("maxWithdraw(address)", address(this)));
            if (success && data.length >= 32) {
                sum += abi.decode(data, (uint256));
            } else {
                // Fallback: safe estimate via convertToAssets + cash
                uint256 shares = IERC20(m).balanceOf(address(this));
                if (shares < 1) continue; // slither: incorrect-equality - use < 1 instead of == 0
                (bool okConvert, uint256 assets) = _safeConvertToAssets(m, shares);
                // FIX P1.L4: continue MUST be inside if-branch so success path runs the cash-cap.
                //          Pre-fix, the unconditional continue made the cash-cap path unreachable
                //          and the market contributed 0 (under-reports liquidity).
                if (!okConvert) {
                    sum += principal[i];
                    continue;
                }
                uint256 cash = IERC20(underlying).balanceOf(m);
                sum += assets < cash ? assets : cash;
            }
        }
        return sum;
    }

    // ===== Adapter interface: deposit/withdraw (NO-CUSTODY) =====
    /// @notice Deposit with multi-market fallback. Tries active market first, then by APY desc.
    /// @dev PULL mode: strategy pre-approves, adapter pulls USDC once.
    ///      If all markets fail, revert rolls back safeTransferFrom atomically.
    function deposit(uint256 assets) external override nonReentrant onlyVault {
        require(assets > 0, "zero");
        if (capacity > 0) require(totalAssets() + assets <= capacity, "cap");

        uint256 n = mkts.length;

        // PULL mode: pull USDC once
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), assets);

        // Try active market first (fast path)
        uint256 firstTry = activeIdx;
        if (firstTry < n) {
            Market storage mkt = mkts[firstTry];
            if (mkt.enabled && !mkt.flagged && mkt.addr != address(0)) {
                _refreshApyCache(mkt.addr);
                if (_safeDepositToMarket(mkt.addr, assets)) {
                    _recordMarketSuccess(mkt.addr);
                    principal[firstTry] += assets;
                    principalTotal += assets;
                    _refreshNavCache();
                    emit Supplied(assets, mkt.addr);
                    return;
                }
                _recordMarketFailure(mkt.addr, firstTry);
            }
        }

        // Fallback: try remaining markets by APY descending
        uint8[] memory idxs = sortMarketsByAPY(false);
        for (uint256 k = 0; k < idxs.length; ++k) {
            uint256 idx = uint256(idxs[k]);
            if (idx == firstTry || idx >= n) continue;
            Market storage m = mkts[idx];
            if (!m.enabled || m.flagged || m.addr == address(0)) continue;

            _refreshApyCache(m.addr);
            if (_safeDepositToMarket(m.addr, assets)) {
                _recordMarketSuccess(m.addr);
                principal[idx] += assets;
                principalTotal += assets;
                activeIdx = uint8(idx);
                _refreshNavCache();
                emit Supplied(assets, m.addr);
                return;
            }
            _recordMarketFailure(m.addr, idx);
        }

        // All markets failed — revert rolls back entire tx including safeTransferFrom
        revert AllMarketsFailed(assets);
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
        withdrawn = 0; // Initialize return variable (slither: uninitialized-local)
        uint256 want = assets;
        uint256 avail = withdrawableAssets();
        if (want > avail) want = avail;
        require(want > 0, "zero");
        // Withdraw pro-rata from worst APY to best, or by available liquidity
        uint256 n = mkts.length;
        uint256 totalWithdrawn = 0;
        uint256 remaining = want;
        // Build sorted index list by APY ascending (worst first)
        uint8[] memory idxs = sortMarketsByAPY(false);
        for (uint256 k = 0; k < n && remaining > 0; ++k) {
            uint8 idx = idxs[k];
            address m = mkts[idx].addr;
            if (m == address(0)) continue;
            uint256 shares = IERC20(m).balanceOf(address(this));
            if (shares < 1) continue; // slither: incorrect-equality - use < 1 instead of == 0

            // Determine withdrawable amount using maxWithdraw() for accurate liquidity check
            uint256 canWithdraw;
            (bool success, bytes memory data) =
                m.staticcall(abi.encodeWithSignature("maxWithdraw(address)", address(this)));
            if (success && data.length >= 32) {
                canWithdraw = abi.decode(data, (uint256));
            } else {
                // Fallback: estimate via cash balance (for non-Morpho vaults)
                uint256 maxAssets = IERC4626Like(m).convertToAssets(shares);
                uint256 cash = IERC20(underlying).balanceOf(m);
                canWithdraw = maxAssets < cash ? maxAssets : cash;
            }

            if (canWithdraw < 1) continue; // slither: incorrect-equality - use < 1 instead of == 0
            uint256 toWithdraw = canWithdraw < remaining ? canWithdraw : remaining;
            uint256 sharesToBurn = IERC4626Like(m).previewWithdraw(toWithdraw);
            // slither: unused-return - capture return value
            uint256 actualSharesBurned = IERC4626Like(m).withdraw(toWithdraw, vault, address(this));
            require(actualSharesBurned > 0 || toWithdraw < 1, "Morpho: withdraw returned 0 shares");
            // Bookkeeping
            uint256 oldPrincipal = principal[idx];
            uint256 currentAssets =
                IERC4626Like(m).convertToAssets(IERC20(m).balanceOf(address(this)));
            uint256 principalDelta = oldPrincipal * toWithdraw
                / (currentAssets + toWithdraw > 0 ? currentAssets + toWithdraw : 1);
            if (principalDelta > principal[idx]) principalDelta = principal[idx];
            principal[idx] -= principalDelta;
            principalTotal -= principalDelta;
            totalWithdrawn += toWithdraw;
            remaining -= toWithdraw;
            emit Withdrawn(toWithdraw, m, vault);
        }
        _refreshNavCache();
        return totalWithdrawn;
    }

    // ===== Adapter interface: APY & yield =====
    uint16 public apyOverrideBps; // optional APY override (bps), 0=disabled

    // ERC-4626 APY snapshot for share price
    struct PpsSnap {
        uint256 pps;
        uint64 ts;
    }
    mapping(address => PpsSnap) public ppsSnap;

    function currentAPYBps() public view override returns (uint16) {
        if (apyOverrideBps != 0) return apyOverrideBps;
        // If active market has a recent snapshot, estimate APY from pps change
        if (activeIdx < mkts.length && mkts[activeIdx].enabled) {
            address m = mkts[activeIdx].addr;
            PpsSnap memory s = ppsSnap[m];
            // PPS_SNAP_TTL: ignore stale snapshots
            if (s.ts > 0 && block.timestamp <= uint256(s.ts) + PPS_SNAP_TTL) {
                uint256 p0 = s.pps;
                (bool ok, uint256 p1) = _safeConvertToAssets(m, 1e18);
                if (ok && p1 > p0) {
                    uint256 dt = block.timestamp - uint256(s.ts);
                    if (dt > 0) {
                        uint256 fracWad = (p1 * 1e18) / p0;
                        if (fracWad > 1e18) {
                            unchecked {
                                fracWad -= 1e18;
                            }
                            uint256 aprWad = (fracWad * 31_536_000) / dt;
                            uint256 bps = aprWad / 1e14;
                            if (bps > type(uint16).max) return type(uint16).max;
                            return uint16(bps);
                        }
                    }
                }
                // convertToAssets failed or p1 <= p0 → fall through to on-chain
            }
        }
        // Fallback to best market metric
        (, uint16 bestAPY) = getBestMarket();
        return bestAPY;
    }

    function incentiveAPYBps() external view override returns (uint16) {
        return incentiveBpsGlobal;
    }

    function harvestableProfit() external pure override returns (uint256) {
        return 0;
    }

    function harvest(
        address /*receiver*/
    )
        external
        pure
        override
        returns (uint256)
    {
        return 0;
    }

    function maxCapacity() external view override returns (uint256) {
        return capacity;
    }

    /// @notice Returns sum of totalAssets() across all enabled Morpho markets
    function externalMarketTVL() external view override returns (uint256 total) {
        total = 0;
        uint256 n = mkts.length;
        for (uint256 i = 0; i < n; ++i) {
            if (!mkts[i].enabled) continue;
            try IERC4626Like(mkts[i].addr).totalAssets() returns (uint256 ta) {
                total += ta;
            } catch {
                // skip failed market
            }
        }
    }

    function setAPYOverrideBps(uint16 bps) external onlyRole(PARAM_ROLE) {
        require(bps <= 10000, "bps>10000");
        apyOverrideBps = bps;
    }

    function pokeAPYSnapshots() external onlyRole(PARAM_ROLE) {
        uint256 n = mkts.length;
        uint64 nowTs = uint64(block.timestamp);
        for (uint256 i = 0; i < n; ++i) {
            address m = mkts[i].addr;
            if (m == address(0)) continue;
            _refreshApyCache(m);
            (bool ok, uint256 pps) = _safeConvertToAssets(m, 1e18);
            if (ok) {
                ppsSnap[m] = PpsSnap({ pps: pps, ts: nowTs });
                // Audit #2 P1.9 — record when APY was last successfully refreshed.
                lastApyUpdateTs[m] = nowTs;
            }
        }
        _refreshNavCache();
    }

    // ===== Optimize/rebalance (hardened) =====
    function optimize()
        external
        nonReentrant
        onlyVault
        returns (uint256 movedUSDC, address fromMarket, address toMarket)
    {
        require(block.timestamp >= lastOptimizeTs + minSecondsBetweenOptimize, "cooldown");
        (uint8 fromIdx, uint8 toIdx, uint256 moveAmount, int256 netBenefitBps) = getRebalancePlan();
        require(moveAmount > 0, "no move");
        require(netBenefitBps >= int256(uint256(gateMinNetBenefitBps)), "no benefit");

        fromMarket = mkts[fromIdx].addr;
        toMarket = mkts[toIdx].addr;
        require(fromMarket != address(0) && toMarket != address(0), "bad market");

        // Safe withdraw
        try IERC4626Like(fromMarket).withdraw(moveAmount, address(this), address(this)) returns (
            uint256 _sharesBurned
        ) {
            emit OptimizeMarketWithdrawn(fromIdx, toIdx, moveAmount, _sharesBurned);
        }
        catch (bytes memory reason) {
            emit MarketDepositFailed(fromMarket, moveAmount, reason);
            _recordMarketFailure(fromMarket, fromIdx);
            return (0, fromMarket, toMarket);
        }

        // Safe deposit to target
        _refreshApyCache(toMarket);
        if (!_safeDepositToMarket(toMarket, moveAmount)) {
            _recordMarketFailure(toMarket, toIdx);
            // Re-deposit to source as fallback
            _refreshApyCache(fromMarket);
            _safeDepositToMarket(fromMarket, moveAmount);
            // Worst case: funds idle in adapter. Strategy will recall via withdraw.
            return (0, fromMarket, toMarket);
        }

        _recordMarketSuccess(toMarket);

        // Accounting: move principal
        uint256 fromP = principal[fromIdx];
        uint256 delta = fromP < moveAmount ? fromP : moveAmount;
        principal[fromIdx] = fromP - delta;
        principal[toIdx] += moveAmount;

        activeIdx = toIdx;
        lastOptimizeTs = uint64(block.timestamp);
        _refreshNavCache();
        emit IntraRebalanced(fromMarket, toMarket, moveAmount);
        return (moveAmount, fromMarket, toMarket);
    }

    // ===== Telemetry/API =====
    function markets() external view returns (address[] memory) {
        uint256 n = mkts.length;
        address[] memory out = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = mkts[i].addr;
        }
        return out;
    }

    function activeMarket() external view returns (address) {
        return mkts[activeIdx].addr;
    }

    function positions() external view returns (uint256[] memory assetsByMarket) {
        uint256 n = mkts.length;
        assetsByMarket = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            address m = mkts[i].addr;
            if (m == address(0)) continue;
            uint256 shares = IERC20(m).balanceOf(address(this));
            (bool ok, uint256 assets) = _safeConvertToAssets(m, shares);
            assetsByMarket[i] = ok ? assets : principal[i];
        }
    }

    function effectiveAPYBps() external view returns (uint16) {
        uint256 tvl = totalAssets();
        if (tvl < 1) return 0; // slither: incorrect-equality - use < 1 instead of == 0
        uint256 n = mkts.length;
        uint256 sum = 0;
        for (uint256 i = 0; i < n; ++i) {
            address m = mkts[i].addr;
            if (m == address(0)) continue;
            uint256 shares = IERC20(m).balanceOf(address(this));
            if (shares < 1) continue; // slither: incorrect-equality - use < 1 instead of == 0
            (bool ok, uint256 alloc) = _safeConvertToAssets(m, shares);
            if (!ok) alloc = principal[i]; // fallback
            uint16 apy = getAPYOnChain(m);
            sum += alloc * apy;
        }
        uint256 result = sum / tvl;
        if (result > type(uint16).max) return type(uint16).max;
        return uint16(result);
    }

    // ===== Internal: Market scoring, APY, selection =====

    /// @dev View-safe wrapper — all callsites use this. Falls back to cached APY.
    function getAPYOnChain(address market) internal view returns (uint16) {
        return _getAPYOnChainOrCached(market);
    }

    function getBestMarket() internal view returns (uint8 idx, uint16 apy) {
        uint256 n = mkts.length;
        uint16 best = 0;
        uint8 bestIdx = 0;
        for (uint8 i = 0; i < n; ++i) {
            Market storage m = mkts[i];
            if (!m.enabled || m.flagged || m.addr == address(0)) continue;
            uint16 apy_ = getAPYOnChain(m.addr);
            if (apy_ > best) {
                best = apy_;
                bestIdx = i;
            }
        }
        return (bestIdx, best);
    }

    function getActiveOrBestMarket() internal view returns (uint8) {
        Market storage m = mkts[activeIdx];
        if (m.enabled && !m.flagged && m.addr != address(0)) return activeIdx;
        (uint8 bestIdx,) = getBestMarket();
        return bestIdx;
    }

    // Returns (fromIdx, toIdx, moveAmount, netBenefitBps)
    function getRebalancePlan() internal view returns (uint8, uint8, uint256, int256) {
        // Find best and worst market by score, and amount to move
        uint8 n = uint8(mkts.length);
        if (n < 2) return (0, 0, 0, 0);
        // Calculate scores for enabled markets
        uint16[] memory scores = new uint16[](n);
        for (uint8 i = 0; i < n; ++i) {
            scores[i] = marketScore(i);
        }
        // Find fromIdx (lowest) and toIdx (highest)
        uint8 fromIdx = 0;
        uint8 toIdx = 0;
        uint16 minScore = type(uint16).max;
        uint16 maxScore = 0;
        for (uint8 i = 0; i < n; ++i) {
            if (!mkts[i].enabled || mkts[i].addr == address(0)) continue;
            if (scores[i] < minScore) {
                minScore = scores[i];
                fromIdx = i;
            }
            if (!mkts[i].flagged && scores[i] > maxScore) {
                maxScore = scores[i];
                toIdx = i;
            }
        }
        if (fromIdx == toIdx) return (0, 0, 0, 0);
        // Compute move amount (all alloc in fromIdx above drift) — safe call
        (bool okFrom, uint256 fromAlloc) = _safeConvertToAssets(
            mkts[fromIdx].addr, IERC20(mkts[fromIdx].addr).balanceOf(address(this))
        );
        if (!okFrom) return (0, 0, 0, 0); // Can't rebalance if can't price source market
        uint256 tvl = totalAssets();
        uint256 minMove = tvl * rebalanceMinMoveBps / BPS_DENOM;
        if (fromAlloc < minMove) return (0, 0, 0, 0);
        // Compute benefit/cost
        uint16 apyFrom = getAPYOnChain(mkts[fromIdx].addr);
        uint16 apyTo = getAPYOnChain(mkts[toIdx].addr);
        require(fromAlloc <= uint256(type(int256).max), "MorphoUsdcMultiMarket: fromAlloc overflow");
        require(
            gasCostUSDC <= uint256(type(int256).max), "MorphoUsdcMultiMarket: gasCostUSDC overflow"
        );
        // casting to int256 is safe because overflow is checked above (uint16/uint8 always fit in int256)
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 deltaAPY = int256(uint256(apyTo)) - int256(uint256(apyFrom));
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 grossBenefit = int256(fromAlloc) * deltaAPY * int256(uint256(gateHorizonDays))
            / (int256(uint256(BPS_DENOM)) * 365);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 moveCost = int256(gasCostUSDC) + int256(fromAlloc)
            * int256(uint256(slippageBpsEstimate + withdrawalSpreadBpsEstimate))
            / int256(uint256(BPS_DENOM));
        int256 netBenefit = grossBenefit - moveCost;
        int256 netBenefitBps =
            netBenefit * int256(uint256(BPS_DENOM)) / int256(fromAlloc < 1 ? 1 : fromAlloc); // slither: incorrect-equality - use < 1 instead of == 0
        return (fromIdx, toIdx, fromAlloc, netBenefitBps);
    }

    // Market composite score (0..10000) — hardened with safe calls
    function marketScore(uint8 idx) internal view returns (uint16) {
        Market storage m = mkts[idx];
        if (!m.enabled || m.addr == address(0)) return 0;
        // APY (safe: _getAPYOnChainOrCached never reverts)
        uint16 apy = getAPYOnChain(m.addr);
        // Liq: liquidity ratio (cash/tvl, bps) — safe calls
        uint256 shares = IERC20(m.addr).balanceOf(address(this));
        (bool okAssets, uint256 assets) = _safeConvertToAssets(m.addr, shares);
        if (!okAssets) assets = principal[idx];

        // Safe totalAssets call for market TVL
        (bool okTvl, bytes memory tvlData) =
            m.addr.staticcall(abi.encodeWithSignature("totalAssets()"));
        uint256 tvl = (okTvl && tvlData.length >= 32) ? abi.decode(tvlData, (uint256)) : 0;

        uint256 cash = IERC20(underlying).balanceOf(m.addr);
        uint256 liqCalc = tvl == 0 ? 0 : (cash * BPS_DENOM) / tvl;
        if (liqCalc > type(uint16).max) liqCalc = type(uint16).max;
        uint16 liq = uint16(liqCalc);
        // Risk: 10000 - riskScoreBps
        uint16 risk = BPS_DENOM - m.riskScoreBps;
        // Stability: use APY as proxy (no EMA)
        uint16 stability = apy;
        // Incentive: global
        uint16 incentive = incentiveBpsGlobal;
        // Weighted sum
        uint16 score = uint16(
            (uint256(wAPY)
                    * apy
                    + uint256(wLiq)
                    * liq
                    + uint256(wRisk)
                    * risk
                    + uint256(wStability)
                    * stability
                    + uint256(wIncentive)
                    * incentive) / BPS_DENOM
        );
        return score;
    }

    // Sort markets by APY, ascending if asc=true, descending if asc=false
    function sortMarketsByAPY(bool asc) internal view returns (uint8[] memory idxs) {
        uint256 n = mkts.length;
        idxs = new uint8[](n);
        for (uint8 i = 0; i < n; ++i) {
            idxs[i] = i;
        }
        // Simple selection sort (n<=10)
        for (uint8 i = 0; i < n; ++i) {
            uint8 best = i;
            for (uint8 j = i + 1; j < n; ++j) {
                uint16 apyBest = getAPYOnChain(mkts[idxs[best]].addr);
                uint16 apyJ = getAPYOnChain(mkts[idxs[j]].addr);
                if (asc ? (apyJ < apyBest) : (apyJ > apyBest)) best = j;
            }
            if (best != i) {
                uint8 tmp = idxs[i];
                idxs[i] = idxs[best];
                idxs[best] = tmp;
            }
        }
    }

    // ===== Idle Asset & Emergency Recovery =====
    event IdleAssetSwept(uint256 amount);
    event EmergencyPullExecuted(uint256 amount);
    /// @dev SLITHER-FIX-3: per-market redeem result captured for incident-response observability.
    event EmergencyMarketRedeemed(uint256 indexed marketIdx, address indexed market, uint256 shares, uint256 assetsOut);
    /// @dev SLITHER-FIX-6: optimize() per-market move telemetry.
    event OptimizeMarketWithdrawn(uint256 indexed fromIdx, uint256 indexed toIdx, uint256 requested, uint256 actualWithdrawn);

    function idleAssetBalance() public view returns (uint256) {
        return IERC20(underlying).balanceOf(address(this));
    }

    /// @notice Returns invested assets from cached per-market NAV (O(n) reads from storage, no external calls)
    function investedAssets() public view returns (uint256 total) {
        uint256 n = mkts.length;
        for (uint256 i = 0; i < n; ++i) {
            if (principal[i] == 0 && cachedMarketNav[i] == 0) continue; // skip empty
            total += cachedMarketNav[i];
        }
    }

    /// @notice Returns invested assets via live external calls (expensive, use for off-chain reads)
    function investedAssetsLive() public view returns (uint256 sum) {
        uint256 n = mkts.length;
        for (uint256 i = 0; i < n; ++i) {
            address m = mkts[i].addr;
            if (m == address(0)) continue;
            uint256 shares = IERC20(m).balanceOf(address(this));
            if (shares < 1) continue; // slither: incorrect-equality - use < 1 instead of == 0
            (bool ok, uint256 assets) = _safeConvertToAssets(m, shares);
            sum += ok ? assets : principal[i];
        }
    }

    /// @notice Refresh cached NAV for all markets (callable by vault)
    function refreshNavCache() external onlyVault {
        _refreshNavCache();
    }

    /// @notice Internal: refresh cached NAV for all markets
    function _refreshNavCache() internal {
        uint256 n = mkts.length;
        for (uint256 i = 0; i < n; ++i) {
            if (principal[i] == 0) { cachedMarketNav[i] = 0; continue; }
            address m = mkts[i].addr;
            if (m == address(0)) { cachedMarketNav[i] = 0; continue; }
            uint256 shares = IERC20(m).balanceOf(address(this));
            if (shares < 1) { cachedMarketNav[i] = 0; continue; }
            (bool ok, uint256 assets) = _safeConvertToAssets(m, shares);
            cachedMarketNav[i] = ok ? assets : principal[i];
        }
    }

    function sweepIdleAssetToVault() external nonReentrant onlyVault {
        uint256 idle = IERC20(underlying).balanceOf(address(this));
        require(idle > 0, "no idle");
        IERC20(underlying).safeTransfer(vault, idle);
        emit IdleAssetSwept(idle);
    }

    function emergencyPullAllToVault() external nonReentrant onlyVault {
        uint256 n = mkts.length;
        for (uint256 i = 0; i < n; ++i) {
            address m = mkts[i].addr;
            if (m == address(0)) continue;
            uint256 shares = IERC20(m).balanceOf(address(this));
            if (shares < 1) continue; // slither: incorrect-equality - use < 1 instead of == 0
            try IERC4626Like(m).redeem(shares, address(this), address(this)) returns (uint256 _assetsOut) {
                emit EmergencyMarketRedeemed(i, m, shares, _assetsOut);
            } catch {
                emit EmergencyMarketRedeemed(i, m, shares, 0);
            }
            principal[i] = 0;
        }
        principalTotal = 0;
        // Transfer FULL balance (withdrawn + any pre-existing idle) to vault
        uint256 fullBalance = IERC20(underlying).balanceOf(address(this));
        if (fullBalance > 0) {
            IERC20(underlying).safeTransfer(vault, fullBalance);
        }
        emit EmergencyPullExecuted(fullBalance);
    }

    // ===== Fallback =====
    // coverage-ignore: ETH guard — intentional revert, no asset path
    receive() external payable {
        revert("MorphoAdapter: no ether");
    }
}
