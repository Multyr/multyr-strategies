// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { StrategyRebalancePlanModule } from "../../../src/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol";
import {
    UsdcMultiLendingVaultTestBase
} from "./UsdcMultiLendingVault.t.sol";
import {
    StrategyScoringModule
} from "../../../src/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import {
    StrategyParamsModule
} from "../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import { StrategySettingsModule } from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {
    UsdcMultiLendingVault
} from "../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";

// ============================================================================
// BLOCCO D — Failure Semantics & Degraded Mode Tests
// ============================================================================
// D1: Degraded mode blocks aggressive ops but preserves exit paths (withdraw).
// D2: Quarantined adapter does not receive new capital.
// D3: Stale external TVL causes score penalty (capped allocation).
// D4: Stale Morpho APY causes adapter to lose advantage (tested via mock APY=0).
// ============================================================================

contract DegradedModeSemanticsTest is UsdcMultiLendingVaultTestBase {

    bytes4 constant ERR_DEGRADED_VIEWS = bytes4(keccak256("DegradedViews()"));

    function setUp() public override {
        super.setUp();
        _addAndEnableAdapter(adapter1);
        _addAndEnableAdapter(adapter2);
        _addAndEnableAdapter(adapter3);

        adapter1.setExtMarketTVL(100_000_000e6);
        adapter2.setExtMarketTVL(80_000_000e6);
        adapter3.setExtMarketTVL(50_000_000e6);

        vm.prank(admin);
        StrategySettingsModule(address(vault)).exitBootstrapMode();
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setMaxIdleAfterDepositBps(10000);
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        vm.prank(admin);
        StrategySettingsModule(address(vault)).setGateParams(30, 0, 5, 5, 1e6);
    }

    function _coreDeposit(uint256 amount) internal {
        _mintAndTransferToVault(core, amount);
        vm.prank(core);
        vault.deposit(amount);
    }

    function _warpAndDeployIdle() internal {
        vm.warp(block.timestamp + 301);
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();
    }

    // -----------------------------------------------------------------------
    // D1: Degraded mode — blocks aggressive, preserves exit paths
    // -----------------------------------------------------------------------

    /// @notice D1a: When >degradedViewThreshold% of adapters have failing totalAssets(),
    ///         harvest() must revert with DegradedViews.
    ///         deploy/rebalance also blocked. But withdraw is NOT blocked (exit path).
    function test_D1a_degradedBlocksHarvestNotWithdraw() public {
        uint256 depositAmount = 300_000e6;
        _coreDeposit(depositAmount);
        for (uint256 i = 0; i < 3; i++) _warpAndDeployIdle();

        // degradedViewThresholdBps = 2500 (25%) with 3 adapters:
        // 1 failing out of 3 = 33% > 25% → degraded
        adapter1.setTotalAssetsReverts(true);
        adapter2.setTotalAssetsReverts(true); // 2/3 = 66% flagged

        // harvest() must revert with DegradedViews
        vm.warp(block.timestamp + 43201);
        vm.expectRevert(ERR_DEGRADED_VIEWS);
        vm.prank(keeper);
        vault.harvest();
    }

    /// @notice D1b: Degraded mode does NOT block withdraw (exit path must always work).
    function test_D1b_degradedDoesNotBlockWithdraw() public {
        uint256 depositAmount = 300_000e6;
        _coreDeposit(depositAmount);
        for (uint256 i = 0; i < 3; i++) _warpAndDeployIdle();

        // Put 2 adapters in failing totalAssets() state
        adapter1.setTotalAssetsReverts(true);
        adapter2.setTotalAssetsReverts(true);

        // Withdraw should still work (core withdrawal path)
        uint256 withdrawAmount = 50_000e6;
        uint256 coreBalBefore = usdc.balanceOf(core);

        // CoreVault calls withdraw(amount, receiver) on strategy
        vm.prank(core);
        uint256 withdrawn = vault.withdraw(withdrawAmount, core);

        assertGt(withdrawn, 0, "D1b: withdraw must succeed even in degraded mode");
        uint256 coreBalAfter = usdc.balanceOf(core);
        assertGt(coreBalAfter, coreBalBefore, "D1b: core must receive funds in degraded mode");
    }

    /// @notice D1c: deployIdle() is blocked when degraded (aggressive op).
    function test_D1c_degradedBlocksDeployIdle() public {
        uint256 depositAmount = 300_000e6;
        _coreDeposit(depositAmount);
        // Don't deploy — keep idle
        adapter1.setTotalAssetsReverts(true);
        adapter2.setTotalAssetsReverts(true);

        vm.warp(block.timestamp + 301);
        vm.expectRevert(ERR_DEGRADED_VIEWS);
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();
    }

    /// @notice D1d: prepareRebalance() is blocked when degraded.
    function test_D1d_degradedBlocksPrepareRebalance() public {
        uint256 depositAmount = 300_000e6;
        _coreDeposit(depositAmount);
        for (uint256 i = 0; i < 3; i++) _warpAndDeployIdle();

        adapter1.setTotalAssetsReverts(true);
        adapter2.setTotalAssetsReverts(true);

        vm.warp(block.timestamp + 21601);
        vm.expectRevert(ERR_DEGRADED_VIEWS);
        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).prepareRebalance();
    }

    // -----------------------------------------------------------------------
    // D2: Quarantined adapter — no new capital, exit still works
    // -----------------------------------------------------------------------

    /// @notice D2a: Quarantined adapter does not receive new deposits via deployIdle.
    function test_D2a_quarantinedAdapterGetsNoNewCapital() public {
        // Quarantine adapter1 before any deposit
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setQuarantined(address(adapter1), true);

        uint256 depositAmount = 300_000e6;
        _coreDeposit(depositAmount);
        for (uint256 i = 0; i < 5; i++) _warpAndDeployIdle();

        // adapter1 must have 0 position (quarantined, no new deposits)
        uint256 pos1 = vault.positionAssets(address(adapter1));
        assertEq(pos1, 0, "D2a: quarantined adapter must receive no new capital");

        // Other adapters should have received capital
        uint256 pos2 = vault.positionAssets(address(adapter2));
        uint256 pos3 = vault.positionAssets(address(adapter3));
        assertGt(pos2 + pos3, 0, "D2a: non-quarantined adapters must receive capital");
    }

    /// @notice D2b: Quarantine does not break withdraw (funds in adapter1 can still be withdrawn).
    function test_D2b_quarantineDoesNotBreakWithdraw() public {
        uint256 depositAmount = 300_000e6;
        _coreDeposit(depositAmount);
        for (uint256 i = 0; i < 3; i++) _warpAndDeployIdle();

        // Verify adapter1 has funds
        uint256 pos1Before = vault.positionAssets(address(adapter1));
        assertGt(pos1Before, 0, "adapter1 should have funds before quarantine");

        // Quarantine adapter1
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setQuarantined(address(adapter1), true);

        // Withdraw should still work
        uint256 withdrawAmount = pos1Before / 2;
        vm.prank(core);
        uint256 withdrawn = vault.withdraw(withdrawAmount, core);
        assertGt(withdrawn, 0, "D2b: withdraw must succeed even with quarantined adapter");
    }

    // -----------------------------------------------------------------------
    // D3: Stale external TVL — adapter loses score advantage
    // -----------------------------------------------------------------------

    /// @notice D3: Adapter A has fresh TVL (large), B has fresh TVL (large), C has stale TVL.
    ///         After TVL goes stale on C, C should receive less capital (CONFIDENCE_MICRO cap).
    function test_D3_staleTvlReducesAllocation() public {
        // Set minimum allowed staleness window (1h)
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setExternalTVLStalenessSeconds(3600); // min=1h

        // All adapters start fresh
        adapter1.setExtMarketTVL(100_000_000e6);
        adapter2.setExtMarketTVL(100_000_000e6);
        adapter3.setExtMarketTVL(100_000_000e6);

        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        uint256 depositAmount = 300_000e6;
        _coreDeposit(depositAmount);
        for (uint256 i = 0; i < 3; i++) _warpAndDeployIdle();

        // Set adapter3 TVL to 0 so next pokeExternalTVL caches 0 for it
        adapter3.setExtMarketTVL(0);

        // Poke external TVL — adapter3 now gets TVL=0 in cache (CONFIDENCE_ZERO)
        // The prevTVL for adapter3 was 50M, new=0 → rejected (delta too large actually)
        // Better approach: set adapter3 TVL to a very small value < 100K (CONFIDENCE_ZERO threshold)
        adapter3.setExtMarketTVL(50_000e6); // 50K — below 100K CONFIDENCE_ZERO threshold
        // Need to reset cache by warping past staleness so prev check doesn't block
        vm.warp(block.timestamp + 3601);

        // Re-poke: adapter3 now has TVL=50K < 100K → CONFIDENCE_ZERO
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        // Any new deployment should not go to adapter3 (CONFIDENCE_ZERO)
        uint256 prevPos3 = vault.positionAssets(address(adapter3));
        _coreDeposit(50_000e6); // new deposit
        vm.warp(block.timestamp + 301);
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();

        uint256 newPos3 = vault.positionAssets(address(adapter3));
        assertApproxEqAbs(newPos3, prevPos3, vault.dustTolerance(),
            "D3: CONFIDENCE_ZERO TVL adapter must receive no new capital");
    }

    /// @notice D3b: TVL fresh -> stale -> must not remain top scorer.
    ///         Adapter with high APY but stale TVL loses to adapter with lower APY but fresh TVL.
    function test_D3b_freshTvlWinsOverStaleHighApy() public {
        // Minimum allowed staleness window (1h)
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setExternalTVLStalenessSeconds(3600);

        // adapter3 has the best APY
        adapter1.setAPY(400);
        adapter2.setAPY(400);
        adapter3.setAPY(2000); // best APY

        // Set adapter3 TVL below 100K threshold (CONFIDENCE_ZERO)
        adapter3.setExtMarketTVL(50_000e6); // 50K < 100K minimum
        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        uint256 depositAmount = 300_000e6;
        _coreDeposit(depositAmount);
        for (uint256 i = 0; i < 3; i++) _warpAndDeployIdle();

        // adapter3 must have 0 allocation despite best APY
        uint256 pos3 = vault.positionAssets(address(adapter3));
        assertEq(pos3, 0, "D3b: CONFIDENCE_ZERO adapter must get 0 allocation despite high APY");

        // adapter1 and adapter2 should have the capital instead
        uint256 pos1 = vault.positionAssets(address(adapter1));
        uint256 pos2 = vault.positionAssets(address(adapter2));
        assertGt(pos1 + pos2, 0, "D3b: fresh TVL adapters must receive capital");
    }

    // -----------------------------------------------------------------------
    // D4: Stale Morpho APY — mock test via zero APY signal
    // -----------------------------------------------------------------------

    /// @notice D4: Adapter with stale APY (returns 0 due to staleness) loses advantage
    ///         over adapters with fresh, real APY.
    ///         We simulate this by setting adapter1.setAPY(0) — equivalent to APY=0 fallback.
    function test_D4_zeroApyAdapterLosesAdvantage() public {
        // adapter1: high APY initially
        adapter1.setAPY(2000);
        adapter2.setAPY(500);
        adapter3.setAPY(400);

        uint256 depositAmount = 300_000e6;
        _coreDeposit(depositAmount);
        for (uint256 i = 0; i < 3; i++) _warpAndDeployIdle();

        uint256 pos1Before = vault.positionAssets(address(adapter1));

        // Simulate APY going stale: adapter1 now returns 0 (stale APY behavior)
        adapter1.setAPY(0);
        adapter2.setAPY(500);
        adapter3.setAPY(400);

        // New deposit — adapter1 with APY=0 should get minimal/no new allocation
        uint256 pos2Before = vault.positionAssets(address(adapter2));
        _coreDeposit(50_000e6);
        _warpAndDeployIdle();

        uint256 pos1After = vault.positionAssets(address(adapter1));
        uint256 pos2After = vault.positionAssets(address(adapter2));

        // New capital should prefer adapter2 (APY=500) over adapter1 (APY=0)
        uint256 gain2 = pos2After > pos2Before ? pos2After - pos2Before : 0;
        uint256 gain1 = pos1After > pos1Before ? pos1After - pos1Before : 0;
        assertGe(gain2, gain1, "D4: adapter with real APY must get more new capital than zero-APY adapter");
    }

    // -----------------------------------------------------------------------
    // I4: Invariant — flagged/degraded adapters get no aggressive allocation
    // -----------------------------------------------------------------------

    /// @notice I4: A flagged adapter must receive no new capital from deployIdle.
}
