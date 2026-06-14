// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import {
    DolomiteUsdcMultiMarketAdapter
} from "../../../src/strategies/usdc-lending/adapters/lending/DolomiteUsdcMultiMarket.sol";

// ============================================================================
// MOCK CONTRACTS for Dolomite tests
// ============================================================================

/// @dev Mock ERC4626-like market (dUSDC vault)
contract MockERC4626Market {
    address public immutable assetAddr;
    uint256 public balance; // shares balance
    uint256 public assetsPerShare = 1e18; // 1:1 initially

    constructor(address _asset) {
        assetAddr = _asset;
    }

    // IERC4626Like
    function asset() external view returns (address) { return assetAddr; }

    function balanceOf(address) external view returns (uint256) { return balance; }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * assetsPerShare) / 1e18;
    }

    function maxWithdraw(address) external view returns (uint256) {
        return (balance * assetsPerShare) / 1e18;
    }

    // NOT baseToken — this is ERC4626 only
    // baseToken() must revert to distinguish from PoolLike
}

/// @dev Mock PoolLike Dolomite market
contract MockPoolLikeMarket {
    address public immutable baseTokenAddr;
    bool public shouldRevertGetAccountWei;
    uint256 public liquidBalance;

    constructor(address _base) {
        baseTokenAddr = _base;
        liquidBalance = type(uint256).max;
    }

    // IDolomiteLike
    function baseToken() external view returns (address) { return baseTokenAddr; }
    function availableLiquidity(address) external view returns (uint256) { return liquidBalance; }

    // IDolomiteMargin.getAccountWei
    function getAccountWei(
        IDolomiteMarginLike.AccountInfo memory,
        uint256
    ) external view returns (IDolomiteMarginLike.Wei memory) {
        require(!shouldRevertGetAccountWei, "getAccountWei reverts");
        return IDolomiteMarginLike.Wei({ sign: true, value: 0 });
    }

    function setShouldRevert(bool v) external { shouldRevertGetAccountWei = v; }

    // NOT asset() — this is PoolLike only (no IERC4626 asset())
}

/// @dev Mock ambiguous market (implements BOTH ERC4626 asset() AND Dolomite baseToken())
contract MockAmbiguousMarket {
    address public immutable addr;
    constructor(address _a) { addr = _a; }
    function asset() external view returns (address) { return addr; }
    function baseToken() external view returns (address) { return addr; }
}

/// @dev Market that implements neither asset() nor baseToken() — triggers UnsupportedMarketType
contract MockNeitherMarket {
    // Intentionally empty — no asset(), no baseToken()
    function someOtherFunction() external pure returns (uint256) { return 42; }
}

/// @dev IDolomiteMargin types for the mock
interface IDolomiteMarginLike {
    struct AccountInfo { address owner; uint256 number; }
    struct Wei { bool sign; uint256 value; }
}

/// @dev Mock registry that provides the mock PoolLike market
/// Must implement IProtocolRegistry: getEnabledVaults(ProtocolType) + isEnabled(ProtocolType, address)
contract MockDolomiteRegistry {
    address[] internal _vaults;

    constructor(address, address pool) {
        _vaults.push(pool);
    }

    // IProtocolRegistry
    function getEnabledVaults(uint8) external view returns (address[] memory) {
        return _vaults;
    }

    function isEnabled(uint8, address) external pure returns (bool) {
        return true;
    }
}

/// @dev Mock USDC token for the adapter
contract MockUSDCToken {
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
}

// ============================================================================
// BLOCCO E — Dolomite Config Correctness Tests
// ============================================================================
// E1: Invalid config (dolomiteConfigValid=false) returns 0 for PoolLike markets.
// E2: Validated config reads correctly.
// E3: Type detection rejects ambiguous markets.
// ============================================================================

