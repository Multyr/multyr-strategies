// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
/// @notice Historical simple annualized PPS return, in basis points (not compounded APY).
library PpsRateLib {
    // Callers sample 1e24 shares to avoid six-decimal PPS rounding dominating short windows.
    uint256 internal constant MIN_WINDOW = 1 hours;
    uint256 internal constant MAX_AGE = 2 days;
    struct Sample { uint256 pps; uint64 ts; uint16 rate; uint64 rateTs; }
    function read(Sample storage s, uint256 pps) internal view returns (uint16) {
        if (s.ts == 0 || s.pps == 0 || pps < s.pps) return 0;
        uint256 dt = block.timestamp - s.ts;
        if (dt > MAX_AGE) return 0;
        if (dt >= MIN_WINDOW) {
            uint256 bps = Math.mulDiv(pps - s.pps, 365 days * 10_000, s.pps) / dt;
            return bps > type(uint16).max ? type(uint16).max : uint16(bps);
        }
        return s.rateTs != 0 && block.timestamp - s.rateTs <= MAX_AGE ? s.rate : 0;
    }
    function update(Sample storage s, uint256 pps) internal {
        // Repeated pokes cannot postpone the next measurement indefinitely.
        if (s.ts != 0 && pps >= s.pps && block.timestamp - s.ts < MIN_WINDOW) return;
        uint16 rate = read(s, pps);
        s.pps = pps;
        s.ts = uint64(block.timestamp);
        s.rate = rate;
        s.rateTs = uint64(block.timestamp);
    }
}
