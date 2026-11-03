// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ═══════════════════════════════════════════════════════════════════════════════
// VenusAccrualRecall.t.sol
// Root counterexample: BSC Venus/USDT18 — exchangeRateStored snapshot used for
// recall quote; redeemUnderlying accrues during mutable call, leaving residual
// vTokens. Fixed by switching emergency paths to emergencyPullAllToVault() with
// actual balance-delta accounting and a salvage normal-withdraw fallback.
//
// Regression matrix:
//   R1  legacy withdraw(pos) path leaves accrual residue (documents pre-fix bug)
//   R2  emergencyRecallAll recovers principal + mid-redemption accrual
//   R3  zero-cache adapter with stranded idle USDC is not skipped
//   R4  true blocked: BOTH emergency and withdraw fail; sibling isolated
//   R5  true blocked swallow: emergency swallows + withdraw fails; cache preserved
//   R6  selectiveRecall uses same full-receipt + salvage path
//   R7  salvage partial recovery: emergency fails, normal withdraw succeeds
// ═══════════════════════════════════════════════════════════════════════════════

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {LendingOracleTestFixture} from "./helpers/LendingOracleTestFixture.sol";
import {UsdcMultiLendingVault} from "../../../src/strategies/usdc-lending/controller/UsdcLendingStrategy.sol";
import {ILendingAdapter} from "../../../src/strategies/usdc-lending/interfaces/ILendingAdapter.sol";
import {StrategyParamsModule} from "../../../src/strategies/usdc-lending/controller/StrategyParamsModule.sol";
import {StrategySettingsModule} from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {StrategyAllocCalcModule} from "../../../src/strategies/usdc-lending/controller/StrategyAllocCalcModule.sol";
import {StrategyScoringModule} from "../../../src/strategies/usdc-lending/controller/StrategyScoringModule.sol";
import {StrategyAdapterOpsModule} from "../../../src/strategies/usdc-lending/controller/StrategyAdapterOpsModule.sol";
import {StrategyRebalanceGateModule} from "../../../src/strategies/usdc-lending/controller/StrategyRebalanceGateModule.sol";
import {StrategyRebalancePlanModule} from "../../../src/strategies/usdc-lending/controller/StrategyRebalancePlanModule.sol";
import {StrategySafetyOverflowModule} from "../../../src/strategies/usdc-lending/controller/StrategySafetyOverflowModule.sol";
import {MockUSDC} from "./UsdcMultiLendingVault.t.sol";

