// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMorphoV2IdleVault {
    function asset() external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function liquidityAdapter() external view returns (address);
    function canSendShares(address account) external view returns (bool);
    function canReceiveAssets(address account) external view returns (bool);
}

/// @notice Gate-checked immediate idle liquidity for Morpho V2's zero-max views.
/// @dev Conservative lower bound. Allocated funds and force-deallocation penalties
/// are excluded. This contract is stateless and never handles or approves tokens.
contract MorphoVaultV2LiquidityView {
    function withdrawableIdle(address asset, address market, address owner, address receiver)
        external view returns (uint256)
    {
        IMorphoV2IdleVault v = IMorphoV2IdleVault(market);
        try v.asset() returns (address actual) { if (actual != asset) return 0; }
        catch { return 0; }
        // These three V2-specific views distinguish its deliberate zero max from
        // V1's binding zero limit, and enforce the actual exit's account gates.
        try v.liquidityAdapter() returns (address) {} catch { return 0; }
        try v.canSendShares(owner) returns (bool allowed) { if (!allowed) return 0; }
        catch { return 0; }
        try v.canReceiveAssets(receiver) returns (bool allowed) { if (!allowed) return 0; }
        catch { return 0; }
        uint256 shares;
        try v.balanceOf(owner) returns (uint256 n) { shares = n; } catch { return 0; }
        if (shares == 0) return 0;
        uint256 assets;
        try v.convertToAssets(shares) returns (uint256 n) { assets = n; } catch { return 0; }
        try IERC20(asset).balanceOf(market) returns (uint256 cash) {
            return assets < cash ? assets : cash;
        } catch { return 0; }
    }
}
