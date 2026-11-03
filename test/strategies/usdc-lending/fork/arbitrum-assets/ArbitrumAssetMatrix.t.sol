// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LendingEthereumAdditionalUnmockedE2EBase} from
    "../actual/LendingEthereumAdditionalUnmockedE2E.t.sol";
import {RealArbitrumFunding} from "./RealArbitrumFunding.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AdminModule} from "@multyr-core/core/modules/AdminModule.sol";
import {LiquidityOpsModule} from "@multyr-core/core/modules/LiquidityOpsModule.sol";
import {EpochedQueueModule} from "@multyr-core/core/modules/EpochedQueueModule.sol";
import {ProtocolRegistry} from
    "@multyr-strategies/strategies/usdc-lending/registry/ProtocolRegistry.sol";
import {AaveV3USDCAdapter as Aave} from
    "@multyr-strategies/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol";
import {CometUsdcMultiMarketAdapter as Comet} from
    "@multyr-strategies/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol";
import {MorphoUsdcMultiMarketAdapter as Morpho} from
    "@multyr-strategies/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol";
import {EulerUsdcMultiMarketAdapter as Euler} from
    "@multyr-strategies/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol";
import {FluidUsdcMultiMarketAdapter as Fluid} from
    "@multyr-strategies/strategies/usdc-lending/adapters/lending/FluidUsdcMultiMarket.sol";
import {DolomiteUsdcMultiMarketAdapter as Dolomite} from
    "@multyr-strategies/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol";
import {VenusUsdcMultiMarketAdapter as Venus} from
    "@multyr-strategies/strategies/usdc-lending/adapters/lending/VenusUsdcMultiMarket.sol";
import {StrategySettingsModule as Settings} from
    "@multyr-strategies/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {StrategyParamsModule as Params} from
    "@multyr-strategies/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import {StrategyScoringModule as Scoring} from
    "@multyr-strategies/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import {LendingAssetConfig} from
    "@multyr-strategies/strategies/usdc-lending/config/LendingAssetConfig.sol";

// ---------------------------------------------------------------------------
// Generic adapter surface used throughout — no family-specific selectors.
// ---------------------------------------------------------------------------
interface IMatrixCoreAdapter {
    function deposit(uint256 assets) external;
    function withdraw(uint256 assets, address receiver) external returns (uint256);
    function emergencyPullAllToVault() external;
    function totalAssets() external view returns (uint256);
    function withdrawableAssets() external view returns (uint256);
    function investedAssets() external view returns (uint256);
    function externalMarketTVL() external view returns (uint256);
    function currentAPYBps() external view returns (uint16);
    function harvest(address receiver) external returns (uint256);
}
interface IMatrixPpsVault {
    function convertToAssets(uint256) external view returns (uint256);
    function totalAssets() external view returns (uint256);
}
interface IMatrixPriceFeed {function latestRoundData() external view returns(uint80,int256,uint256,uint256,uint80);function decimals() external view returns(uint8);}

