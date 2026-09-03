// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    ProtocolRegistry
} from "@multyr-strategies/strategies/usdc-lending/registry/ProtocolRegistry.sol";

contract RegistryVaultMock {}

contract ProtocolRegistryTest is Test {
    ProtocolRegistry internal registry;
    RegistryVaultMock internal vault;
    address internal governance = makeAddr("governanceSafe");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        registry = new ProtocolRegistry(governance);
        vault = new RegistryVaultMock();
    }

    function test_ownerIsGovernance() public view {
        assertEq(registry.owner(), governance);
    }

    function test_onlyOwnerCanMutate() public {
        vm.prank(attacker);
        vm.expectRevert("Ownable: caller is not the owner");
        registry.addVault(
            ProtocolRegistry.ProtocolType.MORPHO, address(vault), "USDC market", 300, 1_000_000e6
        );
    }

    function test_addDisableEnableUpdateAndRemove() public {
        ProtocolRegistry.ProtocolType protocol = ProtocolRegistry.ProtocolType.MORPHO;
        vm.startPrank(governance);
        registry.addVault(protocol, address(vault), "USDC market", 300, 1_000_000e6);
        assertEq(registry.getVaultCount(protocol), 1);
        assertTrue(registry.isEnabled(protocol, address(vault)));
        assertEq(registry.getEnabledVaults(protocol).length, 1);

        registry.setVaultEnabled(protocol, address(vault), false);
        assertFalse(registry.isEnabled(protocol, address(vault)));
        assertEq(registry.getEnabledVaults(protocol).length, 0);

        registry.updateMetadata(protocol, address(vault), "updated", 450, 2_000_000e6);
        ProtocolRegistry.VaultMetadata memory metadata =
            registry.getMetadata(protocol, address(vault));
        assertEq(metadata.name, "updated");
        assertEq(metadata.riskScoreBps, 450);
        assertEq(metadata.maxCapacity, 2_000_000e6);
        assertTrue(metadata.verified);

        registry.setVaultEnabled(protocol, address(vault), true);
        registry.removeVault(protocol, address(vault));
        vm.stopPrank();

        assertEq(registry.getVaultCount(protocol), 0);
        assertFalse(registry.isEnabled(protocol, address(vault)));
        assertFalse(registry.getMetadata(protocol, address(vault)).verified);
    }

    function test_rejectsEOAVaultDuplicateAndInvalidMetadata() public {
        ProtocolRegistry.ProtocolType protocol = ProtocolRegistry.ProtocolType.EULER_V2;

        vm.startPrank(governance);
        vm.expectRevert(ProtocolRegistry.InvalidVault.selector);
        registry.addVault(protocol, attacker, "EOA", 100, 1e6);

        vm.expectRevert(ProtocolRegistry.InvalidRiskScore.selector);
        registry.addVault(protocol, address(vault), "risk", 10_001, 1e6);

        vm.expectRevert(ProtocolRegistry.InvalidCapacity.selector);
        registry.addVault(protocol, address(vault), "capacity", 100, 0);

        registry.addVault(protocol, address(vault), "valid", 100, 1e6);
        vm.expectRevert(ProtocolRegistry.VaultAlreadyAdded.selector);
        registry.addVault(protocol, address(vault), "duplicate", 100, 1e6);
        vm.stopPrank();
    }
}
