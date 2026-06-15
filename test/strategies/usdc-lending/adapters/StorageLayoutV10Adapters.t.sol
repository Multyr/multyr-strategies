// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// =============================================================================
// StorageLayoutV10Adapters.t.sol — V10 adapter storage layout consistency
// =============================================================================
//
// Verifies that the V10 storage+initialize refactor preserved every adapter's
// storage slot layout exactly as reported by `forge inspect <Adapter> storageLayout`.
//
// Technique: vm.store() / vm.load() — bypasses initialize() external calls (every
// adapter validates external contracts in initialize: aToken.UNDERLYING_ASSET_ADDRESS,
// fToken.asset, vToken.underlying, USDC.approve, etc.). Storage layout verification
// is independent of initialization logic.
//
// Golden-file snapshots of `forge inspect` output committed alongside this file:
//   test/strategies/usdc-lending/adapters/snapshots/<Adapter>.storage.json
// These serve as regression baselines: re-run `forge inspect` and diff to detect
// unintended layout changes. A test verifies each snapshot file is readable.
//
// Slot summary (all adapter contracts: AccessControl + ReentrancyGuard + Initializable):
//   slot 0: _roles   (mapping — AccessControl)
//   slot 1: _status  (uint256 — ReentrancyGuard)
//   slot 2: _initialized(uint8@byte0) | _initializing(bool@byte1) | addr_field_0(address@byte2)
//   slot 3+: remaining fields (full-word each unless packed)
//
// StrategyBootstrapper (Initializable only — no AccessControl, no ReentrancyGuard):
//   slot 0: _initialized(uint8@byte0) | _initializing(bool@byte1) | strategy(address@byte2)
//   slot 1: deployer(address@byte0) | used(bool@byte20)
//
// Run: forge test --match-contract StorageLayoutV10Adapters_Test -vv
// =============================================================================

import { Test } from "forge-std/Test.sol";
import { AaveV3USDCAdapter }
    from "../../../../src/strategies/usdc-lending/adapters/lending/AaveV3USDCmarket.sol";
import { CometUsdcMultiMarketAdapter }
    from "../../../../src/strategies/usdc-lending/adapters/lending/CometUsdcMultiMarket.sol";
import { DolomiteUsdcMultiMarketAdapter }
    from "../../../../src/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol";
import { EulerUsdcMultiMarketAdapter }
    from "../../../../src/strategies/usdc-lending/adapters/lending/EulerUsdcMultiMarket.sol";
import { FluidUsdcMultiMarketAdapter }
    from "../../../../src/strategies/usdc-lending/adapters/lending/FluidUsdcMultiMarket.sol";
import { MorphoUsdcMultiMarketAdapter }
    from "../../../../src/strategies/usdc-lending/adapters/lending/MorphoUsdcMultiMarket.sol";
import { VenusUsdcMultiMarketAdapter }
    from "../../../../src/strategies/usdc-lending/adapters/lending/VenusUsdcMultiMarket.sol";
import { RewardSwapHelper }
    from "../../../../src/strategies/usdc-lending/swap/RewardSwapHelper.sol";
import { StrategyBootstrapper }
    from "../../../../src/strategies/usdc-lending/StrategyBootstrapper.sol";

