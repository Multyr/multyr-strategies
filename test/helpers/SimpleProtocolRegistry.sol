// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title SimpleProtocolRegistry
 * @notice Simplified registry for testing WITHOUT timelock
 * @dev This is ONLY for tests - production uses ProtocolRegistryWithTimelock
 */
contract SimpleProtocolRegistry {
    // ===== Protocol Types =====
    enum ProtocolType {
        AAVE_V3,
        EULER_V2,
        MORPHO,
        COMPOUND_V3,
        DOLOMITE,
        GAINS,
        SILO_V2
    }

    // ===== Storage =====

    // Vaults per protocol
    mapping(ProtocolType => address[]) private vaultList;
    mapping(ProtocolType => mapping(address => bool)) public isVaultEnabled;

    // Metadata
    struct VaultMetadata {
        string name;
        uint16 riskScoreBps;
        uint256 maxCapacity;
        bool verified;
    }
    mapping(ProtocolType => mapping(address => VaultMetadata)) public vaultMetadata;

    // ===== Events =====
    event VaultAdded(ProtocolType indexed protocol, address indexed vault, string name);
    event VaultRemoved(ProtocolType indexed protocol, address indexed vault);
    event VaultEnabled(ProtocolType indexed protocol, address indexed vault);
    event VaultDisabled(ProtocolType indexed protocol, address indexed vault);

    // ===== Core Functions =====

    /**
     * @notice Add vault to registry
     * @dev No timelock for testing - instant execution
     */
    function addVault(
        ProtocolType protocol,
        address vault,
        string memory name,
        uint16 riskScoreBps,
        uint256 maxCapacity
    ) external {
        require(vault != address(0), "zero address");
        require(!isVaultEnabled[protocol][vault], "already added");

        vaultList[protocol].push(vault);
        isVaultEnabled[protocol][vault] = true;

        vaultMetadata[protocol][vault] = VaultMetadata({
            name: name, riskScoreBps: riskScoreBps, maxCapacity: maxCapacity, verified: true
        });

        emit VaultAdded(protocol, vault, name);
    }

    /**
     * @notice Remove vault from registry
     */
    function removeVault(ProtocolType protocol, address vault) external {
        require(isVaultEnabled[protocol][vault], "not enabled");

        isVaultEnabled[protocol][vault] = false;

        // Remove from array
        address[] storage vaults = vaultList[protocol];
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i] == vault) {
                vaults[i] = vaults[vaults.length - 1];
                vaults.pop();
                break;
            }
        }

        delete vaultMetadata[protocol][vault];

        emit VaultRemoved(protocol, vault);
    }

    /**
     * @notice Enable/disable vault without removing
     */
    function setVaultEnabled(ProtocolType protocol, address vault, bool enabled) external {
        require(vaultMetadata[protocol][vault].verified, "vault not added");

        isVaultEnabled[protocol][vault] = enabled;

        if (enabled) {
            emit VaultEnabled(protocol, vault);
        } else {
            emit VaultDisabled(protocol, vault);
        }
    }

    /**
     * @notice Update vault metadata
     */
    function updateMetadata(
        ProtocolType protocol,
        address vault,
        string memory name,
        uint16 riskScoreBps,
        uint256 maxCapacity
    ) external {
        require(vaultMetadata[protocol][vault].verified, "vault not added");

        vaultMetadata[protocol][vault] = VaultMetadata({
            name: name, riskScoreBps: riskScoreBps, maxCapacity: maxCapacity, verified: true
        });
    }

    // ===== View Functions =====

    /**
     * @notice Get all enabled vaults for a protocol
     * @dev This is the main function adapters call
     */
    function getEnabledVaults(ProtocolType protocol)
        external
        view
        returns (address[] memory enabledVaults)
    {
        address[] storage allVaults = vaultList[protocol];
        uint256 enabledCount = 0;

        // Count enabled vaults
        for (uint256 i = 0; i < allVaults.length; i++) {
            if (isVaultEnabled[protocol][allVaults[i]]) {
                enabledCount++;
            }
        }

        // Build enabled array
        enabledVaults = new address[](enabledCount);
        uint256 index = 0;
        for (uint256 i = 0; i < allVaults.length; i++) {
            if (isVaultEnabled[protocol][allVaults[i]]) {
                enabledVaults[index] = allVaults[i];
                index++;
            }
        }

        return enabledVaults;
    }

    /**
     * @notice Get vault count for protocol
     */
    function getVaultCount(ProtocolType protocol) external view returns (uint256) {
        return vaultList[protocol].length;
    }

    /**
     * @notice Check if vault is enabled
     */
    function isEnabled(ProtocolType protocol, address vault) external view returns (bool) {
        return isVaultEnabled[protocol][vault];
    }

    /**
     * @notice Get vault metadata
     */
    function getMetadata(ProtocolType protocol, address vault)
        external
        view
        returns (VaultMetadata memory)
    {
        return vaultMetadata[protocol][vault];
    }
}
