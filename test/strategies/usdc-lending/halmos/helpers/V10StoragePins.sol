// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/// @title V10StoragePins — vm.store() helpers for V10 adapter storage layout.
/// @notice Provides per-adapter helpers that pin storage slots for Foundry tests
///         that need to bypass initialize() and directly assert on adapter state.
///
/// @dev V10 storage layout (verified via `forge inspect <Adapter> storageLayout`):
///
///   slot 0 : _roles         (AccessControl mapping)
///   slot 1 : _status        (ReentrancyGuard uint256)
///   slot 2 : _initialized (uint8, offset 0) | _initializing (bool, offset 1) | <first-address> (offset 2)  ← PACKED
///   slot 3+: remaining address fields, each sole occupant of their slot.
///
///   Slot 2 encoding (little-endian EVM packing, LSB = lowest offset):
///     bits  0-7   : _initialized  (uint8)  — must be 1 after init
///     bits  8-15  : _initializing (bool)   — must be 0 after init
///     bits 16-175 : first address field    — 20 bytes = 160 bits, shifted 16 bits
///
///   vm.store() value for slot 2 when setting addr with _initialized=1:
///     bytes32((uint256(uint160(addr)) << 16) | 1)
///
///   vm.store() value for slots 3+ (address sole-occupant):
///     bytes32(uint256(uint160(addr)))
///
/// @dev EXISTING HALMOS TESTS (HalmosSafetyAdapterCapTier, HalmosConservation,
///      HalmosQueueFIFO, HalmosRoles) are pure arithmetic / minimal mock contracts
///      and do NOT reference real adapter storage — this helper is NOT needed for
///      them. It is infrastructure for future adapter-touching Halmos/fuzz tests.
///
///      Layout confirmed by `forge inspect` on commit 98e7006 (V10/P2-03..07).
abstract contract V10StoragePins is Test {
    // ── Slot constants (shared across all V10 adapters) ──────────────────────

    uint256 internal constant _SLOT_ROLES   = 0; // AccessControl mapping
    uint256 internal constant _SLOT_STATUS  = 1; // ReentrancyGuard
    uint256 internal constant _SLOT_INIT_ADDR0 = 2; // packed: _initialized | _initializing | addr0
    uint256 internal constant _SLOT_ADDR1   = 3;
    uint256 internal constant _SLOT_ADDR2   = 4;
    uint256 internal constant _SLOT_ADDR3   = 5; // AaveV3USDCAdapter only (vault)
    uint256 internal constant _SLOT_ADDR4   = 6; // AaveV3USDCAdapter only (maxCap)

    // ── Internal encoding helpers ────────────────────────────────────────────

    /// @dev Encode slot 2 value: _initialized=1, _initializing=false, address at offset 2.
    function _slotAddr0(address addr) internal pure returns (bytes32) {
        // bit 0 = _initialized=1; bits 16-175 = address
        return bytes32((uint256(uint160(addr)) << 16) | 1);
    }

    /// @dev Encode slot 3+ value: address sole-occupant.
    function _slotAddr(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    // ── Per-adapter pin functions ────────────────────────────────────────────
    //
    // AaveV3USDCAdapter
    //   slot 2: asset (packed with _initialized=1)
    //   slot 3: pool
    //   slot 4: aToken
    //   slot 5: vault
    //   slot 6: maxCap (uint256 — stored separately if present; use vm.store directly)
    //
    // EulerUsdcMultiMarketAdapter
    //   slot 2: underlying (packed)
    //   slot 3: vault
    //   slot 4: registry
    //
    // FluidUsdcMultiMarketAdapter
    //   slot 2: asset (packed)
    //   slot 3: vault
    //   slot 4: fToken
    //
    // VenusUsdcMultiMarketAdapter
    //   slot 2: underlying (packed)
    //   slot 3: vault
    //   slot 4: vToken
    //
    // MorphoUsdcMultiMarketAdapter / CometUsdcMultiMarketAdapter / DolomiteUsdcMultiMarketAdapter
    //   slot 2: underlying (packed)
    //   slot 3: vault
    //   slot 4: registry

    function pinAaveAdapter(
        address target,
        address asset_,
        address pool_,
        address aToken_,
        address vault_
    ) internal {
        vm.store(target, bytes32(_SLOT_INIT_ADDR0), _slotAddr0(asset_));
        vm.store(target, bytes32(_SLOT_ADDR1),      _slotAddr(pool_));
        vm.store(target, bytes32(_SLOT_ADDR2),      _slotAddr(aToken_));
        vm.store(target, bytes32(_SLOT_ADDR3),      _slotAddr(vault_));
    }

    function pinEulerAdapter(
        address target,
        address underlying_,
        address vault_,
        address registry_
    ) internal {
        vm.store(target, bytes32(_SLOT_INIT_ADDR0), _slotAddr0(underlying_));
        vm.store(target, bytes32(_SLOT_ADDR1),      _slotAddr(vault_));
        vm.store(target, bytes32(_SLOT_ADDR2),      _slotAddr(registry_));
    }

    function pinFluidAdapter(
        address target,
        address asset_,
        address vault_,
        address fToken_
    ) internal {
        vm.store(target, bytes32(_SLOT_INIT_ADDR0), _slotAddr0(asset_));
        vm.store(target, bytes32(_SLOT_ADDR1),      _slotAddr(vault_));
        vm.store(target, bytes32(_SLOT_ADDR2),      _slotAddr(fToken_));
    }

    function pinVenusAdapter(
        address target,
        address underlying_,
        address vault_,
        address vToken_
    ) internal {
        vm.store(target, bytes32(_SLOT_INIT_ADDR0), _slotAddr0(underlying_));
        vm.store(target, bytes32(_SLOT_ADDR1),      _slotAddr(vault_));
        vm.store(target, bytes32(_SLOT_ADDR2),      _slotAddr(vToken_));
    }

    /// @dev Covers MorphoUsdcMultiMarketAdapter, CometUsdcMultiMarketAdapter,
    ///      and DolomiteUsdcMultiMarketAdapter — identical slot layout.
    function pinRegistryAdapter(
        address target,
        address underlying_,
        address vault_,
        address registry_
    ) internal {
        vm.store(target, bytes32(_SLOT_INIT_ADDR0), _slotAddr0(underlying_));
        vm.store(target, bytes32(_SLOT_ADDR1),      _slotAddr(vault_));
        vm.store(target, bytes32(_SLOT_ADDR2),      _slotAddr(registry_));
    }
}
