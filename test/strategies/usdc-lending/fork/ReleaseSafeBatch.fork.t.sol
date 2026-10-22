// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test, console2} from "forge-std/Test.sol";

interface IReleaseRouter {
    function isStrategyEnabled(address) external view returns(bool);
    function strategyAllowlistDelay() external view returns(uint256);
}
interface IReleaseStrategy {
    function totalAssets() external view returns(uint256);
    function targetIdleBufferBps() external view returns(uint16);
    function rebalanceGasEstimator() external view returns(address);
}
/// Replay the exact user-facing files against deployed contracts, never broadcast.
contract ReleaseSafeBatchTest is Test {
    address constant GOV=0x70ef444799D6FBbE0865bA598Bee6795e064a326;
    address constant OLD=0xa9E676D15976A1332905238ca609Dff9A484Efe0;
    address constant ROUTER=0x37847D2e12892e3298DEE695e7E971fba0Ca3e24;
    string constant DIR="deployments/ema-first-20261023/";
    function test_exactSafeBatches() public {
        if (!vm.envOr("RUN_RELEASE_SAFE_REHEARSAL",false)) {vm.skip(true);return;}
        vm.createSelectFork(vm.envString("REHEARSAL_RPC"),vm.envUint("REHEARSAL_BLOCK"));
        vm.mockCall(address(0x6c),abi.encodeWithSignature("getPricesInWei()"),vm.envBytes("REHEARSAL_FEES"));
        string memory book=vm.readFile(string.concat(DIR,"addresses.json"));
        address fresh=vm.parseJsonAddress(book,".strategy");
        assertFalse(IReleaseRouter(ROUTER).isStrategyEnabled(fresh));
        _batch("01-propose-allowlist.safe.json");
        vm.warp(block.timestamp+IReleaseRouter(ROUTER).strategyAllowlistDelay()+1);
        _batch("02-migrate.safe.json");
        assertFalse(IReleaseRouter(ROUTER).isStrategyEnabled(OLD));
        assertTrue(IReleaseRouter(ROUTER).isStrategyEnabled(fresh));
        assertLe(IReleaseStrategy(OLD).totalAssets(),100);
        assertEq(IReleaseStrategy(fresh).targetIdleBufferBps(),1000);
        assertEq(IReleaseStrategy(fresh).rebalanceGasEstimator(),vm.parseJsonAddress(book,".rebalanceGasEstimator"));
        console2.log("Exact deployed-address Safe batches passed");
    }
    function _batch(string memory name) internal {
        string memory j=vm.readFile(string.concat(DIR,name));
        assertEq(vm.parseJsonAddress(j,".meta.createdFromSafeAddress"),GOV);
        uint256 n=vm.parseJsonUint(vm.readFile(string.concat(DIR,"batch-counts.json")),string.concat(".",keccak256(bytes(name))==keccak256(bytes("01-propose-allowlist.safe.json"))?"proposal":"migration"));
        for(uint256 i;i<n;i++){
            string memory p=string.concat(".transactions[",vm.toString(i),"]");
            address to=vm.parseJsonAddress(j,string.concat(p,".to"));
            bytes memory data=vm.parseJsonBytes(j,string.concat(p,".data"));
            vm.prank(GOV); (bool ok,bytes memory reason)=to.call(data);
            if(!ok){console2.log("Failed batch call",i);assembly("memory-safe"){revert(add(reason,32),mload(reason))}}
        }
    }
}
