// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { AaveV3USDCAdapter } from "../../../../src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol";

// ═══════════════════════════════════════════════════════════════════════════
// MOCKS
// ═══════════════════════════════════════════════════════════════════════════

contract MockUSDCAave {
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
    string public constant name = "USD Coin";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @dev Mock aToken — 1:1 with USDC; balance can be increased by mock pool to simulate yield.
contract MockAToken {
    address public underlyingAsset;
    mapping(address => uint256) public balanceOf;
    uint256 internal _supply;
    bool public revertOnTotalSupply;

    constructor(address _underlying) {
        underlyingAsset = _underlying;
    }

    function UNDERLYING_ASSET_ADDRESS() external view returns (address) {
        return underlyingAsset;
    }

    function setRevertOnTotalSupply(bool v) external { revertOnTotalSupply = v; }

    /// @dev Custom getter (not auto-generated) to allow controlled revert
    function totalSupply() external view returns (uint256) {
        if (revertOnTotalSupply) revert("totalSupply revert");
        return _supply;
    }

    // Pool calls these
    function poolMint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        _supply += amount;
    }

    function poolBurn(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "burn-insufficient");
        balanceOf[from] -= amount;
        _supply -= amount;
    }
}

/// @dev Mock Aave V3 Pool — controllable rate + cash + revert flag for getReserveData
contract MockAavePool {
    address public asset;
    address public aToken;
    uint256 public reserveLiquidityRateRay; // 1e27 scale
    bool public revertOnGetReserveData;

    constructor(address _asset, address _aToken) {
        asset = _asset;
        aToken = _aToken;
    }

    function setLiquidityRateRay(uint256 r) external { reserveLiquidityRateRay = r; }
    function setRevertOnGetReserveData(bool v) external { revertOnGetReserveData = v; }

    function supply(address _asset, uint256 amount, address onBehalfOf, uint16 /*ref*/) external {
        require(_asset == asset, "wrong asset");
        // pull underlying from msg.sender (adapter)
        MockUSDCAave(asset).transferFrom(msg.sender, address(this), amount);
        // mint aToken 1:1 to onBehalfOf
        MockAToken(aToken).poolMint(onBehalfOf, amount);
    }

    function withdraw(address _asset, uint256 amount, address to) external returns (uint256) {
        require(_asset == asset, "wrong asset");
        // burn aToken from msg.sender (adapter)
        uint256 actualAmount = amount;
        // Aave cap: cannot exceed aToken bal. We assume amount valid (test controls).
        MockAToken(aToken).poolBurn(msg.sender, actualAmount);
        MockUSDCAave(asset).transfer(to, actualAmount);
        return actualAmount;
    }

    function getReserveData(address _asset) external view returns (
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
    ) {
        require(!revertOnGetReserveData, "reserve revert");
        require(_asset == asset, "wrong asset");
        configuration = 0;
        liquidityIndex = 1e27;
        currentLiquidityRate = uint128(reserveLiquidityRateRay);
        variableBorrowIndex = 1e27;
        currentVariableBorrowRate = 0;
        currentStableBorrowRate = 0;
        lastUpdateTimestamp = uint40(block.timestamp);
        id = 0;
        aTokenAddress = aToken;
        stableDebtTokenAddress = address(0);
        variableDebtTokenAddress = address(0);
        interestRateStrategyAddress = address(0);
        accruedToTreasury = 0;
        unbacked = 0;
        isolationModeTotalDebt = 0;
    }
}

