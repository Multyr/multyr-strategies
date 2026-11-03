// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {CometUsdcMultiMarketAdapter} from "@multyr-strategies/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol";
import {ProtocolRegistry} from "@multyr-strategies/strategies/usdc-lending/registry/ProtocolRegistry.sol";

interface ICometPublishedTotals {
    function baseToken() external view returns (address);
    function baseIndexScale() external view returns (uint64);
    function totalSupply() external view returns (uint256);
    function totalsBasic() external view returns (uint64, uint64, uint64, uint64, uint104, uint104, uint40, uint8);
}

contract CometPublishedTotalsForkTest is Test {
    function test_actualUsdcTotalsMatchProtocolSupply() public { _check(0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf, false); }
    function test_actualWethTotalsMatchProtocolSupply() public { _check(0x6f7D514bbD4aFf3BcD1140B7344b32f063dEe486, true); }

    function _check(address market, bool exceeds64) internal {
        vm.createSelectFork("https://arbitrum-one.public.blastapi.io", 520094008);
        ICometPublishedTotals comet = ICometPublishedTotals(market);
        address asset = comet.baseToken();
        (uint64 index,,,, uint104 principal,,,) = comet.totalsBasic();
        if (exceeds64) assertGt(uint256(principal), type(uint64).max);
        uint256 storedIndexAssets = uint256(principal) * uint256(index) / uint256(comet.baseIndexScale());
        uint256 expected = comet.totalSupply();
        assertGe(expected, storedIndexAssets, "canonical supply projects positive interest since stored index");
        assertGt(expected, IERC20Metadata(asset).balanceOf(market), "published supply includes borrowed assets");
        CometUsdcMultiMarketAdapter adapter = CometUsdcMultiMarketAdapter(payable(deployCode(
            "CometUsdcMultiMarket.sol:CometUsdcMultiMarketAdapter")));
        ProtocolRegistry registry = ProtocolRegistry(deployCode("ProtocolRegistry.sol:ProtocolRegistry", abi.encode(address(this))));
        registry.addVault(ProtocolRegistry.ProtocolType.COMPOUND_V3, market, "Actual Comet market", 10000, type(uint256).max);
        adapter.initialize(asset, address(this), address(this), type(uint256).max, address(registry));
        assertEq(adapter.externalMarketTVL(), expected, "TVL must match canonical accrued supply, not stale index or cash");
    }
}
