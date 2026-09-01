// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ===========================================================================
// CoreIntegrationDepositWithdraw.fork.t.sol
// ---------------------------------------------------------------------------
// End-to-end fork test. Deploys the USDC lending strategy with the REAL deploy
// script, ADDS IT TO THE REAL, ALREADY-DEPLOYED core system on Arbitrum One
// (register in the real StrategyRouter), then drives full
// deposit -> deploy-to-strategy -> withdraw cycles through the REAL CoreVault
// for BOTH withdrawal structures the vault exposes:
//
//   * "normal"  -- QueueModule.requestClaim(immediate = true): burns shares and
//                  pays assets in the SAME transaction when the exit is within
//                  the epoch cap and the vault holds enough hot liquidity.
//                  Falls back to the queue otherwise.
//   * "epoched" -- QueueModule.requestClaim(immediate = false): escrows the
//                  shares into the queue; a later, permissionless
//                  processQueuedRedemptions() / settleFeesAndProcessQueue()
//                  settles them at the epoch PPS after the lock period.
//                  realizeForQueue() first pulls the liquidity deficit back
//                  OUT of the strategy. endEpochCrystallize() rolls the fee
//                  epoch.
//
// The CoreVault is a queued-withdrawal protocol: ERC-4626 withdraw()/redeem()
// route to the queue module, never to a synchronous transfer. Every queue and
// liquidity-ops selector is ROLE_PUBLIC on the live vault, so the user flow
// needs no privileged prank -- only the one-time "add strategy to core" step
// (StrategyRouter owner) and clearing any pause flag the fork inherits from
// live state (CoreVault owner).
//
// VERSION NOTE: interfaces below are declared locally and target the core ABI
// this repo builds against -- lib/multyr-core @ v1.0.0 (commit 617dddc,
// QueueModule / requestClaim). If the contracts actually live at the addresses
// below have been upgraded past v1.0.0, this suite will fail loudly on a real
// RPC run and the interfaces need to be re-pointed. Nothing here is imported
// from lib/multyr-core, so a lib bump does not silently change the assumptions.
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
//   ARBITRUM_RPC_URL=<rpc> forge test --match-contract CoreIntegrationDepositWithdraw -vvv
// ===========================================================================

import { Test, console2 } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { DeployUsdcLendingStrategy } from "../../../../script/DeployUsdcLendingStrategy.s.sol";
import { UsdcMultiLendingVault } from "../../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";

// --- Local minimal ABIs for the deployed core (see VERSION NOTE) ------------

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
    function pausedWithdrawals() external view returns (bool);
    function unpauseAll() external;
    function deficitForQueue(uint256 maxClaims) external view returns (uint256);
}

interface IQueueLike {
    function requestClaim(bool immediate, uint256 shares) external;
    function processQueuedRedemptions(uint256 maxClaims) external;
    function settleFeesAndProcessQueue(uint256 maxClaims) external;
    function endEpochCrystallize() external;
    function queueLength() external view returns (uint256);
    function pendingShares() external view returns (uint256);
    function nextClaimId() external view returns (uint256);
}

interface ILiquidityOpsLike {
    function canDeploy() external view returns (bool);
    function deployToStrategies(uint256 maxAmount) external;
    function realizeForQueue(uint256 target) external;
    function realizeForReserveAndOps(uint256 maxAmount) external;
}

interface IRouterAdminLike {
    function owner() external view returns (address);
    function register(address strat, uint16 priority, uint16 weightBps) external;
    function setMaxStrategyBps(address strategy, uint16 maxBps) external;
    function setLossCapPerStrategy(address strategy, uint16 capBps) external;
}

