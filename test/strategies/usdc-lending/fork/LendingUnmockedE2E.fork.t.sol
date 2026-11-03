// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
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
abstract contract LendingUnmockedE2EBase is Test {
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

    function _afterAdapterConfigured() internal virtual {}

    function _new(string memory artifact, bytes memory args) internal returns (address a) {
        a = deployCode(artifact, args);
        assertLe(a.code.length, 24576, "production component must satisfy EIP-170");
        keep.push(a);
    }

    function _bind(bytes4 selector, address module) internal {
        uint8 role = registry.getRequiredRole(selector);
        require(role <= 4, "canonical-selector-required");
        core.setModule(selector, module, role);
    }

    function _rpc() internal view returns (string memory) {
        return chain == 42161
            ? vm.envOr("LENDING_RPC_ARBITRUM", string("https://arbitrum-one.public.blastapi.io"))
            : vm.envOr("LENDING_RPC_BASE", string("https://base-mainnet.public.blastapi.io"));
    }

    function _scenario(uint256 chainId, bool weth) internal {
        chain = chainId;
        user = vm.addr(0xB0B); // Deterministic test actor, never a workstation key.
        initialBlock = chain == 42161 ? 514000000 : 52500000;
        setupBlock = chain == 42161 ? 514700000 : 52590000;
        vm.createSelectFork(_rpc(), initialBlock);
        rpcForkBlock = initialBlock;
        market = LendingAssetConfig.get(chain, weth);
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
        _afterAdapterConfigured();
        _fundFromRealHolder(weth);
        uint256 price = oracle.getQuoteFresh(market.asset).price;
        uint256 amount = Math.mulDiv(200e18, unit, price, Math.Rounding.Up);
        uint256 seed = Math.mulDiv(1e18, unit, price, Math.Rounding.Up);
        IERC20Metadata asset = IERC20Metadata(market.asset);
        assertGe(asset.balanceOf(address(this)), amount + seed);
        asset.approve(address(core), seed);
        AdminModule(address(core)).seedDeadDeposit(seed);
        core.unpauseAll();
        core.freezeRouting();
        AdminModule(address(core)).freezeParams();
        asset.transfer(user, amount);
        assertFalse(strategy.hasRole(bytes32(0), user));
        assertFalse(strategy.hasRole(keccak256("CORE_ROLE"), user));
        assertTrue(core.owner() != user && router.owner() != user);
        vm.startPrank(user);
        asset.approve(address(core), amount);
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
        _roll(setupBlock + (chain == 42161 ? 1500 : 180));
        buffer.refreshWarmNav();
        _poke();
        Scoring(address(strategy)).deployIdle();
        assertLe(strategy.idleCash(), 2, "ramp must finish before testing recalls");
        uint256 originalInvestment = adapter.totalAssets();
        _observe();

        // Observe real new price rounds rather than rewriting timestamps or quotes.
        _roll(setupBlock + (chain == 42161 ? 400000 : 50000));
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
        _roll(initialBlock + (chain == 42161 ? 3500000 : 450000));
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
        _roll(initialBlock + (chain == 42161 ? 6000000 : 800000));
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
        address usdc = LendingAssetConfig.get(chain, false).asset;
        address weth = LendingAssetConfig.get(chain, true).asset;
        oracle.setOracleFeed(weth, chain == 42161 ? 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612 : 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70, 1 days);
        oracle.setOracleFeed(usdc, chain == 42161 ? 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3 : 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B, 1 days);
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
        // on both chains with a parameterized asset; no Base deployment parity
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

    function _fundFromRealHolder(bool weth) internal {
        assertEq(HOLDER.code.length, 0, "funding account must be an actual EOA");
        address usdc = LendingAssetConfig.get(chain, false).asset;
        address wrapped = LendingAssetConfig.get(chain, true).asset;
        address source = chain == 42161 ? wrapped : usdc;
        uint256 funding = chain == 42161 ? 0.5e18 : 1000e6;
        uint256 before = IERC20Metadata(source).balanceOf(address(this));
        uint256 holderBefore = IERC20Metadata(source).balanceOf(HOLDER);
        uint256 supplyBefore = IERC20Metadata(source).totalSupply();
        assertGe(holderBefore, funding);
        vm.prank(HOLDER);
        assertTrue(IERC20Metadata(source).transfer(address(this), funding));
        assertEq(IERC20Metadata(source).balanceOf(address(this)) - before, funding);
        uint256 holderAfter = IERC20Metadata(source).balanceOf(HOLDER);
        assertEq(holderAfter, holderBefore - funding);
        assertEq(IERC20Metadata(source).totalSupply(), supplyBefore, "funding must not mint synthetic tokens");
        emit RealFunding(chain, source, HOLDER, holderBefore, funding, holderAfter);
        if ((chain == 42161 && !weth) || (chain == 8453 && weth)) {
            uint256 input = chain == 42161 ? 0.2e18 : 700e6;
            uint256 usdWad = Math.mulDiv(input, oracle.getQuoteFresh(source).price, 10 ** IERC20Metadata(source).decimals());
            uint256 expected = Math.mulDiv(usdWad, 10 ** market.decimals, oracle.getQuoteFresh(market.asset).price);
            address uni = chain == 42161 ? 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45 : 0x2626664c2603336E57B271c5C0b26F421741e481;
            IERC20Metadata(source).approve(uni, input);
            uint256 output = ISwapRouterV3(uni).exactInput(ISwapRouterV3.ExactInputParams(
                abi.encodePacked(source, uint24(500), market.asset), address(this), input, expected * 9900 / 10000));
            assertGe(output, expected * 9900 / 10000);
            emit RealFundingConversion(chain, source, market.asset, input, expected, output);
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

contract LendingUnmockedE2ETest is LendingUnmockedE2EBase {
    function test_unmockedArbitrumUsdc() public { _scenario(42161, false); }
    function test_unmockedArbitrumWeth() public { _scenario(42161, true); }
    function test_unmockedBaseUsdc() public { _scenario(8453, false); }
    function test_unmockedBaseWeth() public { _scenario(8453, true); }
}
