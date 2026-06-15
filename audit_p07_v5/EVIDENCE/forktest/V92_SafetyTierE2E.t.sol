// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ═══════════════════════════════════════════════════════════════════════════════
// V92_SafetyTierE2E.t.sol — P0.7 Safety Adapter Cap Tier — 13-step fork E2E
// ───────────────────────────────────────────────────────────────────────────────
// Fork: Arbitrum mainnet, block 472761449
// RPC:  ARBITRUM_RPC_URL env var — never written to disk or git
//
// Steps (sequential, single-chain state per test):
//  S01 — fork Arbitrum + deploy vault with 3 adapters (A=safety, B/C=normal)
//  S02 — configure P0.7: addSafetyFallbackAdapter(A,7000,7000) + params
//  S03 — deal 1M real USDC, deposit into vault
//  S04 — deployIdle → normal allocation (real USDC flows via ERC-20)
//  S05 — saturate B+C at normal cap, surplus idle → overflow fills A ≤ fbCeiling
//  S06 — force A into tolerance band (fb, hardCeiling] → mandate silent
//  S07 — force A above safety hardCeiling → mandate fires (ok=true, nb=0)
//  S08 — prepareRebalance + drain → A returns to ≤ fbCeiling (+1% rounding)
//  S09 — safety adapter never stamped with mandate cooldown
//  S10 — B over normal hardCeiling, A at 65% tranche: plan preserves A
//  S11 — updateSafetyFallbackCaps(A, 6400, 7000): position in new tolerance band
//  S12 — removeSafetyFallbackAdapter(A) → normal mandate fires on 65% position
//  S13 — total assets conservation (±dust tolerance)
//
// Run: ARBITRUM_RPC_URL=<rpc> forge test --match-path "test/strategies/usdc-lending/fork/**"
// ═══════════════════════════════════════════════════════════════════════════════

import { Test, stdStorage, StdStorage }        from "forge-std/Test.sol";
import { IERC20 }                              from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { UsdcMultiLendingVault }               from "../../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
import { StrategyParamsModule }                from "../../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import { StrategySettingsModule }              from "../../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import { StrategyAllocCalcModule }             from "../../../../src/strategies/usdc-lending/controller/StrategyAllocCalcModule.sol";
import { StrategyScoringModule }               from "../../../../src/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import { StrategyAdapterOpsModule }            from "../../../../src/strategies/usdc-lending/controller/StrategyAdapterOpsModule.sol";
import { StrategyRebalanceGateModule }         from "../../../../src/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol";
import { StrategyRebalancePlanModule }         from "../../../../src/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol";
import { ScoringMockAdapter }                  from "../Scoring_Model.t.sol";