contract CoreIntegrationDepositWithdraw_Fork_Test is Test {
    // --- Real deployed core (Arbitrum One) ---------------------------------
    address constant CORE_VAULT      = 0x685Ec439Fc62736934FF6A74301B50173E34446b;
    address constant STRATEGY_ROUTER = 0x003BF0faD6b644536c14dcbF822b9fE1A3626b74;
    address constant HEALTH_REGISTRY = 0x2bF1C86af4267C068B3c928538F7AA82219cf1D4;
    address constant BUFFER_MANAGER  = 0x4560B3E16B335358dA6bF14ec8f9B9A5D07413a1;
    address constant GUARDIAN        = 0x7407E68a5553E948eed862f19fc6B292eb48d677;

    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    // Throwaway test-only deployer -- NOT the real DEPLOYER_PRIVATE_KEY.
    uint256 constant TEST_DEPLOYER_PK = 0xA11CE5EED;

    // Generous headroom to clear any deposit lock period / roll the fee epoch.
    uint256 constant LOCK_WARP = 21 days;

    // --- State wired per test (Foundry re-runs setUp() for each test) ------
    bool internal ready;
    UsdcMultiLendingVault internal strategy;
    ICoreVaultLike internal vault;
    IQueueLike internal queue;
    ILiquidityOpsLike internal liqOps;
    IRouterAdminLike internal router;

    address internal alice = makeAddr("alice");
    address internal bob   = makeAddr("bob");

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

        vault  = ICoreVaultLike(CORE_VAULT);
        queue  = IQueueLike(CORE_VAULT);
        liqOps = ILiquidityOpsLike(CORE_VAULT);
        router = IRouterAdminLike(STRATEGY_ROUTER);

        require(vault.asset() == USDC, "core vault asset is not USDC");

        _deployStrategy();
        _addStrategyToCore();
        _clearPauseFlags();

        ready = true;
    }

    /// @dev Runs the REAL DeployUsdcLendingStrategy script against the REAL core
    ///      system (7 adapters + bootstrap + Phase 2.6 TVL/liquidity poke).
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
        // Explicit output path -- an ambient .env with STRATEGY_OUTPUT_JSON=
        // (blank) would otherwise make vm.writeJson target "", which reverts.
        vm.setEnv("STRATEGY_OUTPUT_JSON", "broadcast/fork-core-integration-addresses.json");

        DeployUsdcLendingStrategy script = new DeployUsdcLendingStrategy();
        DeployUsdcLendingStrategy.DeploymentResult memory result = script.run();
        strategy = result.strategy;

        assertEq(strategy.adapterCount(), 7, "all 7 adapters registered");
        assertFalse(strategy.paused(), "strategy not paused post-deploy");
        assertEq(strategy.asset(), USDC, "strategy asset is USDC");
        console2.log("[setup] strategy deployed:", address(strategy));
    }

    /// @dev The one governance step: register the strategy in the real
    ///      StrategyRouter as its owner. v1.0.0 register() has no allowlist gate.
    function _addStrategyToCore() internal {
        address rOwner = router.owner();
        vm.startPrank(rOwner);
        router.register(address(strategy), 100, 10_000);
        router.setMaxStrategyBps(address(strategy), 10_000);
        router.setLossCapPerStrategy(address(strategy), 50);
        vm.stopPrank();
        console2.log("[setup] strategy registered in router; owner:", rOwner);
    }

    /// @dev The fork inherits whatever pause flags live state has. Clear them so
    ///      the user flow is exercised end to end.
    function _clearPauseFlags() internal {
        if (vault.paused() || vault.pausedDeposits() || vault.pausedWithdrawals()) {
            vm.prank(vault.owner());
            vault.unpauseAll();
        }
        assertFalse(vault.paused(), "vault unpaused for the test");
        assertFalse(vault.pausedDeposits(), "deposits unpaused");
        assertFalse(vault.pausedWithdrawals(), "withdrawals unpaused");
    }

    // ====================================================================
    //                             HELPERS
    // ====================================================================

    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        deal(USDC, who, assets);
        uint256 sharesBefore = vault.balanceOf(who);
        vm.startPrank(who);
        IERC20(USDC).approve(CORE_VAULT, assets);
        vault.deposit(assets, who);
        vm.stopPrank();
        shares = vault.balanceOf(who) - sharesBefore;
        assertGt(shares, 0, "deposit minted shares");
    }

    /// @dev Push idle vault capital into the registered strategy. ROLE_PUBLIC.
    function _deployIdleToStrategy() internal returns (uint256 movedIntoStrategy) {
        uint256 before = strategy.totalAssets();
        liqOps.deployToStrategies(type(uint256).max);
        movedIntoStrategy = strategy.totalAssets() - before;
    }

    // ====================================================================
    //          TEST 1 -- "normal" structure: instant deposit + withdraw
    // ====================================================================

    function test_normal_structure_instant_deposit_and_withdraw() public {
        if (!ready) return;

        // -- S1: deposit ------------------------------------------------
        uint256 depositAmt = 750_000e6;
        uint256 aliceShares = _deposit(alice, depositAmt);
        uint256 pps0 = vault.convertToAssets(1e18);
        console2.log("[normal] deposited USDC / alice shares:", depositAmt, aliceShares);

        // -- S2: deploy idle capital into the strategy ----------------
        uint256 moved = _deployIdleToStrategy();
        assertGt(moved, 0, "deployToStrategies moved capital into the strategy");
        assertGt(strategy.totalAssets(), 0, "strategy now holds a position");
        console2.log("[normal] capital deployed to strategy:", moved);

        // -- S3: clear the lock period, restock hot liquidity ---------
        vm.warp(block.timestamp + LOCK_WARP);
        uint256 exitShares = aliceShares / 20;                 // ~5% -- small, in-cap
        uint256 expectAssets = vault.convertToAssets(exitShares);
        liqOps.realizeForReserveAndOps(expectAssets * 3);

        // -- S4: instant withdraw -- assets must arrive in the same tx -
        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);
        uint256 sharesBefore = vault.balanceOf(alice);

        vm.prank(alice);
        queue.requestClaim(true, exitShares);

        uint256 received = IERC20(USDC).balanceOf(alice) - usdcBefore;
        uint256 burned = sharesBefore - vault.balanceOf(alice);

        assertGt(received, 0, "instant claim paid assets in the same tx (did not fall back to queue)");
        assertEq(burned, exitShares, "exactly exitShares left alice's balance");
        assertApproxEqRel(received, expectAssets, 0.01e18, "payout ~ PPS value (<=1% fees/slippage)");
        assertEq(queue.pendingShares(), 0, "nothing was queued");
        assertApproxEqRel(vault.convertToAssets(1e18), pps0, 0.01e18, "PPS roughly unchanged across the cycle");
        console2.log("[normal] instant withdrawal received:", received);

        // -- S5: a second instant exit still works -------------------
        liqOps.realizeForReserveAndOps(expectAssets * 3);
        uint256 usdc2 = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        queue.requestClaim(true, exitShares);
        assertGt(IERC20(USDC).balanceOf(alice) - usdc2, 0, "second instant withdrawal also settles immediately");
        assertEq(vault.balanceOf(alice), aliceShares - 2 * exitShares, "second exit burned exitShares");
    }

    // ====================================================================
    //     TEST 2 -- "epoched" structure: request -> realize -> settle
    // ====================================================================

    function test_epoched_structure_queue_settlement_pulls_from_strategy() public {
        if (!ready) return;

        // -- S1: two depositors --------------------------------------
        uint256 aliceShares = _deposit(alice, 600_000e6);
        uint256 bobShares   = _deposit(bob,   400_000e6);
        uint256 pps0 = vault.convertToAssets(1e18);

        // -- S2: deploy the bulk of it into the strategy ------------
        uint256 moved = _deployIdleToStrategy();
        assertGt(moved, 0, "capital deployed to strategy");
        console2.log("[epoched] strategy holds after deploy:", strategy.totalAssets());

        // -- S3: alice queues a LARGE standard (non-instant) exit ---
        uint256 queueLenBefore = queue.queueLength();
        vm.prank(alice);
        queue.requestClaim(false, aliceShares);

        assertEq(vault.balanceOf(alice), 0, "alice's shares moved into queue escrow");
        assertEq(queue.queueLength(), queueLenBefore + 1, "one claim added to the queue");
        assertGe(queue.pendingShares(), aliceShares, "queue tracks alice's pending shares");
        console2.log("[epoched] queued; pendingShares:", queue.pendingShares());

        // -- S4: realize the deficit -- must pull OUT of the strategy
        vm.warp(block.timestamp + LOCK_WARP); // clear lock period
        uint256 stratBefore = strategy.totalAssets();
        uint256 target = vault.deficitForQueue(10);
        if (target == 0) target = 600_000e6;
        liqOps.realizeForQueue(target);

        assertLt(strategy.totalAssets(), stratBefore, "realizeForQueue redeemed the deficit out of the strategy");
        console2.log("[epoched] pulled from strategy:", stratBefore - strategy.totalAssets());

        // -- S5: settle the queue -- permissionless -----------------
        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);
        queue.processQueuedRedemptions(10);

        uint256 received = IERC20(USDC).balanceOf(alice) - usdcBefore;
        assertGt(received, 0, "queued claim settled and paid alice");
        assertApproxEqRel(received, 600_000e6, 0.015e18, "alice recovered ~her principal (<=1.5% fees/slippage)");
        assertEq(queue.pendingShares(), 0, "queue drained after settlement");
        assertEq(vault.balanceOf(alice), 0, "alice's escrowed shares were burned on settlement");
        console2.log("[epoched] alice settled for:", received);

        // -- S6: roll the fee epoch --------------------------------
        vm.warp(block.timestamp + 8 days);
        queue.endEpochCrystallize(); // must not revert

        // -- S7: bob still whole, and can exit the same way --------
        assertEq(vault.balanceOf(bob), bobShares, "bob's position untouched by alice's exit");
        assertApproxEqRel(vault.convertToAssets(1e18), pps0, 0.02e18, "PPS within 2% across the full cycle");

        vm.prank(bob);
        queue.requestClaim(false, bobShares);
        vm.warp(block.timestamp + LOCK_WARP);
        uint256 t2 = vault.deficitForQueue(10);
        if (t2 == 0) t2 = 400_000e6;
        liqOps.realizeForQueue(t2);
        uint256 bobBefore = IERC20(USDC).balanceOf(bob);
        queue.settleFeesAndProcessQueue(10);
        assertApproxEqRel(
            IERC20(USDC).balanceOf(bob) - bobBefore,
            400_000e6,
            0.02e18,
            "bob recovered ~his principal via settleFeesAndProcessQueue"
        );
        assertEq(queue.pendingShares(), 0, "queue empty after both users exit");
    }

    // ====================================================================
    //   TEST 3 -- value conservation across a mixed deposit/withdraw cycle
    // ====================================================================

    function test_value_conservation_mixed_cycle() public {
        if (!ready) return;

        uint256 tvlBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();

        uint256 aShares = _deposit(alice, 500_000e6);
        _deposit(bob, 500_000e6);
        _deployIdleToStrategy();

        // alice: instant (normal) exit of a small slice
        vm.warp(block.timestamp + LOCK_WARP);
        uint256 aExit = aShares / 10;
        liqOps.realizeForReserveAndOps(vault.convertToAssets(aExit) * 3);
        vm.prank(alice);
        queue.requestClaim(true, aExit);

        // bob: full queued exit
        uint256 bShares = vault.balanceOf(bob);
        vm.prank(bob);
        queue.requestClaim(false, bShares);
        vm.warp(block.timestamp + LOCK_WARP);
        uint256 target = vault.deficitForQueue(10);
        if (target == 0) target = 500_000e6;
        liqOps.realizeForQueue(target);
        queue.processQueuedRedemptions(10);

        // Net: alice holds 90% of her shares, bob fully out.
        assertEq(vault.balanceOf(alice), aShares - aExit, "alice residual shares");
        assertEq(vault.balanceOf(bob), 0, "bob fully exited");

        uint256 tvlAfter = vault.totalAssets();
        uint256 supplyAfter = vault.totalSupply();
        assertGt(supplyAfter, supplyBefore, "net new shares from alice's residual position");
        assertGt(tvlAfter, tvlBefore, "vault TVL grew by alice's retained deposit");

        // Outstanding shares still redeem to ~reported TVL (no value leak).
        uint256 redeemableAll = vault.convertToAssets(supplyAfter);
        assertApproxEqRel(redeemableAll, tvlAfter, 0.01e18, "outstanding shares redeem to ~TVL (<=1% drift)");
        console2.log("[conservation] tvlAfter / supplyAfter / redeemableAll:", tvlAfter, supplyAfter, redeemableAll);
    }
}
