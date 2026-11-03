// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LendingEthereumAdditionalUnmockedE2EBase} from "./LendingEthereumAdditionalUnmockedE2E.t.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AdminModule} from "@multyr-core/core/modules/AdminModule.sol";
import {LiquidityOpsModule} from "@multyr-core/core/modules/LiquidityOpsModule.sol";
import {EpochedQueueModule} from "@multyr-core/core/modules/EpochedQueueModule.sol";
import {StrategySettingsModule as Settings} from
    "@multyr-strategies/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {StrategyScoringModule as Scoring} from
    "@multyr-strategies/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import {AaveV3USDCAdapter} from
    "@multyr-strategies/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol";
import {LendingAssetConfig} from
    "@multyr-strategies/strategies/usdc-lending/config/LendingAssetConfig.sol";
import {ISwapRouterV3} from
    "@multyr-strategies/strategies/usdc-lending/swap/RewardSwapHelper.sol";

interface IFundingFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// Proves that a genuinely funded small independent user can fully exit
/// (zero remaining shares, exact owed balance) within the unchanged 10%
/// epoch cap while the larger user's capital remains invested.
/// Covers USDT (six-decimal non-USDC) and WETH (eighteen-decimal).
/// No mock/deal/etch/store/warp/mockCall. Holder impersonation is disclosed
/// via RealFunding events from the base.
abstract contract FullUserExitE2EBase is LendingEthereumAdditionalUnmockedE2EBase {
    using SafeERC20 for IERC20Metadata;

    address internal user2;

    event FullExitVerified(
        address asset,
        uint256 rpcBlock,
        address exiter,
        uint256 exitShares,
        uint256 totalSupplyAtRequest,
        uint256 epochCapBps,
        uint256 assetsReceived,
        uint256 remainingUser1Shares,
        uint256 adapterAssetsAfter,
        uint256 navPerShareBefore,
        uint256 navPerShareAfter
    );

    /// Hook invoked after adapter registration and _poke, before funding.
    function _afterFullExitAdapterConfigured() internal virtual {}

    function _fullExitChain() internal pure virtual returns (uint256) { return 1; }
    function _fullExitInitialBlock() internal pure virtual returns (uint256) { return 26150000; }
    function _fullExitSetupBlock() internal pure virtual returns (uint256) { return 26165000; }
    function _fullExitPhaseBlock(uint8 phase) internal view virtual returns (uint256) {
        if (phase == 0) return setupBlock + 40;
        if (phase == 1) return setupBlock + 8000;
        if (phase == 2) return initialBlock + 100000;
        require(phase == 3, "unknown exit phase");
        return initialBlock + 160000;
    }

    function _configureFullExitMarket(bool weth) internal virtual {
        market = LendingAssetConfig.Market(
            1,
            0xdAC17F958D2ee523a2206206994597C13D831ec7,
            6,
            0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2,
            0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a
        );
        if (weth) {
            market.asset = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
            market.decimals = 18;
            market.aToken = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;
        }
    }

    function _fundFullExit(bool weth) internal virtual {
        if (weth) {
            this.fundWethForTest();
            this.fundWethForTest();
            this.fundWethForTest();
        } else {
            _fundFromRealHolder(false);
            _fundFromRealHolder(false);
            _fundFromRealHolder(false);
        }
    }

    /// Production core: user1 ~$2000 + user2 ~$125 + seed ~$1.
    /// user2 / total = 125/2126 ~= 5.88% < unchanged 10% epoch cap.
    /// Each deposit exceeds the actual frozen Core $100 minimum.
    function _fullExitScenario(bool weth) internal {
        chain = _fullExitChain();
        user  = vm.addr(0xB0B);
        user2 = vm.addr(0xB0C2);
        initialBlock = _fullExitInitialBlock();
        setupBlock   = _fullExitSetupBlock();
        vm.createSelectFork(_rpc(), initialBlock);
        rpcForkBlock = initialBlock;

        _configureFullExitMarket(weth);

        _configureProductionCore();
        strategy = _candidate();
        {
            uint256 eta = router.proposeStrategyAllowlist(address(strategy));
            vm.makePersistent(keep);
            _roll(setupBlock);
            assertGe(block.timestamp, eta);
        }
        buffer.refreshWarmNav();
        _observe();
        router.executeStrategyAllowlist(address(strategy));
        router.register(address(strategy), 0, 10000);
        router.setMaxStrategyBps(address(strategy), 10000);
        router.setLossCapPerStrategy(address(strategy), 50);

        {
            uint256 unit = 10 ** market.decimals;
            adapter = AaveV3USDCAdapter(payable(
                _new("AaveV3USDCmarket.sol:AaveV3USDCAdapter", bytes(""))
            ));
            adapter.initialize(
                market.asset, market.aavePool, market.aToken,
                address(this), address(strategy), 10_000_000 * unit
            );
        }
        Settings(address(strategy)).whitelistAdapter(address(adapter), true);
        strategy.addAdapter(address(adapter));
        strategy.toggleAdapter(address(adapter), true);
        Settings(address(strategy)).setAdapterDepositMode(address(adapter), false);
        _poke();
        _afterFullExitAdapterConfigured();

        // Fund from real on-chain sources; three calls = 3000 USDT-equiv.
        _fundFullExit(weth);

        this.depositBothUsers();

        vm.makePersistent(keep);
        vm.makePersistent(market.asset);
        vm.makePersistent(market.aavePool);
        vm.makePersistent(market.aToken);
        _persistDebtTokens();
        _roll(_fullExitPhaseBlock(0));
        buffer.refreshWarmNav();
        _poke();
        Scoring(address(strategy)).deployIdle();
        assertLe(strategy.idleCash(), 2, "ramp must finish before exit test");
        _observe();

        this.exerciseEpoch1Exit();
    }

    /// Deposits user1 (~$2000) and user2 (~$125), verifies cap invariant,
    /// then deploys capital. Extracted to reduce stack depth in _fullExitScenario.
    function depositBothUsers() external {
        require(msg.sender == address(this));
        IERC20Metadata asset = IERC20Metadata(market.asset);
        uint256 price  = oracle.getQuoteFresh(market.asset).price;
        uint256 unit   = 10 ** market.decimals;
        uint256 seed   = Math.mulDiv(1e18,    unit, price, Math.Rounding.Up);
        uint256 amount1 = Math.mulDiv(2000e18, unit, price, Math.Rounding.Up);
        uint256 amount2 = Math.mulDiv(125e18,  unit, price, Math.Rounding.Up);
        assertGe(asset.balanceOf(address(this)), seed + amount1 + amount2,
            "funding must cover seed + user1 + user2");

        asset.forceApprove(address(core), seed);
        AdminModule(address(core)).seedDeadDeposit(seed);
        core.unpauseAll();
        core.freezeRouting();
        AdminModule(address(core)).freezeParams();

        asset.safeTransfer(user, amount1);
        vm.startPrank(user);
        asset.forceApprove(address(core), amount1);
        uint256 shares1 = core.deposit(amount1, user);
        vm.stopPrank();
        assertGt(shares1, 0);

        asset.safeTransfer(user2, amount2);
        vm.startPrank(user2);
        asset.forceApprove(address(core), amount2);
        uint256 shares2 = core.deposit(amount2, user2);
        vm.stopPrank();
        assertGt(shares2, 0);

        // user2's entire holding must fit within the unchanged 10% epoch cap.
        assertLt(shares2 * 10000 / core.totalSupply(), 1000,
            "user2 entire allocation fits within unchanged 10pct epoch cap");
        assertFalse(strategy.hasRole(bytes32(0), user2));
        assertTrue(core.owner() != user2);

        LiquidityOpsModule(address(core)).deployToStrategies(type(uint256).max);
        Scoring(address(strategy)).deployIdle();
        assertGt(adapter.totalAssets(), 0, "real capital must enter Aave");
    }

    /// Epoch 1: user1 requests 8% partial exit (~$160) consuming most hot cash,
    /// then funds and claims. Calls exerciseEpoch2FullExit for user2's complete exit.
    function exerciseEpoch1Exit() external {
        require(msg.sender == address(this), "self-only");
        _roll(_fullExitPhaseBlock(1));
        buffer.refreshWarmNav();
        _poke();
        strategy.harvest();

        uint256 shares1 = core.balanceOf(user);
        uint256 shares2 = core.balanceOf(user2);
        assertGt(shares1, 0);
        assertGt(shares2, 0);
        assertGt(adapter.totalAssets(), 0, "adapter invested before epoch 1");

        uint256 firstExitShares = shares1 * 800 / 10000;
        assertLt(firstExitShares * 10000 / core.totalSupply(), 1000,
            "user1 partial request within unchanged 10pct epoch cap");

        uint256 user1BalBefore = IERC20Metadata(market.asset).balanceOf(user);
        EpochedQueueModule queue = EpochedQueueModule(address(core));
        vm.prank(user);
        (uint256 epoch1, uint256 claim1) = queue.requestEpochWithdrawal(firstExitShares);
        uint256 owed1 = queue.epochClaim(epoch1, claim1).assetsOwed;
        assertGt(owed1, 0, "epoch 1 owed non-zero");

        _roll(_fullExitPhaseBlock(2));
        buffer.refreshWarmNav();
        _poke();
        strategy.harvest();
        _observe();

        queue.closeCurrentEpoch();
        queue.fundEpoch(epoch1);
        for (uint256 i; i < 4 && queue.epochDeficit(epoch1) > 0; ++i) {
            LiquidityOpsModule(address(core)).realizeForQueue(queue.epochDeficit(epoch1));
            queue.fundEpoch(epoch1);
        }
        assertEq(queue.epochDeficit(epoch1), 0, "epoch 1 fully funded");

        vm.prank(user);
        queue.claimEpochAssets(epoch1, claim1);
        assertEq(
            IERC20Metadata(market.asset).balanceOf(user) - user1BalBefore,
            owed1,
            "user1 received exact epoch-1 owed balance"
        );
        assertEq(core.balanceOf(user), shares1 - firstExitShares, "user1 shares reduced");
        assertEq(core.balanceOf(user2), shares2, "user2 shares untouched after epoch 1");

        this.exerciseEpoch2FullExit();
    }

    /// Epoch 2: user2 requests full exit. After epoch 1 drained hot cash,
    /// user2's claim exceeds remaining core idle, so invested capital is recalled.
    /// Asserts: zero user2 shares, exact owed amount, user1 NAV conserved.
    function exerciseEpoch2FullExit() external {
        require(msg.sender == address(this), "self-only");

        uint256 shares1 = core.balanceOf(user);
        uint256 shares2 = core.balanceOf(user2);
        uint256 totalAtRequest = core.totalSupply();

        // user2's full allocation must still fit within the unchanged 10% cap.
        assertLt(shares2 * 10000 / totalAtRequest, 1000,
            "user2 full shares within 10pct of current supply - cap unchanged");

        uint256 user2BalBefore = IERC20Metadata(market.asset).balanceOf(user2);
        uint256 epoch2;
        uint256 claim2;
        uint256 owed2;
        {
            EpochedQueueModule queue = EpochedQueueModule(address(core));
            vm.prank(user2);
            (epoch2, claim2) = queue.requestEpochWithdrawal(shares2);
            owed2 = queue.epochClaim(epoch2, claim2).assetsOwed;
            assertGt(owed2, 0, "user2 owed non-zero assets");
        }

        _roll(_fullExitPhaseBlock(3));
        buffer.refreshWarmNav();
        _poke();
        strategy.harvest();
        _observe();

        // Remaining core idle must be below user2's owed amount, proving recall.
        assertGt(owed2, IERC20Metadata(market.asset).balanceOf(address(core)),
            "user2 exit requires recall of invested capital");

        uint256 adapterBeforeFund = adapter.totalAssets();
        {
            EpochedQueueModule queue = EpochedQueueModule(address(core));
            queue.closeCurrentEpoch();
            queue.fundEpoch(epoch2);
            for (uint256 i; i < 4 && queue.epochDeficit(epoch2) > 0; ++i) {
                LiquidityOpsModule(address(core)).realizeForQueue(queue.epochDeficit(epoch2));
                queue.fundEpoch(epoch2);
            }
            assertEq(queue.epochDeficit(epoch2), 0, "user2 epoch fully funded");
            assertLt(adapter.totalAssets(), adapterBeforeFund,
                "adapter assets declined - invested capital was recalled");
        }

        uint256 navPre = core.convertToAssets(1e18);
        uint256 val1Pre = core.convertToAssets(shares1);

        vm.prank(user2);
        EpochedQueueModule(address(core)).claimEpochAssets(epoch2, claim2);
        assertTrue(EpochedQueueModule(address(core)).epochClaim(epoch2, claim2).claimed,
            "full exit leaves no unsettled claim");

        uint256 navPost  = core.convertToAssets(1e18);
        uint256 val1Post = core.convertToAssets(shares1);

        // --- Primary exit invariants ---
        assertEq(core.balanceOf(user2), 0,
            "user2 zero remaining shares after full exit");
        assertEq(IERC20Metadata(market.asset).balanceOf(user2) - user2BalBefore, owed2,
            "user2 received exact owed balance");

        // --- User1 conservation invariants ---
        assertEq(core.balanceOf(user), shares1,
            "user1 shares unchanged after user2 full exit");
        assertGe(val1Post, val1Pre,
            "user1 redeemable value cannot decrease from user2 claim");
        assertLe(val1Post - val1Pre, 1,
            "claim rounding residual at most 1 raw asset unit");
        assertGt(adapter.totalAssets(), 0,
            "user1 capital still invested in Aave after user2 full exit");

        emit FullExitVerified(
            market.asset, rpcForkBlock,
            user2, shares2, totalAtRequest,
            1000, owed2, shares1,
            adapter.totalAssets(), navPre, navPost
        );

        // Full strategy recall: verify accounting and user1 NAV conservation.
        {
            uint256 coreBal = IERC20Metadata(market.asset).balanceOf(address(core));
            uint256 recalled = router.withdrawAllToCore(address(strategy));
            assertGt(recalled, 0, "router must recall non-zero capital");
            assertEq(
                IERC20Metadata(market.asset).balanceOf(address(core)) - coreBal,
                recalled,
                "core delta equals recalled amount"
            );
            assertLe(strategy.totalAssets(), 2, "strategy at dust after full recall");
            assertLe(adapter.totalAssets(),  2, "adapter at dust after full recall");
            assertEq(core.balanceOf(user), shares1,
                "user1 shares unchanged after strategy recall");
            assertApproxEqAbs(core.convertToAssets(shares1), val1Post, 2,
                "user1 NAV conserved through strategy recall");
        }

        _observe();
    }

    /// Funds this test contract with WETH via real USDT->WETH UniV3 swap.

    /// HOLDER impersonation is disclosed; 1000 USDT yields ~0.333 ETH at $3000/ETH.
    function fundWethForTest() external {
        require(msg.sender == address(this));
        IERC20Metadata usdt = IERC20Metadata(0xdAC17F958D2ee523a2206206994597C13D831ec7);
        uint256 funding      = 1000e6;
        uint256 holderBefore = usdt.balanceOf(HOLDER);
        uint256 beforeThis   = usdt.balanceOf(address(this));
        uint256 supply       = usdt.totalSupply();
        assertGe(holderBefore, funding);
        vm.prank(HOLDER);
        usdt.safeTransfer(address(this), funding);
        assertEq(usdt.balanceOf(address(this)) - beforeThis, funding);
        assertEq(usdt.balanceOf(HOLDER), holderBefore - funding);
        assertEq(usdt.totalSupply(), supply, "no synthetic funding");
        emit RealFunding(1, address(usdt), HOLDER, holderBefore, funding, usdt.balanceOf(HOLDER));

        // USDT/USD feed to compute expected WETH output; answer has 8 decimals.
        (uint80 round, int256 answer,, uint256 updated, uint80 answered) =
            IFundingFeed(0x3E7d1eAB13ad0104d2750B8863b489D65364e32D).latestRoundData();
        assertGt(answer, 0);
        assertGe(answered, round);
        assertLe(block.timestamp - updated, 1 days);

        uint256 expected = Math.mulDiv(
            funding, uint256(answer) * 1e22, oracle.getQuoteFresh(market.asset).price
        );

        address swapRouter = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
        IERC20Metadata weth = IERC20Metadata(market.asset);
        uint256 wethBefore = weth.balanceOf(address(this));
        uint256 wethSupply = weth.totalSupply();
        usdt.forceApprove(swapRouter, funding);
        uint256 received = ISwapRouterV3(swapRouter).exactInput(
            ISwapRouterV3.ExactInputParams(
                abi.encodePacked(address(usdt), uint24(500), market.asset),
                address(this),
                funding,
                expected * 9900 / 10000
            )
        );
        usdt.forceApprove(swapRouter, 0);
        assertEq(weth.balanceOf(address(this)) - wethBefore, received);
        assertGe(received, expected * 9900 / 10000);
        assertEq(weth.totalSupply(), wethSupply, "no synthetic WETH");
        emit RealFundingConversion(1, address(usdt), market.asset, funding, expected, received);
    }
}

contract FullUserExitE2ETest is FullUserExitE2EBase {
    function test_fullExitSmallUser_usdt() public { _fullExitScenario(false); }
    function test_fullExitSmallUser_weth() public { _fullExitScenario(true); }
}
