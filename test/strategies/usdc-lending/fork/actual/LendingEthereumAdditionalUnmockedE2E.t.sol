// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CoreVault} from "@multyr-core/core/CoreVault.sol";
import {GlobalConfig} from "@multyr-core/core/config/GlobalConfig.sol";
import {PriceOracleMiddleware} from "@multyr-core/core/modules/PriceOracleMiddleware.sol";
import {BufferManager} from "@multyr-core/core/modules/BufferManager.sol";
import {IBufferManager} from "@multyr-core/interfaces/IBufferManager.sol";
import {SelectorRegistry} from "@multyr-core/core/libraries/SelectorRegistry.sol";
import {AdminModule} from "@multyr-core/core/modules/AdminModule.sol";
import {ERC4626Module} from "@multyr-core/core/modules/ERC4626Module.sol";
import {LiquidityOpsModule} from "@multyr-core/core/modules/LiquidityOpsModule.sol";
import {EpochedQueueModule} from "@multyr-core/core/modules/EpochedQueueModule.sol";
import {StrategyRouter} from "@multyr-core/core/modules/StrategyRouter.sol";
import {UsdcMultiLendingVault as Strategy} from "@multyr-strategies/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
import {StrategySettingsModule as Settings} from "@multyr-strategies/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {StrategyParamsModule as StrategyParams} from "@multyr-strategies/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import {StrategyScoringModule as Scoring} from "@multyr-strategies/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import {AaveV3USDCAdapter} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol";
import {LendingAssetConfig} from "@multyr-strategies/strategies/usdc-lending/config/LendingAssetConfig.sol";
import {ISwapRouterV3} from "@multyr-strategies/strategies/usdc-lending/swap/RewardSwapHelper.sol";

