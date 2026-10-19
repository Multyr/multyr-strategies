// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UsdcMultiLendingVaultTestBase} from "./UsdcMultiLendingVault.t.sol";
import {StrategyRouter} from "@multyr-core/core/modules/StrategyRouter.sol";
import {IStrategyRouter} from "@multyr-core/interfaces/IStrategyRouter.sol";
import {StrategySettingsModule} from "../../../src/strategies/usdc-lending/controller/StrategySettingsModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev A funded reward fixture; transfers native USDC rather than mocking token code.
contract ForkHarvestReward {
    address public immutable vault;
    address public immutable underlying;
    uint256 public reward = 1e6;
    constructor(address v, address token) { vault = v; underlying = token; }
    function isPushMode() external pure returns (bool) { return false; }
    function totalAssets() external pure returns (uint256) { return 0; }
    function harvestableProfit() external view returns (uint256) { return reward; }
    function harvest(address receiver) external returns (uint256 amount) {
        require(msg.sender == vault, "vault");
        amount = reward;
        reward = 0;
        require(IERC20(underlying).transfer(receiver, amount), "transfer");
    }
}

/// @dev Opt-in RPC fork. All registration/funding/role operations are local fork mutations.
/// Core, router and native USDC runtime code is unchanged during the tested calls.
contract RouterHarvestForkTest is UsdcMultiLendingVaultTestBase {
    bool runFork;
    bytes32 coreCodeHash;
    bytes32 routerCodeHash;
    bytes32 tokenCodeHash;

    function setUp() public override {
        runFork = vm.envOr("RUN_ROUTER_HARVEST_FORK", false);
        if (!runFork) return;
        vm.createSelectFork(vm.envString("ROUTER_HARVEST_RPC"), vm.envUint("ROUTER_HARVEST_BLOCK"));
        core = 0x5e0cdb76487BD96Ff069Ef7F78eaDF5b5909C8cb;
        router = 0x37847D2e12892e3298DEE695e7E971fba0Ca3e24;
        coreCodeHash = core.codehash;
        routerCodeHash = router.codehash;
        bytes memory nativeTokenCode = ARBITRUM_USDC.code;
        tokenCodeHash = ARBITRUM_USDC.codehash;
        super.setUp();
        // The common deployment fixture temporarily installs mock token code;
        // restore native USDC before any integration operation or funding.
        vm.etch(ARBITRUM_USDC, nativeTokenCode);
        StrategyRouter liveRouter = StrategyRouter(router);
        address governor = liveRouter.owner();
        vm.prank(governor);
        uint256 eta = liveRouter.proposeStrategyAllowlist(address(vault));
        vm.warp(eta);
        vm.startPrank(governor);
        liveRouter.executeStrategyAllowlist(address(vault));
        // Isolate the new strategy in this fork only. This is NOT a migration recipe:
        // production must drain and reconcile before disabling old strategies.
        IStrategyRouter.StrategyInfo[] memory old = liveRouter.list();
        for (uint256 i; i < old.length; ++i) liveRouter.toggle(old[i].strat, false);
        liveRouter.register(address(vault), 100, 10000);
        vm.stopPrank();
    }

    function test_deployedRouterHarvestAndRecallWithUnchangedCoreCode() public {
        if (!runFork) { vm.skip(true); return; }
        ForkHarvestReward adapter = new ForkHarvestReward(address(vault), ARBITRUM_USDC);
        vm.startPrank(admin);
        StrategySettingsModule(address(vault)).whitelistAdapter(address(adapter), true);
        vault.addAdapter(address(adapter));
        vault.toggleAdapter(address(adapter), true);
        vm.stopPrank();
        deal(ARBITRUM_USDC, address(adapter), 1e6);
        assertFalse(vault.hasRole(KEEPER_ROLE, router));
        vm.prank(core);
        (uint256 visited, int256 pnl, uint256 realized) = StrategyRouter(router).harvest(0);
        assertEq(visited, 1);
        assertEq(pnl, 1e6);
        assertEq(realized, 1e6);
        assertEq(IERC20(ARBITRUM_USDC).balanceOf(address(vault)), 1e6);
        uint256 before = IERC20(ARBITRUM_USDC).balanceOf(core);
        address governor = StrategyRouter(router).owner();
        vm.prank(governor);
        uint256 recalled = StrategyRouter(router).withdrawAllToCore(address(vault));
        assertEq(recalled, 1e6);
        assertEq(IERC20(ARBITRUM_USDC).balanceOf(core), before + 1e6);
        assertEq(core.codehash, coreCodeHash);
        assertEq(router.codehash, routerCodeHash);
        assertEq(ARBITRUM_USDC.codehash, tokenCodeHash);
    }
}
