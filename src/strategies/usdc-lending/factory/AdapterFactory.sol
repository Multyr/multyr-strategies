// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title AdapterFactory
/// @notice Deterministic CREATE2 deploy + atomic initialize for V10 adapters.
/// @dev Eliminates the front-run window between deploy and initialize by
///      bundling both into a single transaction with caller-defined salt.
///      All adapters deployed via this factory are byte-identical across
///      chains; only the factory itself is chain-specific (admin = chain
///      governance multisig).
contract AdapterFactory is AccessControl {
    bytes32 public constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");

    event AdapterDeployed(
        address indexed adapter,
        address indexed initiator,
        bytes32 salt,
        bytes32 codehash
    );

    error InitializeReverted(address adapter, bytes data);
    error AlreadyDeployed(address expected);
    error AddressMismatch(address expected, address actual);
    error ZeroAdmin();

    constructor(address admin_) {
        if (admin_ == address(0)) revert ZeroAdmin();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(DEPLOYER_ROLE, admin_);
    }

    /// @notice Atomic CREATE2 deploy + initialize.
    /// @param creationCode Bytecode (concat constructor+runtime) of target.
    ///        Constructor MUST call _disableInitializers() and accept ZERO args.
    /// @param salt CREATE2 salt for deterministic address derivation.
    /// @param initData ABI-encoded call to target's initialize() function.
    /// @return adapter The deployed adapter address.
    function deployAndInit(
        bytes calldata creationCode,
        bytes32 salt,
        bytes calldata initData
    ) external onlyRole(DEPLOYER_ROLE) returns (address adapter) {
        address expected = computeAddress(creationCode, salt);
        if (expected.code.length != 0) revert AlreadyDeployed(expected);

        bytes memory code = creationCode;
        assembly {
            adapter := create2(0, add(code, 0x20), mload(code), salt)
            if iszero(adapter) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
        if (adapter != expected) revert AddressMismatch(expected, adapter);

        (bool ok, bytes memory ret) = adapter.call(initData);
        if (!ok) revert InitializeReverted(adapter, ret);

        emit AdapterDeployed(adapter, msg.sender, salt, adapter.codehash);
    }

    /// @notice Deterministic CREATE2 address computation.
    /// @dev Same factory + salt + creationCode = same address across all EVM chains.
    function computeAddress(
        bytes calldata creationCode,
        bytes32 salt
    ) public view returns (address) {
        bytes32 codeHash = keccak256(creationCode);
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            codeHash
        )))));
    }
}
