// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ProtocolRegistry
/// @notice Governance-controlled allowlist of external lending markets.
/// @dev The enum order and read ABI intentionally match the registry interface
///      embedded in the registry-backed USDC lending adapters.
contract ProtocolRegistry is Ownable {
    enum ProtocolType {
        AAVE_V3,
        EULER_V2,
        MORPHO,
        COMPOUND_V3,
        DOLOMITE,
        GAINS,
        SILO_V2
    }

    struct VaultMetadata {
        string name;
        uint16 riskScoreBps;
        uint256 maxCapacity;
        bool verified;
    }

    mapping(ProtocolType => address[]) private vaultList;
    mapping(ProtocolType => mapping(address => bool)) public isVaultEnabled;
    mapping(ProtocolType => mapping(address => VaultMetadata)) public vaultMetadata;

    event VaultAdded(ProtocolType indexed protocol, address indexed vault, string name);
    event VaultRemoved(ProtocolType indexed protocol, address indexed vault);
    event VaultEnabled(ProtocolType indexed protocol, address indexed vault);
    event VaultDisabled(ProtocolType indexed protocol, address indexed vault);
    event VaultMetadataUpdated(
        ProtocolType indexed protocol,
        address indexed vault,
        string name,
        uint16 riskScoreBps,
        uint256 maxCapacity
    );

    error ZeroAddress();
    error InvalidVault();
    error InvalidRiskScore();
    error InvalidCapacity();
    error VaultAlreadyAdded();
    error VaultNotAdded();

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (initialOwner != msg.sender) _transferOwnership(initialOwner);
    }

    function addVault(
        ProtocolType protocol,
        address vault,
        string calldata name,
        uint16 riskScoreBps,
        uint256 maxCapacity
    ) external onlyOwner {
        if (vault == address(0)) revert ZeroAddress();
        if (vault.code.length == 0) revert InvalidVault();
        if (vaultMetadata[protocol][vault].verified) revert VaultAlreadyAdded();
        _validateMetadata(riskScoreBps, maxCapacity);

        vaultList[protocol].push(vault);
        isVaultEnabled[protocol][vault] = true;
        vaultMetadata[protocol][vault] = VaultMetadata({
            name: name, riskScoreBps: riskScoreBps, maxCapacity: maxCapacity, verified: true
        });

        emit VaultAdded(protocol, vault, name);
    }

    function removeVault(ProtocolType protocol, address vault) external onlyOwner {
        if (!vaultMetadata[protocol][vault].verified) revert VaultNotAdded();

        address[] storage vaults = vaultList[protocol];
        uint256 len = vaults.length;
        for (uint256 i = 0; i < len; ++i) {
            if (vaults[i] == vault) {
                vaults[i] = vaults[len - 1];
                vaults.pop();
                break;
            }
        }

        delete isVaultEnabled[protocol][vault];
        delete vaultMetadata[protocol][vault];
        emit VaultRemoved(protocol, vault);
    }

    function setVaultEnabled(ProtocolType protocol, address vault, bool enabled)
        external
        onlyOwner
    {
        if (!vaultMetadata[protocol][vault].verified) revert VaultNotAdded();
        isVaultEnabled[protocol][vault] = enabled;
        if (enabled) emit VaultEnabled(protocol, vault);
        else emit VaultDisabled(protocol, vault);
    }

    function updateMetadata(
        ProtocolType protocol,
        address vault,
        string calldata name,
        uint16 riskScoreBps,
        uint256 maxCapacity
    ) external onlyOwner {
        if (!vaultMetadata[protocol][vault].verified) revert VaultNotAdded();
        _validateMetadata(riskScoreBps, maxCapacity);

        vaultMetadata[protocol][vault] = VaultMetadata({
            name: name, riskScoreBps: riskScoreBps, maxCapacity: maxCapacity, verified: true
        });
        emit VaultMetadataUpdated(protocol, vault, name, riskScoreBps, maxCapacity);
    }

    function getEnabledVaults(ProtocolType protocol)
        external
        view
        returns (address[] memory enabledVaults)
    {
        address[] storage allVaults = vaultList[protocol];
        uint256 len = allVaults.length;
        uint256 enabledCount;
        for (uint256 i = 0; i < len; ++i) {
            if (isVaultEnabled[protocol][allVaults[i]]) ++enabledCount;
        }

        enabledVaults = new address[](enabledCount);
        uint256 index;
        for (uint256 i = 0; i < len; ++i) {
            address vault = allVaults[i];
            if (isVaultEnabled[protocol][vault]) enabledVaults[index++] = vault;
        }
    }

    function getVaultCount(ProtocolType protocol) external view returns (uint256) {
        return vaultList[protocol].length;
    }

    function isEnabled(ProtocolType protocol, address vault) external view returns (bool) {
        return isVaultEnabled[protocol][vault];
    }

    function getMetadata(ProtocolType protocol, address vault)
        external
        view
        returns (VaultMetadata memory)
    {
        return vaultMetadata[protocol][vault];
    }

    function _validateMetadata(uint16 riskScoreBps, uint256 maxCapacity) private pure {
        if (riskScoreBps > 10_000) revert InvalidRiskScore();
        if (maxCapacity == 0) revert InvalidCapacity();
    }
}