/// @dev Production contracts and real feeds/markets. No mock/etch/store/deal/warp.
/// Historical rolling updates canonical feeds; persistence retains scenario-owned
/// deployments and the real market state modified by scenario transactions.
abstract contract LendingEthereumAdditionalUnmockedE2EBase is Test {
    using SafeERC20 for IERC20Metadata;
    address constant HOLDER = 0xF977814e90dA44bFA03b6295A0616a897441aceC;
    address user;
    address[] keep;
    CoreVault core;
    GlobalConfig config;
    PriceOracleMiddleware oracle;
    BufferManager buffer;
    StrategyRouter router;
    Strategy strategy;
    AaveV3USDCAdapter adapter;
    SelectorRegistry registry;
    LendingAssetConfig.Market market;
    uint256 chain;
    uint256 initialBlock;
    uint256 setupBlock;
    uint256 rpcForkBlock;

    event RealScenario(uint256 chainId, address asset, uint256 rpcForkBlock, uint256 evmBlockNumber,
        uint256 timestamp, uint256 priceWad, uint48 oracleUpdatedAt,
        uint256 coreNav, uint256 invested, uint256 idle);
    event RealFunding(uint256 chainId, address token, address holder,
        uint256 holderBefore, uint256 transferred, uint256 holderAfter);
    event RealFundingConversion(uint256 chainId, address input, address output,
        uint256 amountIn, uint256 oracleExpected, uint256 amountReceived);

    function _new(string memory artifact, bytes memory args) internal virtual returns (address a) {
        a = deployCode(artifact, args);
        assertLe(a.code.length, 24576, "production component must satisfy EIP-170");
        keep.push(a);
    }

    function _bind(bytes4 selector, address module) internal {
        uint8 role = registry.getRequiredRole(selector);
        require(role <= 4, "canonical-selector-required");
        core.setModule(selector, module, role);
    }

    function _rpc() internal view virtual returns (string memory) {
        return "https://eth-mainnet.public.blastapi.io";
    }

    function _scenario(uint256 chainId, bool weth) internal {
        chain = chainId;
        user = vm.addr(0xB0B); // Deterministic test actor, never a workstation key.
        initialBlock = 26150000;
        setupBlock = 26165000;
        vm.createSelectFork(_rpc(), initialBlock);
        rpcForkBlock = initialBlock;
        market = LendingAssetConfig.Market(1, weth ? 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8 : 0xdAC17F958D2ee523a2206206994597C13D831ec7, 6, 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2, weth ? 0x0C0d01AbF3e6aDfcA0989eBbA9d6e85dD58EaB1E : 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a);
        _configureProductionCore();
        strategy = _candidate();
        uint256 eta = router.proposeStrategyAllowlist(address(strategy));
        vm.makePersistent(keep);
        _roll(setupBlock);
        assertGe(block.timestamp, eta);
        buffer.refreshWarmNav();
        _observe();
        router.executeStrategyAllowlist(address(strategy));
        router.register(address(strategy), 0, 10000);
        router.setMaxStrategyBps(address(strategy), 10000);
        router.setLossCapPerStrategy(address(strategy), 50);

        uint256 unit = 10 ** market.decimals;
        adapter = AaveV3USDCAdapter(payable(_new("AaveV3USDCmarket.sol:AaveV3USDCAdapter", bytes(""))));
        adapter.initialize(market.asset, market.aavePool, market.aToken,
            address(this), address(strategy), 10000 * unit);
        Settings(address(strategy)).whitelistAdapter(address(adapter), true);
        strategy.addAdapter(address(adapter));
        strategy.toggleAdapter(address(adapter), true);
        Settings(address(strategy)).setAdapterDepositMode(address(adapter), false);
        _poke();
        _fundFromRealHolder(weth);
        uint256 price = oracle.getQuoteFresh(market.asset).price;
        uint256 amount = Math.mulDiv(200e18, unit, price, Math.Rounding.Up);
        uint256 seed = Math.mulDiv(1e18, unit, price, Math.Rounding.Up);
        IERC20Metadata asset = IERC20Metadata(market.asset);
        assertGe(asset.balanceOf(address(this)), amount + seed);
        asset.forceApprove(address(core), seed);
        AdminModule(address(core)).seedDeadDeposit(seed);
        core.unpauseAll();
        core.freezeRouting();
        AdminModule(address(core)).freezeParams();
        asset.safeTransfer(user, amount);
        assertFalse(strategy.hasRole(bytes32(0), user));
        assertFalse(strategy.hasRole(keccak256("CORE_ROLE"), user));
        assertTrue(core.owner() != user && router.owner() != user);
        vm.startPrank(user);
        asset.forceApprove(address(core), amount);
        uint256 shares = core.deposit(amount, user);
        vm.stopPrank();
        assertGt(shares, 0);
        LiquidityOpsModule(address(core)).deployToStrategies(type(uint256).max);
        Scoring(address(strategy)).deployIdle();
        assertGt(adapter.totalAssets(), 0, "real capital must enter Aave");

        // Keep only actual state affected by this counterfactual portfolio.
        // Feeds remain canonical historical chain data at every subsequent roll.
        vm.makePersistent(keep);
        vm.makePersistent(market.asset);
        vm.makePersistent(market.aavePool);
        vm.makePersistent(market.aToken);
        _persistDebtTokens();
        _roll(setupBlock + 40);
        buffer.refreshWarmNav();
        _poke();
        Scoring(address(strategy)).deployIdle();
        assertLe(strategy.idleCash(), 2, "ramp must finish before testing recalls");
        uint256 originalInvestment = adapter.totalAssets();
        _observe();

        this.exerciseEpochs(shares, originalInvestment);
    }

    function exerciseEpochs(uint256 shares, uint256 originalInvestment) external {
        require(msg.sender == address(this), "self-only scenario step");
        IERC20Metadata asset = IERC20Metadata(market.asset);
        // Observe real new price rounds rather than rewriting timestamps or quotes.
        _roll(setupBlock + 8000);
        buffer.refreshWarmNav();
        _poke();
        strategy.harvest();
        EpochedQueueModule queue = EpochedQueueModule(address(core));
        // Keep the actual 10% epoch cap and published buffer configuration.
        // The first 9.5% claim consumes most hot cash; the next epoch must recall
        // invested funds. No cap/reserve threshold is relaxed to manufacture this.
        vm.prank(user);
        (uint256 firstEpoch, uint256 firstClaim) = queue.requestEpochWithdrawal(shares * 950 / 10000);
        uint256 firstOwed = queue.epochClaim(firstEpoch, firstClaim).assetsOwed;
        _roll(initialBlock + 100000);
        buffer.refreshWarmNav();
        _poke();
        strategy.harvest();
        queue.closeCurrentEpoch();
        queue.fundEpoch(firstEpoch);
        assertEq(queue.epochDeficit(firstEpoch), 0);
        uint256 beforeFirstClaim = asset.balanceOf(user);
        vm.prank(user);
        queue.claimEpochAssets(firstEpoch, firstClaim);
        assertEq(asset.balanceOf(user) - beforeFirstClaim, firstOwed);
        vm.prank(user);
        (uint256 epoch, uint256 claim) = queue.requestEpochWithdrawal(shares / 20);
        uint256 owed = queue.epochClaim(epoch, claim).assetsOwed;
        assertGt(owed, asset.balanceOf(address(core)), "exit must require invested capital");
        _roll(initialBlock + 160000);
        buffer.refreshWarmNav();
        _poke();
        strategy.harvest();
        _observe();
        uint256 investedBefore = adapter.totalAssets();
        assertGt(investedBefore, originalInvestment, "real Aave interest must accrue over the historical interval");
        queue.closeCurrentEpoch();
        for (uint256 i; i < 4 && queue.epochDeficit(epoch) > 0; ++i) {
            uint256 beforeDeficit = queue.epochDeficit(epoch);
            LiquidityOpsModule(address(core)).realizeForQueue(beforeDeficit);
            queue.fundEpoch(epoch);
            assertLt(queue.epochDeficit(epoch), beforeDeficit, "real funding must progress");
        }
        assertEq(queue.epochDeficit(epoch), 0);
        uint256 beforeClaim = asset.balanceOf(user);
        vm.prank(user);
        queue.claimEpochAssets(epoch, claim);
        assertEq(asset.balanceOf(user) - beforeClaim, owed);
        assertEq(core.balanceOf(user), shares - shares * 950 / 10000 - shares / 20);
        assertLt(adapter.totalAssets(), investedBefore, "Aave assets must actually be recalled");
        uint256 coreBeforeExit = asset.balanceOf(address(core));
        uint256 recalled = router.withdrawAllToCore(address(strategy));
        assertGt(recalled, 0);
        assertEq(asset.balanceOf(address(core)) - coreBeforeExit, recalled);
        assertLe(strategy.totalAssets(), 2);
        assertLe(adapter.totalAssets(), 2);
        assertTrue(core.isRoutingFrozen());
        _observe();
    }

    function _configureProductionCore() internal {
        config = GlobalConfig(_new("GlobalConfig.sol:GlobalConfig",
            abi.encode(address(this), uint16(0), uint16(0), uint16(0), uint64(1 days), uint8(10), uint16(100), uint256(300), uint256(1 days))));
        oracle = PriceOracleMiddleware(_new("PriceOracleMiddleware.sol:PriceOracleMiddleware", abi.encode(address(this))));
        oracle.setOracleFeed(market.asset, _assetFeed(), 1 days);
        config.setAssetOracleConfig(market.asset, address(oracle), 1 days);
        core = CoreVault(payable(_new("CoreVault.sol:CoreVault",
            abi.encode(IERC20Metadata(market.asset), "Real data portfolio", "rDATA", address(this), address(this), address(config)))));
        registry = SelectorRegistry(_new("SelectorRegistry.sol:SelectorRegistry", bytes("")));
        core.setSelectorRegistry(address(registry));
        address admin = _new("AdminModule.sol:AdminModule", bytes(""));
        address erc = _new("ERC4626Module.sol:ERC4626Module", bytes(""));
        address queue = _new("EpochedQueueModule.sol:EpochedQueueModule", bytes(""));
        address liq = _new("LiquidityOpsModule.sol:LiquidityOpsModule", bytes(""));
        _bind(AdminModule.setBufferManager.selector, admin);
        _bind(AdminModule.setRouter.selector, admin);
        _bind(AdminModule.setInitialFees.selector, admin);
        _bind(AdminModule.setInitialPerfParams.selector, admin);
        _bind(AdminModule.seedDeadDeposit.selector, admin);
        _bind(AdminModule.freezeParams.selector, admin);
        _bind(bytes4(keccak256("deposit(uint256,address)")), erc);
        _bind(bytes4(keccak256("mint(uint256,address)")), erc);
        _bind(bytes4(keccak256("withdraw(uint256,address,address)")), erc);
        _bind(bytes4(keccak256("redeem(uint256,address,address)")), erc);
        _bind(EpochedQueueModule.requestEpochWithdrawal.selector, queue);
        _bind(EpochedQueueModule.closeCurrentEpoch.selector, queue);
        _bind(EpochedQueueModule.fundEpoch.selector, queue);
        _bind(EpochedQueueModule.claimEpochAssets.selector, queue);
        _bind(EpochedQueueModule.epochClaim.selector, queue);
        _bind(EpochedQueueModule.epochDeficit.selector, queue);
        _bind(LiquidityOpsModule.deployToStrategies.selector, liq);
        _bind(LiquidityOpsModule.realizeForQueue.selector, liq);
        // Published shadow authorizes only external ERC4626; self-calls use
        // the frozen Core built-in bypass, not extra module-map permissions.
        core.authorizeModule(erc, true);
        // Published Arbitrum shadow BPS at block520094008, deliberately reused
        // on Ethereum with USDT/PYUSD; no Ethereum deployment parity
        // is claimed. No reserve/cap guard is lowered to force a green exit.
        IBufferManager.BufferConfig memory b = IBufferManager.BufferConfig(400, 200, 600, 800, 400, 50, market.asset, address(0), 0, false);
        buffer = BufferManager(_new("BufferManager.sol:BufferManager", abi.encode(address(this), address(core), b)));
        router = StrategyRouter(_new("StrategyRouter.sol:StrategyRouter", abi.encode(address(this), address(core), address(config))));
        AdminModule(address(core)).setBufferManager(address(buffer));
        AdminModule(address(core)).setRouter(address(router));
        AdminModule(address(core)).setInitialFees(0, 0, 0, 0, address(this));
        AdminModule(address(core)).setInitialPerfParams(2e17, 7 days);
        uint256 unit = 10 ** market.decimals;
        uint256 price = oracle.getQuoteFresh(market.asset).price;
        config.setVaultDepositLimits(address(core), Math.mulDiv(10_000_000e18, unit, price),
            Math.mulDiv(500_000e18, unit, price), Math.mulDiv(100e18, unit, price, Math.Rounding.Up));
    }

    function _assetFeed() internal view virtual returns(address) {
        if(market.asset==0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)return 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
        return market.asset==0x6c3ea9036406852006290770BEdFcAbA0e23A0e8?0x8f1dF6D7F2db73eECE86a18b4381F4707b918FB1:0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    }

    function _candidate() internal returns (Strategy s) {
        address p = _new("StrategyParamsModule.sol:StrategyParamsModule", abi.encode(market.asset, address(core)));
        address o = _new("StrategyAdapterOpsModule.sol:StrategyAdapterOpsModule", abi.encode(market.asset, address(core), p, address(0), address(0)));
        address c = _new("StrategyScoringModule.sol:StrategyScoringModule", abi.encode(market.asset, address(core), p, address(0), o));
        address g = _new("StrategyRebalanceGateModule.sol:StrategyRebalanceGateModule", abi.encode(market.asset, address(core), p, c, o));
        Strategy.StrategyInitParams memory x;
        x.maxAdaptersPerAllocation=5; x.minAdaptersActive=1;
        x.wAPY=5000; x.wLiq=2000; x.wRisk=2000; x.wStability=1000;
        x.newAdapterRampBps=5000; x.minSecondsBetweenRebalances=86400;
        x.minSecondsBetweenHarvests=86400; x.minSecondsBetweenDeployIdle=300;
        x.harvestThresholdBps=100; x.stabilityEMAPeriod=7;
        x.maxIdleAfterDepositBps=10000; x.maxIdleBootstrapBps=10000;
        x.dustTolerance=1; x.externalTVLStalenessSeconds=1 days;
        x.gateHorizonDays=7; x.gasCostUSDC=1e6; x.degradedViewThresholdBps=2500;
        s=Strategy(payable(_new("UsdcLendingStrategy.sol:UsdcMultiLendingVault", abi.encode(market.asset,address(core),address(router),address(this),address(this),address(0),p,c,o,g,x))));
        s.setSettingsModule(_new("StrategySettingsModule.sol:StrategySettingsModule", abi.encode(market.asset,address(core))));
        s.setAllocCalcModule(_new("StrategyAllocCalcModule.sol:StrategyAllocCalcModule", abi.encode(market.asset,address(core))));
        s.setRebalancePlanModule(_new("StrategyRebalancePlanModule.sol:StrategyRebalancePlanModule", abi.encode(market.asset,address(core),p,c,o)));
        Settings(address(s)).setSafetyOverflowModule(_new("StrategySafetyOverflowModule.sol:StrategySafetyOverflowModule", abi.encode(market.asset,address(core),p,c,o)));
    }

    function _fundFromRealHolder(bool pyusd) internal {
        address holder = pyusd ? 0xAFBb1a7E9ddEf38D9bC4A220E702B18DAcaa2a62 : HOLDER;
        IERC20Metadata token = IERC20Metadata(market.asset);
        assertEq(holder.code.length, 0, "real EOA funding");
        uint256 funding = 1000e6;
        uint256 holderBefore = token.balanceOf(holder);
        uint256 beforeBalance = token.balanceOf(address(this));
        uint256 supply = token.totalSupply();
        assertGe(holderBefore, funding);
        vm.prank(holder);
        token.safeTransfer(address(this), funding);
        assertEq(token.balanceOf(address(this)) - beforeBalance, funding);
        assertEq(token.balanceOf(holder), holderBefore - funding);
        assertEq(token.totalSupply(), supply, "no synthetic funding");
        emit RealFunding(chain, market.asset, holder, holderBefore, funding, token.balanceOf(holder));
    }
    function _persistDebtTokens() internal {
        (bool ok, bytes memory data) = market.aavePool.staticcall(abi.encodeWithSignature("getReserveData(address)", market.asset));
        require(ok && data.length == 480, "published reserve layout");
        for (uint256 i=9; i<=10; ++i) {
            uint256 word;
            assembly ("memory-safe") { word := mload(add(add(data,32),mul(i,32))) }
            address debt = address(uint160(word));
            if (debt.code.length>0) vm.makePersistent(debt);
        }
    }
    function _poke() internal {
        StrategyParams(address(strategy)).pokeExternalTVL();
        StrategyParams(address(strategy)).pokeLiquidityBatch(0, 1);
    }

    function _roll(uint256 target) internal {
        vm.rollFork(target);
        rpcForkBlock = target;
    }

    function _observe() internal {
        // Production middleware calls the actual canonical Chainlink aggregator.
        uint256 price = oracle.getQuoteFresh(market.asset).price;
        uint48 ts = oracle.getQuoteFresh(market.asset).lastUpdate;
        assertGt(ts, 0); assertLe(ts, block.timestamp);
        // Arbitrum's EVM block.number is the L1 number, not its RPC L2 tag.
        emit RealScenario(chain, market.asset, rpcForkBlock, block.number, block.timestamp, price, ts,
            core.totalAssets(), address(adapter) == address(0) ? 0 : adapter.totalAssets(),
            address(strategy) == address(0) ? 0 : strategy.idleCash());
    }
}

contract LendingEthereumAdditionalUnmockedE2ETest is LendingEthereumAdditionalUnmockedE2EBase {
    function test_realEthereumUsdtProductionCoreLifecycle() public { _scenario(1, false); }
    function test_realEthereumPyusdProductionCoreLifecycle() public { _scenario(1, true); }
}