contract DolomiteConfigCorrectnessTest is Test {

    MockUSDCToken usdc;
    MockPoolLikeMarket poolMarket;
    MockERC4626Market erc4626Market;
    MockAmbiguousMarket ambiguousMarket;
    DolomiteUsdcMultiMarketAdapter adapter;

    address admin = address(0x1);
    address vaultAddr = address(0x2);

    // Use abi.encodeWithSelector for custom errors with args (bytes4 alone mis-matches in this Foundry version)
    // Selectors verified via `cast sig`:
    //   AmbiguousMarketType(address)                 = 0x49558683
    //   UnsupportedMarketType(address)               = 0x8e959fcf
    //   InvalidDolomiteConfig(address,uint256,uint256) = 0xb7d67295

    function setUp() public {
        usdc = new MockUSDCToken();
        poolMarket = new MockPoolLikeMarket(address(usdc));
        erc4626Market = new MockERC4626Market(address(usdc));
        ambiguousMarket = new MockAmbiguousMarket(address(usdc));

        // Build a minimal PoolLike-only adapter
        // We need a registry or to directly add a market
        // The constructor requires mkts.length > 0, so we use a registry
        MockDolomiteRegistry registry = new MockDolomiteRegistry(address(usdc), address(poolMarket));

        adapter = new DolomiteUsdcMultiMarketAdapter();
        adapter.initialize(address(usdc), admin, vaultAddr, 0, address(registry));
    }

    // -----------------------------------------------------------------------
    // E1: Invalid config — PoolLike market returns 0 for _assetsOn()
    // -----------------------------------------------------------------------

    /// @notice E1a: With dolomiteConfigValid=false (post-mutation), totalAssets() must return 0
    ///         for PoolLike markets (no silent balanceOf fallback).
    function test_E1a_invalidConfigReturnsZeroForPoolLike() public {
        // After constructor (with registry), config should be invalid (never validated)
        assertFalse(adapter.dolomiteConfigValid(), "E1a: config must be invalid after construction");

        // totalAssets() with invalid config should reflect only principal (which is 0)
        uint256 total = adapter.totalAssets();
        // With no deposits and invalid config, totalAssets == 0
        assertEq(total, 0, "E1a: totalAssets must be 0 with invalid config and no deposits");
    }

    /// @notice E1b: After config mutation (e.g. setUsdcMarketId), config becomes invalid again.
    function test_E1b_mutationInvalidatesConfig() public {
        // First validate
        vm.prank(admin);
        adapter.validateDolomiteConfig();
        assertTrue(adapter.dolomiteConfigValid(), "E1b: config must be valid after validateDolomiteConfig");

        // Mutate config
        vm.prank(admin);
        adapter.setUsdcMarketId(18); // different market ID
        assertFalse(adapter.dolomiteConfigValid(), "E1b: config must be invalid after mutation");
    }

    // -----------------------------------------------------------------------
    // E2: Validated config reads correctly
    // -----------------------------------------------------------------------

    /// @notice E2a: After validateDolomiteConfig(), dolomiteConfigValid=true
    ///         and _assetsOn() can read PoolLike market state.
    function test_E2a_validatedConfigWorks() public {
        // Configure correct market ID
        vm.prank(admin);
        adapter.setUsdcMarketId(17);
        vm.prank(admin);
        adapter.setAccountNumber(0);

        // Validate
        vm.prank(admin);
        adapter.validateDolomiteConfig();
        assertTrue(adapter.dolomiteConfigValid(), "E2a: config must be valid after validate");

        // With valid config, totalAssets should not revert and returns 0 (no deposits)
        uint256 total = adapter.totalAssets();
        assertEq(total, 0, "E2a: totalAssets must be 0 with valid config and no deposits");
    }

    /// @notice E2b: validateDolomiteConfig() reverts with InvalidDolomiteConfig
    ///         if getAccountWei reverts.
    function test_E2b_validateRevertsOnBadConfig() public {
        // Make the mock market's getAccountWei revert
        poolMarket.setShouldRevert(true);

        vm.prank(admin);
        // InvalidDolomiteConfig(address market, uint256 marketId, uint256 accountNumber)
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(0xb7d67295), // InvalidDolomiteConfig(address,uint256,uint256)
            address(poolMarket),
            uint256(0),
            uint256(0)
        ));
        adapter.validateDolomiteConfig();

        assertFalse(adapter.dolomiteConfigValid(), "E2b: config must remain invalid after failed validate");
    }

    // -----------------------------------------------------------------------
    // E3: Type detection rejects ambiguous markets
    // -----------------------------------------------------------------------

    /// @notice E3a: addMarket() rejects an ambiguous market (implements both ERC4626 and PoolLike).
    function test_E3a_addMarketRejectsAmbiguous() public {
        // ambiguousMarket implements both asset() and baseToken() returning usdc
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(0x49558683), // AmbiguousMarketType(address)
            address(ambiguousMarket)
        ));
        adapter.addMarket(address(ambiguousMarket), DolomiteUsdcMultiMarketAdapter.MarketType.ERC4626);
    }

    /// @notice E3b: addMarket() rejects wrong declared type (ERC4626 market declared as PoolLike).
    function test_E3b_addMarketRejectsWrongDeclaredType() public {
        // erc4626Market has asset() but not baseToken()
        // Declaring it as PoolLike should fail (detected=ERC4626, declared=PoolLike)
        vm.prank(admin);
        vm.expectRevert("Dolomite: declared type mismatch with detected");
        adapter.addMarket(address(erc4626Market), DolomiteUsdcMultiMarketAdapter.MarketType.PoolLike);
    }

    /// @notice E3c: addMarket() rejects wrong declared type (PoolLike market declared as ERC4626).
    function test_E3c_addMarketRejectsPoolLikeDeclaredAsERC4626() public {
        // poolMarket has baseToken() but not asset()
        vm.prank(admin);
        vm.expectRevert("Dolomite: declared type mismatch with detected");
        adapter.addMarket(address(poolMarket), DolomiteUsdcMultiMarketAdapter.MarketType.ERC4626);
    }

    /// @notice E3d: addMarket() rejects a market that implements neither interface.
    function test_E3d_addMarketRejectsUnknownMarket() public {
        // Deploy a contract that implements neither asset() nor baseToken()
        address neitherMarket = address(new MockNeitherMarket());
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(0x8e959fcf), // UnsupportedMarketType(address)
            neitherMarket
        ));
        adapter.addMarket(neitherMarket, DolomiteUsdcMultiMarketAdapter.MarketType.ERC4626);
    }

    // -----------------------------------------------------------------------
    // E1 + E2: Config cycle invariant
    // -----------------------------------------------------------------------

    /// @notice Config guard invariant: validate → mutate → invalid → re-validate → valid.
    function test_E_configCycleInvariant() public {
        // Step 1: validate
        vm.prank(admin);
        adapter.validateDolomiteConfig();
        assertTrue(adapter.dolomiteConfigValid(), "step 1: must be valid");

        // Step 2: mutate → invalid
        vm.prank(admin);
        adapter.setUsdcMarketId(18);
        assertFalse(adapter.dolomiteConfigValid(), "step 2: must be invalid after mutation");

        // Step 3: re-validate with correct ID → valid
        vm.prank(admin);
        adapter.setUsdcMarketId(17);
        vm.prank(admin);
        adapter.validateDolomiteConfig();
        assertTrue(adapter.dolomiteConfigValid(), "step 3: must be valid after re-validate");
    }
}
