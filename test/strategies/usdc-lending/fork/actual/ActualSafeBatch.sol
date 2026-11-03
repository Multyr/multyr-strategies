// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

interface IActualSafe {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function nonce() external view returns (uint256);
    function approveHash(bytes32 hashToApprove) external;
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 _nonce
    ) external view returns (bytes32);
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        bytes memory signatures
    ) external returns (bool);
}

/// @dev Local fork-only Safe batch helper. Never broadcasts transactions. Owner impersonation
///      and approveHash calls execute against canonical Safe bytecode on the local fork only.
abstract contract ActualSafeBatchReference is Test {
    // Canonical MultiSendCallOnly v1.3.0 — codehash independently matched at Arbitrum block 520384312
    // against safe-deployments v1.3.0 manifest (chainId 42161).
    address internal constant MULTISEND_CALL_ONLY =
        0x40A2aCCbd92BCA938b02010E17A5b8929b49130D;
    bytes32 internal constant MULTISEND_CODEHASH =
        0xa9865ac2d9c7a1591619b188c4d88167b50df6cc0c5327fcbd1c8c75f7c066ad;

    event ActualSafeBatchExecuted(
        address indexed governance,
        uint256 nonce,
        bytes32 txHash,
        uint256 threshold,
        address[] targets,
        bytes[] calls,
        bytes fullExecCalldata,
        uint256 executionGas
    );

    function _executeActualSafeBatch(
        address governance,
        address[] memory targets,
        bytes[] memory calls
    ) internal returns (uint256 executionGas) {
        require(
            targets.length > 0 && targets.length == calls.length,
            "ActualSafeBatch: empty or mismatched arrays"
        );

        // Verify canonical MultiSendCallOnly is deployed at the expected address on this fork.
        require(
            MULTISEND_CALL_ONLY.codehash == MULTISEND_CODEHASH,
            "ActualSafeBatch: unexpected MultiSendCallOnly codehash"
        );

        // Encode each sub-transaction as a CALL (operation = 0).
        bytes memory packed;
        for (uint256 i = 0; i < targets.length; i++) {
            packed = abi.encodePacked(
                packed,
                uint8(0),
                targets[i],
                uint256(0),
                uint256(calls[i].length),
                calls[i]
            );
        }

        bytes memory payload = abi.encodeWithSignature("multiSend(bytes)", packed);

        IActualSafe safe = IActualSafe(governance);

        // Fetch live Safe state from the fork — no hardcoded owner addresses.
        address[] memory owners = safe.getOwners();
        uint256 threshold = safe.getThreshold();
        uint256 priorNonce = safe.nonce();

        require(
            threshold > 0 && threshold <= owners.length,
            "ActualSafeBatch: invalid Safe threshold"
        );

        // Insertion-sort owners ascending by uint160 — Safe verifies signatures in ascending order.
        for (uint256 i = 1; i < owners.length; i++) {
            address key = owners[i];
            uint256 j = i;
            while (j > 0 && uint160(owners[j - 1]) > uint160(key)) {
                owners[j] = owners[j - 1];
                j--;
            }
            owners[j] = key;
        }

        // Compute the canonical Safe transaction hash via the actual on-fork Safe contract.
        bytes32 txHash = safe.getTransactionHash(
            MULTISEND_CALL_ONLY,
            0,
            payload,
            1,          // DelegateCall — required for MultiSend
            0,
            0,
            0,
            address(0),
            address(0),
            priorNonce
        );

        // For each of the `threshold` lowest-addressed owners: impersonate locally, call
        // approveHash against the actual Safe bytecode on the fork, then append the
        // 65-byte pre-approved-hash sentinel (r = owner, s = 0, v = 1).
        bytes memory signatures;
        for (uint256 i = 0; i < threshold; i++) {
            address owner = owners[i];
            vm.prank(owner);
            safe.approveHash(txHash);
            signatures = abi.encodePacked(
                signatures,
                bytes32(uint256(uint160(owner))),
                bytes32(0),
                uint8(1)
            );
        }

        bytes memory fullExecCalldata = abi.encodeCall(
            IActualSafe.execTransaction,
            (
                MULTISEND_CALL_ONLY,
                0,
                payload,
                1,
                0,
                0,
                0,
                address(0),
                address(0),
                signatures
            )
        );

        // gasleft() is not transaction receipt gas; zero-refund configuration (gasPrice=0,
        // gasToken=address(0)) does not prove production gas economics.
        uint256 gasBefore = gasleft();
        bool success = safe.execTransaction(
            MULTISEND_CALL_ONLY,
            0,
            payload,
            1,
            0,
            0,
            0,
            address(0),
            address(0),
            signatures
        );
        executionGas = gasBefore - gasleft();

        require(success, "ActualSafeBatch: execTransaction returned false");
        require(
            safe.nonce() == priorNonce + 1,
            "ActualSafeBatch: Safe nonce did not advance after execution"
        );

        // Event data is proof-of-execution for this local fork run only.
        // fullExecCalldata is NOT a broadcastable production batch: candidate addresses are
        // local fork deployments and approvals occur only within this fork context.
        emit ActualSafeBatchExecuted(
            governance,
            priorNonce,
            txHash,
            threshold,
            targets,
            calls,
            fullExecCalldata,
            executionGas
        );
    }
}
