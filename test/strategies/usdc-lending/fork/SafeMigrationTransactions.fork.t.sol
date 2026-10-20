// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test, console2} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
interface ISafeMigrationRouter {
    struct Allocation { address strat; uint256 amount; bool fundsAlreadyTransferred; }
    function pendingStrategyAllowlist(address) external view returns (uint256);
    function isStrategyEnabled(address) external view returns (bool);
    function planDeposit(uint256) external view returns (Allocation[] memory);
}
interface ISafeMigrationNav { function totalAssets() external view returns(uint256); }
interface ISafeMigrationToken { function balanceOf(address) external view returns(uint256); }

/// @notice Executes the exact unsigned Safe calldata against the deployed contracts.
contract SafeMigrationTransactionsTest is Test {
    using stdJson for string;
    address constant GOV=0x70ef444799D6FBbE0865bA598Bee6795e064a326;
    address constant CORE=0x5e0cdb76487BD96Ff069Ef7F78eaDF5b5909C8cb;
    address constant OLD=0x7bF0f446BB20b54597E66a602cB94D0F231D24E2;
    address constant ROUTER=0x37847D2e12892e3298DEE695e7E971fba0Ca3e24;
    address constant USDC=0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    string constant DIR="deployments/replacement-20261017/";
    function _batch(string memory name, uint256 count) internal {
        string memory j=vm.readFile(string.concat(DIR,name));
        for(uint256 i; i<count; ++i) {
            string memory key=string.concat(".transactions[",vm.toString(i),"]");
            address to=j.readAddress(string.concat(key,".to"));
            bytes memory data=j.readBytes(string.concat(key,".data"));
            require(keccak256(bytes(j.readString(string.concat(key,".value"))))==keccak256("0"),"nonzero value");
            vm.prank(GOV);
            (bool ok,bytes memory reason)=to.call(data);
            if(!ok) assembly { revert(add(reason,32),mload(reason)) }
        }
    }
    function test_exactSafeMigrationBatches() public {
        if(!vm.envOr("RUN_SAFE_MIGRATION",false)) { vm.skip(true); return; }
        vm.createSelectFork(vm.envString("REHEARSAL_RPC"));
        address fresh=vm.readFile(string.concat(DIR,"addresses.json")).readAddress(".strategy");
        uint256 oldNav=ISafeMigrationNav(OLD).totalAssets();
        uint256 coreBalance=ISafeMigrationToken(USDC).balanceOf(CORE);
        bytes32 coreHash=CORE.codehash;
        bytes32 routerHash=ROUTER.codehash;
        _batch("01-propose-allowlist.safe.json",1);
        // Read the live delay rather than assuming a deployment-time constant.
        (bool ok,bytes memory data)=ROUTER.staticcall(abi.encodeWithSignature("strategyAllowlistDelay()"));
        require(ok); vm.warp(block.timestamp+abi.decode(data,(uint256))+1);
        _batch("02-migrate.safe.json",18);
        assertFalse(ISafeMigrationRouter(ROUTER).isStrategyEnabled(OLD));
        assertTrue(ISafeMigrationRouter(ROUTER).isStrategyEnabled(fresh));
        ISafeMigrationRouter.Allocation[] memory plan=ISafeMigrationRouter(ROUTER).planDeposit(1e6);
        bool routed;
        for(uint256 i; i<plan.length; ++i) if(plan[i].strat==fresh && plan[i].amount>0) routed=true;
        assertTrue(routed,"existing Router cannot route to replacement");
        assertLe(ISafeMigrationNav(OLD).totalAssets(),100);
        assertGe(ISafeMigrationToken(USDC).balanceOf(CORE)+100,coreBalance+oldNav);
        assertEq(CORE.codehash,coreHash);assertEq(ROUTER.codehash,routerHash);
        console2.log("Old NAV recalled to unchanged Core",oldNav);
    }
}
