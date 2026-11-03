// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VenusUsdcMultiMarketAdapter} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/VenusUsdcMultiMarket.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LendingAssetConfig} from "@multyr-strategies/strategies/usdc-lending/config/LendingAssetConfig.sol";
import {StrategySettingsModule as Settings} from "@multyr-strategies/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {StrategyParamsModule as StrategyParams} from "@multyr-strategies/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import {StrategyScoringModule as Scoring} from "@multyr-strategies/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import {LiquidityOpsModule} from "@multyr-core/core/modules/LiquidityOpsModule.sol";
import {AdminModule} from "@multyr-core/core/modules/AdminModule.sol";
import {ReadOnlyGasEstimator, IMeasurements, IFeeInfo, IFeed} from "@multyr-strategies/strategies/usdc-lending/gas/ReadOnlyGasEstimator.sol";
import {LendingEthereumAdditionalUnmockedE2EBase} from "./LendingEthereumAdditionalUnmockedE2E.t.sol";

// ---------------------------------------------------------------------------
// Minimal local interfaces — only functions actually called in this fixture.
// ---------------------------------------------------------------------------

interface IVTokenBsc {
    function underlying() external view returns (address);
    function interestRateModel() external view returns (address);
    function accrueInterest() external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function supplyRatePerBlock() external view returns (uint256);
    function blocksOrSecondsPerYear() external view returns (uint256);
    function getCash() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function totalReserves() external view returns (uint256);
}

