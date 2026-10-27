// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILiveAdapter {
    function deposit(uint256) external;
    function withdraw(uint256, address) external returns (uint256);
    function isPushMode() external view returns (bool);
}

/// @dev Run explicitly on an archive fork; never broadcasts or signs transactions.
contract AdapterForkTest is Test {
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant STRATEGY = 0x7bF0f446BB20b54597E66a602cB94D0F231D24E2;

    function test_liveAdaptersGasMatrix() public {
        if (!vm.envOr("RUN_ADAPTER_FORK", false)) return;
        address[5] memory adapters = [
            0x744c6a46bB4F1287cEB9Bd8Ff8693AB0B7503de7,
            0x36ad387092EDe0ccB8cA663DC216D0320D19b677,
            0xC994B1936246899d2DD6134F543715A336ff81dd,
            0x9Fd8E87220a61103Db264b583A2f0caAEc4B6019,
            0x2f988C3Ee375e1Ac25d10ee018FBC9FAfD857B7f
        ];
        uint256[3] memory sizes = [uint256(10e6), 100e6, 10000e6];
        for (uint256 i; i < 5; i++) {
            for (uint256 j; j < 3; j++) {
                uint256 checkpoint = vm.snapshotState();
                address a = adapters[i];
                uint256 amount = sizes[j];
                deal(USDC, STRATEGY, amount);
                bool push = ILiveAdapter(a).isPushMode();
                vm.startPrank(STRATEGY);
                uint256 before = gasleft();
                if (push) IERC20(USDC).transfer(a, amount);
                else IERC20(USDC).approve(a, amount);
                (bool ok,) = a.call(abi.encodeCall(ILiveAdapter.deposit, (amount)));
                if (!push) IERC20(USDC).approve(a, 0);
                uint256 depositGas = before - gasleft();
                emit log_named_address("adapter", a);
                emit log_named_uint("amount USDC6", amount);
                emit log_named_uint("deposit success", ok ? 1 : 0);
                emit log_named_uint("measured deposit EVM gas", depositGas);
                if (ok) {
                    before = gasleft();
                    (bool withdrew, bytes memory ret) =
                        a.call(abi.encodeCall(ILiveAdapter.withdraw, (amount, STRATEGY)));
                    uint256 withdrawGas = before - gasleft();
                    emit log_named_uint("withdraw success", withdrew ? 1 : 0);
                    emit log_named_uint("measured withdraw EVM gas", withdrawGas);
                    if (withdrew) assertLe(abi.decode(ret, (uint256)), amount);
                }
                vm.stopPrank();
                assertTrue(vm.revertToState(checkpoint));
            }
        }
    }
}
