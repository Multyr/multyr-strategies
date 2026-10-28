// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {EmaPrototype} from "../src/EmaPrototype.sol";

contract EmaTest is Test {
    function test_initializationAndDefaultAlpha() public pure {
        assertEq(EmaPrototype.next(0, 100000, 0), 100000);
        assertEq(EmaPrototype.next(100000, 200000, 0), 120000);
        assertEq(EmaPrototype.next(100000, 0, 2000), 100000);
    }

    function testFuzz_emaBounded(uint64 old, uint64 observed) public pure {
        uint64 n = EmaPrototype.next(old, observed, 2000);
        if (observed == 0) {
            assertEq(n, old);
            return;
        }
        if (old == 0) {
            assertEq(n, observed);
            return;
        }
        assertGe(n, old < observed ? old : observed);
        assertLe(n, old > observed ? old : observed);
    }
}
