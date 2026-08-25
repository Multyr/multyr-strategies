// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * FINDING: PUSH-mode deposit failures leave real USDC sitting at the adapter,
 *          untracked by the strategy's bookkeeping AND invisible to
 *          totalAssets()/NAV, with no automatic on-chain recovery.
 * SEVERITY: MEDIUM (standalone) — HIGH when chained with the unauthenticated
 *           `safeAdapterDeposit`/`deployIdleToAdapters` access-control bypass
 *           documented in AccessControlBypass_AdapterOpsAndScoring.t.sol,
 *           because that path additionally skips every eligibility/cap check
 *           that would normally make this scenario rare.
 *
 * `StrategyAdapterOpsModule.safeAdapterDeposit()` (StrategyAdapterOpsModule.sol:41-55),
 * for any adapter with `pushDepositMode[adapter] == true` (auto-configured
 * from `ILendingAdapter.isPushMode()` at `addAdapter()` time — currently only
 * Euler in production, but any future/compromised adapter reporting
 * `isPushMode() == true` qualifies):
 *
 *     ASSET.safeTransfer(adapter, amount);              // (1) unconditional
 *     try ILendingAdapter(adapter).deposit(amount) {
 *         ...
 *     } catch (bytes memory reason) {
 *         emit AdapterDepositFailed(adapter, amount, reason);
 *         emit AdapterFundsStranded(adapter, amount);    // (2) named for a reason
 *         ...
 *         return false;
 *     }
 *
 * Step (1) always executes before step (2)'s try/catch. If `deposit()`
 * reverts for ANY reason (adapter-side cap hit, external protocol paused,
 * a transient revert, or an adapter simply written/compromised to always
 * revert), the USDC transferred in step (1) is not, and structurally cannot
 * be, rolled back — Solidity has no way to undo an already-executed external
 * call from inside a later `catch` block. The caller (`_deployIdleToAdapters`
 * / `_executeRebalanceStepInternal`) correctly does NOT increment
 * `positionAssets[adapter]` when `ok == false`, so the strategy's own
 * accounting shows nothing was deployed — but `totalAssets()` also queries
 * `adapter.totalAssets()` (not the adapter's raw USDC balance), so the
 * stranded funds are invisible there too. They are real, on-chain, and
 * recoverable ONLY via `StrategySettingsModule.callAdapterEmergencySweep()`
 * (DEFAULT_ADMIN_ROLE-gated, fully manual, off-chain-triggered).
 */

import { Test, console2 } from "forge-std/Test.sol";
import { ILendingAdapter } from "../../../../src/strategies/usdc-lending/interfaces/ILendingAdapter.sol";
import {
    UsdcMultiLendingVaultTestBase,
    MockUSDC,
    MockLendingAdapter
} from "../UsdcMultiLendingVault.t.sol";

/// @dev Minimal PUSH-mode adapter stub (mirrors Euler's isPushMode()==true
///      contract shape) with a controllable deposit-failure switch, used to
///      deterministically reproduce the stranding scenario described above.
contract PushModeAdapterStub is ILendingAdapter {
    address public immutable underlyingAsset;
    address public vault;
    uint256 public deposited;
    bool public depositShouldRevert;

    constructor(address _underlying) { underlyingAsset = _underlying; }

    function setVault(address v) external { vault = v; }
    function setDepositShouldRevert(bool r) external { depositShouldRevert = r; }

    function name() external pure returns (string memory) { return "PushModeAdapterStub"; }
    function underlying() external view returns (address) { return underlyingAsset; }
    function totalAssets() external view returns (uint256) { return deposited; }
    function withdrawableAssets() external view returns (uint256) { return deposited; }

    function deposit(uint256 assets) external {
        // PUSH mode: the strategy has ALREADY transferred `assets` worth of
        // USDC to this contract's own balance before calling deposit(). If
        // this reverts, that USDC stays here, untracked.
        require(!depositShouldRevert, "simulated external-protocol deposit failure");
        deposited += assets;
    }

    function withdraw(uint256 assets, address receiver) external returns (uint256) {
        uint256 amt = assets > deposited ? deposited : assets;
        deposited -= amt;
        MockUSDC(underlyingAsset).transfer(receiver, amt);
        return amt;
    }

    function currentAPYBps() external pure returns (uint16) { return 500; }
    function incentiveAPYBps() external pure returns (uint16) { return 0; }
    function harvestableProfit() external pure returns (uint256) { return 0; }
    function harvest(address) external pure returns (uint256) { return 0; }
    function maxCapacity() external pure returns (uint256) { return type(uint256).max; }
    function isPushMode() external pure returns (bool) { return true; }

    function idleAssetBalance() external view returns (uint256) {
        return MockUSDC(underlyingAsset).balanceOf(address(this));
    }
    function investedAssets() external view returns (uint256) { return deposited; }

    function sweepIdleAssetToVault() external {
        uint256 bal = MockUSDC(underlyingAsset).balanceOf(address(this));
        if (bal > 0) MockUSDC(underlyingAsset).transfer(vault, bal);
    }
    function emergencyPullAllToVault() external {
        uint256 bal = MockUSDC(underlyingAsset).balanceOf(address(this));
        if (bal > 0) MockUSDC(underlyingAsset).transfer(vault, bal);
        deposited = 0;
    }
    function externalMarketTVL() external pure returns (uint256) { return 50_000_000e6; }
}

contract PushModeAdapter_FundStranding_PoC is UsdcMultiLendingVaultTestBase {
    PushModeAdapterStub public pushAdapter;

    function setUp() public override {
        super.setUp();

        pushAdapter = new PushModeAdapterStub(ARBITRUM_USDC);
        pushAdapter.setVault(address(vault));

        vm.startPrank(admin);
        (bool wlOk, ) = address(vault).call(
            abi.encodeWithSignature("whitelistAdapter(address,bool)", address(pushAdapter), true)
        );
        require(wlOk, "whitelistAdapter failed");
        vault.addAdapter(address(pushAdapter));
        vault.toggleAdapter(address(pushAdapter), true);
        vm.stopPrank();

        // Confirm PUSH mode was auto-configured from isPushMode()==true — we
        // deliberately do NOT call setAdapterDepositMode() to override it,
        // unlike the shared _addAndEnableAdapter() helper.
        assertTrue(vault.pushDepositMode(address(pushAdapter)), "sanity: adapter auto-configured as PUSH mode");

        vm.startPrank(keeper);
        StrategyParamsModuleLike(address(vault)).pokeExternalTVL();
        (bool liqOk, ) = address(vault).call(abi.encodeWithSignature("pokeLiquidityBatch(uint256,uint256)", 0, 10));
        require(liqOk, "pokeLiquidityBatch failed");
        vm.stopPrank();
    }

    function test_POC_failed_push_deposit_strands_funds_invisibly() public {
        uint256 amt = 250_000e6;
        usdc.mint(address(vault), amt);

        pushAdapter.setDepositShouldRevert(true);

        uint256 tvlBefore = vault.totalAssets();
        uint256 idleBefore = vault.idleCash();

        vm.warp(block.timestamp + vault.minSecondsBetweenDeployIdle() + 1); // clear deployIdle() cooldown
        vm.prank(keeper);
        (bool ok, ) = address(vault).call(abi.encodeWithSignature("deployIdle()"));
        require(ok, "deployIdle() call unexpectedly failed");

        // Ordinary per-adapter exposure/ramp caps mean not necessarily 100% of
        // `amt` is attempted in a single deployIdle() pass for a brand-new
        // adapter -- that's expected, unrelated behavior. What matters is:
        // whatever amount WAS attempted is now stuck, untracked, at the adapter.
        uint256 attempted = idleBefore - vault.idleCash();
        assertGt(attempted, 0, "sanity: deployIdle() actually attempted a non-zero deposit into the PUSH adapter");

        // The USDC really left the vault and is really sitting at the adapter...
        assertEq(usdc.balanceOf(address(pushAdapter)), attempted, "funds physically transferred to the adapter (PUSH pre-transfer)");

        // ...but nothing tracks it: bookkeeping shows zero position...
        assertEq(vault.positionAssets(address(pushAdapter)), 0, "positionAssets was never incremented (deposit() reverted)");

        // ...and totalAssets()/NAV doesn't see it either, because it reads
        // adapter.totalAssets() (protocol-side accounting), not the adapter's
        // raw idle USDC balance.
        assertEq(pushAdapter.totalAssets(), 0, "adapter's own accounting shows zero too (deposit() never completed)");
        uint256 tvlAfter = vault.totalAssets();
        assertEq(
            tvlAfter, tvlBefore - attempted,
            "VULNERABLE: NAV silently drops by the stranded amount -- funds are real and recoverable, but invisible to every on-chain view until a manual DEFAULT_ADMIN_ROLE sweep"
        );

        // Recovery exists but is 100% manual/off-chain-triggered (not
        // exercised further here) -- StrategySettingsModule.callAdapterEmergencySweep(),
        // DEFAULT_ADMIN_ROLE only. No keeper op or retry path calls it automatically.
    }
}

interface StrategyParamsModuleLike {
    function pokeExternalTVL() external;
}
