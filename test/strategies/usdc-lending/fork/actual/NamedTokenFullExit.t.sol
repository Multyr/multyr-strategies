// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EthereumNativeFeeFullExitBase} from "./EthereumNativeFeeFullExit.t.sol";
import {FullUserExitE2EBase} from "./FullUserExitE2E.t.sol";
import {LendingAssetConfig} from "@multyr-strategies/strategies/usdc-lending/config/LendingAssetConfig.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// Actual holder funding, original economic/risk settings and unchanged Core
/// lock/cap policy. Closed protocol counterfactual across canonical headers;
/// no historical earned-return or deployment approval is claimed.
contract EthereumNamedTokenFullExitTest is EthereumNativeFeeFullExitBase {
    using SafeERC20 for IERC20Metadata;
    bool private useWstEth;
    address private selectedFeed;

    function test_nativeFeeFullExit_wsteth() public { useWstEth=true; _fullExitScenario(false); }
    function test_nativeFeeFullExit_rlusd() public { _fullExitScenario(false); }

    function _configureFullExitMarket(bool) internal override {
        market=LendingAssetConfig.Market(1,
            useWstEth?0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0:0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD,
            18,0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2,
            useWstEth?0x0B925eD163218f6662a35e0f0371Ac234f9E9371:0xFa82580c16A31D0c1bC632A36F82e83EfEF3Eec0);
        selectedFeed=useWstEth?_new("WstEthUsdPriceFeed.sol:WstEthUsdPriceFeed",
            abi.encode(market.asset,0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8)):
            0x26C46B7aD0012cA71F2298ada567dC9Af14E7f2A;
    }

    function _assetFeed() internal view override returns(address){ return selectedFeed; }

    function _fundFullExit(bool) internal override {
        // These EOAs hold actual tokens at setupBlock26165000 (not merely today).
        address holder=useWstEth?0x41d16Cb3c7c770b71C950c1Ea26eeeD0bE7A0562:
            0x76686a450114F3E5285D8F276e9033B3cb129EBE;
        assertEq(holder.code.length,0,"actual EOA funding");
        IERC20Metadata token=IERC20Metadata(market.asset);
        uint256 funding=Math.mulDiv(3000e18,10**market.decimals,
            oracle.getQuoteFresh(market.asset).price,Math.Rounding.Up);
        uint256 supply=token.totalSupply();
        uint256 beforeHolder=token.balanceOf(holder);
        uint256 beforeThis=token.balanceOf(address(this));
        assertGe(beforeHolder,funding,"actual historical holder funding");
        vm.prank(holder);token.safeTransfer(address(this),funding);
        assertEq(token.balanceOf(holder),beforeHolder-funding);
        assertEq(token.balanceOf(address(this))-beforeThis,funding);
        assertEq(token.totalSupply(),supply,"no synthetic funding");
        emit RealFunding(chain,market.asset,holder,beforeHolder,funding,token.balanceOf(holder));
    }
}

/// Forge cannot execute Nitro0x6c natively. This proves the actual USDT0 Core
/// lifecycle; genuine Nitro gas/economic quotes are a separate eth_simulateV1 gate.
contract ArbitrumUsdt0FullExitTest is FullUserExitE2EBase {
    function test_actualArbitrumUsdt0FullExit() public { _fullExitScenario(false); }
    function _rpc() internal pure override returns(string memory){return "https://arbitrum-one.public.blastapi.io";}
    function _fullExitChain() internal pure override returns(uint256){return 42161;}
    function _fullExitInitialBlock() internal pure override returns(uint256){return 513000000;}
    function _fullExitSetupBlock() internal pure override returns(uint256){return 513800000;}
    function _fullExitPhaseBlock(uint8 phase) internal pure override returns(uint256){
        if(phase==0)return 513802000;
        if(phase==1)return 514200000;
        if(phase==2)return 517000000;
        require(phase==3,"unknown exit phase");return 520000000;
    }
    function _configureFullExitMarket(bool) internal override {
        market=LendingAssetConfig.Market(42161,0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9,6,
            0x794a61358D6845594F94dc1DB02A252b5b4814aD,0x6ab707Aca953eDAeFBc4fD23bA73294241490620);
    }
    function _assetFeed() internal pure override returns(address){return 0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7;}
}