/// @notice BSC fork integration: real Venus vUSDT18 + candidate strategy + NativeL1FeeInfo/ReadOnlyGasEstimator.
/// @dev    No mock/deal/etch/store/warp. Inherits production Core deployment helpers from the
///         Ethereum base; overrides chain, RPC, asset feed, and adapter wiring.
///         Does NOT exercise the two-epoch full user exit path — initial fixture only.
contract BscNativeFeeStrategyIntegrationTest is LendingEthereumAdditionalUnmockedE2EBase {
    using SafeERC20 for IERC20Metadata;

    // ── BSC production addresses ────────────────────────────────────────────
    address constant BSC_USDT      = 0x55d398326f99059fF775485246999027B3197955; // 18 dec
    address constant BSC_USDT_USD  = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320; // USDT/USD 8 dec
    address constant BSC_BNB_USD   = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE; // BNB/USD  8 dec
    address constant BSC_VUSDT     = 0xfD5840Cd36d94D7229439859C0112a4185BC0255; // vUSDT Core

    // ── Own Venus field — NOT cast to base AaveV3USDCAdapter ────────────────
    VenusUsdcMultiMarketAdapter venusAdapter;
    ReadOnlyGasEstimator gasEstimator;

    // ── Base overrides ───────────────────────────────────────────────────────

    function _bscRpc() internal pure returns (string memory) {
        return "https://bsc-mainnet.public.blastapi.io";
    }

    /// @dev Returns real USDT/USD feed on BSC (8 dec, heartbeat ~24 h).
    ///      NOT 0xa767… (ADA/USD). Verified description: "USDT / USD".
    function _assetFeed() internal view override returns (address) {
        // market.asset is checked in the base; guard is belt-and-suspenders.
        require(market.asset == BSC_USDT, "feed: wrong asset");
        return BSC_USDT_USD;
    }

    // ── Main test ────────────────────────────────────────────────────────────

    function test_bscNativeFeeVenusIntegration() public {
        _setupChain();
        _deployCore();
        _deployVenusAdapter();
        _deployGasEstimator();
        _assertGasQuote();
        _fundAndDeposit();
        _deployCapital();
        _assertVenusPosition();
        _assertRecall();
    }

    // =========================================================================
    //  Phase helpers — split to avoid Yul stack depth.
    // =========================================================================

    function _setupChain() internal {
        chain       = 56;
        user        = vm.addr(0xB0B);
        initialBlock = 129000000;
        setupBlock   = 129400000;
        vm.createSelectFork(_bscRpc(), initialBlock);
        assertEq(block.chainid, 56, "must fork BSC");
        rpcForkBlock = initialBlock;
        market = LendingAssetConfig.Market(
            56,
            BSC_USDT,
            18,
            address(0),
            address(0)
        );
    }

    function _deployCore() internal {
        _configureProductionCore();
        strategy = _candidate();
        uint256 eta = router.proposeStrategyAllowlist(address(strategy));
        vm.makePersistent(keep);
        _roll(setupBlock);
        assertGe(block.timestamp, eta, "timelock not elapsed");
        buffer.refreshWarmNav();
        router.executeStrategyAllowlist(address(strategy));
        router.register(address(strategy), 0, 10000);
        router.setMaxStrategyBps(address(strategy), 10000);
        router.setLossCapPerStrategy(address(strategy), 50);
    }

    function _deployVenusAdapter() internal {
        IVTokenBsc vt = IVTokenBsc(BSC_VUSDT);
        require(vt.underlying() == BSC_USDT, "vToken/asset mismatch");

        // Read the real market or its real interest model; never assume block time.
        uint256 slots = _actualSlots(BSC_VUSDT);

        venusAdapter = VenusUsdcMultiMarketAdapter(
            payable(_new("VenusUsdcMultiMarket.sol:VenusUsdcMultiMarketAdapter", bytes("")))
        );
        venusAdapter.initialize(
            BSC_USDT,
            address(this),
            address(strategy),
            0,          // capacity_ = 0 (unlimited)
            BSC_VUSDT,
            slots
        );

        // Actual accrueInterest must succeed (return 0).
        assertEq(venusAdapter.accrueVenusInterest(), 0, "Venus accrueInterest failed");

        Settings(address(strategy)).whitelistAdapter(address(venusAdapter), true);
        strategy.addAdapter(address(venusAdapter));
        strategy.toggleAdapter(address(venusAdapter), true);
        Settings(address(strategy)).setAdapterDepositMode(address(venusAdapter), false);
        _poke();
    }

    function _deployGasEstimator() internal {
        // NativeL1FeeInfo(maxBytes=4096, priorityFee=1 gwei)
        address feeInfo = _new(
            "NativeL1FeeInfo.sol:NativeL1FeeInfo",
            abi.encode(uint256(4096), uint256(1 gwei))
        );

        ReadOnlyGasEstimator.Config memory cfg = ReadOnlyGasEstimator.Config({
            prepareGas:        400_000,
            stepGas:           150_000,
            finalizeGas:       200_000,
            defaultDepositGas: 1_000_000,
            defaultWithdrawGas:2_000_000,
            intrinsicGas:      23_112,
            calldataBytes:     132,
            marginBps:         2_500,
            maxPriceAge:       3_600,
            usdcMaxPriceAge:   3_600,
            sequencerGrace:    3_600,
            fallbackUSDC:      1e6
        });

        gasEstimator = ReadOnlyGasEstimator(
            payable(_new(
                "ReadOnlyGasEstimator.sol:ReadOnlyGasEstimator",
                abi.encode(
                    IFeeInfo(feeInfo),
                    IFeed(BSC_BNB_USD),
                    IFeed(address(0)),  // quoteFeed = 0 (unused)
                    IFeed(address(0)),  // seq = 0 (L1/BSC)
                    cfg
                )
            ))
        );

        Settings(address(strategy)).setRebalanceGasEstimator(address(gasEstimator));
    }

    event ActualBscNativeFee(uint256 chainId, uint256 rpcBlock, address asset, uint256 annualSlots,
        uint256 priceWad, uint256 sourcePrice, uint256 gasUnits, uint256 executionWei, uint256 costUSD6);

    function _actualSlots(address m) internal view returns (uint256 n) {
        (bool ok, bytes memory raw) = m.staticcall(abi.encodeWithSignature("blocksOrSecondsPerYear()"));
        if (!ok || raw.length < 32) {
            address model = IVTokenBsc(m).interestRateModel();
            (ok, raw) = model.staticcall(abi.encodeWithSignature("blocksPerYear()"));
            if (!ok || raw.length < 32) (ok, raw) = model.staticcall(abi.encodeWithSignature("BLOCKS_PER_YEAR()"));
        }
        require(ok && raw.length >= 32, "actual annual normalization required");
        n = abi.decode(raw, (uint256));
        require(n > 0 && n <= 200_000_000, "annual slots range");
    }

    function _assertGasQuote() internal {
        IFeed bnbFeed = IFeed(BSC_BNB_USD);
        assertEq(bnbFeed.decimals(), 8);
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answered) = bnbFeed.latestRoundData();
        assertGt(roundId, 0); assertGt(answer, 0); assertGe(answered, roundId);
        assertLe(updatedAt, block.timestamp); assertLe(block.timestamp - updatedAt, 3600);
        (uint256 perTx, uint256 perByte,,,, uint256 sourcePrice) = gasEstimator.feeInfo().getPricesInWei();
        assertEq(perTx, 0); assertEq(perByte, 0); assertEq(sourcePrice, block.basefee + 1 gwei);
        (uint32 observations,) = IMeasurements(address(strategy)).depositGasObservation(address(venusAdapter));
        assertEq(observations, 0, "actual cold-start observations");
        ReadOnlyGasEstimator.Action[] memory actions = new ReadOnlyGasEstimator.Action[](1);
        actions[0] = ReadOnlyGasEstimator.Action(address(venusAdapter), 1e18, true);
        ReadOnlyGasEstimator.Quote memory q = gasEstimator.estimate(address(strategy), actions, 2, true);
        uint256 expectedGas = 1796224;
        uint256 execution = expectedGas * (tx.gasprice > sourcePrice ? tx.gasprice : sourcePrice);
        uint256 priceWad = uint256(answer) * 1e10;
        uint256 usdWei = Math.mulDiv(execution, priceWad, 1e18, Math.Rounding.Up);
        uint256 usd6 = Math.ceilDiv(usdWei, 1e12);
        uint256 expected = Math.mulDiv(usd6, 12500, 10000, Math.Rounding.Up);
        assertTrue(q.reliable, "real BNB quote must be reliable; fallback is not positive evidence");
        assertTrue(q.usedDefaults); assertEq(q.l2Gas, expectedGas); assertEq(q.txCount, 2);
        assertEq(q.posterWei, 0); assertEq(q.executionWei, execution); assertEq(q.costUSDC, expected);
        assertEq(gasEstimator.quoteCurrency(), bytes32("USD6"));
        assertEq(IERC20Metadata(BSC_USDT).decimals(), 18); assertEq(strategy.asset(), BSC_USDT);
        emit ActualBscNativeFee(block.chainid, rpcForkBlock, BSC_USDT, venusAdapter.blocksPerYear(),
            priceWad, sourcePrice, q.l2Gas, q.executionWei, q.costUSDC);
    }

    function _fundAndDeposit() internal {
        // ── Transfer 3 000e18 USDT18 from real BSC holder (Binance hot wallet) ─
        IERC20Metadata token = IERC20Metadata(BSC_USDT);
        uint256 funding      = 3_000e18;
        uint256 holderBefore = token.balanceOf(HOLDER);
        uint256 selfBefore   = token.balanceOf(address(this));
        uint256 supply       = token.totalSupply();
        assertGe(holderBefore, funding, "HOLDER insufficient USDT18 balance");

        vm.prank(HOLDER);
        token.safeTransfer(address(this), funding);

        assertEq(token.balanceOf(address(this)) - selfBefore, funding,  "received exact funding");
        assertEq(token.balanceOf(HOLDER), holderBefore - funding,       "holder debited exactly");
        assertEq(token.totalSupply(), supply,                           "total supply unchanged");
        emit RealFunding(chain, BSC_USDT, HOLDER, holderBefore, funding, token.balanceOf(HOLDER));

        // ── Seed ~$1 (dead shares) and deposit ~$2 000 ──────────────────────
        uint256 price  = oracle.getQuoteFresh(BSC_USDT).price;
        uint256 unit   = 10 ** market.decimals; // 1e18
        uint256 seed   = Math.mulDiv(1e18,    unit, price, Math.Rounding.Up);
        uint256 amount = Math.mulDiv(2_000e18, unit, price, Math.Rounding.Up);
        assertGe(token.balanceOf(address(this)), amount + seed, "insufficient for seed+deposit");

        token.forceApprove(address(core), seed);
        AdminModule(address(core)).seedDeadDeposit(seed);
        core.unpauseAll();
        core.freezeRouting();
        AdminModule(address(core)).freezeParams();

        token.safeTransfer(user, amount);
        assertFalse(strategy.hasRole(bytes32(0), user));
        assertFalse(strategy.hasRole(keccak256("CORE_ROLE"), user));
        assertTrue(core.owner() != user && router.owner() != user);

        vm.startPrank(user);
        token.forceApprove(address(core), amount);
        uint256 shares = core.deposit(amount, user);
        vm.stopPrank();
        assertGt(shares, 0, "shares minted");
    }

    function _deployCapital() internal {
        LiquidityOpsModule(address(core)).deployToStrategies(type(uint256).max);
        Scoring(address(strategy)).deployIdle();

        vm.makePersistent(keep);
        vm.makePersistent(BSC_USDT);
        vm.makePersistent(BSC_VUSDT);
        vm.makePersistent(address(venusAdapter));
        uint256 previousTimestamp = vm.getBlockTimestamp();
        _roll(setupBlock + 1000);
        assertGe(vm.getBlockTimestamp(), previousTimestamp + 300, "actual BSC history respects deploy cooldown");
        buffer.refreshWarmNav();
        _poke();
        Scoring(address(strategy)).deployIdle();
        assertLe(strategy.idleCash(), 2, "real ramp finished before recall");
    }

    function _assertVenusPosition() internal {
        IVTokenBsc vt = IVTokenBsc(BSC_VUSDT);

        // ── vToken balance must be positive ─────────────────────────────────
        uint256 vBal = vt.balanceOf(address(venusAdapter));
        assertGt(vBal, 0, "vToken balance must be positive after capital deployment");

        // ── Independent: raw vToken * exchangeRate / 1e18 vs adapter totalAssets ─
        uint256 rate            = vt.exchangeRateStored();
        uint256 derivedUnderly  = vBal * rate / 1e18;
        uint256 adapterTA       = venusAdapter.totalAssets();
        // Allow ±1 wei rounding difference only.
        uint256 diff = derivedUnderly > adapterTA ? derivedUnderly - adapterTA : adapterTA - derivedUnderly;
        assertLe(diff, 1, "vToken position cross-check (rounding bounded)");

        // ── Actual supply APR using actual annual slots ──────────────────────
        uint256 supplyRate = vt.supplyRatePerBlock();
        uint256 annualSlots = venusAdapter.blocksPerYear();
        uint256 aprBps = supplyRate * annualSlots / 1e14;
        assertGt(aprBps, 0, "Venus supply APR must be positive");
        // Adapter's own view must agree with independent calculation.
        uint16 adapterApy = venusAdapter.currentAPYBps();
        assertEq(adapterApy, aprBps > type(uint16).max ? type(uint16).max : uint16(aprBps),
            "adapter APY bps must match independent calculation");

        // ── Raw external TVL: getCash + totalBorrows - totalReserves ─────────
        uint256 cash     = vt.getCash();
        uint256 borrows  = vt.totalBorrows();
        uint256 reserves = vt.totalReserves();
        uint256 rawTVL   = cash + borrows - reserves;
        assertGt(rawTVL, 0, "raw external TVL positive");

        (bool debtOk, bytes memory debtRaw) = BSC_VUSDT.staticcall(abi.encodeWithSignature("badDebt()"));
        if (debtOk && debtRaw.length >= 32) rawTVL += abi.decode(debtRaw, (uint256));
        assertApproxEqAbs(venusAdapter.externalMarketTVL(), rawTVL, 1, "exact independent external TVL");
        assertApproxEqAbs(vt.totalSupply() * rate / 1e18, rawTVL, 1, "protocol book liabilities");

        // ── Candidate scoring data: APY must be positive ─────────────────────
        assertGt(venusAdapter.currentAPYBps(), 0, "Venus adapter APY bps > 0 (scoring input)");
    }

    function _assertRecall() internal {
        IERC20Metadata token = IERC20Metadata(BSC_USDT);
        uint256 coreBeforeRecall = token.balanceOf(address(core));
        uint256 recalled = router.withdrawAllToCore(address(strategy));
        assertGt(recalled, 0, "recall must return capital");
        assertEq(token.balanceOf(address(core)) - coreBeforeRecall, recalled, "recall delta exact");
        assertLe(strategy.totalAssets(), 2, "strategy must be emptied (dust <= 2)");
        assertLe(venusAdapter.totalAssets(), 2, "Venus adapter must be emptied (dust <= 2)");
        assertTrue(core.totalAssets() > 0, "core NAV still positive after recall");
    }
}