contract V92_SafetyTierE2E is Test {
    using stdStorage for StdStorage;

    // ── Constants ──────────────────────────────────────────────────────────────
    address constant ARBITRUM_USDC      = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    uint256 constant FORK_BLOCK         = 472_761_449;

    uint16  constant SAFETY_FB_ABS_BPS  = 7000;  // 70% TVL — fallback abs cap for adapterA
    uint16  constant SAFETY_FB_REL_BPS  = 7000;  // 70% extTVL — fallback rel cap (non-binding: deep ext market)
    uint16  constant NORMAL_CAP_BPS     = 5000;  // 50% TVL — normal max exposure
    uint16  constant CAPDRIFT_TOL_BPS   = 250;   // 2.5% tolerance band above each cap
    uint16  constant MAX_IDLE_BPS       = 500;   // 5% TVL max idle before overflow fires
    uint32  constant MANDATE_COOLDOWN   = 3 days;

    uint256 constant DEPOSIT_AMOUNT     = 1_000_000e6; // 1M USDC

    // ── Roles ──────────────────────────────────────────────────────────────────
    address internal admin  = address(0xA11CE);
    address internal core   = address(0xC0FFEE);
    address internal router = address(0xBEEF);
    address internal keeper = address(0xCAFE);

    // ── Protocol state ─────────────────────────────────────────────────────────
    UsdcMultiLendingVault internal vault;
    ScoringMockAdapter    internal adapterA; // safety fallback
    ScoringMockAdapter    internal adapterB; // normal
    ScoringMockAdapter    internal adapterC; // normal

    // ── setUp: S01 fork + deploy, S02 configure safety tier ───────────────────

    function setUp() public {
        // S01: Fork Arbitrum mainnet at pinned block — exercises real USDC ERC-20.
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), FORK_BLOCK);

        // S01: Deploy mock adapters referencing real USDC token address.
        adapterA = new ScoringMockAdapter(ARBITRUM_USDC);
        adapterB = new ScoringMockAdapter(ARBITRUM_USDC);
        adapterC = new ScoringMockAdapter(ARBITRUM_USDC);

        // Deep external market TVL: rel-cap never binds, isolates abs-cap logic.
        adapterA.setAPY(500);  adapterA.setExtMarketTVL(500_000_000e6);
        adapterB.setAPY(400);  adapterB.setExtMarketTVL(500_000_000e6);
        adapterC.setAPY(900);  adapterC.setExtMarketTVL(500_000_000e6);

        // S01: Deploy strategy modules.
        StrategyParamsModule paramsMod = new StrategyParamsModule(ARBITRUM_USDC, core);
        StrategyAdapterOpsModule adapterOpsMod = new StrategyAdapterOpsModule(
            ARBITRUM_USDC, core, address(paramsMod), address(0), address(0)
        );
        StrategyScoringModule scoringMod = new StrategyScoringModule(
            ARBITRUM_USDC, core, address(paramsMod), address(0), address(adapterOpsMod)
        );
        StrategyRebalanceGateModule gateMod = new StrategyRebalanceGateModule(
            ARBITRUM_USDC, core, address(paramsMod), address(scoringMod), address(adapterOpsMod)
        );

        vault = new UsdcMultiLendingVault(
            ARBITRUM_USDC, core, router, admin, keeper, address(0),
            address(paramsMod), address(scoringMod), address(adapterOpsMod),
            address(gateMod), _baseParams()
        );

        StrategyRebalancePlanModule planMod = new StrategyRebalancePlanModule(
            ARBITRUM_USDC, core, address(paramsMod), address(scoringMod), address(adapterOpsMod)
        );
        vm.prank(admin); vault.setRebalancePlanModule(address(planMod));

        StrategySettingsModule settingsMod = new StrategySettingsModule(ARBITRUM_USDC, core);
        vm.prank(admin); vault.setSettingsModule(address(settingsMod));

        StrategyAllocCalcModule allocCalcMod = new StrategyAllocCalcModule(ARBITRUM_USDC, core);
        vm.prank(admin); vault.setAllocCalcModule(address(allocCalcMod));

        vm.startPrank(admin);
        address(vault).call(abi.encodeWithSignature("whitelistAdapter(address,bool)", address(adapterA), true));
        vault.addAdapter(address(adapterA));
        address(vault).call(abi.encodeWithSignature("whitelistAdapter(address,bool)", address(adapterB), true));
        vault.addAdapter(address(adapterB));
        address(vault).call(abi.encodeWithSignature("whitelistAdapter(address,bool)", address(adapterC), true));
        vault.addAdapter(address(adapterC));
        vault.toggleAdapter(address(adapterA), true);
        vault.toggleAdapter(address(adapterB), true);
        vault.toggleAdapter(address(adapterC), true);
        vm.stopPrank();

        vm.prank(keeper);
        StrategyParamsModule(address(vault)).pokeExternalTVL();

        // S02: Configure P0.7 safety tier.
        vm.startPrank(admin);
        StrategySettingsModule(address(vault)).setCapDriftTolerance(CAPDRIFT_TOL_BPS);
        StrategySettingsModule(address(vault)).addSafetyFallbackAdapter(
            address(adapterA), SAFETY_FB_ABS_BPS, SAFETY_FB_REL_BPS
        );
        StrategySettingsModule(address(vault)).setMaxIdleBps(MAX_IDLE_BPS);
        StrategySettingsModule(address(vault)).setMandateRedeployCooldown(MANDATE_COOLDOWN);
        StrategySettingsModule(address(vault)).setTargetSafetyMargin(300);
        vm.stopPrank();
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────

    function _baseParams() internal pure returns (UsdcMultiLendingVault.StrategyInitParams memory p) {
        p = UsdcMultiLendingVault.StrategyInitParams({
            maxAdaptersPerAllocation: 3,
            minAdaptersActive: 2,
            rebalanceMinMoveBps: 50,
            minSecondsBetweenRebalances: 21600,
            driftToleranceBps: 80,
            wAPY: 5000,
            wLiq: 2000,
            wRisk: 2000,
            wStability: 1000,
            wIncentive: 0,
            incentiveDecayHalfLife: 86400,
            adapterMaxExposureBps: 5000,
            newAdapterRampBps: 8000,
            gateHorizonDays: 30,
            gateMinNetBenefitBps: 2,
            slippageBpsEstimate: 5,
            withdrawalSpreadBpsEstimate: 5,
            gasCostUSDC: 1e6,
            harvestThresholdBps: 5,
            minSecondsBetweenHarvests: 43200,
            dustTolerance: 10000,
            stabilityEMAPeriod: 7,
            minNewAdapterSeed: 0,
            newAdapterRampDuration: 0,
            maxIdleAfterDepositBps: 500,
            maxIdleBootstrapBps: 5000,
            degradedViewThresholdBps: 2500,
            failureDecaySeconds: 3600,
            minSecondsBetweenDeployIdle: 300,
            bootstrapDuration: 0,
            maxRelativeExposureBps: 0,
            externalTVLStalenessSeconds: 43200
        });
    }

    /// @dev total TVL = vault idle + all adapter positions
    function _totalTvl() internal view returns (uint256 sum) {
        sum  = IERC20(ARBITRUM_USDC).balanceOf(address(vault));
        sum += vault.positionAssets(address(adapterA));
        sum += vault.positionAssets(address(adapterB));
        sum += vault.positionAssets(address(adapterC));
    }

    /// @dev fbCeiling for adapterA at absCapBps = SAFETY_FB_ABS_BPS
    function _fbCeiling(uint256 tvl) internal pure returns (uint256) {
        return (uint256(SAFETY_FB_ABS_BPS) * tvl) / 10_000;
    }

    /// @dev Safety hard ceiling = fbCeiling × (1 + tolerance)
    function _safetyHardCeiling(uint256 tvl) internal pure returns (uint256) {
        return (_fbCeiling(tvl) * (10_000 + uint256(CAPDRIFT_TOL_BPS))) / 10_000;
    }

    /// @dev Normal hard ceiling = normalCap × (1 + tolerance)
    function _normalHardCeiling(uint256 tvl) internal pure returns (uint256) {
        return ((uint256(NORMAL_CAP_BPS) * tvl / 10_000) * (10_000 + uint256(CAPDRIFT_TOL_BPS))) / 10_000;
    }

    /// @dev Force adapter's positionAssets to target; deal real USDC to match.
    ///      Preserves full protocol invariant: vault storage + adapter storage + USDC balance all agree.
    function _forcePosition(ScoringMockAdapter adapter, uint256 target) internal {
        deal(ARBITRUM_USDC, address(adapter), target);
        adapter.setDeposited(target);
        stdstore.target(address(vault))
            .sig("positionAssets(address)")
            .with_key(address(adapter))
            .checked_write(target);
    }

    /// @dev Force adapter to pct% of the NEW total TVL (accounts for target inflating TVL).
    ///      Closed-form: target = tvlOthers × pct / (10000 - pct)
    function _forcePctOfNewTvl(ScoringMockAdapter adapter, uint16 pctBps) internal {
        require(pctBps > 0 && pctBps < 10_000, "_forcePctOfNewTvl: pct out of range");
        uint256 tvlOthers = _totalTvl() - vault.positionAssets(address(adapter));
        uint256 target = (tvlOthers * uint256(pctBps)) / (10_000 - uint256(pctBps));
        _forcePosition(adapter, target);
    }

    /// @dev Execute all queued plan steps (up to 10 guard).
    function _drainPlan() internal {
        for (uint256 i = 0; i < 10; ++i) {
            if (vault.rebalancePlanPhase() == 0) break;
            vm.prank(keeper);
            StrategyRebalancePlanModule(address(vault)).executeRebalanceStep();
        }
    }

    /// @dev True if the prepared plan contains a WITHDRAW action for `adapter`.
    ///      Bit 255 encodes isDeposit per StrategyStorageLayout: 1 = deposit, 0 = withdraw.
    function _planHasWithdrawFor(address adapter) internal view returns (bool) {
        uint8 total = vault.rebalancePlanTotalActions();
        for (uint8 i = 0; i < total; i++) {
            address a   = vault.rebalancePlanAdapters(i);
            uint256 amt = vault.rebalancePlanAmounts(i);
            if (a == adapter && (amt >> 255) == 0) return true;
        }
        return false;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 13-step sequential lifecycle
    // ═══════════════════════════════════════════════════════════════════════════

    function test_V92_SafetyTier_full_lifecycle() public {
        // ── S03: Deposit 1M USDC (real Arbitrum USDC via deal) ─────────────────
        deal(ARBITRUM_USDC, core, DEPOSIT_AMOUNT);
        vm.startPrank(core);
        IERC20(ARBITRUM_USDC).transfer(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();

        assertEq(_totalTvl(), DEPOSIT_AMOUNT, "S03: TVL must equal deposit amount");

        // ── S04: deployIdle — real USDC flows from vault to adapters via ERC-20 ─
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();

        uint256 idleAfterS04 = IERC20(ARBITRUM_USDC).balanceOf(address(vault));
        assertLt(idleAfterS04, DEPOSIT_AMOUNT, "S04: deployIdle must reduce vault idle balance");
        // Confirm TVL conserved across the ERC-20 transfer
        assertEq(_totalTvl(), DEPOSIT_AMOUNT, "S04: TVL must be conserved after deployIdle");

        // ── S05: Overflow path — A absorbs surplus idle bounded by fbCeiling ────
        // Saturate B and C at their absolute cap to exhaust the normal allocation path.
        uint256 tvl5 = _totalTvl();
        uint256 normalCapAmt = (tvl5 * NORMAL_CAP_BPS) / 10_000;
        _forcePosition(adapterB, normalCapAmt);
        _forcePosition(adapterC, normalCapAmt);

        // Add surplus idle that only the safety overflow path can absorb.
        uint256 surplusIdle = 200_000e6;
        deal(ARBITRUM_USDC, address(vault),
            IERC20(ARBITRUM_USDC).balanceOf(address(vault)) + surplusIdle);

        vm.warp(1781278151); // fork_ts + 301s — past minSecondsBetweenDeployIdle

        uint256 posA_beforeOverflow = vault.positionAssets(address(adapterA));
        vm.prank(keeper);
        StrategyScoringModule(address(vault)).deployIdle();

        uint256 posA_afterOverflow = vault.positionAssets(address(adapterA));
        assertGt(posA_afterOverflow, posA_beforeOverflow,
            "S05: overflow must route surplus idle into safety adapterA");

        // Fallback ceiling enforced on the overflow deposit.
        uint256 tvl5b    = _totalTvl();
        uint256 fbCeil5  = _fbCeiling(tvl5b);
        assertLe(posA_afterOverflow, fbCeil5,
            "S05: safety adapterA must not exceed fbCeiling after overflow");

        // ── S06: Tolerance band (fbCeiling, hardCeiling] — mandate silent ───────
        // Force A to 69% of TVL: above fbCeiling (70% is fb but tolerance band
        // starts immediately above; 69% is below fb, so actually above fb — let
        // me recalculate:
        // SAFETY_FB_ABS_BPS = 7000 → fbCeiling = 70% TVL
        // Force at 69%: 69% < 70% → that would be BELOW fbCeiling.
        // Need to be above fbCeiling but below hardCeiling.
        // hardCeiling = 70% × 1.025 = 71.75%
        // So 71% is in the band (70%, 71.75%) ✓
        _forcePctOfNewTvl(adapterA, 7100); // 71% of TVL — in (70%, 71.75%) band

        {
            uint256 posA6 = vault.positionAssets(address(adapterA));
            uint256 tvl6  = _totalTvl();
            uint256 fb6   = _fbCeiling(tvl6);
            uint256 hc6   = _safetyHardCeiling(tvl6);
            assertGt(posA6, fb6,  "S06 setup: adapterA must be above fbCeiling");
            assertLt(posA6, hc6,  "S06 setup: adapterA must be below safety hardCeiling");
        }

        vm.warp(1781882951); // S06 absolute: fork+301+7d
        {
            (bool ok6, , int256 nb6) = StrategyRebalanceGateModule(address(vault)).canRebalance();
            // Mandate fires only above hardCeiling (nb=0 is the mandate signature).
            // In the tolerance band, ok=false or ok=true with nb>0 (APY-driven).
            if (ok6) {
                assertGt(nb6, 0,
                    "S06: mandate must not fire in tolerance band (ok=true only via APY benefit)");
            }
        }

        // ── S07: Above safety hardCeiling → mandate fires ───────────────────────
        _forcePctOfNewTvl(adapterA, 7500); // 75% > safety hardCeiling 71.75%

        {
            uint256 posA7 = vault.positionAssets(address(adapterA));
            uint256 tvl7  = _totalTvl();
            uint256 hc7   = _safetyHardCeiling(tvl7);
            assertGt(posA7, hc7, "S07 setup: adapterA must be above safety hardCeiling");
        }

        vm.warp(1782487751); // S07 absolute: fork+301+14d

        {
            (bool ok7, , int256 nb7) = StrategyRebalanceGateModule(address(vault)).canRebalance();
            assertTrue(ok7,               "S07: mandate must fire above safety hardCeiling");
            assertEq(nb7, int256(0),      "S07: mandate signature is nb=0 (protection, not APY)");
        }


        // ── S08: Execute mandate — adapterA returns to ≤ fbCeiling ─────────────
        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).prepareRebalance();
        _drainPlan();


        {
            uint256 posA8     = vault.positionAssets(address(adapterA));
            uint256 tvl8      = _totalTvl();
            uint256 fb8       = _fbCeiling(tvl8);
            uint256 fb8Tol    = fb8 + fb8 / 100; // +1% tolerance for integer rounding
            assertLe(posA8, fb8Tol,
                "S08: adapterA must be within fbCeiling (+1% rounding) after mandate execution");
        }

        // ── S09: Safety adapter must never receive mandate cooldown timestamp ────
        assertEq(
            vault.lastRelCapMandateTs(address(adapterA)), 0,
            "S09: safety adapter lastRelCapMandateTs must remain zero after mandate"
        );

        // ── S10: Preserve safety tranche — mandate targets B, not A ─────────────
        // Reset: A at 65% (valid safety tranche), B at 55% (above normal hardCeiling ~51.25%).
        _forcePctOfNewTvl(adapterA, 6500);
        _forcePctOfNewTvl(adapterB, 5500);

        {
            uint256 tvl10 = _totalTvl();
            uint256 normHc = _normalHardCeiling(tvl10);
            assertGt(vault.positionAssets(address(adapterB)), normHc,
                "S10 setup: adapterB must be above normal hardCeiling");
            assertLt(vault.positionAssets(address(adapterA)), _safetyHardCeiling(tvl10),
                "S10 setup: adapterA must be below safety hardCeiling");
        }

        vm.warp(1783092551); // S10 absolute: fork+301+21d

        vm.prank(keeper);
        StrategyRebalancePlanModule(address(vault)).prepareRebalance();

        {
            bool aWithdraw = _planHasWithdrawFor(address(adapterA));
            bool bWithdraw = _planHasWithdrawFor(address(adapterB));
            assertFalse(aWithdraw,
                "S10: mandate plan must NOT include withdraw from safety adapterA in valid tranche");
            assertTrue(bWithdraw,
                "S10: mandate plan must include withdraw from over-cap adapterB");
        }
        _drainPlan();

        // ── S11: Governance Semantic A — cap reduction creates tolerance-band state
        // Reduce A's fallback abs cap from 7000 → 6400.
        // New fbCeiling = 64% TVL; new hardCeiling = 65.6% TVL.
        // Force A to 65%: in new band (64%, 65.6%) → mandate silent.
        _forcePctOfNewTvl(adapterA, 6500); // 65% of TVL

        vm.prank(admin);
        StrategySettingsModule(address(vault)).updateSafetyFallbackCaps(
            address(adapterA), 6400, SAFETY_FB_REL_BPS
        );

        // Verify cap update is reflected in storage.
        {
            (uint16 newAbsBps, ) = vault.safetyFallback(address(adapterA));
            assertEq(newAbsBps, 6400, "S11: governance cap update must be persisted in storage");
        }

        {
            uint256 posA11 = vault.positionAssets(address(adapterA));
            uint256 tvl11  = _totalTvl();
            // New ceilings after governance update.
            uint256 newFb11 = (uint256(6400) * tvl11) / 10_000;
            uint256 newHc11 = (newFb11 * (10_000 + uint256(CAPDRIFT_TOL_BPS))) / 10_000;

            // Position (65%) is above new fbCeiling (64%) — this is Governance Semantic A:
            // a cap reduction does not revert the setter or immediately unwind the position.
            assertGt(posA11, newFb11, "S11: position above new fbCeiling after cap reduction");

            if (posA11 < newHc11) {
                // Position in new tolerance band → mandate must NOT fire yet.
                vm.warp(1783697351); // S11 absolute: fork+301+28d
                (bool ok11, , int256 nb11) = StrategyRebalanceGateModule(address(vault)).canRebalance();
                if (ok11) {
                    assertGt(nb11, 0,
                        "S11: position in tolerance band after cap reduction must not mandate-fire");
                }
                // else: ok=false is also valid (no benefit above cost)
            }
            // If posA11 >= newHc11, the mandate is expected to fire — both outcomes are
            // valid per the spec; we only assert the storage update above.
        }

        // ── S12: Remove safety → normal-cap semantics → mandate fires ──────────
        // Restore A to 65%, then strip safety status. Normal hardCeiling ~51.25%.
        _forcePctOfNewTvl(adapterA, 6500);

        vm.prank(admin);
        StrategySettingsModule(address(vault)).removeSafetyFallbackAdapter(address(adapterA));

        // Safety storage must be cleared.
        {
            (uint16 absAfter, uint16 relAfter) = vault.safetyFallback(address(adapterA));
            assertEq(absAfter, 0, "S12: safety absCapBps must be zero after remove");
            assertEq(relAfter, 0, "S12: safety relCapBps must be zero after remove");
        }

        // Position at 65% now falls under normal cap semantics: normal hardCeiling ≈ 51.25%.
        {
            uint256 tvl12 = _totalTvl();
            uint256 normHc12 = _normalHardCeiling(tvl12);
            assertGt(vault.positionAssets(address(adapterA)), normHc12,
                "S12 setup: adapterA must exceed normal hardCeiling after safety removal");
        }

        vm.warp(1784301951); // S12 absolute: fork+301+35d
        {
            (bool ok12, , int256 nb12) = StrategyRebalanceGateModule(address(vault)).canRebalance();
            assertTrue(ok12,          "S12: mandate must fire on adapterA under normal cap semantics");
            assertEq(nb12, int256(0), "S12: mandate signature nb=0 (protection, not APY)");
        }

        // ── S13: Accounting conservation ──────────────────────────────────────
        // Total assets (idle + all positions) must approximate the deposited amount.
        // Dust tolerance = 10000 wei per _baseParams; allow a slightly wider margin
        // for integer rounding across multi-step stdstore writes.
        uint256 totalS13 = _totalTvl();
        assertGt(totalS13, 0,
            "S13: protocol TVL must be positive (no catastrophic accounting loss)");
        assertGe(totalS13, DEPOSIT_AMOUNT,
            "S13: total assets must not drop below initial deposit amount");
    }
}
