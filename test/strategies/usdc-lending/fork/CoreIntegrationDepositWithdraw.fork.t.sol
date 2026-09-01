// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ===========================================================================
// CoreIntegrationDepositWithdraw.fork.t.sol
// ---------------------------------------------------------------------------
// End-to-end fork test. Deploys the USDC lending strategy with the REAL deploy
// script, ADDS IT TO THE REAL, ALREADY-DEPLOYED core system on Arbitrum One
// (allowlist -> register in the real StrategyRouter), then drives full
// deposit -> deploy-to-strategy -> withdraw cycles through the REAL CoreVault
// for BOTH withdrawal structures the vault exposes:
//
//   * "normal"  -- EpochedQueueModule.requestInstantWithdrawal(): burns shares
//                  and pays assets in the SAME transaction when the exit is
//                  within the per-epoch cap and past the lock period. Falls
//                  back to an epoch claim otherwise.
//   * "epoched" -- requestEpochWithdrawal -> closeCurrentEpoch -> fundEpoch
//                  (fundEpoch pulls the liquidity deficit back OUT of the
//                  strategy via router.planRedeem/executeRedeemBatch) ->
//                  claimEpochAssets / batchClaimEpochAssets.
//
// The CoreVault is a fully-queued-withdrawal protocol: ERC-4626
// withdraw()/redeem() always revert AsyncWithdrawalRequired, so every exit
// goes through the queue module. Both queue entry points, plus
// deployToStrategies() and realizeForReserveAndOps(), are ROLE_PUBLIC on the
// live vault -- no privileged prank is needed for the user flow, only for the
// one-time "add strategy to core" step (StrategyRouter owner), a re-poke of
// the strategy's external-TVL cache after the allowlist timelock warp
// (strategy admin, still the throwaway deployer pre-seal), and clearing any
// pause flag the fork inherits from live state (CoreVault owner).
//
// The deployed core ABI (verified against the live fork on 2026-09-01) is the
// EpochedQueueModule / strategy-allowlist generation -- NEWER than this repo's
// pinned lib/multyr-core (v1.0.0). All core interfaces below are therefore
// declared LOCALLY and nothing is imported from lib/multyr-core: a lib bump
// cannot silently change what this test asserts, and the test does not depend
// on the pinned lib being in sync with mainnet.
//
// Real, verified-on-chain core (chainId 42161):
//   CoreVault              0x685Ec439Fc62736934FF6A74301B50173E34446b
//   StrategyRouter         0x003BF0faD6b644536c14dcbF822b9fE1A3626b74
//   StrategyHealthRegistry 0x2bF1C86af4267C068B3c928538F7AA82219cf1D4
//   BufferManager          0x4560B3E16B335358dA6bF14ec8f9B9A5D07413a1
//   Guardian               0x7407E68a5553E948eed862f19fc6B292eb48d677
//
// RPC: ARBITRUM_RPC_URL -- the whole suite skips gracefully when absent
//      (CI without secrets), matching the other fork suites in this directory.
//
// Run:
//   ARBITRUM_RPC_URL=<rpc> forge test \
//     --match-path "test/strategies/usdc-lending/fork/CoreIntegrationDepositWithdraw.fork.t.sol" -vvv
// ===========================================================================

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployUsdcLendingStrategy} from "../../../../script/DeployUsdcLendingStrategy.s.sol";
import {
    UsdcMultiLendingVault
} from "../../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";

// --- Local minimal ABIs for the deployed core (see header note) -------------

interface ICoreVaultLike {
    function asset() external view returns (address);
    function owner() external view returns (address);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function paused() external view returns (bool);
    function pausedDeposits() external view returns (bool);
    function pausedInstantWithdrawal() external view returns (bool);
    function pausedQueuedRequest() external view returns (bool);
    function pausedEpochCloseFund() external view returns (bool);
    function pausedFundedClaim() external view returns (bool);
    function unpauseAll() external;
}