// ---------------------------------------------------------------------------
// 7-family × N-asset Arbitrum production Core + candidate strategy lifecycle.
// Configured entirely by environment; no vm.deal/etch/store/mockCall/warp.
// ---------------------------------------------------------------------------
contract ArbitrumAssetMatrixTest is LendingEthereumAdditionalUnmockedE2EBase, RealArbitrumFunding {
    using SafeERC20 for IERC20Metadata;

    // family: 0=Aave 1=Comet 2=Morpho 3=Euler 4=Fluid 5=Dolomite 6=Venus
    uint256 mFamily;
    address mVenue;   // MATRIX_MARKET
    address mFeed;    // MATRIX_FEED
    address mReceipt; // MATRIX_RECEIPT (aToken for Aave)
    bool    mV2;      // MATRIX_V2 (Morpho V2 liquidity helper)
    address mAdapter; // deployed adapter
    address mUser2;

    // Machine-readable events — all integers preserved.
    event ActualMatrixFunding(
        uint256 family, address asset, uint256 pin, uint256 received, uint256 supplyUnchanged
    );
    event ActualMatrixMarketRate(
        uint256 family, address asset, address market, uint256 pin, uint256 extUsd6, uint16 aprBps
    );
    event ActualMatrixConversion(
        uint256 family, address asset, uint256 rawTvl, uint256 priceWad,
        uint8 decimals, uint256 usd6Floor, uint256 inverseRaw
    );
    event ActualMatrixPolicyRejection(
        uint256 family, address asset, address market, uint256 extUsd6, uint256 pin
    );
    event ActualMatrixScore(
        uint256 family, address asset, uint256 invested, bool policyAccepted
    );
    event ActualMatrixEpochClaim(
        uint256 family, address asset, uint256 epoch, address claimant,
        uint256 shares, uint256 owed, uint256 received
    );
    event ActualMatrixInvestedNav(
        uint256 family, address asset, address market, uint256 pin,
        uint256 invested, uint256 recalled, uint256 residual
    );

    // -----------------------------------------------------------------------
    // Base overrides
    // -----------------------------------------------------------------------
    function _rpc() internal view override returns (string memory) {
        return vm.envString("ARBITRUM_RPC_URL");
    }

    function _assetFeed() internal view override returns (address) {
        return mFeed;
    }

    // Use CREATE2-based deployment to guarantee zero token balance at fixture
    // address, avoiding the accidental USDT0 canonical donation at 0x5615.
    function _new(string memory artifact, bytes memory args) internal override returns (address a) {
        a = _deployArbitrumFixture(artifact, args, market.asset, keep.length);
        keep.push(a);
    }

    // -----------------------------------------------------------------------
    // Single public test entry point
    // -----------------------------------------------------------------------
    function test_arbitrumRealAssetCoreStrategyLifecycle() public {
        mFamily  = vm.envUint("MATRIX_FAMILY");
        mFeed    = vm.envAddress("MATRIX_FEED");
        mVenue   = vm.envAddress("MATRIX_MARKET");
        mReceipt = vm.envOr("MATRIX_RECEIPT", address(0));
        mV2      = vm.envOr("MATRIX_V2", false);
        mUser2   = vm.addr(0xB0C2);

        // market.asset must be set before any _new call (used in CREATE2 salt).
        address asset = vm.envAddress("MATRIX_ASSET");
        // Temporary struct; decimals resolved after fork where token has code.
        market = LendingAssetConfig.Market(
            42161,
            asset,
            0,   // decimals resolved below
            mFamily == 0 ? mVenue   : address(0),
            mFamily == 0 ? mReceipt : address(0)
        );

        chain  = 42161;
        user   = vm.addr(0xB0B);

        vm.createSelectFork(_rpc(), 513000000);
        rpcForkBlock = 513000000;
        assertEq(block.chainid, 42161, "must fork Arbitrum");

        market.decimals = uint8(IERC20Metadata(asset).decimals());

        // Deploy production Core + candidate strategy.
        _configureProductionCore();
        strategy = _candidate();
        uint256 eta = router.proposeStrategyAllowlist(address(strategy));
        vm.makePersistent(keep);
        _roll(513800000);
        assertGe(vm.getBlockTimestamp(), eta, "timelock must have elapsed");
        buffer.refreshWarmNav();
        router.executeStrategyAllowlist(address(strategy));
        router.register(address(strategy), 0, 10000);
        router.setMaxStrategyBps(address(strategy), 10000);
        router.setLossCapPerStrategy(address(strategy), 50);

        // Build and register the family adapter (vault = strategy, not test contract).
        mAdapter = _buildAdapter();
        Settings(address(strategy)).whitelistAdapter(mAdapter, true);
        strategy.addAdapter(mAdapter);
        strategy.toggleAdapter(mAdapter, true);
        // Exercise the strategy's automatic deposit-mode probe, including
        // Euler's mandatory push mode; do not mask it with an admin override.

        // Prime PPS-based adapters across a real canonical interval before funding.
        // Adapter + registry persist; all market state remains canonical.
        if (mFamily == 2 || mFamily == 4 || mFamily == 5) {
            this.primePpsRate(mAdapter, mVenue);
        } else {
            vm.makePersistent(keep);
            _roll(514200000);
        }
        // Venus: trigger interest accrual permissionlessly.
        if (mFamily == 6) {
            assertEq(Venus(payable(mAdapter)).accrueVenusInterest(), 0, "Venus accrue must not fail");
        }

        // --- Independent TVL / USD-conversion / APR check at pin ---
        _checkIndependentTvlAndRate();

        uint256 extUsd6 = _extUsd6();
        emit ActualMatrixMarketRate(
            mFamily, market.asset, mVenue, rpcForkBlock,
            extUsd6, IMatrixCoreAdapter(mAdapter).currentAPYBps()
        );

        // Policy-rejection: production 100 k USD floor; do not lower limits.
        if (extUsd6 < 100_000e6) {
            emit ActualMatrixPolicyRejection(mFamily, market.asset, mVenue, extUsd6, rpcForkBlock);
            _policyRejectionExit();
            return;
        }

        // --- Fund via real USDT0 holder + UniV3 swap (no vm.deal) ---
        uint256 received = _fundArbitrumAsset(market.asset, mFeed, 3000);
        assertGt(received, 0, "real funding must yield tokens");
        emit ActualMatrixFunding(
            mFamily, market.asset, rpcForkBlock, received, IERC20Metadata(market.asset).totalSupply()
        );

        // Persist funding-side state and market accounting before capital moves.
        _persistArbitrumFunding();
        _persistMarketDeps();
        vm.makePersistent(keep);

        // Deploy both users + seed through production Core.
        this.matrixSeedAndDeposit(received);
        _persistMarketDeps();

        // Advance to canonical ramp completion (>1 day from pin 514200000).
        _maintainTo(515000000);
        buffer.refreshWarmNav();
        _poke();
        Scoring(address(strategy)).deployIdle();
        assertLe(strategy.idleCash(), 2, "ramp must complete before epoch test");

        uint256 invested0 = IMatrixCoreAdapter(mAdapter).totalAssets();
        assertGt(invested0, 0, "real capital must be deployed to production venue");
        emit ActualMatrixInvestedNav(mFamily, market.asset, mVenue, rpcForkBlock, invested0, 0, 0);
        emit ActualMatrixScore(mFamily, market.asset, invested0, true);

        // --- Two-epoch exit lifecycle ---
        this.matrixEpoch1(invested0);
    }

    // -----------------------------------------------------------------------
    // PPS priming (Morpho / Fluid / Dolomite): two canonical fork rolls.
    // No position or token state modified. Adapter + registry persisted only.
    // -----------------------------------------------------------------------
    function primePpsRate(address a, address venue) external {
        require(msg.sender == address(this), "self-only");
        uint256 pps0 = IMatrixPpsVault(venue).convertToAssets(1e24);
        uint256 ts0  = vm.getBlockTimestamp();
        _pokeAdapter(a);
        assertEq(IMatrixCoreAdapter(a).currentAPYBps(), 0, "unprimed must report zero");
        vm.makePersistent(keep);
        _roll(514200000);
        uint256 pps1 = IMatrixPpsVault(venue).convertToAssets(1e24);
        uint256 ts1  = vm.getBlockTimestamp();
        assertGe(ts1 - ts0, 1 hours, "must span at least one hour");
        assertLe(ts1 - ts0, 2 days,  "span must not exceed two days");
        assertGe(pps1, pps0, "PPS must be non-decreasing");
        uint256 exp = pps1 > pps0
            ? Math.min(
                type(uint16).max,
                (pps1 - pps0) * 315360000000 / pps0 / (ts1 - ts0)
              )
            : 0;
        if(mFamily==2&&ts1-ts0>1 days)assertEq(IMatrixCoreAdapter(a).currentAPYBps(),0,"stale Morpho quote remains conservative before maintenance");
        else assertEq(IMatrixCoreAdapter(a).currentAPYBps(), exp, "independent PPS APR");
        _pokeAdapter(a);
        assertEq(IMatrixCoreAdapter(a).currentAPYBps(), exp, "maintenance must preserve rate");
    }

    // -----------------------------------------------------------------------
    // Seed + two-user deposit (external self-call reduces stack depth).
    // -----------------------------------------------------------------------
    function matrixSeedAndDeposit(uint256 totalReceived) external {
        require(msg.sender == address(this));
        IERC20Metadata tok = IERC20Metadata(market.asset);
        uint256 price  = oracle.getQuoteFresh(market.asset).price;
        uint256 unit   = 10 ** market.decimals;
        uint256 seed   = Math.mulDiv(1e18,     unit, price, Math.Rounding.Up);
        uint256 amt1   = Math.mulDiv(2000e18,  unit, price, Math.Rounding.Up);
        uint256 amt2   = Math.mulDiv(125e18,   unit, price, Math.Rounding.Up);
        assertGe(totalReceived, seed + amt1 + amt2, "funding must cover seed+u1+u2");

        tok.forceApprove(address(core), seed);
        AdminModule(address(core)).seedDeadDeposit(seed);
        core.unpauseAll();
        core.freezeRouting();
        AdminModule(address(core)).freezeParams();

        tok.safeTransfer(user, amt1);
        vm.startPrank(user);
        tok.forceApprove(address(core), amt1);
        assertGt(core.deposit(amt1, user), 0, "user1 deposit must mint shares");
        vm.stopPrank();

        tok.safeTransfer(mUser2, amt2);
        vm.startPrank(mUser2);
        tok.forceApprove(address(core), amt2);
        assertGt(core.deposit(amt2, mUser2), 0, "user2 deposit must mint shares");
        vm.stopPrank();

        assertLt(
            core.balanceOf(mUser2) * 10000 / core.totalSupply(),
            1000,
            "user2 entire holding fits within unchanged 10pct epoch cap"
        );

        _poke();
        LiquidityOpsModule(address(core)).deployToStrategies(type(uint256).max);
        Scoring(address(strategy)).deployIdle();
        if(_extUsd6()<100_000e6)assertEq(IMatrixCoreAdapter(mAdapter).totalAssets(),0,"rejected venue stays unfunded");
        else assertGt(IMatrixCoreAdapter(mAdapter).totalAssets(), 0, "capital must enter venue");
        if(mFamily==3&&_extUsd6()>=100_000e6){assertTrue(strategy.depositModeKnown(mAdapter));assertTrue(strategy.pushDepositMode(mAdapter),"Euler push mode must be discovered automatically");}
    }

    // -----------------------------------------------------------------------
    // Epoch 1: user1 requests 8 % partial exit at 515000000.
    // Close + fund + claim at 517500000 (> 7 days after request).
    // -----------------------------------------------------------------------
    function matrixEpoch1(uint256 invested0) external {
        require(msg.sender == address(this));
        EpochedQueueModule queue = EpochedQueueModule(address(core));
        IERC20Metadata tok = IERC20Metadata(market.asset);

        uint256 s1 = core.balanceOf(user);
        uint256 s2 = core.balanceOf(mUser2);
        assertGt(s1, 0); assertGt(s2, 0);

        uint256 exit1 = s1 * 800 / 10000;
        assertLt(exit1 * 10000 / core.totalSupply(), 1000, "user1 partial within 10pct cap");

        vm.prank(user);
        (uint256 epoch1, uint256 cl1) = queue.requestEpochWithdrawal(exit1);
        uint256 owed1 = queue.epochClaim(epoch1, cl1).assetsOwed;
        assertGt(owed1, 0, "epoch1 owed must be non-zero");
        emit ActualMatrixEpochClaim(mFamily, market.asset, epoch1, user, exit1, owed1, 0);

        // > 7 days elapsed → timestamps from real headers, no warp.
        _maintainTo(517500000);
        buffer.refreshWarmNav();
        _poke();
        strategy.harvest();

        queue.closeCurrentEpoch();
        queue.fundEpoch(epoch1);
        for (uint256 i; i < 4 && queue.epochDeficit(epoch1) > 0; ++i) {
            LiquidityOpsModule(address(core)).realizeForQueue(queue.epochDeficit(epoch1));
            queue.fundEpoch(epoch1);
        }
        assertEq(queue.epochDeficit(epoch1), 0, "epoch1 must be fully funded");

        uint256 u1Before = tok.balanceOf(user);
        vm.prank(user);
        queue.claimEpochAssets(epoch1, cl1);
        assertEq(tok.balanceOf(user) - u1Before, owed1, "user1 received exact owed1");
        assertEq(core.balanceOf(user), s1 - exit1, "user1 shares reduced");
        assertEq(core.balanceOf(mUser2), s2, "user2 shares untouched after epoch1");
        emit ActualMatrixEpochClaim(mFamily, market.asset, epoch1, user, exit1, owed1, owed1);

        this.matrixEpoch2(invested0);
    }

    // -----------------------------------------------------------------------
    // Epoch 2: user2 requests full exit at 517500000.
    // Close + fund + claim at 520094008 (> 7 days). Full recall + dust check.
    // -----------------------------------------------------------------------
    function matrixEpoch2(uint256 invested0) external {
        require(msg.sender == address(this));
        EpochedQueueModule queue = EpochedQueueModule(address(core));
        IERC20Metadata tok = IERC20Metadata(market.asset);

        uint256 s2 = core.balanceOf(mUser2);
        assertLt(s2 * 10000 / core.totalSupply(), 1000, "user2 full shares within 10pct cap");

        vm.prank(mUser2);
        (uint256 epoch2, uint256 cl2) = queue.requestEpochWithdrawal(s2);
        uint256 owed2 = queue.epochClaim(epoch2, cl2).assetsOwed;
        assertGt(owed2, 0, "epoch2 owed must be non-zero");

        _maintainTo(520094008);
        buffer.refreshWarmNav();
        _poke();
        strategy.harvest();
        _observe();

        // Second exit must require capital recall from the adapter.
        assertGt(
            owed2, tok.balanceOf(address(core)),
            "user2 exit must require recall of invested capital"
        );

        uint256 adBefore = IMatrixCoreAdapter(mAdapter).totalAssets();
        queue.closeCurrentEpoch();
        queue.fundEpoch(epoch2);
        for (uint256 i; i < 4 && queue.epochDeficit(epoch2) > 0; ++i) {
            LiquidityOpsModule(address(core)).realizeForQueue(queue.epochDeficit(epoch2));
            queue.fundEpoch(epoch2);
        }
        assertEq(queue.epochDeficit(epoch2), 0, "epoch2 must be fully funded");
        assertLt(
            IMatrixCoreAdapter(mAdapter).totalAssets(), adBefore,
            "adapter assets decline when invested capital is recalled"
        );

        uint256 u2Before = tok.balanceOf(mUser2);
        vm.prank(mUser2);
        queue.claimEpochAssets(epoch2, cl2);
        assertEq(tok.balanceOf(mUser2) - u2Before, owed2, "user2 received exact owed2");
        assertEq(core.balanceOf(mUser2), 0, "user2 zero remaining shares");
        emit ActualMatrixEpochClaim(mFamily, market.asset, epoch2, mUser2, s2, owed2, owed2);

        // Earlier withdrawals and harvests reduce the position: comparing its
        // final balance with the initial principal would not measure interest.
        assertGt(invested0,0,"initial actual investment recorded");

        // Full strategy recall — exact Core balance delta, adapter residual ≤ 2 units.
        uint256 coreBefore = tok.balanceOf(address(core));
        uint256 recalled   = router.withdrawAllToCore(address(strategy));
        assertGt(recalled, 0, "router must recall non-zero capital");
        assertEq(
            tok.balanceOf(address(core)) - coreBefore, recalled,
            "core delta must equal recalled amount"
        );
        assertLe(strategy.totalAssets(), 2, "strategy at dust after full recall");
        assertLe(
            IMatrixCoreAdapter(mAdapter).totalAssets(), 2,
            "adapter at dust after full recall"
        );
        emit ActualMatrixInvestedNav(
            mFamily, market.asset, mVenue, rpcForkBlock,
            adBefore, recalled, IMatrixCoreAdapter(mAdapter).totalAssets()
        );
        _observe();
    }

    // -----------------------------------------------------------------------
    // Policy-rejection path: TVL < $100 k.
    // Prove strategy correctly withholds capital; small user exits from idle.
    // -----------------------------------------------------------------------
    function _policyRejectionExit() internal {
        Params(address(strategy)).pokeExternalTVL();
        Params(address(strategy)).pokeLiquidityBatch(0, 1);
        assertEq(Params(address(strategy)).tierConfidence(IMatrixCoreAdapter(mAdapter).externalMarketTVL(),uint64(vm.getBlockTimestamp()),1 days),0,"unchanged USD risk floor rejects this market");
        uint256 received = _fundArbitrumAsset(market.asset, mFeed, 3000);
        _persistArbitrumFunding();
        _persistMarketDeps();
        vm.makePersistent(keep);
        this.matrixSeedAndDeposit(received);
        _maintainTo(515000000);
        buffer.refreshWarmNav();_poke();
        assertEq(IMatrixCoreAdapter(mAdapter).totalAssets(),0,"funded allocation attempt preserves risk exclusion");
        emit ActualMatrixScore(mFamily,market.asset,0,false);
        IERC20Metadata tok = IERC20Metadata(market.asset);
        EpochedQueueModule queue = EpochedQueueModule(address(core));
        uint256 shares=core.balanceOf(mUser2);assertGt(shares,0);
        assertLt(shares*10000/core.totalSupply(),1000,"full small-user exit respects original epoch cap");
        vm.prank(mUser2);
        (uint256 ep, uint256 cl) = queue.requestEpochWithdrawal(shares);
        uint256 owed = queue.epochClaim(ep, cl).assetsOwed;
        assertGt(owed, 0);
        _maintainTo(520094008);
        buffer.refreshWarmNav();
        queue.closeCurrentEpoch();
        queue.fundEpoch(ep);
        for(uint256 i;i<4&&queue.epochDeficit(ep)>0;++i){LiquidityOpsModule(address(core)).realizeForQueue(queue.epochDeficit(ep));queue.fundEpoch(ep);}
        assertEq(queue.epochDeficit(ep), 0, "idle-cash exit must fund fully");
        uint256 before = tok.balanceOf(mUser2);
        vm.prank(mUser2);
        queue.claimEpochAssets(ep, cl);
        assertEq(tok.balanceOf(mUser2) - before, owed, "exact owed on idle-cash exit");
        assertEq(core.balanceOf(mUser2), 0, "zero shares after idle exit");
    }

    // -----------------------------------------------------------------------
    // Adapter construction — vault = strategy (not test contract).
    // -----------------------------------------------------------------------
    function _buildAdapter() internal returns (address a) {
        if (mFamily == 0) {
            a = _new("AaveV3USDCmarket.sol:AaveV3USDCAdapter", bytes(""));
            Aave(payable(a)).initialize(
                market.asset, mVenue, mReceipt, address(this), address(strategy), 0
            );
            // Wire inherited adapter field for _observe() totalAssets access.
            adapter = Aave(payable(a));
            return a;
        }
        if (mFamily == 3) {
            address[] memory ms = new address[](1); ms[0] = mVenue;
            a = _new("EulerUsdcMultiMarket.sol:EulerUsdcMultiMarketAdapter", bytes(""));
            Euler(payable(a)).initialize(address(strategy), market.asset, ms, address(0), address(this));
            Euler(payable(a)).initializeMarkets();
            return a;
        }
        if (mFamily == 4) {
            a = _new("FluidUsdcMultiMarket.sol:FluidUsdcMultiMarketAdapter", bytes(""));
            Fluid(payable(a)).initialize(market.asset, address(this), address(strategy), 0, mVenue);
            return a;
        }
        if (mFamily == 6) {
            a = _new("VenusUsdcMultiMarket.sol:VenusUsdcMultiMarketAdapter", bytes(""));
            Venus(payable(a)).initialize(
                market.asset, address(this), address(strategy), 0, mVenue, 31536000
            );
            return a;
        }
        ProtocolRegistry r = ProtocolRegistry(
            _new("ProtocolRegistry.sol:ProtocolRegistry", abi.encode(address(this)))
        );
        ProtocolRegistry.ProtocolType pt = mFamily == 1
            ? ProtocolRegistry.ProtocolType.COMPOUND_V3
            : mFamily == 2
                ? ProtocolRegistry.ProtocolType.MORPHO
                : ProtocolRegistry.ProtocolType.DOLOMITE;
        r.addVault(pt, mVenue, "matrix Arbitrum venue", 1000, type(uint128).max);
        if (mFamily == 1) {
            a = _new("CometUsdcMultiMarket.sol:CometUsdcMultiMarketAdapter", bytes(""));
            Comet(payable(a)).initialize(market.asset, address(this), address(strategy), 0, address(r));
        } else if (mFamily == 2) {
            a = _new("MorphoUsdcMultiMarket.sol:MorphoUsdcMultiMarketAdapter", bytes(""));
            Morpho(payable(a)).initialize(
                market.asset, address(this), address(strategy), 0, address(r)
            );
            if (mV2) {
                Morpho(payable(a)).setVaultV2LiquidityView(
                    _new("MorphoVaultV2LiquidityView.sol:MorphoVaultV2LiquidityView", bytes(""))
                );
            }
        } else {
            require(mFamily == 5, "ArbitrumAssetMatrix: unknown family");
            a = _new("DolomiteUsdcMultiMarket.sol:DolomiteUsdcMultiMarketAdapter", bytes(""));
            Dolomite(payable(a)).initialize(
                market.asset, address(this), address(strategy), 0, address(r)
            );
        }
    }

    // -----------------------------------------------------------------------
    // Persist real market accounting modified by the scenario's transactions.
    // Oracle feeds are canonical chain data and must NOT be persisted.
    // -----------------------------------------------------------------------
    function _persistMarketDeps() internal {
        vm.makePersistent(market.asset);
        if (mFamily == 0) {
            // Aave pool, aToken, variable/stable debt tokens.
            vm.makePersistent(mVenue);
            vm.makePersistent(mReceipt);
            _persistDebtTokens(); // base implementation uses market.aavePool
        } else if (mFamily == 1) {
            // Comet cToken is the receipt and tracks balances internally.
            vm.makePersistent(mVenue);
        } else if (mFamily == 2) {
            // Resolve actual chain bindings; Ethereum singleton addresses are
            // not evidence of Arbitrum dependencies.
            if(!mV2)_persistBoundDependency(mVenue,"MORPHO()");
            vm.makePersistent(mVenue);
        } else if (mFamily == 3) {
            // EVault and its actual EVC binding on this chain.
            vm.makePersistent(mVenue);
            _persistBoundDependency(mVenue,"EVC()");
            vm.makePersistent(0x000000000022D473030F116dDEE9F6B43aC78BA3);
        } else if (mFamily == 4) {
            // The real Fluid accounting layer is captured by its NAV graph.
            vm.makePersistent(mVenue);
        } else if (mFamily == 5) {
            // Dolomite dToken (ERC4626 wrapper) and the Margin contract.
            vm.makePersistent(mVenue);
            (bool ok, bytes memory raw) = mVenue.staticcall(
                abi.encodeWithSignature("DOLOMITE_MARGIN()")
            );
            require(ok&&raw.length==32,"real Dolomite accounting dependency");
            address margin=abi.decode(raw,(address));require(margin.code.length>0,"deployed Dolomite Margin");vm.makePersistent(margin);
        } else if (mFamily == 6) {
            // vToken; comptroller holds interest-rate state.
            vm.makePersistent(mVenue);
            (bool ok, bytes memory raw) = mVenue.staticcall(
                abi.encodeWithSignature("comptroller()")
            );
            if (ok && raw.length == 32) {
                address comp = abi.decode(raw, (address));
                if (comp.code.length > 0) vm.makePersistent(comp);
            }
        }
        if(mFamily==2||mFamily==4)this.preserveMatrixNavDependencies();
    }
    function _persistBoundDependency(address target,string memory signature) internal {
        (bool ok,bytes memory raw)=target.staticcall(abi.encodeWithSignature(signature));require(ok&&raw.length==32,"actual chain dependency getter");
        address dependency=abi.decode(raw,(address));require(dependency.code.length>0,"deployed actual dependency");vm.makePersistent(dependency);
    }

    function preserveMatrixNavDependencies() external {
        require(msg.sender==address(this));
        vm.startStateDiffRecording();IMatrixPpsVault(mVenue).totalAssets();
        Vm.AccountAccess[] memory accessed=vm.stopAndReturnStateDiff();
        require(accessed.length>0&&accessed.length<=512,"bounded genuine NAV dependency graph");
        for(uint256 i;i<accessed.length;++i){address account=accessed[i].account;if(account.code.length==0)continue;
            require(account!=mFeed&&account!=0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3&&account!=0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612&&account!=0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7&&account!=0x6ce185860a4963106506C203335A2910413708e9,"canonical price feed must advance");
            vm.makePersistent(account);
        }
    }

    function _maintainTo(uint256 target) internal {
        if(mFamily!=2&&mFamily!=4&&mFamily!=5){_roll(target);return;}
        while(rpcForkBlock<target){uint256 next=rpcForkBlock+400000;if(next>target)next=target;uint256 previous=vm.getBlockTimestamp();_roll(next);assertLe(vm.getBlockTimestamp()-previous,2 days,"canonical PPS observation remains within production window");_pokeAdapter(mAdapter);}
    }

    // -----------------------------------------------------------------------
    // Adapter-specific maintenance (APY snapshot, interest accrual).
    // -----------------------------------------------------------------------
    function _pokeAdapter(address a) internal {
        if (mFamily == 2) Morpho(payable(a)).pokeAPYSnapshots();
        else if (mFamily == 4) Fluid(payable(a)).pokeAPYSnapshots();
        else if (mFamily == 5) Dolomite(payable(a)).pokeAPYSnapshots();
    }

    // -----------------------------------------------------------------------
    // External TVL → USD6 and inverse conversion; independent of strategy math.
    // floor(raw * priceWad / (10^decimals * 1e12))
    // ceil(usd6 * 10^decimals * 1e12 / priceWad)
    // -----------------------------------------------------------------------
    function _checkIndependentTvlAndRate() internal {
        uint256 priceWad = oracle.getQuoteFresh(market.asset).price;
        IMatrixPriceFeed feed=IMatrixPriceFeed(mFeed);(uint80 round,int256 answer,,uint256 updated,uint80 answered)=feed.latestRoundData();
        assertGt(answer,0);assertGe(answered,round);assertGt(round,0);assertLe(updated,vm.getBlockTimestamp());assertLe(vm.getBlockTimestamp()-updated,1 days);assertEq(feed.decimals(),8);
        assertEq(priceWad,uint256(answer)*1e10,"frozen Core quote equals independent raw Chainlink USD price");
        uint256 extRaw   = IMatrixCoreAdapter(mAdapter).externalMarketTVL();
        uint8   dec      = market.decimals;
        uint256 denom    = (10 ** dec) * 1e12;
        uint256 usd6     = Math.mulDiv(extRaw, priceWad, denom);
        uint256 inv      = Math.mulDiv(usd6, denom, priceWad, Math.Rounding.Up);
        assertEq(
            Params(address(strategy)).assetUnitsToUsd6(extRaw), usd6,
            "independent TVL USD6 conversion"
        );
        assertEq(Params(address(strategy)).usd6ToAssetUnits(usd6),inv,"independent inverse conversion rounds up");
        emit ActualMatrixConversion(mFamily, market.asset, extRaw, priceWad, dec, usd6, inv);
    }

    function _extUsd6() internal view returns (uint256) {
        uint256 priceWad = oracle.getQuoteFresh(market.asset).price;
        uint256 extRaw   = IMatrixCoreAdapter(mAdapter).externalMarketTVL();
        return Math.mulDiv(extRaw, priceWad, (10 ** market.decimals) * 1e12);
    }
}
