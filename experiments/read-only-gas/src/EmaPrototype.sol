// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Prototype accounting primitive. Call ONLY after successful operations.
/// Failure/zero-result measurements must stay separate from successful samples.
library EmaPrototype {
    function next(uint64 previous, uint256 observed, uint16 alpha) internal pure returns (uint64) {
        require(alpha <= 10000 && observed <= type(uint64).max, "invalid sample");
        if (observed == 0) return previous;
        if (previous == 0) return uint64(observed);
        uint256 smoothing = alpha == 0 ? 2000 : alpha;
        return uint64((uint256(previous) * (10000 - smoothing) + observed * smoothing) / 10000);
    }
}