interface IQueueLike {
    function requestInstantWithdrawal(uint256 shares)
        external
        returns (bool settledImmediately, uint256 epochId, uint256 claimId);
    function requestEpochWithdrawal(uint256 shares)
        external
        returns (uint256 epochId, uint256 claimId);
    function closeCurrentEpoch() external;
    function canCloseCurrentEpoch() external view returns (bool);
    function fundEpoch(uint256 epochId) external;
    function claimEpochAssets(uint256 epochId, uint256 claimId) external returns (uint256 assets);
    function batchClaimEpochAssets(uint256 epochId, uint256[] calldata claimIds)
        external
        returns (uint256 totalAssets);
    function currentEpochId() external view returns (uint256);
    function totalEscrowedShares() external view returns (uint256);
    function epochDeficit(uint256 epochId) external view returns (uint256);
}

interface ILiquidityOpsLike {
    function deployToStrategies(uint256 maxAmount) external;
    function realizeForReserveAndOps(uint256 maxAmount) external;
    function realizeForQueue(uint256 target) external;
}

interface IRouterAdminLike {
    function owner() external view returns (address);
    function strategyAllowlist(address) external view returns (bool);
    function strategyAllowlistDelay() external view returns (uint256);
    function proposeStrategyAllowlist(address strat) external returns (uint256 eta);
    function executeStrategyAllowlist(address strat) external;
    function register(address strat, uint16 priority, uint16 weightBps) external;
    function setMaxStrategyBps(address strategy, uint16 maxBps) external;
    function setLossCapPerStrategy(address strategy, uint16 capBps) external;
}

