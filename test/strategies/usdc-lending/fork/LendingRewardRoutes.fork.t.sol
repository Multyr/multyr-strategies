// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {RewardSwapHelper, ISwapRouterV3, IChainlinkFeed} from "../../../../src/strategies/usdc-lending/swap/RewardSwapHelper.sol";
import {LendingAssetConfig} from "../../../../src/strategies/usdc-lending/config/LendingAssetConfig.sol";

/// @dev Real feeds, real routers and real pools; only initial token funding is synthetic.
contract LendingRewardRoutesForkTest is Test {
    function test_arbitrumWethToUsdcPrimary() public { _swap(42161, false, false); }
    function test_arbitrumUsdcToWethPrimary() public { _swap(42161, true, false); }
    function test_arbitrumWethToUsdcCamelotFallback() public { _swap(42161, false, true); }
    function test_arbitrumUsdcToWethCamelotFallback() public { _swap(42161, true, true); }
    function test_baseWethToUsdcPrimary() public { _swap(8453, false, false); }
    function test_baseUsdcToWethPrimary() public { _swap(8453, true, false); }

    function _swap(uint256 chainId, bool outputWeth, bool forceFallback) internal {
        if (chainId == 42161) vm.createSelectFork(vm.envOr("LENDING_ARBITRUM_RPC", string("https://arbitrum-one.public.blastapi.io")), 520094008);
        else vm.createSelectFork("https://mainnet.base.org", 53345555);
        address output = LendingAssetConfig.get(chainId, outputWeth).asset;
        address reward = LendingAssetConfig.get(chainId, !outputWeth).asset;
        address ethUsd = chainId == 42161 ? 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612 : 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
        address usdcUsd = chainId == 42161 ? 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3 : 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
        address sequencer = chainId == 42161 ? 0xFdB631F5EE196F0ed6FAa767959853A9F217697D : 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
        address uni = chainId == 42161 ? 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45 : 0x2626664c2603336E57B271c5C0b26F421741e481;
        address camelot = chainId == 42161 ? 0x1F721E2E82F6676FCE4eA07A5958cF098D339e18 : address(0);
        RewardSwapHelper helper = new RewardSwapHelper();
        helper.initializeAsset(output, address(this), uni, camelot);
        helper.setOutputAssetOracle(outputWeth ? ethUsd : usdcUsd, 90_000);
        helper.setSequencerUptimeFeed(sequencer);
        address rewardFeed = outputWeth ? usdcUsd : ethUsd;
        helper.setRewardConfig(reward, rewardFeed, IChainlinkFeed(rewardFeed).decimals(),
            IERC20Metadata(reward).decimals(), 90_000, abi.encodePacked(reward, uint24(500), output),
            camelot == address(0) ? bytes("") : abi.encodePacked(reward, output), 500);
        helper.grantRole(helper.KEEPER_ROLE(), address(this));
        uint256 amount = outputWeth ? 100e6 : 0.01e18;
        deal(reward, address(this), amount);
        IERC20Metadata(reward).approve(address(helper), amount);
        if (forceFallback) vm.mockCallRevert(uni, abi.encodeWithSelector(ISwapRouterV3.exactInput.selector), bytes("forced-primary-failure"));
        address receiver = address(0xCAFE);
        uint256 before = IERC20Metadata(output).balanceOf(receiver);
        uint256 minimum = helper.previewExpectedOut(reward, amount) * 9500 / 10000;
        assertTrue(helper.canSwap(reward));
        uint256 received = helper.swapToAsset(reward, amount, receiver);
        assertGe(received, minimum);
        assertGt(received, 0);
        assertEq(IERC20Metadata(output).balanceOf(receiver) - before, received);
        assertEq(IERC20Metadata(output).balanceOf(address(helper)), 0);
        assertEq(IERC20Metadata(reward).balanceOf(address(helper)), 0);
    }
}