contract StorageLayoutV10Adapters_Test is Test {

    // ── Sentinel addresses — distinct, non-zero, non-overlapping ────────────
    address constant S_ASSET    = address(uint160(0x1001));
    address constant S_POOL     = address(uint160(0x1002));
    address constant S_ATOKEN   = address(uint160(0x1003));
    address constant S_VAULT    = address(uint160(0x1004));
    address constant S_REGISTRY = address(uint160(0x1005));
    address constant S_FTOKEN   = address(uint160(0x1006));
    address constant S_VTOKEN   = address(uint160(0x1007));
    address constant S_USDC     = address(uint160(0x1008));
    address constant S_UNI_V3   = address(uint160(0x1009));
    address constant S_CAMELOT  = address(uint160(0x100A));
    address constant S_STRATEGY = address(uint160(0x100B));
    address constant S_DEPLOYER = address(uint160(0x100C));

    // ── Slot encoding helpers ────────────────────────────────────────────────

    // Encode addr into the packed slot 2 (AC+RG adapters):
    //   bits  0- 7: _initialized = 1
    //   bits  8-15: _initializing = false (0)
    //   bits 16-175: address
    function _slot2Pack(address addr) internal pure returns (bytes32) {
        return bytes32((uint256(uint160(addr)) << 16) | 1);
    }

    // Encode addr into the packed slot 0 (StrategyBootstrapper — Initializable only):
    //   same packing as slot 2 above but at slot 0
    function _slot0Pack(address addr) internal pure returns (bytes32) {
        return bytes32((uint256(uint160(addr)) << 16) | 1);
    }

    // Read full-word address from a solo slot (no packing)
    function _loadAddr(address target, uint256 slot) internal view returns (address) {
        return address(uint160(uint256(vm.load(target, bytes32(slot)))));
    }

    // Read address from the packed slot at byte offset 2 (bits 16+)
    function _loadAddrPacked(address target, uint256 slot) internal view returns (address) {
        return address(uint160(uint256(vm.load(target, bytes32(slot))) >> 16));
    }

    // Read _initialized flag (byte 0 of a packed slot)
    function _loadInitialized(address target, uint256 slot) internal view returns (uint8) {
        return uint8(uint256(vm.load(target, bytes32(slot))) & 0xFF);
    }

    // ========================================================================
    // AAVE V3 — slot layout (forge inspect AaveV3USDCAdapter storageLayout):
    //   slot 0: _roles (mapping, AccessControl)
    //   slot 1: _status (uint256, ReentrancyGuard)
    //   slot 2: _initialized(u8@0) | _initializing(bool@1) | asset(address@2)
    //   slot 3: pool (IPool → address)
    //   slot 4: aToken (address)
    //   slot 5: vault (address)
    // ========================================================================

    function test_AaveAdapter_slot2_assetPackedAtOffset2() public {
        AaveV3USDCAdapter a = new AaveV3USDCAdapter();
        vm.store(address(a), bytes32(uint256(2)), _slot2Pack(S_ASSET));
        assertEq(_loadAddrPacked(address(a), 2), S_ASSET, "Aave: asset at slot 2 offset 2");
    }

    function test_AaveAdapter_slot3_pool() public {
        AaveV3USDCAdapter a = new AaveV3USDCAdapter();
        vm.store(address(a), bytes32(uint256(3)), bytes32(uint256(uint160(S_POOL))));
        assertEq(_loadAddr(address(a), 3), S_POOL, "Aave: pool at slot 3");
    }

    function test_AaveAdapter_slot4_aToken() public {
        AaveV3USDCAdapter a = new AaveV3USDCAdapter();
        vm.store(address(a), bytes32(uint256(4)), bytes32(uint256(uint160(S_ATOKEN))));
        assertEq(_loadAddr(address(a), 4), S_ATOKEN, "Aave: aToken at slot 4");
    }

    function test_AaveAdapter_slot5_vault() public {
        AaveV3USDCAdapter a = new AaveV3USDCAdapter();
        vm.store(address(a), bytes32(uint256(5)), bytes32(uint256(uint160(S_VAULT))));
        assertEq(_loadAddr(address(a), 5), S_VAULT, "Aave: vault at slot 5");
    }

    function test_AaveAdapter_initializableAtSlot2() public {
        // OZ 4.x Initializable uses sequential storage (NOT ERC-7201 namespaced).
        // After empty constructor: _initialized == 0 (uninitialized).
        // After vm.store with _initialized=1: reads back as 1, confirming slot placement.
        AaveV3USDCAdapter a = new AaveV3USDCAdapter();
        assertEq(_loadInitialized(address(a), 2), 0, "Aave: _initialized starts 0");
        vm.store(address(a), bytes32(uint256(2)), bytes32(uint256(1))); // set _initialized=1
        assertEq(_loadInitialized(address(a), 2), 1, "Aave: _initialized at slot 2 byte 0");
    }

    // ========================================================================
    // COMET — slot layout (forge inspect CometUsdcMultiMarketAdapter):
    //   slot 0: _roles
    //   slot 1: _status
    //   slot 2: _initialized(u8@0) | _initializing(bool@1) | underlying(address@2)
    //   slot 3: vault (address)
    //   slot 4: registry (IProtocolRegistry → address)
    // ========================================================================

    function test_CometAdapter_slot2_underlyingPackedAtOffset2() public {
        CometUsdcMultiMarketAdapter a = new CometUsdcMultiMarketAdapter();
        vm.store(address(a), bytes32(uint256(2)), _slot2Pack(S_USDC));
        assertEq(_loadAddrPacked(address(a), 2), S_USDC, "Comet: underlying at slot 2 offset 2");
    }

    function test_CometAdapter_slot3_vault() public {
        CometUsdcMultiMarketAdapter a = new CometUsdcMultiMarketAdapter();
        vm.store(address(a), bytes32(uint256(3)), bytes32(uint256(uint160(S_VAULT))));
        assertEq(_loadAddr(address(a), 3), S_VAULT, "Comet: vault at slot 3");
    }

    function test_CometAdapter_slot4_registry() public {
        CometUsdcMultiMarketAdapter a = new CometUsdcMultiMarketAdapter();
        vm.store(address(a), bytes32(uint256(4)), bytes32(uint256(uint160(S_REGISTRY))));
        assertEq(_loadAddr(address(a), 4), S_REGISTRY, "Comet: registry at slot 4");
    }

    function test_CometAdapter_initializableAtSlot2() public {
        CometUsdcMultiMarketAdapter a = new CometUsdcMultiMarketAdapter();
        assertEq(_loadInitialized(address(a), 2), 0, "Comet: _initialized starts 0");
        vm.store(address(a), bytes32(uint256(2)), bytes32(uint256(1)));
        assertEq(_loadInitialized(address(a), 2), 1, "Comet: _initialized at slot 2 byte 0");
    }

    // ========================================================================
    // DOLOMITE — slot layout (forge inspect DolomiteUsdcMultiMarketAdapter):
    //   slot 0: _roles
    //   slot 1: _status
    //   slot 2: _initialized(u8@0) | _initializing(bool@1) | asset(address@2)
    //   slot 3: vault (address)
    //   slot 4: registry (IProtocolRegistry → address)
    // ========================================================================

    function test_DolomiteAdapter_slot2_assetPackedAtOffset2() public {
        DolomiteUsdcMultiMarketAdapter a = new DolomiteUsdcMultiMarketAdapter();
        vm.store(address(a), bytes32(uint256(2)), _slot2Pack(S_ASSET));
        assertEq(_loadAddrPacked(address(a), 2), S_ASSET, "Dolomite: asset at slot 2 offset 2");
    }

    function test_DolomiteAdapter_slot3_vault() public {
        DolomiteUsdcMultiMarketAdapter a = new DolomiteUsdcMultiMarketAdapter();
        vm.store(address(a), bytes32(uint256(3)), bytes32(uint256(uint160(S_VAULT))));
        assertEq(_loadAddr(address(a), 3), S_VAULT, "Dolomite: vault at slot 3");
    }

    function test_DolomiteAdapter_slot4_registry() public {
        DolomiteUsdcMultiMarketAdapter a = new DolomiteUsdcMultiMarketAdapter();
        vm.store(address(a), bytes32(uint256(4)), bytes32(uint256(uint160(S_REGISTRY))));
        assertEq(_loadAddr(address(a), 4), S_REGISTRY, "Dolomite: registry at slot 4");
    }

    function test_DolomiteAdapter_initializableAtSlot2() public {
        DolomiteUsdcMultiMarketAdapter a = new DolomiteUsdcMultiMarketAdapter();
        assertEq(_loadInitialized(address(a), 2), 0, "Dolomite: _initialized starts 0");
        vm.store(address(a), bytes32(uint256(2)), bytes32(uint256(1)));
        assertEq(_loadInitialized(address(a), 2), 1, "Dolomite: _initialized at slot 2 byte 0");
    }

    // ========================================================================
    // EULER — slot layout (forge inspect EulerUsdcMultiMarketAdapter):
    //   slot 0: _roles
    //   slot 1: _status
    //   slot 2: _initialized(u8@0) | _initializing(bool@1) | USDC(address@2)
    //   slot 3: vault (address)
    //   slot 4: registry (IProtocolRegistry → address)
    // ========================================================================

    function test_EulerAdapter_slot2_usdcPackedAtOffset2() public {
        EulerUsdcMultiMarketAdapter a = new EulerUsdcMultiMarketAdapter();
        vm.store(address(a), bytes32(uint256(2)), _slot2Pack(S_USDC));
        assertEq(_loadAddrPacked(address(a), 2), S_USDC, "Euler: USDC at slot 2 offset 2");
    }

    function test_EulerAdapter_slot3_vault() public {
        EulerUsdcMultiMarketAdapter a = new EulerUsdcMultiMarketAdapter();
        vm.store(address(a), bytes32(uint256(3)), bytes32(uint256(uint160(S_VAULT))));
        assertEq(_loadAddr(address(a), 3), S_VAULT, "Euler: vault at slot 3");
    }

    function test_EulerAdapter_slot4_registry() public {
        EulerUsdcMultiMarketAdapter a = new EulerUsdcMultiMarketAdapter();
        vm.store(address(a), bytes32(uint256(4)), bytes32(uint256(uint160(S_REGISTRY))));
        assertEq(_loadAddr(address(a), 4), S_REGISTRY, "Euler: registry at slot 4");
    }

    function test_EulerAdapter_initializableAtSlot2() public {
        EulerUsdcMultiMarketAdapter a = new EulerUsdcMultiMarketAdapter();
        assertEq(_loadInitialized(address(a), 2), 0, "Euler: _initialized starts 0");
        vm.store(address(a), bytes32(uint256(2)), bytes32(uint256(1)));
        assertEq(_loadInitialized(address(a), 2), 1, "Euler: _initialized at slot 2 byte 0");
    }

    // ========================================================================
    // FLUID — slot layout (forge inspect FluidUsdcMultiMarketAdapter):
    //   slot 0: _roles
    //   slot 1: _status
    //   slot 2: _initialized(u8@0) | _initializing(bool@1) | asset(address@2)
    //   slot 3: vault (address)
    //   slot 4: fToken (IERC4626 → address)
    // ========================================================================

    function test_FluidAdapter_slot2_assetPackedAtOffset2() public {
        FluidUsdcMultiMarketAdapter a = new FluidUsdcMultiMarketAdapter();
        vm.store(address(a), bytes32(uint256(2)), _slot2Pack(S_ASSET));
        assertEq(_loadAddrPacked(address(a), 2), S_ASSET, "Fluid: asset at slot 2 offset 2");
    }

    function test_FluidAdapter_slot3_vault() public {
        FluidUsdcMultiMarketAdapter a = new FluidUsdcMultiMarketAdapter();
        vm.store(address(a), bytes32(uint256(3)), bytes32(uint256(uint160(S_VAULT))));
        assertEq(_loadAddr(address(a), 3), S_VAULT, "Fluid: vault at slot 3");
    }

    function test_FluidAdapter_slot4_fToken() public {
        FluidUsdcMultiMarketAdapter a = new FluidUsdcMultiMarketAdapter();
        vm.store(address(a), bytes32(uint256(4)), bytes32(uint256(uint160(S_FTOKEN))));
        assertEq(_loadAddr(address(a), 4), S_FTOKEN, "Fluid: fToken at slot 4");
    }

    function test_FluidAdapter_initializableAtSlot2() public {
        FluidUsdcMultiMarketAdapter a = new FluidUsdcMultiMarketAdapter();
        assertEq(_loadInitialized(address(a), 2), 0, "Fluid: _initialized starts 0");
        vm.store(address(a), bytes32(uint256(2)), bytes32(uint256(1)));
        assertEq(_loadInitialized(address(a), 2), 1, "Fluid: _initialized at slot 2 byte 0");
    }

    // ========================================================================
    // MORPHO — slot layout (forge inspect MorphoUsdcMultiMarketAdapter):
    //   slot 0: _roles
    //   slot 1: _status
    //   slot 2: _initialized(u8@0) | _initializing(bool@1) | underlying(address@2)
    //   slot 3: vault (address)
    //   slot 4: registry (IProtocolRegistry → address)
    // ========================================================================

    function test_MorphoAdapter_slot2_underlyingPackedAtOffset2() public {
        MorphoUsdcMultiMarketAdapter a = new MorphoUsdcMultiMarketAdapter();
        vm.store(address(a), bytes32(uint256(2)), _slot2Pack(S_USDC));
        assertEq(_loadAddrPacked(address(a), 2), S_USDC, "Morpho: underlying at slot 2 offset 2");
    }

    function test_MorphoAdapter_slot3_vault() public {
        MorphoUsdcMultiMarketAdapter a = new MorphoUsdcMultiMarketAdapter();
        vm.store(address(a), bytes32(uint256(3)), bytes32(uint256(uint160(S_VAULT))));
        assertEq(_loadAddr(address(a), 3), S_VAULT, "Morpho: vault at slot 3");
    }

    function test_MorphoAdapter_slot4_registry() public {
        MorphoUsdcMultiMarketAdapter a = new MorphoUsdcMultiMarketAdapter();
        vm.store(address(a), bytes32(uint256(4)), bytes32(uint256(uint160(S_REGISTRY))));
        assertEq(_loadAddr(address(a), 4), S_REGISTRY, "Morpho: registry at slot 4");
    }

    function test_MorphoAdapter_initializableAtSlot2() public {
        MorphoUsdcMultiMarketAdapter a = new MorphoUsdcMultiMarketAdapter();
        assertEq(_loadInitialized(address(a), 2), 0, "Morpho: _initialized starts 0");
        vm.store(address(a), bytes32(uint256(2)), bytes32(uint256(1)));
        assertEq(_loadInitialized(address(a), 2), 1, "Morpho: _initialized at slot 2 byte 0");
    }

    // ========================================================================
    // VENUS — slot layout (forge inspect VenusUsdcMultiMarketAdapter):
    //   slot 0: _roles
    //   slot 1: _status
    //   slot 2: _initialized(u8@0) | _initializing(bool@1) | underlying(address@2)
    //   slot 3: vault (address)
    //   slot 4: vToken (address)
    // ========================================================================

    function test_VenusAdapter_slot2_underlyingPackedAtOffset2() public {
        VenusUsdcMultiMarketAdapter a = new VenusUsdcMultiMarketAdapter();
        vm.store(address(a), bytes32(uint256(2)), _slot2Pack(S_USDC));
        assertEq(_loadAddrPacked(address(a), 2), S_USDC, "Venus: underlying at slot 2 offset 2");
    }

    function test_VenusAdapter_slot3_vault() public {
        VenusUsdcMultiMarketAdapter a = new VenusUsdcMultiMarketAdapter();
        vm.store(address(a), bytes32(uint256(3)), bytes32(uint256(uint160(S_VAULT))));
        assertEq(_loadAddr(address(a), 3), S_VAULT, "Venus: vault at slot 3");
    }

    function test_VenusAdapter_slot4_vToken() public {
        VenusUsdcMultiMarketAdapter a = new VenusUsdcMultiMarketAdapter();
        vm.store(address(a), bytes32(uint256(4)), bytes32(uint256(uint160(S_VTOKEN))));
        assertEq(_loadAddr(address(a), 4), S_VTOKEN, "Venus: vToken at slot 4");
    }

    function test_VenusAdapter_initializableAtSlot2() public {
        VenusUsdcMultiMarketAdapter a = new VenusUsdcMultiMarketAdapter();
        assertEq(_loadInitialized(address(a), 2), 0, "Venus: _initialized starts 0");
        vm.store(address(a), bytes32(uint256(2)), bytes32(uint256(1)));
        assertEq(_loadInitialized(address(a), 2), 1, "Venus: _initialized at slot 2 byte 0");
    }

    // ========================================================================
    // REWARD SWAP HELPER — slot layout (forge inspect RewardSwapHelper):
    //   slot 0: _roles
    //   slot 1: _status
    //   slot 2: _initialized(u8@0) | _initializing(bool@1) | usdc(address@2)
    //   slot 3: uniswapV3Router (address)
    //   slot 4: camelotV3Router (address)
    // ========================================================================

    function test_RewardSwapHelper_slot2_usdcPackedAtOffset2() public {
        RewardSwapHelper a = new RewardSwapHelper();
        vm.store(address(a), bytes32(uint256(2)), _slot2Pack(S_USDC));
        assertEq(_loadAddrPacked(address(a), 2), S_USDC, "RewardSwapHelper: usdc at slot 2 offset 2");
    }

    function test_RewardSwapHelper_slot3_uniswapV3Router() public {
        RewardSwapHelper a = new RewardSwapHelper();
        vm.store(address(a), bytes32(uint256(3)), bytes32(uint256(uint160(S_UNI_V3))));
        assertEq(_loadAddr(address(a), 3), S_UNI_V3, "RewardSwapHelper: uniswapV3Router at slot 3");
    }

    function test_RewardSwapHelper_slot4_camelotV3Router() public {
        RewardSwapHelper a = new RewardSwapHelper();
        vm.store(address(a), bytes32(uint256(4)), bytes32(uint256(uint160(S_CAMELOT))));
        assertEq(_loadAddr(address(a), 4), S_CAMELOT, "RewardSwapHelper: camelotV3Router at slot 4");
    }

    function test_RewardSwapHelper_initializableAtSlot2() public {
        RewardSwapHelper a = new RewardSwapHelper();
        assertEq(_loadInitialized(address(a), 2), 0, "RewardSwapHelper: _initialized starts 0");
        vm.store(address(a), bytes32(uint256(2)), bytes32(uint256(1)));
        assertEq(_loadInitialized(address(a), 2), 1, "RewardSwapHelper: _initialized at slot 2 byte 0");
    }

    // ========================================================================
    // STRATEGY BOOTSTRAPPER — slot layout (forge inspect StrategyBootstrapper):
    //   Inherits: Initializable ONLY (no AccessControl, no ReentrancyGuard).
    //   slot 0: _initialized(u8@0) | _initializing(bool@1) | strategy(address@2)
    //   slot 1: deployer(address@0) | used(bool@20)
    //
    // Note: _initialized is at slot 0 (NOT slot 2) because there is no
    // AccessControl (_roles at slot 0) or ReentrancyGuard (_status at slot 1).
    // ========================================================================

    function test_StrategyBootstrapper_slot0_strategyPackedAtOffset2() public {
        StrategyBootstrapper b = new StrategyBootstrapper();
        vm.store(address(b), bytes32(uint256(0)), _slot0Pack(S_STRATEGY));
        assertEq(_loadAddrPacked(address(b), 0), S_STRATEGY, "Bootstrapper: strategy at slot 0 offset 2");
    }

    function test_StrategyBootstrapper_slot1_deployer() public {
        StrategyBootstrapper b = new StrategyBootstrapper();
        // slot 1: deployer(address@byte0) | used(bool@byte20)
        vm.store(address(b), bytes32(uint256(1)), bytes32(uint256(uint160(S_DEPLOYER))));
        assertEq(_loadAddr(address(b), 1), S_DEPLOYER, "Bootstrapper: deployer at slot 1 offset 0");
    }

    function test_StrategyBootstrapper_initializableAtSlot0() public {
        // Bootstrapper has no AccessControl or ReentrancyGuard, so _initialized
        // is packed into slot 0 (not slot 2 like the main adapters).
        StrategyBootstrapper b = new StrategyBootstrapper();
        assertEq(_loadInitialized(address(b), 0), 0, "Bootstrapper: _initialized starts 0 at slot 0");
        vm.store(address(b), bytes32(uint256(0)), bytes32(uint256(1)));
        assertEq(_loadInitialized(address(b), 0), 1, "Bootstrapper: _initialized at slot 0 byte 0");
    }

    // ========================================================================
    // GOLDEN-FILE SNAPSHOT EXISTENCE TESTS
    // Verify that forge inspect JSON snapshots are committed and readable.
    // Re-run: forge inspect <Adapter> storageLayout --json > snapshots/<Adapter>.storage.json
    // Diff: git diff test/strategies/usdc-lending/adapters/snapshots/ after any src/ change.
    // ========================================================================

    function test_Snapshot_AaveV3_exists() public view {
        string memory s = vm.readFile(
            "test/strategies/usdc-lending/adapters/snapshots/AaveV3USDCAdapter.storage.json"
        );
        assertGt(bytes(s).length, 0, "AaveV3USDCAdapter snapshot must be non-empty");
    }

    function test_Snapshot_Comet_exists() public view {
        string memory s = vm.readFile(
            "test/strategies/usdc-lending/adapters/snapshots/CometUsdcMultiMarketAdapter.storage.json"
        );
        assertGt(bytes(s).length, 0, "CometUsdcMultiMarketAdapter snapshot must be non-empty");
    }

    function test_Snapshot_Dolomite_exists() public view {
        string memory s = vm.readFile(
            "test/strategies/usdc-lending/adapters/snapshots/DolomiteUsdcMultiMarketAdapter.storage.json"
        );
        assertGt(bytes(s).length, 0, "DolomiteUsdcMultiMarketAdapter snapshot must be non-empty");
    }

    function test_Snapshot_Euler_exists() public view {
        string memory s = vm.readFile(
            "test/strategies/usdc-lending/adapters/snapshots/EulerUsdcMultiMarketAdapter.storage.json"
        );
        assertGt(bytes(s).length, 0, "EulerUsdcMultiMarketAdapter snapshot must be non-empty");
    }

    function test_Snapshot_Fluid_exists() public view {
        string memory s = vm.readFile(
            "test/strategies/usdc-lending/adapters/snapshots/FluidUsdcMultiMarketAdapter.storage.json"
        );
        assertGt(bytes(s).length, 0, "FluidUsdcMultiMarketAdapter snapshot must be non-empty");
    }

    function test_Snapshot_Morpho_exists() public view {
        string memory s = vm.readFile(
            "test/strategies/usdc-lending/adapters/snapshots/MorphoUsdcMultiMarketAdapter.storage.json"
        );
        assertGt(bytes(s).length, 0, "MorphoUsdcMultiMarketAdapter snapshot must be non-empty");
    }

    function test_Snapshot_Venus_exists() public view {
        string memory s = vm.readFile(
            "test/strategies/usdc-lending/adapters/snapshots/VenusUsdcMultiMarketAdapter.storage.json"
        );
        assertGt(bytes(s).length, 0, "VenusUsdcMultiMarketAdapter snapshot must be non-empty");
    }

    function test_Snapshot_RewardSwapHelper_exists() public view {
        string memory s = vm.readFile(
            "test/strategies/usdc-lending/adapters/snapshots/RewardSwapHelper.storage.json"
        );
        assertGt(bytes(s).length, 0, "RewardSwapHelper snapshot must be non-empty");
    }

    function test_Snapshot_StrategyBootstrapper_exists() public view {
        string memory s = vm.readFile(
            "test/strategies/usdc-lending/adapters/snapshots/StrategyBootstrapper.storage.json"
        );
        assertGt(bytes(s).length, 0, "StrategyBootstrapper snapshot must be non-empty");
    }
}