// ─────────────────────────────────────────────────────────────────────────────
// VenusStyleAdapter
// Models Venus BSC behaviour:
//   totalAssets()              → stale snapshot (exchangeRateStored, no accrual)
//   withdraw(amount, recv)     → transfers exactly `amount`, leaves accrued yield
//   emergencyPullAllToVault()  → redeems all shares, sweeps full balance to vault
//   simulateAccrual(n)         → mints n USDC WITHOUT updating snapshot
//                                (models interest accrued mid-redeemUnderlying)
// ─────────────────────────────────────────────────────────────────────────────
contract VenusStyleAdapter is ILendingAdapter {
    address public immutable underlying_;
    address public vault_;
    uint256 public snapshot;        // stale position (exchangeRateStored equivalent)
    bool public emergencyReverts;
    bool public emergencySwallows;  // call returns without revert, transfers nothing
    bool public withdrawReverts;
    bool public reportsZero;

    constructor(address _underlying, address _vault) {
        underlying_ = _underlying;
        vault_ = _vault;
    }

    // ── ILendingAdapter ───────────────────────────────────────────────────────

    function name() external pure override returns (string memory) { return "VenusStyleMock"; }
    function underlying() external view override returns (address) { return underlying_; }
    function totalAssets() external view override returns (uint256) { return reportsZero ? 0 : snapshot; }
    function withdrawableAssets() external view override returns (uint256) { return snapshot; }

    function deposit(uint256 assets) external override {
        MockUSDC(underlying_).transferFrom(msg.sender, address(this), assets);
        snapshot += assets;
    }

    /// @dev Transfers exactly `assets` — does NOT accrue; yield since snapshot remains.
    function withdraw(uint256 assets, address receiver) external override returns (uint256) {
        require(!withdrawReverts, "venus: withdraw reverts");
        uint256 bal = MockUSDC(underlying_).balanceOf(address(this));
        uint256 toSend = assets > bal ? bal : assets;
        if (toSend > 0) MockUSDC(underlying_).transfer(receiver, toSend);
        snapshot = snapshot >= toSend ? snapshot - toSend : 0;
        return toSend;
    }

    function currentAPYBps() external pure override returns (uint16) { return 500; }
    function incentiveAPYBps() external pure override returns (uint16) { return 0; }
    function harvestableProfit() external pure override returns (uint256) { return 0; }
    function harvest(address) external pure override returns (uint256) { return 0; }
    function maxCapacity() external pure override returns (uint256) { return type(uint256).max; }
    function isPushMode() external pure override returns (bool) { return false; }
    function idleAssetBalance() external view override returns (uint256) {
        uint256 bal = MockUSDC(underlying_).balanceOf(address(this));
        return bal > snapshot ? bal - snapshot : 0;
    }
    function investedAssets() external view override returns (uint256) { return snapshot; }
    function sweepIdleAssetToVault() external override {}
    function externalMarketTVL() external pure override returns (uint256) { return 100_000_000e6; }

    /// @dev Full-receipt redemption: redeems all shares, sweeps entire balance to vault.
    function emergencyPullAllToVault() external override {
        require(!emergencyReverts, "venus: emergency reverts");
        if (!emergencySwallows) {
            uint256 bal = MockUSDC(underlying_).balanceOf(address(this));
            if (bal > 0) MockUSDC(underlying_).transfer(vault_, bal);
            snapshot = 0;
        }
        // emergencySwallows: returns without revert, transfers nothing (hidden protocol failure)
    }

    // ── Test helpers ──────────────────────────────────────────────────────────

    /// Seed principal: funds adapter and sets snapshot.
    function fundPrincipal(uint256 amount) external {
        MockUSDC(underlying_).mint(address(this), amount);
        snapshot = amount;
    }

    /// Add yield AFTER snapshot — models interest accrued during mutable redemption call.
    function simulateAccrual(uint256 amount) external {
        MockUSDC(underlying_).mint(address(this), amount);
        // snapshot intentionally NOT updated
    }

    function setEmergencyReverts(bool v) external { emergencyReverts = v; }
    function setEmergencySwallows(bool v) external { emergencySwallows = v; }
    function setWithdrawReverts(bool v) external { withdrawReverts = v; }
    function setReportsZero(bool v) external { reportsZero = v; }
    function setVault(address v) external { vault_ = v; }
}