/// @dev Mock Aave Rate Provider with controllable rate + ts + revert flag
contract MockAaveRateProvider {
    uint256 public rateRay;
    uint64 public lastUpdateTs;
    bool public revertOnNew;

    function setRate(uint256 r, uint64 ts) external {
        rateRay = r;
        lastUpdateTs = ts;
    }

    function setRevertOnNew(bool v) external { revertOnNew = v; }

    function getLiquidityRateRay(address /*asset*/) external view returns (uint256) {
        return rateRay;
    }

    function getLiquidityRateRayWithTs(address /*asset*/) external view returns (uint256, uint64) {
        if (revertOnNew) revert("provider new abi unsupported");
        return (rateRay, lastUpdateTs);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// TEST CONTRACT
// ═══════════════════════════════════════════════════════════════════════════

// Minimal IERC20 totalSupply override hack: we need MockAToken to respond to .totalSupply()
// for adapter.externalMarketTVL(). Solidity-level: IERC20(aToken).totalSupply() routes to
// the public state variable `totalSupply` — which exists on MockAToken (uint256 public totalSupply).
// So no extra wiring needed. The revert flag for testing is added via a sentinel modifier.

contract AaveV3USDCAdapterTest is Test {
    MockUSDCAave internal usdc;
    MockAToken internal aToken;
    MockAavePool internal pool;
    MockAaveRateProvider internal rateProvider;
    AaveV3USDCAdapter internal adapter;

    address internal admin = address(0xA11CE);
    address internal vault = address(0xBEEF);
    address internal alice = address(0xA1);

    function setUp() public {
        usdc = new MockUSDCAave();
        aToken = new MockAToken(address(usdc));
        pool = new MockAavePool(address(usdc), address(aToken));
        rateProvider = new MockAaveRateProvider();

        adapter = new AaveV3USDCAdapter();
        adapter.initialize(address(usdc), address(pool), address(aToken), admin, vault, 0);
    }

    function _deposit(uint256 amount) internal {
        usdc.mint(vault, amount);
        vm.startPrank(vault);
        usdc.approve(address(adapter), amount);
        adapter.deposit(amount);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    function test_constructor_revertsOnZeroAsset() public {
        AaveV3USDCAdapter _tmp = new AaveV3USDCAdapter();
        vm.expectRevert(bytes("zero"));
        _tmp.initialize(address(0), address(pool), address(aToken), admin, vault, 0);
    }

    function test_constructor_revertsOnZeroPool() public {
        AaveV3USDCAdapter _tmp = new AaveV3USDCAdapter();
        vm.expectRevert(bytes("zero"));
        _tmp.initialize(address(usdc), address(0), address(aToken), admin, vault, 0);
    }

    function test_constructor_revertsOnZeroAToken() public {
        AaveV3USDCAdapter _tmp = new AaveV3USDCAdapter();
        vm.expectRevert(bytes("zero"));
        _tmp.initialize(address(usdc), address(pool), address(0), admin, vault, 0);
    }

    function test_constructor_revertsOnZeroAdmin() public {
        AaveV3USDCAdapter _tmp = new AaveV3USDCAdapter();
        vm.expectRevert(bytes("zero"));
        _tmp.initialize(address(usdc), address(pool), address(aToken), address(0), vault, 0);
    }

    function test_constructor_revertsOnZeroVault() public {
        AaveV3USDCAdapter _tmp = new AaveV3USDCAdapter();
        vm.expectRevert(bytes("zero"));
        _tmp.initialize(address(usdc), address(pool), address(aToken), admin, address(0), 0);
    }

    function test_constructor_revertsOnATokenAssetMismatch() public {
        MockUSDCAave other = new MockUSDCAave();
        MockAToken mismatched = new MockAToken(address(other));
        AaveV3USDCAdapter _tmp = new AaveV3USDCAdapter();
        vm.expectRevert(bytes("aToken/asset mismatch"));
        _tmp.initialize(address(usdc), address(pool), address(mismatched), admin, vault, 0);
    }

    function test_constructor_setsState() public view {
        assertEq(adapter.asset(), address(usdc));
        assertEq(address(adapter.pool()), address(pool));
        assertEq(adapter.aToken(), address(aToken));
        assertEq(adapter.vault(), vault);
        assertEq(adapter.maxCap(), 0);
        assertEq(uint256(adapter.maxRateStalenessSec()), 90_000);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // METADATA
    // ═══════════════════════════════════════════════════════════════════════

    function test_name() public view {
        assertEq(adapter.name(), "AaveV3_USDC_Adapter_Arbitrum");
    }

    function test_isPushMode_false() public view {
        assertFalse(adapter.isPushMode());
    }

    function test_underlying_isUSDC() public view {
        assertEq(adapter.underlying(), address(usdc));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ACCOUNTING
    // ═══════════════════════════════════════════════════════════════════════

    function test_idleAssetBalance_zero_initially() public view {
        assertEq(adapter.idleAssetBalance(), 0);
    }

    function test_idleAssetBalance_reflectsRawUSDC() public {
        usdc.mint(address(adapter), 200e6);
        assertEq(adapter.idleAssetBalance(), 200e6);
    }

    function test_investedAssets_reflectsATokenBalance() public {
        _deposit(1000e6);
        assertEq(adapter.investedAssets(), 1000e6);
    }

    function test_totalAssets_sumOfIdleAndInvested() public {
        usdc.mint(address(adapter), 100e6);
        _deposit(900e6);
        assertEq(adapter.totalAssets(), 1000e6);
    }

    function test_withdrawableAssets_boundedByPoolLiquidity() public {
        _deposit(1000e6);
        // pool has 1000e6 USDC after deposit; aToken bal = 1000e6
        // simulate pool drain: send some USDC out of pool
        vm.prank(address(pool));
        usdc.transfer(alice, 700e6); // pool now has 300e6
        assertEq(adapter.withdrawableAssets(), 300e6);
    }

    function test_withdrawableAssets_boundedByATokenBalance() public {
        _deposit(500e6);
        // pool has plenty (500e6), aToken bal = 500e6 → withdrawable = 500e6
        assertEq(adapter.withdrawableAssets(), 500e6);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // LIFECYCLE — DEPOSIT
    // ═══════════════════════════════════════════════════════════════════════

    function test_deposit_happyPath() public {
        _deposit(1000e6);
        assertEq(usdc.balanceOf(vault), 0);
        assertEq(adapter.investedAssets(), 1000e6);
        assertEq(usdc.balanceOf(address(pool)), 1000e6);
    }

    function test_deposit_revertsOnZeroAmount() public {
        vm.prank(vault);
        vm.expectRevert(bytes("ZERO_ASSETS"));
        adapter.deposit(0);
    }

    function test_deposit_revertsOnNonVault() public {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(adapter), 1000e6);
        vm.expectRevert(bytes("not vault"));
        adapter.deposit(1000e6);
        vm.stopPrank();
    }

    function test_deposit_respectsMaxCap() public {
        adapter = new AaveV3USDCAdapter();
        adapter.initialize(address(usdc), address(pool), address(aToken), admin, vault, 500e6);
        usdc.mint(vault, 600e6);
        vm.startPrank(vault);
        usdc.approve(address(adapter), 600e6);
        vm.expectRevert(bytes("CAP"));
        adapter.deposit(600e6);
        vm.stopPrank();
    }

    function test_deposit_revokesApprovalAfter() public {
        _deposit(1000e6);
        assertEq(usdc.allowance(address(adapter), address(pool)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // LIFECYCLE — WITHDRAW
    // ═══════════════════════════════════════════════════════════════════════

    function test_withdraw_happyPath() public {
        _deposit(1000e6);
        vm.prank(vault);
        uint256 got = adapter.withdraw(500e6, vault);
        assertEq(got, 500e6);
        assertEq(usdc.balanceOf(vault), 500e6);
    }

    function test_withdraw_revertsOnZeroAmount() public {
        vm.prank(vault);
        vm.expectRevert(bytes("ZERO_ASSETS"));
        adapter.withdraw(0, vault);
    }

    function test_withdraw_revertsOnNonVault() public {
        _deposit(500e6);
        vm.prank(alice);
        vm.expectRevert(bytes("not vault"));
        adapter.withdraw(100e6, vault);
    }

    function test_withdraw_clampedByPoolLiquidity() public {
        _deposit(1000e6);
        // drain pool to 200e6
        vm.prank(address(pool));
        usdc.transfer(alice, 800e6);

        vm.prank(vault);
        uint256 got = adapter.withdraw(800e6, vault);
        assertEq(got, 200e6, "clamped to pool liq");
    }

    function test_withdraw_alwaysSendsToVault() public {
        _deposit(1000e6);
        vm.prank(vault);
        adapter.withdraw(500e6, alice);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(vault), 500e6);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // YIELD VIEWS — P1.L1 HYBRID PATTERN
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev P1.L1 step (1): admin override has top priority
    function test_currentAPYBps_overrideTakesPriority() public {
        vm.prank(admin);
        adapter.setAPYOverrideBps(450);

        // Even with rate provider + direct read populated, override wins
        rateProvider.setRate(5e25, uint64(block.timestamp)); // 500 bps
        vm.prank(admin);
        adapter.setRateProvider(address(rateProvider));
        pool.setLiquidityRateRay(7e25); // 700 bps

        assertEq(adapter.currentAPYBps(), 450);
    }

    /// @dev P1.L1 step (2): keeper cache fresh → uses cache
    function test_currentAPYBps_keeperCacheFresh() public {
        // 5% APY = 500 bps = 5e25 ray
        rateProvider.setRate(5e25, uint64(block.timestamp));
        vm.prank(admin);
        adapter.setRateProvider(address(rateProvider));

        // Pool also has direct rate but cache wins when fresh
        pool.setLiquidityRateRay(8e25); // would be 800 bps if fallback used

        assertEq(adapter.currentAPYBps(), 500);
    }

    /// @dev P1.L1 step (3): cache stale → falls through to direct read
    function test_currentAPYBps_keeperCacheStale_FallsToDirect() public {
        // Cache age > maxRateStalenessSec (default 24h)
        rateProvider.setRate(5e25, uint64(block.timestamp));
        vm.prank(admin);
        adapter.setRateProvider(address(rateProvider));

        skip(2 days); // age > 86400
        pool.setLiquidityRateRay(7e25); // 700 bps direct

        assertEq(adapter.currentAPYBps(), 700, "fell back to direct read");
    }

    /// @dev P1.L1 step (3): provider doesn't support new ABI → catches and falls through
    function test_currentAPYBps_providerNewAbiUnsupported_FallsToDirect() public {
        rateProvider.setRevertOnNew(true);
        rateProvider.setRate(5e25, uint64(block.timestamp));
        vm.prank(admin);
        adapter.setRateProvider(address(rateProvider));
        pool.setLiquidityRateRay(6e25); // 600 bps direct

        assertEq(adapter.currentAPYBps(), 600);
    }

    /// @dev P1.L1: zero rate from cache → still falls through to direct
    function test_currentAPYBps_cacheZeroRate_FallsToDirect() public {
        rateProvider.setRate(0, uint64(block.timestamp));
        vm.prank(admin);
        adapter.setRateProvider(address(rateProvider));
        pool.setLiquidityRateRay(4e25); // 400 bps

        assertEq(adapter.currentAPYBps(), 400);
    }

    /// @dev P1.L1: zero ts from cache → still falls through to direct
    function test_currentAPYBps_cacheZeroTs_FallsToDirect() public {
        rateProvider.setRate(5e25, 0);
        vm.prank(admin);
        adapter.setRateProvider(address(rateProvider));
        pool.setLiquidityRateRay(4e25); // 400 bps

        assertEq(adapter.currentAPYBps(), 400);
    }

    /// @dev P1.L1 step (4): all sources fail/empty → 0
    function test_currentAPYBps_allSourcesEmpty_ReturnsZero() public view {
        // No rate provider set, pool's rate not set (0)
        assertEq(adapter.currentAPYBps(), 0);
    }

    /// @dev P1.L1 step (4): direct read reverts → 0
    function test_currentAPYBps_directReadReverts_ReturnsZero() public {
        pool.setRevertOnGetReserveData(true);
        assertEq(adapter.currentAPYBps(), 0);
    }

    /// @dev P1.L1: rateRay → bps formula correctness
    function test_currentAPYBps_rayToBpsConversion() public {
        // 1e25 ray = 100 bps
        pool.setLiquidityRateRay(1e25);
        assertEq(adapter.currentAPYBps(), 100);

        // 5.5e25 ray = 550 bps
        pool.setLiquidityRateRay(5.5e25);
        assertEq(adapter.currentAPYBps(), 550);
    }

    /// @dev Clamp to uint16 max (e.g. corrupted rate)
    function test_currentAPYBps_clampedToUint16Max() public {
        pool.setLiquidityRateRay(1e30); // ~1e7 bps, way > uint16 max
        assertEq(adapter.currentAPYBps(), type(uint16).max);
    }

    /// @dev Cache exactly at staleness boundary still considered fresh
    function test_currentAPYBps_cacheAtStalenessBoundary() public {
        rateProvider.setRate(5e25, uint64(block.timestamp));
        vm.prank(admin);
        adapter.setRateProvider(address(rateProvider));

        skip(86_400); // exactly maxRateStalenessSec
        pool.setLiquidityRateRay(7e25);

        // age == maxRateStalenessSec → still fresh (boundary inclusive)
        assertEq(adapter.currentAPYBps(), 500);
    }

    function test_incentiveAPYBps_default() public view {
        assertEq(adapter.incentiveAPYBps(), 0);
    }

    function test_incentiveAPYBps_setter() public {
        // Step 4.4: incentiveAPYBps now applies haircut (default 7500 = retain 25%).
        // legacy incentiveBps=250 -> 250 * 2500/10000 = 62
        vm.prank(admin);
        adapter.setIncentiveBps(250);
        assertEq(adapter.incentiveAPYBps(), 62);
    }

    function test_harvestableProfit_zero() public view {
        assertEq(adapter.harvestableProfit(), 0);
    }

    function test_harvest_zero() public {
        // Step 4.4: harvest now has onlyVault. Reward pipeline not initialized -> returns 0.
        vm.prank(vault);
        assertEq(adapter.harvest(address(this)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // EXTERNAL MARKET TVL
    // ═══════════════════════════════════════════════════════════════════════

    function test_externalMarketTVL_returnsATokenSupply() public {
        _deposit(1_000_000e6);
        assertEq(adapter.externalMarketTVL(), 1_000_000e6);
    }

    function test_externalMarketTVL_returnsZero_ifTotalSupplyReverts() public {
        _deposit(500e6); // populate aToken supply
        aToken.setRevertOnTotalSupply(true);
        // Adapter's try/catch should swallow the revert and return 0
        assertEq(adapter.externalMarketTVL(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN GATES
    // ═══════════════════════════════════════════════════════════════════════

    function test_setMaxCap_adminOnly() public {
        vm.prank(admin);
        adapter.setMaxCap(2_000_000e6);
        assertEq(adapter.maxCap(), 2_000_000e6);
    }

    function test_setMaxCap_revertsOnNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.setMaxCap(100e6);
    }

    function test_setIncentiveBps_adminOnly() public {
        // Step 4.4: incentiveAPYBps applies haircut (legacy=300 -> 300 * 2500/10000 = 75)
        vm.prank(admin);
        adapter.setIncentiveBps(300);
        assertEq(adapter.incentiveAPYBps(), 75);
    }

    function test_setAPYOverrideBps_adminOnly() public {
        vm.prank(admin);
        adapter.setAPYOverrideBps(700);
        assertEq(uint256(adapter.apyOverrideBps()), 700);
    }

    function test_setRateProvider_revertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(bytes("zero address"));
        adapter.setRateProvider(address(0));
    }

    function test_setRateProvider_setsState() public {
        vm.prank(admin);
        adapter.setRateProvider(address(rateProvider));
        assertEq(adapter.rateProvider(), address(rateProvider));
    }

    function test_setMaxRateStalenessSec_belowMin_reverts() public {
        vm.prank(admin);
        vm.expectRevert(bytes("staleness-range"));
        adapter.setMaxRateStalenessSec(3_599);
    }

    function test_setMaxRateStalenessSec_aboveMax_reverts() public {
        vm.prank(admin);
        vm.expectRevert(bytes("staleness-range"));
        adapter.setMaxRateStalenessSec(uint32(30 days + 1));
    }

    function test_setMaxRateStalenessSec_atBoundary_OK() public {
        vm.prank(admin);
        adapter.setMaxRateStalenessSec(3_600);
        assertEq(uint256(adapter.maxRateStalenessSec()), 3_600);

        vm.prank(admin);
        adapter.setMaxRateStalenessSec(uint32(30 days));
        assertEq(uint256(adapter.maxRateStalenessSec()), 30 days);
    }

    function test_setMaxRateStalenessSec_revertsOnNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.setMaxRateStalenessSec(7_200);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // IDLE & EMERGENCY
    // ═══════════════════════════════════════════════════════════════════════

    function test_sweepIdleAssetToVault_happyPath() public {
        usdc.mint(address(adapter), 250e6);
        vm.prank(vault);
        adapter.sweepIdleAssetToVault();
        assertEq(usdc.balanceOf(vault), 250e6);
    }

    function test_sweepIdleAssetToVault_revertsOnZeroIdle() public {
        vm.prank(vault);
        vm.expectRevert(bytes("no idle"));
        adapter.sweepIdleAssetToVault();
    }

    function test_sweepIdleAssetToVault_revertsOnNonVault() public {
        usdc.mint(address(adapter), 100e6);
        vm.prank(alice);
        vm.expectRevert(bytes("not vault"));
        adapter.sweepIdleAssetToVault();
    }

    function test_emergencyPullAllToVault_withdrawsAndSweeps() public {
        _deposit(800e6);
        usdc.mint(address(adapter), 50e6);
        vm.prank(vault);
        adapter.emergencyPullAllToVault();
        assertEq(usdc.balanceOf(vault), 850e6);
        assertEq(adapter.investedAssets(), 0);
        assertEq(adapter.idleAssetBalance(), 0);
    }

    function test_emergencyPullAllToVault_revertsOnNonVault() public {
        vm.prank(alice);
        vm.expectRevert(bytes("not vault"));
        adapter.emergencyPullAllToVault();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SWEEP PROTECTION
    // ═══════════════════════════════════════════════════════════════════════

    function test_receiveETH_reverts() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(adapter).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_fallback_reverts() public {
        (bool ok,) = address(adapter).call(abi.encodeWithSignature("nope()"));
        assertFalse(ok);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event Supplied(uint256 assets);
    event Withdrawn(uint256 assets, address receiver);
    event APYOverrideUpdated(uint16 newBps);
    event RateProviderUpdated(address provider);
    event MaxRateStalenessUpdated(uint32 secs);

    function test_deposit_emitsSupplied() public {
        usdc.mint(vault, 1000e6);
        vm.startPrank(vault);
        usdc.approve(address(adapter), 1000e6);
        vm.expectEmit(false, false, false, true);
        emit Supplied(1000e6);
        adapter.deposit(1000e6);
        vm.stopPrank();
    }

    function test_withdraw_emitsWithdrawn() public {
        _deposit(1000e6);
        vm.prank(vault);
        vm.expectEmit(false, false, false, true);
        emit Withdrawn(500e6, vault);
        adapter.withdraw(500e6, vault);
    }

    function test_setRateProvider_emitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit RateProviderUpdated(address(rateProvider));
        adapter.setRateProvider(address(rateProvider));
    }

    function test_setMaxRateStalenessSec_emitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit MaxRateStalenessUpdated(7200);
        adapter.setMaxRateStalenessSec(7200);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STEP 4.4 — REWARD PIPELINE INTEGRATION
    // ═══════════════════════════════════════════════════════════════════════

    address internal core = address(0xC04E);

    function _initRewardPipeline_Aave() internal returns (
        MockERC20Reward token,
        MockAaveRewardsController rc,
        MockAaveSwapHelper helper
    ) {
        token = new MockERC20Reward();
        rc = new MockAaveRewardsController(address(token));
        helper = new MockAaveSwapHelper(address(usdc));
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        vm.prank(admin);
        adapter.initRewardConfig(tokens, address(rc), address(helper));
    }

    function test_v44_initRewardConfig_happyPath() public {
        (MockERC20Reward t, MockAaveRewardsController rc, MockAaveSwapHelper h) = _initRewardPipeline_Aave();
        // Step 4.6: rewardToken() removed; verify whitelist + count
        assertTrue(adapter.isRewardWhitelisted(address(t)));
        assertEq(adapter.rewardTokensCount(), 1);
        assertEq(adapter.rewardTokens()[0], address(t));
        assertEq(adapter.rewardsController(), address(rc));
        assertEq(adapter.swapHelper(), address(h));
    }

    function test_v44_initRewardConfig_idempotent() public {
        (MockERC20Reward t, MockAaveRewardsController rc, MockAaveSwapHelper h) = _initRewardPipeline_Aave();
        address[] memory tokens = new address[](1);
        tokens[0] = address(t);
        vm.prank(admin);
        vm.expectRevert(bytes("already-init"));
        adapter.initRewardConfig(tokens, address(rc), address(h));
    }

    function test_v44_initRewardConfig_revertsOnZeroController() public {
        MockERC20Reward t = new MockERC20Reward();
        MockAaveSwapHelper h = new MockAaveSwapHelper(address(usdc));
        address[] memory tokens = new address[](1);
        tokens[0] = address(t);
        vm.prank(admin);
        vm.expectRevert(bytes("zero"));
        adapter.initRewardConfig(tokens, address(0), address(h));
    }

    function test_v44_initRewardConfig_revertsOnEmptyTokens() public {
        MockAaveRewardsController rc = new MockAaveRewardsController(address(0));
        MockAaveSwapHelper h = new MockAaveSwapHelper(address(usdc));
        address[] memory empty = new address[](0);
        vm.prank(admin);
        vm.expectRevert(bytes("empty-tokens"));
        adapter.initRewardConfig(empty, address(rc), address(h));
    }

    function test_v44_initRewardConfig_revertsOnZeroToken() public {
        MockAaveRewardsController rc = new MockAaveRewardsController(address(0));
        MockAaveSwapHelper h = new MockAaveSwapHelper(address(usdc));
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        vm.prank(admin);
        vm.expectRevert(bytes("zero-token"));
        adapter.initRewardConfig(tokens, address(rc), address(h));
    }

    function test_v44_initRewardConfig_revertsOnDuplicate() public {
        MockERC20Reward t = new MockERC20Reward();
        MockAaveRewardsController rc = new MockAaveRewardsController(address(t));
        MockAaveSwapHelper h = new MockAaveSwapHelper(address(usdc));
        address[] memory tokens = new address[](2);
        tokens[0] = address(t);
        tokens[1] = address(t); // duplicate
        vm.prank(admin);
        vm.expectRevert(bytes("duplicate"));
        adapter.initRewardConfig(tokens, address(rc), address(h));
    }

    function test_v44_initRewardConfig_nonAdmin_reverts() public {
        MockERC20Reward t = new MockERC20Reward();
        MockAaveRewardsController rc = new MockAaveRewardsController(address(t));
        MockAaveSwapHelper h = new MockAaveSwapHelper(address(usdc));
        address[] memory tokens = new address[](1);
        tokens[0] = address(t);
        vm.prank(alice);
        vm.expectRevert();
        adapter.initRewardConfig(tokens, address(rc), address(h));
    }

    // ─── Step 4.6: addRewardToken / removeRewardToken ───────────────────

    function test_v46_addRewardToken_extendsList() public {
        _initRewardPipeline_Aave();
        MockERC20Reward t2 = new MockERC20Reward();
        vm.prank(admin);
        adapter.addRewardToken(address(t2));
        assertEq(adapter.rewardTokensCount(), 2);
        assertTrue(adapter.isRewardWhitelisted(address(t2)));
    }

    function test_v46_addRewardToken_revertsOnZero() public {
        _initRewardPipeline_Aave();
        vm.prank(admin);
        vm.expectRevert(bytes("zero"));
        adapter.addRewardToken(address(0));
    }

    function test_v46_addRewardToken_revertsOnDuplicate() public {
        (MockERC20Reward t,,) = _initRewardPipeline_Aave();
        vm.prank(admin);
        vm.expectRevert(bytes("already-whitelisted"));
        adapter.addRewardToken(address(t));
    }

    function test_v46_addRewardToken_nonAdmin_reverts() public {
        _initRewardPipeline_Aave();
        MockERC20Reward t2 = new MockERC20Reward();
        vm.prank(alice);
        vm.expectRevert();
        adapter.addRewardToken(address(t2));
    }

    function test_v46_removeRewardToken_shrinks() public {
        (MockERC20Reward t,,) = _initRewardPipeline_Aave();
        MockERC20Reward t2 = new MockERC20Reward();
        vm.prank(admin);
        adapter.addRewardToken(address(t2));
        assertEq(adapter.rewardTokensCount(), 2);

        vm.prank(admin);
        adapter.removeRewardToken(address(t));
        assertEq(adapter.rewardTokensCount(), 1);
        assertFalse(adapter.isRewardWhitelisted(address(t)));
        assertTrue(adapter.isRewardWhitelisted(address(t2)));
    }

    function test_v46_removeRewardToken_revertsOnNotWhitelisted() public {
        _initRewardPipeline_Aave();
        MockERC20Reward unknown = new MockERC20Reward();
        vm.prank(admin);
        vm.expectRevert(bytes("not-whitelisted"));
        adapter.removeRewardToken(address(unknown));
    }

    function test_v46_removeRewardToken_nonAdmin_reverts() public {
        (MockERC20Reward t,,) = _initRewardPipeline_Aave();
        vm.prank(alice);
        vm.expectRevert();
        adapter.removeRewardToken(address(t));
    }

    function test_v44_setHaircutBps_capCheck() public {
        vm.prank(admin);
        vm.expectRevert(bytes("bps>10000"));
        adapter.setIncentiveHaircutBps(10_001);
    }

    function test_v44_defaultHaircut_7500() public view {
        assertEq(uint256(adapter.incentiveHaircutBps()), 7500);
    }

    // Haircut math
    function test_v44_incentiveAPYBps_appliesHaircutOnRealized() public {
        vm.prank(admin);
        adapter.setRealizedRewardAPRBps(1000);
        assertEq(adapter.incentiveAPYBps(), 250);
    }

    function test_v44_incentiveAPYBps_realizedTakesPriorityOverLegacy() public {
        vm.startPrank(admin);
        adapter.setIncentiveBps(800); // legacy
        adapter.setRealizedRewardAPRBps(2000);
        vm.stopPrank();
        // realized=2000 wins -> 2000*2500/10000 = 500
        assertEq(adapter.incentiveAPYBps(), 500);
    }

    // M1 harvestableProfit gate
    function test_v44_harvestableProfit_zeroIfNotInit() public view {
        assertEq(adapter.harvestableProfit(), 0);
    }

    function test_v44_harvestableProfit_zeroIfCannotSwap() public {
        (MockERC20Reward t,, MockAaveSwapHelper h) = _initRewardPipeline_Aave();
        t.mint(address(adapter), 5e18);
        h.setCanSwap(false);
        assertEq(adapter.harvestableProfit(), 0);
    }

    function test_v44_harvestableProfit_returnsExpected() public {
        (MockERC20Reward t,, MockAaveSwapHelper h) = _initRewardPipeline_Aave();
        t.mint(address(adapter), 5e18);
        h.setExpectedOut(300_000_000);
        assertEq(adapter.harvestableProfit(), 300_000_000);
    }

    // M2 harvest graceful
    function test_v44_harvest_happyPath() public {
        (MockERC20Reward t, MockAaveRewardsController rc, MockAaveSwapHelper h) = _initRewardPipeline_Aave();
        rc.setClaimAmount(8e18);
        h.setOutAmount(480_000_000);

        vm.prank(vault);
        uint256 realized = adapter.harvest(core);

        assertEq(realized, 480_000_000);
        assertEq(usdc.balanceOf(core), 480_000_000);
        assertEq(t.balanceOf(address(adapter)), 0);
    }

    function test_v44_harvest_defersOnStaleOracle() public {
        (MockERC20Reward t, MockAaveRewardsController rc, MockAaveSwapHelper h) = _initRewardPipeline_Aave();
        rc.setClaimAmount(5e18);
        h.setCanSwap(false);

        vm.prank(vault);
        uint256 realized = adapter.harvest(core);

        assertEq(realized, 0);
        assertEq(t.balanceOf(address(adapter)), 5e18);
    }

    function test_v44_harvest_handlesClaimRevert() public {
        (, MockAaveRewardsController rc,) = _initRewardPipeline_Aave();
        rc.setRevertOnClaim(true);
        vm.prank(vault);
        uint256 realized = adapter.harvest(core);
        assertEq(realized, 0);
    }

    function test_v44_harvest_handlesSwapRevertGracefully() public {
        (MockERC20Reward t, MockAaveRewardsController rc, MockAaveSwapHelper h) = _initRewardPipeline_Aave();
        rc.setClaimAmount(5e18);
        h.setRevertOnSwap(true);
        vm.prank(vault);
        uint256 realized = adapter.harvest(core);
        assertEq(realized, 0);
        assertEq(t.balanceOf(address(adapter)), 5e18);
    }

    function test_v44_harvest_revertsOnNonVault() public {
        _initRewardPipeline_Aave();
        vm.prank(alice);
        vm.expectRevert(bytes("not vault"));
        adapter.harvest(core);
    }

    function test_v44_harvest_resetsApprovalAfterSwap() public {
        (MockERC20Reward t, MockAaveRewardsController rc, MockAaveSwapHelper h) = _initRewardPipeline_Aave();
        rc.setClaimAmount(3e18);
        h.setOutAmount(180e6);
        vm.prank(vault);
        adapter.harvest(core);
        assertEq(t.allowance(address(adapter), address(h)), 0);
    }

    function test_v44_pendingRewardBalance_reflects() public {
        (MockERC20Reward t,,) = _initRewardPipeline_Aave();
        t.mint(address(adapter), 4e18);
        // Step 4.6: pendingRewardBalance is now per-token
        assertEq(adapter.pendingRewardBalance(address(t)), 4e18);
    }

    function test_v46_pendingRewardBalance_zeroForNonWhitelisted() public {
        _initRewardPipeline_Aave();
        MockERC20Reward unknown = new MockERC20Reward();
        unknown.mint(address(adapter), 100e18); // tokens dropped at adapter
        // Even with balance, returns 0 because not whitelisted
        assertEq(adapter.pendingRewardBalance(address(unknown)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STEP 4.6 — MULTI-TOKEN HARVEST TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function _initWithMultiTokens() internal returns (
        MockERC20Reward token1,
        MockERC20Reward token2,
        MockAaveRewardsController rc,
        MockAaveSwapHelper helper
    ) {
        token1 = new MockERC20Reward();
        token2 = new MockERC20Reward();
        // Single rewards controller mock; we'll set per-token claim amounts
        rc = new MockAaveRewardsController(address(0)); // 0 means accept any
        helper = new MockAaveSwapHelper(address(usdc));
        address[] memory tokens = new address[](2);
        tokens[0] = address(token1);
        tokens[1] = address(token2);
        vm.prank(admin);
        adapter.initRewardConfig(tokens, address(rc), address(helper));
    }

    function test_v46_harvest_multiToken_happyPath() public {
        (MockERC20Reward t1, MockERC20Reward t2, MockAaveRewardsController rc, MockAaveSwapHelper h)
            = _initWithMultiTokens();
        rc.setClaimAmountForToken(address(t1), 5e18);
        rc.setClaimAmountForToken(address(t2), 3e18);
        h.setOutAmount(100e6); // each swap returns 100e6 USDC

        vm.prank(vault);
        uint256 realized = adapter.harvest(core);

        // Both tokens swapped → 200e6 USDC total
        assertEq(realized, 200e6);
        assertEq(usdc.balanceOf(core), 200e6);
        assertEq(t1.balanceOf(address(adapter)), 0);
        assertEq(t2.balanceOf(address(adapter)), 0);
    }

    function test_v46_harvest_multiToken_partialSwapDeferral() public {
        (MockERC20Reward t1, MockERC20Reward t2, MockAaveRewardsController rc, MockAaveSwapHelper h)
            = _initWithMultiTokens();
        rc.setClaimAmountForToken(address(t1), 5e18);
        rc.setClaimAmountForToken(address(t2), 3e18);
        h.setCanSwapForToken(address(t1), true);
        h.setCanSwapForToken(address(t2), false); // t2 oracle stale → defer
        h.setOutAmount(100e6);

        vm.prank(vault);
        uint256 realized = adapter.harvest(core);

        // Only t1 swapped → 100e6, t2 retained
        assertEq(realized, 100e6);
        assertEq(t1.balanceOf(address(adapter)), 0);
        assertEq(t2.balanceOf(address(adapter)), 3e18, "t2 retained for retry");
    }

    function test_v46_harvest_multiToken_oneClaimRevert_othersUnaffected() public {
        (MockERC20Reward t1, MockERC20Reward t2, MockAaveRewardsController rc, MockAaveSwapHelper h)
            = _initWithMultiTokens();
        // t1 claim reverts, t2 claim succeeds → t2 still swapped
        rc.setRevertOnTokenClaim(address(t1), true);
        rc.setClaimAmountForToken(address(t2), 4e18);
        h.setOutAmount(150e6);

        vm.prank(vault);
        uint256 realized = adapter.harvest(core);

        assertEq(realized, 150e6, "t2 swap succeeded despite t1 claim revert");
    }

    function test_v46_harvest_emptyWhitelistReturns0() public {
        // Init then remove all tokens
        (MockERC20Reward t,,) = _initRewardPipeline_Aave();
        vm.prank(admin);
        adapter.removeRewardToken(address(t));
        assertEq(adapter.rewardTokensCount(), 0);

        vm.prank(vault);
        uint256 realized = adapter.harvest(core);
        assertEq(realized, 0);
    }

    function test_v46_harvestableProfit_sumsAcrossTokens() public {
        (MockERC20Reward t1, MockERC20Reward t2,, MockAaveSwapHelper h) = _initWithMultiTokens();
        t1.mint(address(adapter), 5e18);
        t2.mint(address(adapter), 3e18);
        h.setExpectedOut(100e6); // each token preview returns 100e6
        // Sum = 200e6
        assertEq(adapter.harvestableProfit(), 200e6);
    }

    function test_v46_harvestableProfit_skipsTokensWithStaleOracle() public {
        (MockERC20Reward t1, MockERC20Reward t2,, MockAaveSwapHelper h) = _initWithMultiTokens();
        t1.mint(address(adapter), 5e18);
        t2.mint(address(adapter), 3e18);
        h.setCanSwapForToken(address(t1), true);
        h.setCanSwapForToken(address(t2), false);
        h.setExpectedOut(100e6);
        // Only t1 contributes
        assertEq(adapter.harvestableProfit(), 100e6);
    }

    function test_v46_harvestableProfit_zeroIfHelperUnset() public {
        (MockERC20Reward t1, MockERC20Reward t2,,) = _initWithMultiTokens();
        t1.mint(address(adapter), 5e18);
        t2.mint(address(adapter), 3e18);
        vm.prank(admin);
        adapter.setSwapHelper(address(0));
        assertEq(adapter.harvestableProfit(), 0);
    }

    // ─── setSwapHelper dedicated tests ───────────────────────────────────

    function test_v46_setSwapHelper_updatesState() public {
        _initRewardPipeline_Aave();
        MockAaveSwapHelper newHelper = new MockAaveSwapHelper(address(usdc));
        vm.prank(admin);
        adapter.setSwapHelper(address(newHelper));
        assertEq(adapter.swapHelper(), address(newHelper));
    }

    function test_v46_setSwapHelper_allowsZero_emergencyDisable() public {
        _initRewardPipeline_Aave();
        vm.prank(admin);
        adapter.setSwapHelper(address(0));
        assertEq(adapter.swapHelper(), address(0));
    }

    function test_v46_setSwapHelper_nonAdmin_reverts() public {
        _initRewardPipeline_Aave();
        vm.prank(alice);
        vm.expectRevert();
        adapter.setSwapHelper(address(1));
    }

    function test_v46_setSwapHelper_emitsEvent() public {
        _initRewardPipeline_Aave();
        MockAaveSwapHelper newHelper = new MockAaveSwapHelper(address(usdc));
        vm.expectEmit(true, false, false, false);
        emit AaveV3USDCAdapter.SwapHelperUpdated(address(newHelper));
        vm.prank(admin);
        adapter.setSwapHelper(address(newHelper));
    }

    // ─── setRealizedRewardAPRBps / setIncentiveHaircutBps ────────────────

    function test_v46_setRealizedRewardAPRBps_updatesState() public {
        vm.prank(admin);
        adapter.setRealizedRewardAPRBps(200);
        assertEq(adapter.realizedRewardAPRBps(), 200);
    }

    function test_v46_setRealizedRewardAPRBps_nonAdmin_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.setRealizedRewardAPRBps(200);
    }

    function test_v46_setIncentiveHaircutBps_updatesState() public {
        vm.prank(admin);
        adapter.setIncentiveHaircutBps(1500);
        assertEq(adapter.incentiveHaircutBps(), 1500);
    }

    function test_v46_setIncentiveHaircutBps_revertsAbove10000() public {
        vm.prank(admin);
        vm.expectRevert(bytes("bps>10000"));
        adapter.setIncentiveHaircutBps(10_001);
    }

    function test_v46_setIncentiveHaircutBps_nonAdmin_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.setIncentiveHaircutBps(500);
    }

    // ─── harvest: non-vault reverts ───────────────────────────────────────

    function test_v46_harvest_revertsOnNonVault() public {
        _initRewardPipeline_Aave();
        vm.prank(alice);
        vm.expectRevert(bytes("not vault"));
        adapter.harvest(alice);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// STEP 4.6 — MULTI-TOKEN MOCKS (replace single-token Step 4.4 mocks)
// ═══════════════════════════════════════════════════════════════════════════

contract MockERC20Reward {
    string public constant symbol = "REWARD";
    uint8 public constant decimals = 18;
    string public constant name = "Reward";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount; totalSupply += amount;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount; balanceOf[to] += amount; return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allow");
        require(balanceOf[from] >= amount, "bal");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount; balanceOf[to] += amount; return true;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount; return true;
    }
}

contract MockAaveRewardsController {
    address public defaultRewardToken; // for backward-compat single-token tests
    mapping(address => uint256) public claimAmountByToken;
    mapping(address => bool) public revertOnTokenClaim;

    constructor(address _t) { defaultRewardToken = _t; }

    function setClaimAmount(uint256 a) external {
        // backward-compat: sets default token claim amount
        claimAmountByToken[defaultRewardToken] = a;
    }
    function setClaimAmountForToken(address token, uint256 a) external {
        claimAmountByToken[token] = a;
    }
    function setRevertOnClaim(bool v) external {
        revertOnTokenClaim[defaultRewardToken] = v;
    }
    function setRevertOnTokenClaim(address token, bool v) external {
        revertOnTokenClaim[token] = v;
    }

    function claimRewardsToSelf(
        address[] calldata /*assets*/,
        uint256 /*amount*/,
        address reward
    ) external returns (uint256) {
        if (revertOnTokenClaim[reward]) revert("rc-revert");
        uint256 amt = claimAmountByToken[reward];
        if (amt > 0) {
            MockERC20Reward(reward).mint(msg.sender, amt);
        }
        return amt;
    }

    function getUserRewards(
        address[] calldata /*assets*/,
        address /*user*/,
        address reward
    ) external view returns (uint256) {
        return claimAmountByToken[reward];
    }
}

contract MockAaveSwapHelper {
    address public usdc;
    bool public canSwapDefault = true;
    mapping(address => bool) public canSwapByToken;
    mapping(address => bool) public canSwapByTokenSet;
    bool public revertOnSwap;
    uint256 public outAmount;
    uint256 public expectedOut;

    constructor(address _usdc) { usdc = _usdc; }

    function setCanSwap(bool v) external { canSwapDefault = v; }
    function setCanSwapForToken(address token, bool v) external {
        canSwapByToken[token] = v;
        canSwapByTokenSet[token] = true;
    }
    function setRevertOnSwap(bool v) external { revertOnSwap = v; }
    function setOutAmount(uint256 a) external { outAmount = a; }
    function setExpectedOut(uint256 e) external { expectedOut = e; }

    function canSwap(address token) external view returns (bool) {
        if (canSwapByTokenSet[token]) return canSwapByToken[token];
        return canSwapDefault;
    }
    function previewExpectedOut(address, uint256) external view returns (uint256) { return expectedOut; }
    function swapToUSDC(address rewardToken, uint256 amountIn, address receiver) external returns (uint256) {
        if (revertOnSwap) revert("swap-revert");
        MockERC20Reward(rewardToken).transferFrom(msg.sender, address(this), amountIn);
        (bool ok,) = usdc.call(abi.encodeWithSignature("mint(address,uint256)", receiver, outAmount));
        require(ok, "mint-failed");
        return outAmount;
    }
}