contract CoreIntegrationDepositWithdraw_Fork_Test is Test {
    // --- Real deployed core (Arbitrum One) --------------------------------
    address constant CORE_VAULT = 0x685Ec439Fc62736934FF6A74301B50173E34446b;
    address constant STRATEGY_ROUTER = 0x003BF0faD6b644536c14dcbF822b9fE1A3626b74;
    address constant HEALTH_REGISTRY = 0x2bF1C86af4267C068B3c928538F7AA82219cf1D4;
    address constant BUFFER_MANAGER = 0x4560B3E16B335358dA6bF14ec8f9B9A5D07413a1;
    address constant GUARDIAN = 0x7407E68a5553E948eed862f19fc6B292eb48d677;

    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    // PriceOracleMiddleware (from the deployment manifest). The router's
    // checkOracleFreshness guard on executeRedeemBatch reads this; the multi-day
    // warp used to mature the withdrawal epoch pushes the live Chainlink USDC
    // feed past its 24h staleness bound, so _closeAndFundEpoch() pins a fresh
    // quote here right before the redeem.
    address constant PRICE_ORACLE = 0x0EB0B79654B7c762FE66Dad64a3e5740ffFFB2ce;

    // Throwaway test-only deployer -- NOT the real DEPLOYER_PRIVATE_KEY. The
    // deploy script grants it strategy DEFAULT_ADMIN_ROLE (rootTimelock arg ==
    // deployer), which this test uses only to re-poke the TVL cache.
    uint256 constant TEST_DEPLOYER_PK = 0xA11CE5EED;

    // Warp to clear a deposit lock period and to roll the withdrawal-cap epoch.
    uint256 constant LOCK_WARP = 31 days;

    // --- State wired per test (Foundry re-runs setUp() for each test) -----
    bool internal ready;
    UsdcMultiLendingVault internal strategy;
    ICoreVaultLike internal vault;
    IQueueLike internal queue;
    ILiquidityOpsLike internal liqOps;
    IRouterAdminLike internal router;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    // ====================================================================
    //                              SETUP
    // ====================================================================

    function setUp() public {
        string memory rpc = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            emit log("ARBITRUM_RPC_URL not set - skipping CoreIntegrationDepositWithdraw fork suite");
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        require(block.chainid == 42161, "not Arbitrum One");
        require(CORE_VAULT.code.length > 0, "CoreVault has no code on this fork");
        require(STRATEGY_ROUTER.code.length > 0, "StrategyRouter has no code on this fork");

        vault = ICoreVaultLike(CORE_VAULT);
        queue = IQueueLike(CORE_VAULT);
        liqOps = ILiquidityOpsLike(CORE_VAULT);
        router = IRouterAdminLike(STRATEGY_ROUTER);
        require(vault.asset() == USDC, "core vault asset is not USDC");

        _deployStrategy();
        _addStrategyToCore(); // allowlist timelock warp happens here
        _repokeStrategyTVL(); // refresh the external-TVL cache post-warp
        _clearPauseFlags();

        ready = true;
    }

    /// @dev Runs the REAL DeployUsdcLendingStrategy script against the REAL core
    ///      (7 adapters + bootstrap + Phase 2.6 TVL/liquidity poke).
    function _deployStrategy() internal {
        address dep = vm.addr(TEST_DEPLOYER_PK);
        vm.deal(dep, 10 ether);
        deal(USDC, dep, 1_000_000); // 1 USDC -- covers the 0.001 USDC Euler Permit2 dust

        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(TEST_DEPLOYER_PK));
        vm.setEnv("VAULT_ADDRESS", vm.toString(CORE_VAULT));
        vm.setEnv("STRATEGY_ROUTER_ADDRESS", vm.toString(STRATEGY_ROUTER));
        vm.setEnv("BUFFER_MANAGER_ADDRESS", vm.toString(BUFFER_MANAGER));
        vm.setEnv("HEALTH_REGISTRY_ADDRESS", vm.toString(HEALTH_REGISTRY));
        vm.setEnv("GUARDIAN_ADDRESS", vm.toString(GUARDIAN));
        vm.setEnv("STRATEGY_OUTPUT_JSON", "broadcast/fork-core-integration-addresses.json");

        DeployUsdcLendingStrategy script = new DeployUsdcLendingStrategy();
        DeployUsdcLendingStrategy.DeploymentResult memory result = script.run();
        strategy = result.strategy;

        assertEq(strategy.adapterCount(), 7, "all 7 adapters registered");
        assertFalse(strategy.paused(), "strategy not paused post-deploy");
        assertEq(strategy.asset(), USDC, "strategy asset is USDC");
        console2.log("[setup] strategy deployed:", address(strategy));
    }

    /// @dev The one governance step: allowlist (timelock) + register the
    ///      strategy in the real StrategyRouter, as its owner.
    function _addStrategyToCore() internal {
        address rOwner = router.owner();
        vm.startPrank(rOwner);
        if (!router.strategyAllowlist(address(strategy))) {
            router.proposeStrategyAllowlist(address(strategy));
            vm.warp(block.timestamp + router.strategyAllowlistDelay() + 1);
            router.executeStrategyAllowlist(address(strategy));
        }
        router.register(address(strategy), 100, 10_000);
        // Cap the strategy at 50% of vault TVL: keeps a large hot buffer so
        // queue settlement needs only a bounded strategy redeem (7-adapter
        // planRedeem is gas-heavy on a fork), while still exercising the
        // "pull from strategy" path.
        router.setMaxStrategyBps(address(strategy), 5_000);
        // Max loss cap (5%) for the test: real ERC-4626 vault-share redemptions
        // (Morpho/Euler/Fluid) can realise a few bps of rounding/slippage on a
        // large pull, and a tight cap would make executeRedeemBatch bail.
        router.setLossCapPerStrategy(address(strategy), 500);
        vm.stopPrank();

        assertTrue(router.strategyAllowlist(address(strategy)), "strategy allowlisted");
        console2.log("[setup] strategy registered in router; owner:", rOwner);
    }

    /// @dev The allowlist warp (~2 days) exceeds the strategy's external-TVL
    ///      staleness bound, which would make every adapter ineligible for
    ///      allocation. Refresh it, exactly as the deploy script's Phase 2.6
    ///      does (the throwaway deployer still holds strategy DEFAULT_ADMIN_ROLE
    ///      pre-seal).
    function _repokeStrategyTVL() internal {
        address dep = vm.addr(TEST_DEPLOYER_PK);
        bytes32 keeperRole = strategy.KEEPER_ROLE();
        vm.prank(dep);
        strategy.grantRole(keeperRole, address(this));

        (bool okTvl,) = address(strategy).call(abi.encodeWithSignature("pokeExternalTVL()"));
        (bool okLiq,) = address(strategy)
            .call(
                abi.encodeWithSignature(
                    "pokeLiquidityBatch(uint256,uint256)", uint256(0), uint256(10)
                )
            );
        require(okTvl && okLiq, "post-warp re-poke failed");

        vm.prank(dep);
        strategy.revokeRole(keeperRole, address(this));
    }

    /// @dev The fork inherits whatever pause flags live state has. Clear them.
    function _clearPauseFlags() internal {
        bool anyPaused = vault.paused() || vault.pausedDeposits() || vault.pausedInstantWithdrawal()
            || vault.pausedQueuedRequest() || vault.pausedEpochCloseFund()
            || vault.pausedFundedClaim();
        if (anyPaused) {
            vm.prank(vault.owner());
            vault.unpauseAll();
        }
        assertFalse(vault.paused(), "vault unpaused for the test");
    }

    // ====================================================================
    //                             HELPERS
    // ====================================================================

    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        deal(USDC, who, assets);
        uint256 before = vault.balanceOf(who);
        vm.startPrank(who);
        IERC20(USDC).approve(CORE_VAULT, assets);
        vault.deposit(assets, who);
        vm.stopPrank();
        shares = vault.balanceOf(who) - before;
        assertGt(shares, 0, "deposit minted shares");
    }

    /// @dev Push idle vault capital into the registered strategy. ROLE_PUBLIC.
    function _deployIdleToStrategy() internal returns (uint256 movedIntoStrategy) {
        uint256 before = strategy.totalAssets();
        liqOps.deployToStrategies(type(uint256).max);
        movedIntoStrategy = strategy.totalAssets() - before;
    }

    /// @dev Pin a fresh USDC quote on the PriceOracleMiddleware. The multi-day
    ///      warp used to mature the withdrawal epoch pushes the live Chainlink
    ///      feed past its 24h staleness bound, which reverts the router's
    ///      checkOracleFreshness guard on executeRedeemBatch. Call AFTER the
    ///      last warp -- the mock is static, so a later warp re-stales it.
    function _freshenOracle() internal {
        vm.mockCall(
            PRICE_ORACLE,
            abi.encodeWithSignature("getQuote(address)", USDC),
            abi.encode(uint256(1e18), uint8(8), uint48(block.timestamp), true)
        );
    }

    /// @dev Warp until the current epoch matures, close it (locks PPS), then
    ///      cover the locked-pps liability: realizeForQueue() pulls hot -> warm
    ///      -> strategy redeem, fundEpoch() marks the epoch once hot covers it.
    ///      Both are bounded per call (planRedeem walks the adapters), so loop;
    ///      the cap keeps a genuine throughput shortfall an assertion failure
    ///      rather than an out-of-gas.
    function _closeAndFundEpoch(uint256 epochId) internal {
        uint256 guard;
        while (!queue.canCloseCurrentEpoch()) {
            vm.warp(block.timestamp + 7 days);
            require(++guard < 40, "epoch never matured");
        }
        _freshenOracle();
        queue.closeCurrentEpoch();

        for (uint256 i = 0; i < 8 && queue.epochDeficit(epochId) != 0; ++i) {
            uint256 d = queue.epochDeficit(epochId);
            try liqOps.realizeForQueue(d) {} catch {}
            try queue.fundEpoch(epochId) {} catch {}
            if (queue.epochDeficit(epochId) == d) break; // no progress
        }
        assertEq(queue.epochDeficit(epochId), 0, "epoch fully funded to zero deficit");
    }

    // ====================================================================
    //          TEST 1 -- "normal" structure: instant deposit + withdraw
    // ====================================================================

    function test_normal_structure_instant_deposit_and_withdraw() public {
        if (!ready) return;

        // -- S1: deposit --------------------------------------------------
        uint256 depositAmt = 500_000e6;
        uint256 aliceShares = _deposit(alice, depositAmt);
        uint256 pps0 = vault.convertToAssets(1e18);
        console2.log("[normal] deposited USDC / alice shares:", depositAmt, aliceShares);

        // -- S2: deploy idle capital into the strategy -----------------
        uint256 moved = _deployIdleToStrategy();
        assertGt(moved, 0, "deployToStrategies moved capital into the strategy");
        assertGt(strategy.totalAssets(), 0, "strategy now holds a position");
        console2.log("[normal] capital deployed to strategy:", moved);

        // -- S3: clear the lock period, restock hot liquidity ----------
        vm.warp(block.timestamp + LOCK_WARP);
        uint256 exitShares = aliceShares / 20; // ~5% -- small, in-cap
        uint256 expectAssets = vault.convertToAssets(exitShares);
        liqOps.realizeForReserveAndOps(expectAssets * 3);

        // -- S4: instant withdraw -- assets must arrive in the same tx -
        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        (bool settled,,) = queue.requestInstantWithdrawal(exitShares);

        assertTrue(settled, "in-cap instant withdrawal settles immediately (no epoch claim)");

        uint256 received = IERC20(USDC).balanceOf(alice) - usdcBefore;
        assertGt(received, 0, "assets paid in the same tx");
        assertEq(aliceShares - vault.balanceOf(alice), exitShares, "exactly exitShares burned");
        // Instant exits carry an immediate-exit penalty; payout is at-or-below
        // the mark-to-PPS value, within a few percent.
        assertLe(received, expectAssets, "instant exit never overpays vs PPS value");
        assertGe(
            received,
            expectAssets * 96 / 100,
            "instant exit payout within ~4% of PPS value (exit penalty + spread)"
        );
        assertEq(queue.totalEscrowedShares(), 0, "nothing landed in the queue");
        assertApproxEqRel(
            vault.convertToAssets(1e18), pps0, 0.01e18, "PPS roughly unchanged across the cycle"
        );
        console2.log("[normal] instant withdrawal received:", received);

        // -- S5: alice's remaining position stays fully redeemable -----
        assertApproxEqRel(
            vault.convertToAssets(vault.balanceOf(alice)),
            depositAmt - expectAssets,
            0.01e18,
            "residual shares still mark to ~the un-withdrawn principal"
        );
    }

    // ====================================================================
    //     TEST 2 -- "epoched" structure: request -> close -> fund -> claim
    // ====================================================================

    function test_epoched_structure_full_lifecycle_pulls_from_strategy() public {
        if (!ready) return;

        // -- S1: two depositors ---------------------------------------
        uint256 aliceAssets = 150_000e6;
        uint256 bobAssets = 100_000e6;
        uint256 aliceShares = _deposit(alice, aliceAssets);
        uint256 bobShares = _deposit(bob, bobAssets);
        uint256 pps0 = vault.convertToAssets(1e18);

        // -- S2: deploy the bulk of it into the strategy ------------
        uint256 moved = _deployIdleToStrategy();
        assertGt(moved, 0, "capital deployed to strategy");
        console2.log("[epoched] strategy holds after deploy:", strategy.totalAssets());

        // -- S3: alice queues a full epoch exit -------------------
        // Exceeds the hot buffer, so settling it requires redeeming part of
        // the position back out of the strategy.
        vm.prank(alice);
        (uint256 epochId, uint256 claimId) = queue.requestEpochWithdrawal(aliceShares);

        assertEq(vault.balanceOf(alice), 0, "alice's shares moved into escrow");
        assertGe(queue.totalEscrowedShares(), aliceShares, "escrow tracks alice's shares");
        console2.log("[epoched] queued epoch / claim:", epochId, claimId);

        // -- S4/S5: close + fund the epoch -- covering the liability
        //          requires redeeming the deficit OUT of the strategy.
        uint256 stratBeforeFund = strategy.totalAssets();
        _closeAndFundEpoch(epochId);
        assertLt(
            strategy.totalAssets(),
            stratBeforeFund,
            "epoch settlement redeemed the deficit out of the strategy"
        );
        console2.log(
            "[epoched] strategy redeemed for queue:", stratBeforeFund - strategy.totalAssets()
        );

        // -- S6: alice claims -------------------------------------
        uint256 balBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = queue.claimEpochAssets(epochId, claimId);

        assertEq(
            IERC20(USDC).balanceOf(alice) - balBefore, claimed, "claim transferred `claimed` USDC"
        );
        assertApproxEqRel(
            claimed, aliceAssets, 0.015e18, "alice recovered ~her principal (<=1.5% fees/slippage)"
        );
        assertEq(queue.totalEscrowedShares(), 0, "escrow drained after the only claim settles");
        console2.log("[epoched] alice claimed:", claimed);

        // -- S7: bob still whole, exits the same way via batch claim
        assertEq(vault.balanceOf(bob), bobShares, "bob's position untouched by alice's exit");
        assertApproxEqRel(
            vault.convertToAssets(1e18), pps0, 0.02e18, "PPS within 2% across the full cycle"
        );

        vm.prank(bob);
        (uint256 epochId2, uint256 claimId2) = queue.requestEpochWithdrawal(bobShares);
        assertGe(epochId2, epochId, "bob's claim is in this epoch or a later one");

        _closeAndFundEpoch(epochId2);

        uint256[] memory ids = new uint256[](1);
        ids[0] = claimId2;
        uint256 bobBefore = IERC20(USDC).balanceOf(bob);
        vm.prank(bob);
        uint256 bobTotal = queue.batchClaimEpochAssets(epochId2, ids);

        assertEq(IERC20(USDC).balanceOf(bob) - bobBefore, bobTotal, "batch claim paid bob");
        assertApproxEqRel(bobTotal, bobAssets, 0.02e18, "bob recovered ~his principal");
        assertEq(queue.totalEscrowedShares(), 0, "escrow drained after both users exit");
    }

    // ====================================================================
    //   TEST 3 -- value conservation across a mixed deposit/withdraw cycle
    // ====================================================================

    function test_value_conservation_mixed_cycle() public {
        if (!ready) return;

        uint256 tvlBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();

        uint256 aShares = _deposit(alice, 150_000e6);
        _deposit(bob, 150_000e6);
        _deployIdleToStrategy();

        // alice: instant (normal) exit of a small slice
        vm.warp(block.timestamp + LOCK_WARP);
        uint256 aExit = aShares / 10;
        liqOps.realizeForReserveAndOps(vault.convertToAssets(aExit) * 3);
        vm.prank(alice);
        queue.requestInstantWithdrawal(aExit);

        // bob: full epoched exit
        uint256 bShares = vault.balanceOf(bob);
        vm.prank(bob);
        (uint256 ep, uint256 cl) = queue.requestEpochWithdrawal(bShares);
        _closeAndFundEpoch(ep);
        vm.prank(bob);
        queue.claimEpochAssets(ep, cl);

        // Net: alice holds 90% of her shares, bob fully out.
        assertEq(vault.balanceOf(alice), aShares - aExit, "alice residual shares");
        assertEq(vault.balanceOf(bob), 0, "bob fully exited");

        uint256 tvlAfter = vault.totalAssets();
        uint256 supplyAfter = vault.totalSupply();
        assertGt(supplyAfter, supplyBefore, "net new shares from alice's residual position");
        assertGt(tvlAfter, tvlBefore, "vault TVL grew by alice's retained deposit");

        // Outstanding shares still redeem to ~reported TVL (no value leak).
        uint256 redeemableAll = vault.convertToAssets(supplyAfter);
        assertApproxEqRel(
            redeemableAll, tvlAfter, 0.01e18, "outstanding shares redeem to ~TVL (<=1% drift)"
        );
        console2.log(
            "[conservation] tvlAfter / supplyAfter / redeemableAll:",
            tvlAfter,
            supplyAfter,
            redeemableAll
        );
    }
}
