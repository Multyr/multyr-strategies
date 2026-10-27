// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UsdcMultiLendingVaultTestBase} from "./UsdcMultiLendingVault.t.sol";
import {StrategyRouter} from "@multyr-core/core/modules/StrategyRouter.sol";
import {IStrategy} from "@multyr-core/interfaces/IStrategyRouter.sol";
import {Unauthorized} from "../../../src/strategies/usdc-lending/controller/StrategyStorageLayout.sol";
import {StrategyUpkeep} from "../../../src/strategies/usdc-lending/automation/LendingStrategyUpkeep.sol";

contract HarvestCoreCaller {
    function asset() external pure returns (address) {
        return 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    }
    function harvest(StrategyRouter target) external returns (uint256, int256, uint256) {
        return target.harvest(0);
    }
}

/// @dev Real StrategyRouter + real modular strategy; only Core caller/token/adapters are fixtures.
contract RouterHarvestIntegrationTest is UsdcMultiLendingVaultTestBase {
    StrategyRouter actualRouter;
    HarvestCoreCaller caller;

    function setUp() public override {
        super.setUp();
        caller = new HarvestCoreCaller();
        actualRouter = new StrategyRouter(address(this), address(caller), address(this));
        vm.prank(admin);
        vault.grantRole(CORE_ROLE, address(actualRouter));
        uint256 eta = actualRouter.proposeStrategyAllowlist(address(vault));
        vm.warp(eta);
        actualRouter.executeStrategyAllowlist(address(vault));
        actualRouter.register(address(vault), 100, 10000);
        _setupAdaptersForRebalance();
        _mintAndTransferToVault(core, 250_000e6);
        vm.prank(core);
        vault.deposit(250_000e6);
    }

    function test_routerHarvestDecodesReturnsWithoutKeeperGrant() public {
        assertFalse(vault.hasRole(KEEPER_ROLE, address(actualRouter)));
        adapter1.setHarvestable(10e6);
        adapter2.setHarvestable(5e6);
        uint256 before = vault.totalAssets();
        (uint256 visited, int256 pnl, uint256 realized) = caller.harvest(actualRouter);
        assertEq(visited, 1);
        assertEq(pnl, 15e6);
        assertEq(realized, 15e6);
        assertEq(vault.totalAssets(), before + 15e6);
        // Reward collection stays invested in strategy; never report a Core transfer.
        assertEq(usdc.balanceOf(address(caller)), 0);
        (, pnl, realized) = caller.harvest(actualRouter);
        assertEq(pnl, 0);
        assertEq(realized, 0);
    }

    function test_routerRecallIncludesUncachedAccruedInterest() public {
        uint256 prior = vault.totalAssets();
        adapter1.setDeposited(adapter1.deposited() + 10e6);
        usdc.mint(address(adapter1), 10e6);
        uint256 got = actualRouter.withdrawAllToCore(address(vault));
        assertEq(got, prior + 10e6);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.positionAssets(address(adapter1)), 0);
    }

    function test_routerRecallRetainsCachedFallbackWhenNavReadFails() public {
        uint256 prior = vault.totalAssets();
        adapter1.setTotalAssetsReverts(true);
        uint256 got = actualRouter.withdrawAllToCore(address(vault));
        assertEq(got, prior);
        assertEq(vault.positionAssets(address(adapter1)), 0);
    }

    function test_routerHarvestPreservesPartialFailureHandling() public {
        adapter1.setHarvestable(10e6);
        adapter1.setHarvestReverts(true);
        adapter2.setHarvestable(5e6);
        (, int256 pnl, uint256 realized) = caller.harvest(actualRouter);
        assertEq(pnl, 5e6);
        assertEq(realized, 5e6);
        assertEq(adapter1.harvestableProfit(), 10e6);
    }

    function test_priorAccruedNavIsNotReportedAgain() public {
        adapter1.setDeposited(adapter1.deposited() + 10e6);
        (, int256 pnl, uint256 realized) = caller.harvest(actualRouter);
        assertEq(pnl, 0);
        assertEq(realized, 0);
    }

    function test_keeperAndCoreCanDecodeSameInterface() public {
        adapter1.setHarvestable(1e6);
        vm.prank(keeper);
        (int256 pnl, uint256 realized) = IStrategy(address(vault)).harvest();
        assertEq(pnl, 1e6);
        assertEq(realized, 1e6);
        vm.prank(core);
        (pnl, realized) = IStrategy(address(vault)).harvest();
        assertEq(pnl, 0);
        assertEq(realized, 0);
    }

    function test_unprivilegedHarvestRemainsBlocked() public {
        vm.prank(user);
        vm.expectRevert(Unauthorized.selector);
        IStrategy(address(vault)).harvest();
    }

    function test_existingUpkeepIgnoresAdditionalReturnValues() public {
        address[] memory strategies = new address[](1);
        strategies[0] = address(vault);
        StrategyUpkeep upkeep = new StrategyUpkeep(strategies);
        vm.prank(admin);
        vault.grantRole(KEEPER_ROLE, address(upkeep));
        adapter1.setHarvestable(10e6);
        uint256 before = vault.totalAssets();
        upkeep.performUpkeep(abi.encode(uint8(1), uint256(0)));
        assertEq(adapter1.harvestableProfit(), 0);
        assertEq(vault.totalAssets(), before + 10e6);
    }
}
