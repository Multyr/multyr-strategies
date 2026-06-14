// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UsdcMultiLendingVault } from "./controller/UsdcLendingStrategy.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/**
 * @title StrategyBootstrapper
 * @notice One-shot adapter registration for UsdcMultiLendingVault
 * @dev Audit-grade solution for "privileged deployer" problem:
 *
 * PROBLEM: Strategy grants DEFAULT_ADMIN_ROLE only to Timelock.
 *          Deployer cannot register adapters without admin rights.
 *          Registering via Timelock governance requires delay = bad UX.
 *
 * SOLUTION: Bootstrapper is a one-shot contract that:
 *   1. Receives BOOTSTRAP_ROLE from strategy constructor
 *   2. Registers all adapters in a single batch call
 *   3. Renounces BOOTSTRAP_ROLE permanently
 *   4. Can never be used again (used flag + role renounced)
 *
 * SECURITY:
 *   - Deployer has NO admin rights
 *   - Bootstrapper has ONLY BOOTSTRAP_ROLE (not DEFAULT_ADMIN)
 *   - One-shot: after bootstrap(), role is renounced forever
 *   - Immutable: strategy address set in constructor
 *   - Only deployer can call bootstrap() (prevents frontrunning)
 *
 * INVARIANT: After bootstrap(), no address has BOOTSTRAP_ROLE.
 */
contract StrategyBootstrapper is Initializable {
    // ═══════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════

    error AlreadyBootstrapped();
    error NotDeployer();
    error EmptyAdapters();
    error ZeroAddress();

    // ═══════════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice The strategy this bootstrapper is bound to
    // --- V10 Storage (was immutable in V9.x; logically immutable post-initialize) ---
    UsdcMultiLendingVault public strategy;

    /// @notice The deployer who can execute bootstrap
    address public deployer;

    /// @notice One-shot flag - prevents reuse
    bool public used;

    // ═══════════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════════

    event Bootstrapped(address indexed strategy, uint256 adapterCount);
    event AdapterRegistered(address indexed adapter);

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Create bootstrapper bound to a strategy
     * @param _strategy The UsdcMultiLendingVault to bootstrap
     * @dev Strategy must grant BOOTSTRAP_ROLE to this contract in its constructor
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice One-shot initialization called atomically by AdapterFactory.
    /// @dev deployer_ is explicit — msg.sender in initialize() would be AdapterFactory, not deployer.
    function initialize(address payable _strategy, address deployer_) external initializer {
        if (_strategy == address(0) || deployer_ == address(0)) revert ZeroAddress();
        strategy = UsdcMultiLendingVault(_strategy);
        deployer = deployer_;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // BOOTSTRAP (ONE-SHOT)
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Register all adapters and renounce BOOTSTRAP_ROLE
     * @param adapters Array of adapter addresses to register and enable
     * @dev Can only be called once by deployer. After this:
     *      - All adapters are registered and enabled
     *      - BOOTSTRAP_ROLE is renounced (no one has it)
     *      - This function reverts on any subsequent call
     */
    function bootstrap(address[] calldata adapters) external {
        // One-shot guard
        if (used) revert AlreadyBootstrapped();
        if (msg.sender != deployer) revert NotDeployer();
        if (adapters.length == 0) revert EmptyAdapters();

        // Mark as used FIRST (reentrancy protection)
        used = true;

        // Whitelist + register + enable each adapter atomically.
        // whitelistAdapter accepts BOOTSTRAP_ROLE so no DEFAULT_ADMIN needed.
        for (uint256 i = 0; i < adapters.length; i++) {
            address adapter = adapters[i];
            if (adapter == address(0)) revert ZeroAddress();

            (bool wlOk, bytes memory wlErr) = address(strategy).call(
                abi.encodeWithSignature("whitelistAdapter(address,bool)", adapter, true)
            );
            if (!wlOk) { assembly { revert(add(wlErr, 32), mload(wlErr)) } }

            // Skip addAdapter if already registered (idempotent)
            if (!strategy.isAdapter(adapter)) {
                strategy.addAdapter(adapter);
                strategy.toggleAdapter(adapter, true);
                emit AdapterRegistered(adapter);
            }
        }

        // Renounce BOOTSTRAP_ROLE - this is permanent
        bytes32 BOOTSTRAP_ROLE = strategy.BOOTSTRAP_ROLE();
        strategy.renounceRole(BOOTSTRAP_ROLE, address(this));

        emit Bootstrapped(address(strategy), adapters.length);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if bootstrap has been executed
     * @return True if bootstrap() was called
     */
    function isBootstrapped() external view returns (bool) {
        return used;
    }

    /**
     * @notice Check if this bootstrapper still has BOOTSTRAP_ROLE
     * @return True if bootstrapper can still call addAdapter
     */
    function hasBootstrapRole() external view returns (bool) {
        bytes32 BOOTSTRAP_ROLE = strategy.BOOTSTRAP_ROLE();
        return strategy.hasRole(BOOTSTRAP_ROLE, address(this));
    }
}