// ─────────────────────────────────────────────────────────────────────────────
// Base fixture
// ─────────────────────────────────────────────────────────────────────────────
abstract contract VenusRecallBase is LendingOracleTestFixture {
    using stdStorage for StdStorage;

    address constant ARBITRUM_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    UsdcMultiLendingVault public vault;
    MockUSDC public usdc;

    address public admin  = address(0xA11CE);
    address public core;
    address public router = address(0xBEEF);
    address public keeper = address(0xCAFE);

    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;

    VenusStyleAdapter public adapterA;
    VenusStyleAdapter public adapterB;

    function _deploy() internal {
        usdc = new MockUSDC();
        vm.etch(ARBITRUM_USDC, address(usdc).code);
        usdc = MockUSDC(ARBITRUM_USDC);
        core = _newOracleCore(1e18);

        // Deploy adapters with a placeholder vault; update after vault is deployed.
        adapterA = new VenusStyleAdapter(ARBITRUM_USDC, address(1));
        adapterB = new VenusStyleAdapter(ARBITRUM_USDC, address(1));

        StrategyParamsModule paramsMod = StrategyParamsModule(payable(deployCode("StrategyParamsModule.sol:StrategyParamsModule", abi.encode(ARBITRUM_USDC, core))));
        StrategyAdapterOpsModule adapterOpsMod = StrategyAdapterOpsModule(payable(deployCode("StrategyAdapterOpsModule.sol:StrategyAdapterOpsModule", abi.encode(
            ARBITRUM_USDC, core, address(paramsMod), address(0), address(0)
        ))));
        StrategyScoringModule scoringMod = StrategyScoringModule(payable(deployCode("StrategyScoringModule.sol:StrategyScoringModule", abi.encode(
            ARBITRUM_USDC, core, address(paramsMod), address(0), address(adapterOpsMod)
        ))));
        StrategyRebalanceGateModule gateMod = StrategyRebalanceGateModule(payable(deployCode("StrategyRebalanceGateModule.sol:StrategyRebalanceGateModule", abi.encode(
            ARBITRUM_USDC, core, address(paramsMod), address(scoringMod), address(adapterOpsMod)
        ))));

        vault = UsdcMultiLendingVault(payable(deployCode("UsdcLendingStrategy.sol:UsdcMultiLendingVault", abi.encode(
            ARBITRUM_USDC, core, router, admin, keeper, address(0),
            address(paramsMod), address(scoringMod), address(adapterOpsMod),
            address(gateMod), _params()
        ))));

        adapterA.setVault(address(vault));
        adapterB.setVault(address(vault));

        StrategyRebalancePlanModule planMod = StrategyRebalancePlanModule(payable(deployCode("StrategyRebalancePlanModule.sol:StrategyRebalancePlanModule", abi.encode(
            ARBITRUM_USDC, core, address(paramsMod), address(scoringMod), address(adapterOpsMod)
        ))));
        vm.prank(admin); vault.setRebalancePlanModule(address(planMod));

        StrategySettingsModule settingsMod = StrategySettingsModule(payable(deployCode("StrategySettingsModule.sol:StrategySettingsModule", abi.encode(ARBITRUM_USDC, core))));
        vm.prank(admin); vault.setSettingsModule(address(settingsMod));

        StrategyAllocCalcModule allocMod = StrategyAllocCalcModule(payable(deployCode("StrategyAllocCalcModule.sol:StrategyAllocCalcModule", abi.encode(ARBITRUM_USDC, core))));
        vm.prank(admin); vault.setAllocCalcModule(address(allocMod));

        StrategySafetyOverflowModule overflowMod = StrategySafetyOverflowModule(payable(deployCode("StrategySafetyOverflowModule.sol:StrategySafetyOverflowModule", abi.encode(
            ARBITRUM_USDC, core, address(0), address(0), address(adapterOpsMod)
        ))));
        vm.prank(admin);
        StrategySettingsModule(address(vault)).setSafetyOverflowModule(address(overflowMod));

        _register(adapterA);
        _register(adapterB);
    }

    function _register(VenusStyleAdapter adapter) internal {
        vm.startPrank(admin);
        (bool wl,) = address(vault).call(
            abi.encodeWithSignature("whitelistAdapter(address,bool)", address(adapter), true)
        );
        require(wl, "whitelist failed");
        vault.addAdapter(address(adapter));
        vault.toggleAdapter(address(adapter), true);
        vm.stopPrank();
    }

    function _writePosition(address adapter, uint256 amount) internal {
        stdstore.target(address(vault))
            .sig("positionAssets(address)")
            .with_key(adapter)
            .checked_write(amount);
    }

    function _params() internal pure returns (UsdcMultiLendingVault.StrategyInitParams memory p) {
        p = UsdcMultiLendingVault.StrategyInitParams({
            maxAdaptersPerAllocation: 3,
            minAdaptersActive: 1,
            rebalanceMinMoveBps: 50,
            minSecondsBetweenRebalances: 21600,
            driftToleranceBps: 80,
            wAPY: 4000, wLiq: 2000, wRisk: 2000, wStability: 1000, wIncentive: 1000,
            incentiveDecayHalfLife: 86400,
            adapterMaxExposureBps: 8000,
            newAdapterRampBps: 8000,
            gateHorizonDays: 30,
            gateMinNetBenefitBps: 2,
            slippageBpsEstimate: 5,
            withdrawalSpreadBpsEstimate: 5,
            gasCostUSDC: 1e6,
            harvestThresholdBps: 5,
            minSecondsBetweenHarvests: 43200,
            dustTolerance: 1000,
            stabilityEMAPeriod: 7,
            minNewAdapterSeed: 0,
            newAdapterRampDuration: 0,
            maxIdleAfterDepositBps: 9000,
            maxIdleBootstrapBps: 9000,
            degradedViewThresholdBps: 2500,
            failureDecaySeconds: 3600,
            minSecondsBetweenDeployIdle: 0,
            bootstrapDuration: 0,
            maxRelativeExposureBps: 0,
            externalTVLStalenessSeconds: 43200
        });
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test contract
// ─────────────────────────────────────────────────────────────────────────────
contract VenusAccrualRecall_Test is VenusRecallBase {
    event AdapterWithdrawFailed(address indexed adapter, uint256 amount, bytes reason);

    function setUp() public { _deploy(); }

    // R1 — Documents pre-fix bug: withdraw(snapshot) leaves mid-call accrual residue.
    //      Tests adapter directly — not the vault recall path — as a stable reference.
    function test_R1_legacyWithdrawPath_leavesAccrualResidue() public {
        adapterA.fundPrincipal(1000e6);
        adapterA.simulateAccrual(200e6);

        uint256 snap = adapterA.snapshot();
        adapterA.withdraw(snap, address(this));

        assertEq(usdc.balanceOf(address(this)), 1000e6, "R1: principal");
        assertEq(usdc.balanceOf(address(adapterA)), 200e6, "R1: accrual stranded");
    }

    // R2 — Full-receipt emergency call recovers principal AND accrual added after snapshot.
    function test_R2_emergencyRecallAll_recoversPrincipalAndAccrual() public {
        adapterA.fundPrincipal(1000e6);
        adapterA.simulateAccrual(200e6);
        _writePosition(address(adapterA), 1000e6); // cache = stale snapshot

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        vm.prank(admin);
        vault.emergencyRecallAll();

        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, 1200e6, "R2: principal+accrual");
        assertEq(usdc.balanceOf(address(adapterA)), 0, "R2: adapter drained");
        assertEq(vault.positionAssets(address(adapterA)), 0, "R2: cache zeroed");
    }

    // R3 — Adapter with positionAssets=0 and snapshot=0 but actual USDC balance > 0
    //      must not be skipped (stranded idle from PUSH deposit or prior bug).
    function test_R3_zeroCacheAdapter_idleFundsRecovered() public {
        adapterA.simulateAccrual(500e6); // snapshot stays 0; actual balance = 500e6
        _writePosition(address(adapterA), 0);

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        vm.prank(admin);
        vault.emergencyRecallAll();

        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, 500e6, "R3: idle recovered");
        assertEq(usdc.balanceOf(address(adapterA)), 0, "R3: adapter drained");
    }

    // R4 — True blocked case: BOTH emergencyPullAllToVault AND withdraw revert for A.
    //      Healthy sibling B is not affected. A's cache preserved at last known value.
    function test_R4_trueBlocked_bothFailuresIsolated() public {
        adapterA.fundPrincipal(800e6);
        adapterB.fundPrincipal(600e6);
        _writePosition(address(adapterA), 800e6);
        _writePosition(address(adapterB), 600e6);

        adapterA.setEmergencyReverts(true);
        adapterA.setWithdrawReverts(true); // salvage also blocked

        // Two failure events expected for A: phase-1 emergency and phase-3 salvage.
        vm.expectEmit(true, false, false, false);
        emit AdapterWithdrawFailed(address(adapterA), 0, "");

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        vm.prank(admin);
        vault.emergencyRecallAll();

        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, 600e6, "R4: B recovered");
        assertEq(usdc.balanceOf(address(adapterA)), 800e6, "R4: A untouched");
        assertEq(vault.positionAssets(address(adapterA)), 800e6, "R4: A cache preserved");
        assertEq(vault.positionAssets(address(adapterB)), 0, "R4: B cache zeroed");
    }

    // R5 — True blocked swallow: emergencyPullAllToVault swallows failure (no revert,
    //      no transfer) AND withdraw also reverts. Cache must reflect live totalAssets
    //      (still non-zero), not silently zeroed.
    function test_R5_trueBlockedSwallow_cachePreserved() public {
        adapterA.fundPrincipal(700e6);
        _writePosition(address(adapterA), 700e6);

        adapterA.setEmergencySwallows(true);
        adapterA.setWithdrawReverts(true); // salvage also blocked

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        vm.prank(admin);
        vault.emergencyRecallAll();

        assertEq(usdc.balanceOf(address(vault)), vaultBefore, "R5: vault unchanged");
        assertEq(usdc.balanceOf(address(adapterA)), 700e6, "R5: adapter still funded");
        // totalAssets() still returns 700e6 (snapshot unchanged) → cache updated to live
        assertEq(vault.positionAssets(address(adapterA)), 700e6, "R5: cache at live position");
    }

    // R6 — selectiveRecall uses the same full-receipt + salvage path.
    function test_R6_selectiveRecall_fullAccrualRecall() public {
        adapterA.fundPrincipal(500e6);
        adapterA.simulateAccrual(150e6);
        _writePosition(address(adapterA), 500e6);

        address[] memory targets = new address[](1);
        targets[0] = address(adapterA);

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        vm.prank(admin);
        vault.selectiveRecall(targets);

        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, 650e6, "R6: full recall");
        assertEq(usdc.balanceOf(address(adapterA)), 0, "R6: adapter drained");
    }

    // R7 — Salvage partial recovery: emergencyPullAllToVault fails, but one normal
    //      withdraw(remaining, vault) succeeds and recovers the position.
    //      Demonstrates the fallback path does NOT leave funds stranded when
    //      full-receipt API is unavailable but the protocol allows partial exit.
    function test_R7_salvageFallback_recoversAfterEmergencyFail() public {
        adapterA.fundPrincipal(1000e6); // snapshot = 1000e6, actual balance = 1000e6
        _writePosition(address(adapterA), 1000e6);

        adapterA.setEmergencyReverts(true); // full-receipt unavailable
        // withdrawReverts stays false → salvage withdraw succeeds

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        vm.prank(admin);
        vault.emergencyRecallAll();

        // Emergency failed (event emitted) but salvage recovered the full snapshot
        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, 1000e6, "R7: salvage recovered");
        assertEq(usdc.balanceOf(address(adapterA)), 0, "R7: adapter drained");
        assertEq(vault.positionAssets(address(adapterA)), 0, "R7: cache zeroed after salvage");
    }
    function test_R8_manualSalvageDoesNotSeedOrdinaryWithdrawEMA() public {
        adapterA.fundPrincipal(1000e6);
        _writePosition(address(adapterA), 1000e6);
        adapterA.setEmergencyReverts(true);
        vm.prank(admin);
        vault.emergencyRecallAll();
        assertEq(usdc.balanceOf(address(adapterA)), 0, "manual salvage must recover assets");
        (uint32 count,) = vault.withdrawGasObservation(address(adapterA));
        assertEq(count, 0, "exceptional warmed salvage must not seed ordinary plan EMA");
    }

    function test_R9_failedPullZeroViewPreservesKnownCache() public {
        adapterA.fundPrincipal(1000e6);
        _writePosition(address(adapterA), 1000e6);
        adapterA.setEmergencyReverts(true);
        adapterA.setWithdrawReverts(true);
        adapterA.setReportsZero(true);
        uint256 cashBefore = usdc.balanceOf(address(vault));
        vm.prank(admin);
        vault.emergencyRecallAll();
        assertEq(usdc.balanceOf(address(vault)), cashBefore);
        assertEq(usdc.balanceOf(address(adapterA)), 1000e6);
        assertEq(vault.positionAssets(address(adapterA)), 1000e6,
            "failed pull with zero recovery must not erase known cached exposure");
    }

    function test_R10_successfulEmptyPullClearsStaleCache() public {
        _writePosition(address(adapterA), 1000e6);
        assertEq(usdc.balanceOf(address(adapterA)), 0);
        vm.prank(admin);
        vault.emergencyRecallAll();
        assertEq(vault.positionAssets(address(adapterA)), 0,
            "successful empty pull and zero NAV must clear stale cached exposure");
    }

}
