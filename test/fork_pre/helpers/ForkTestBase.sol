// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ═══════════════════════════════════════════════════════════════════════════
// ForkTestBase.sol — Shared base for V10 adapter fork tests
// ───────────────────────────────────────────────────────────────────────────
// All canonical addresses from DeployUsdcLendingStrategy.s.sol (verified).
// Protocol existence at block 472761449 (~December 2024 Arbitrum):
//  ✓ CONFIRMED: USDC, Aave V3, Comet, Fluid (enabled 2024-10-15),
//               Euler V2 (deployed 2024-09-04), Dolomite dUSDC
//  ? UNCERTAIN: Morpho MetaMorpho vaults (DefiLlama first tracked 2025-10-09)
//               → MorphoAdapterFork uses code-existence check + vm.skip if absent
// ═══════════════════════════════════════════════════════════════════════════

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract ForkTestBase is Test {

    // ── Canonical Arbitrum mainnet addresses ────────────────────────────────

    address constant USDC       = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant USDC_WHALE = 0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7;

    // Aave V3
    address constant AAVE_V3_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant AAVE_AUSDC   = 0x724dc807b04555b71ed48a6896b6F41593b8C637;

    // Compound III (Comet)
    address constant COMET_USDC = 0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf;

    // Fluid
    address constant FLUID_FUSDC = 0x1A996cb54bb95462040408C06122D45D6Cdb6096;

    // Euler V2 — 4 EVaults for USDC (from deployment config)
    address constant EULER_VAULT_1 = 0x6aFB8d3F6D4A34e9cB2f217317f4dc8e05Aa673b;
    address constant EULER_VAULT_2 = 0x44C10DA836d2aBe881b77bbB0b3DCE5f85C0C1Cc;
    address constant EULER_VAULT_3 = 0x05d28A86E057364F6ad1a88944297E58Fc6160b3;
    address constant EULER_VAULT_4 = 0x0a1eCC5Fe8C9be3C809844fcBe615B46A869b899;

    // Morpho MetaMorpho vaults (may not exist at DEFAULT_FORK_BLOCK — see note above)
    address constant MORPHO_VAULT_1 = 0x7e97fa6893871A2751B5fE961978DCCb2c201E65; // Gauntlet USDC Core
    address constant MORPHO_VAULT_2 = 0x4B6F1C9E5d470b97181786b26da0d0945A7cf027; // Hyperithm USDC Apex
    address constant MORPHO_VAULT_4 = 0x5c0C306Aaa9F877de636f4d5822cA9F2E81563BA; // Steakhouse HY USDC
    address constant MORPHO_VAULT_6 = 0x7c574174DA4b2be3f705c6244B4BfA0815a8B3Ed; // Gauntlet USDC Prime
    address constant MORPHO_VAULT_8 = 0x36b69949d60d06ECcC14DE0Ae63f4E00cc2cd8B9; // Yearn Degen USDC

    // Dolomite — dUSDC ERC-4626 vault + infrastructure addresses
    address constant DOLOMITE_dUSDC    = 0x444868B6e8079ac2c55eea115250f92C2b2c4D14;
    address constant DOLOMITE_MARGIN   = 0x6Bd780E7fDf01D77e4d475c821f1e7AE05409072;
    address constant DOLOMITE_DW_PROXY = 0xAdB9D68c613df4AA363B42161E1282117C7B9594;
    uint256 constant DOLOMITE_USDC_MARKET_ID = 17;

    // Uniswap V3 Router (for swap tests in later phases)
    address constant UNI_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // Standard test parameters
    uint256 constant DEFAULT_FORK_BLOCK = 472_761_449;
    uint256 constant SEED_USDC          = 1_000_000e6; // 1M USDC
    uint256 constant MAX_CAP            = 10_000_000e6; // 10M USDC

    // ── Fork setup ───────────────────────────────────────────────────────────

    /// @notice Setup Arbitrum fork; vm.skip(true) when ARBITRUM_RPC_URL is absent.
    function _setupFork() internal returns (string memory rpc) {
        rpc = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return "";
        }
        vm.createSelectFork(rpc, DEFAULT_FORK_BLOCK);
        require(block.chainid == 42161, "Not Arbitrum mainnet");
    }

    /// @notice Setup fork + require a specific env-var address (for optional adapters).
    function _setupForkWithAddr(string memory envKey)
        internal
        returns (string memory rpc, address addr)
    {
        rpc = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return ("", address(0)); }
        addr = vm.envOr(envKey, address(0));
        if (addr == address(0)) { vm.skip(true); return ("", address(0)); }
        vm.createSelectFork(rpc, DEFAULT_FORK_BLOCK);
        require(block.chainid == 42161, "Not Arbitrum mainnet");
    }

    // ── USDC seeding helpers ─────────────────────────────────────────────────

    function _seedUsdc(address recipient, uint256 amount) internal {
        vm.prank(USDC_WHALE);
        IERC20(USDC).transfer(recipient, amount);
    }

    function _dealUsdc(address recipient, uint256 amount) internal {
        deal(USDC, recipient, amount);
    }
}
