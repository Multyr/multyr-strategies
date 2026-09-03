#!/usr/bin/env python3
"""Generate direct-Safe batches for a fresh Arbitrum strategy deployment."""

import argparse
import json
import os
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, List, Sequence


REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CORE_BOOK = REPO_ROOT.parent / "multyr-core" / "broadcast" / "core-addresses.json"
DEFAULT_STRATEGY_BOOK = REPO_ROOT / "broadcast" / "strategy-addresses.json"
DEFAULT_ADMIN_ROLE = "0x" + "00" * 32
KEEPER_ROLE = "0xfc8737ab85eb45125971625a9ebdb75cc78e01d5c1fa80c4c6e5203f47bc4fab"

# abi.encode(uint8(3), uint256(0)): StrategyUpkeep OP_POKE_APY.
POKE_APY_PERFORM_DATA = "0x" + ("0" * 63) + "3" + ("0" * 64)


def load_json(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def resolve_cast(explicit: str) -> str:
    candidate = explicit or "cast"
    found = shutil.which(candidate)
    if found:
        return found
    if explicit and Path(explicit).is_file():
        return explicit
    foundry_cast = Path.home() / ".foundry" / "bin" / "cast"
    if foundry_cast.is_file():
        return str(foundry_cast)
    raise SystemExit("Foundry cast is required to encode and validate Safe calls")


def encode(cast_bin: str, signature: str, args: Sequence[str]) -> str:
    result = subprocess.run(
        [cast_bin, "calldata", signature, *args],
        check=True,
        capture_output=True,
        text=True,
    )
    calldata = result.stdout.strip()
    if not calldata.startswith("0x"):
        raise RuntimeError(f"unexpected cast output for {signature}")
    return calldata


def cast_call(
    cast_bin: str,
    rpc_url: str,
    target: str,
    signature: str,
    *args: str,
) -> str:
    result = subprocess.run(
        [cast_bin, "call", target, signature, *args, "--rpc-url", rpc_url],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise SystemExit(
            f"on-chain validation failed for {target} {signature}; "
            "this is likely the unsafe legacy deployment"
        )
    return result.stdout.strip()


def require_address(actual: str, expected: str, label: str) -> None:
    if actual.lower() != expected.lower():
        raise SystemExit(f"{label}: expected {expected}, got {actual}")


def validate_fresh_strategy(
    cast_bin: str,
    rpc_url: str,
    safe: str,
    strategy_book: Dict[str, Any],
) -> None:
    """Fail closed if the address book does not describe the fixed deployment."""
    registry = strategy_book.get("protocolRegistry", "")
    if not registry:
        raise SystemExit("strategy address book has no protocolRegistry")

    chain_result = subprocess.run(
        [cast_bin, "chain-id", "--rpc-url", rpc_url],
        check=False,
        capture_output=True,
        text=True,
    )
    if chain_result.returncode != 0:
        raise SystemExit("unable to read chain id from RPC_URL")
    if chain_result.stdout.strip() != "42161":
        raise SystemExit(
            f"RPC reports chain id {chain_result.stdout.strip()}, expected 42161"
        )

    require_address(
        cast_call(cast_bin, rpc_url, registry, "owner()(address)"),
        safe,
        "ProtocolRegistry owner",
    )
    require_address(
        cast_call(
            cast_bin,
            rpc_url,
            strategy_book["strategyUpkeep"],
            "owner()(address)",
        ),
        safe,
        "StrategyUpkeep owner",
    )

    for key in ("strategy", "adapterFactory"):
        has_admin = cast_call(
            cast_bin,
            rpc_url,
            strategy_book[key],
            "hasRole(bytes32,address)(bool)",
            DEFAULT_ADMIN_ROLE,
            safe,
        )
        if has_admin != "true":
            raise SystemExit(f"{key}: Safe does not hold DEFAULT_ADMIN_ROLE")

    for key in ("morphoAdapter", "cometAdapter", "eulerAdapter", "dolomiteAdapter"):
        require_address(
            cast_call(cast_bin, rpc_url, strategy_book[key], "registry()(address)"),
            registry,
            f"{key} registry",
        )


def tx(
    cast_bin: str,
    step: str,
    target: str,
    signature: str,
    *args: str,
) -> Dict[str, Any]:
    return {
        "_step": step,
        "to": target,
        "value": "0",
        "data": encode(cast_bin, signature, args),
        "contractMethod": None,
        "contractInputsValues": None,
    }


def batch(
    name: str,
    description: str,
    safe: str,
    transactions: List[Dict[str, Any]],
) -> Dict[str, Any]:
    return {
        "version": "1.0",
        "chainId": "42161",
        "createdAt": int(time.time() * 1000),
        "meta": {
            "name": name,
            "description": description,
            "txBuilderVersion": "1.18.0",
            "createdFromSafeAddress": safe,
            "createdFromOwnerAddress": "",
        },
        "transactions": transactions,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--core-addresses", type=Path, default=DEFAULT_CORE_BOOK)
    parser.add_argument("--strategy-addresses", type=Path, default=DEFAULT_STRATEGY_BOOK)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "safe-batches",
    )
    parser.add_argument("--safe", help="Override the Safe; defaults to core governor")
    parser.add_argument("--cast", default="", help="Path or command name for cast")
    parser.add_argument("--rpc-url", default=os.environ.get("RPC_URL", ""))
    args = parser.parse_args()

    core = load_json(args.core_addresses)
    strategy_book = load_json(args.strategy_addresses)
    if int(core["chainId"]) != 42161 or int(strategy_book["chainId"]) != 42161:
        raise SystemExit("both address books must be for Arbitrum One (42161)")

    cast_bin = resolve_cast(args.cast)
    safe = args.safe or core["governor"]
    if not args.rpc_url:
        raise SystemExit("RPC_URL or --rpc-url is required")
    validate_fresh_strategy(cast_bin, args.rpc_url, safe, strategy_book)

    vault = core["vault"]
    global_config = core["globalConfig"]
    router = core["strategyRouter"]
    health = core["healthRegistry"]
    strategy = strategy_book["strategy"]
    upkeep = strategy_book["strategyUpkeep"]

    vault_cap = str(20_000 * 10**6)
    one_usdc = str(10**6)

    phase1 = [
        tx(cast_bin, "1 - accept CoreVault ownership", vault, "acceptOwnerTransfer()"),
        tx(
            cast_bin,
            "2 - set vault/user cap=20,000 USDC and min deposit=1 USDC",
            global_config,
            "setVaultDepositLimits(address,uint256,uint256,uint256)",
            vault,
            vault_cap,
            vault_cap,
            one_usdc,
        ),
        tx(
            cast_bin,
            "3 - TEST MODE: 100% instant exit, 1 USDC claim floor, no lock",
            global_config,
            "setVaultWithdrawalOverride(address,(uint16,uint256,uint256,uint256,uint64))",
            vault,
            "(10000,0,0,1000000,0)",
        ),
        tx(
            cast_bin,
            "4 - lower strategy deployment floor to 1 USDC",
            global_config,
            "setVaultGovCaps(address,uint64,uint256,uint16,uint16,uint16,uint64,uint256,uint256,uint16)",
            vault,
            "172800",
            "500000000000000000",
            "500",
            "200",
            "200",
            "604800",
            one_usdc,
            "1000000",
            "3000",
        ),
        tx(
            cast_bin,
            "5 - remove low-TVL 50% global strategy-adapter ceiling",
            strategy,
            "setRebalanceParams(uint16,uint16,uint16,uint32,uint16,uint16,uint16)",
            "3",
            "2",
            "50",
            "86400",
            "80",
            "0",
            "500",
        ),
        tx(
            cast_bin,
            "6 - authorize strategy health reporting",
            health,
            "setAuthorizedCaller(address,bool)",
            strategy,
            "true",
        ),
        tx(
            cast_bin,
            "7 - temporarily grant Safe KEEPER_ROLE",
            strategy,
            "grantRole(bytes32,address)",
            KEEPER_ROLE,
            safe,
        ),
        tx(
            cast_bin,
            "8 - refresh all adapter liquidity caches",
            strategy,
            "pokeLiquidityBatch(uint256,uint256)",
            "0",
            "10",
        ),
        tx(
            cast_bin,
            "9 - remove temporary Safe KEEPER_ROLE",
            strategy,
            "revokeRole(bytes32,address)",
            KEEPER_ROLE,
            safe,
        ),
        tx(
            cast_bin,
            "10 - start router's mandatory two-day delay",
            router,
            "proposeStrategyAllowlist(address)",
            strategy,
        ),
    ]

    phase2 = [
        tx(
            cast_bin,
            "1 - execute matured allowlist proposal",
            router,
            "executeStrategyAllowlist(address)",
            strategy,
        ),
        tx(
            cast_bin,
            "2 - register and enable strategy",
            router,
            "register(address,uint16,uint16)",
            strategy,
            "100",
            "10000",
        ),
        tx(
            cast_bin,
            "3 - allow up to 100% router allocation",
            router,
            "setMaxStrategyBps(address,uint16)",
            strategy,
            "10000",
        ),
        tx(
            cast_bin,
            "4 - set per-strategy loss cap to 50 bps",
            router,
            "setLossCapPerStrategy(address,uint16)",
            strategy,
            "50",
        ),
        tx(
            cast_bin,
            "5 - refresh APY and external-TVL caches",
            upkeep,
            "performUpkeep(bytes)",
            POKE_APY_PERFORM_DATA,
        ),
        tx(
            cast_bin,
            "6 - temporarily grant Safe KEEPER_ROLE",
            strategy,
            "grantRole(bytes32,address)",
            KEEPER_ROLE,
            safe,
        ),
        tx(
            cast_bin,
            "7 - refresh all adapter liquidity caches",
            strategy,
            "pokeLiquidityBatch(uint256,uint256)",
            "0",
            "10",
        ),
        tx(
            cast_bin,
            "8 - remove temporary Safe KEEPER_ROLE",
            strategy,
            "revokeRole(bytes32,address)",
            KEEPER_ROLE,
            safe,
        ),
        tx(cast_bin, "9 - unpause CoreVault", vault, "unpauseAll()"),
    ]

    restore = [
        tx(
            cast_bin,
            "1 - restore normal instant withdrawal guards",
            global_config,
            "setVaultWithdrawalOverride(address,(uint16,uint256,uint256,uint256,uint64))",
            vault,
            "(1000,0,0,100000000,86400)",
        ),
        tx(
            cast_bin,
            "2 - restore the 10 USDC strategy deployment floor",
            global_config,
            "setVaultGovCaps(address,uint64,uint256,uint16,uint16,uint16,uint64,uint256,uint256,uint16)",
            vault,
            "172800",
            "500000000000000000",
            "500",
            "200",
            "200",
            "604800",
            "10000000",
            "1000000",
            "3000",
        ),
    ]

    outputs = {
        "01-safe-config-and-propose.json": batch(
            "Multyr fresh strategy: configure + propose",
            "Direct Safe calls with test-mode limits for the 3 USDC smoke flow.",
            safe,
            phase1,
        ),
        "02-safe-activate-after-router-delay.json": batch(
            "Multyr fresh strategy: activate after router delay",
            "Execute only after strategyAllowlistEta, then refresh and unpause.",
            safe,
            phase2,
        ),
        "03-safe-restore-normal-withdrawal-guards.json": batch(
            "Multyr: restore normal withdrawal guards",
            "Optional batch; preserves the 20,000 USDC vault cap.",
            safe,
            restore,
        ),
    }

    args.output_dir.mkdir(parents=True, exist_ok=True)
    for filename, payload in outputs.items():
        destination = args.output_dir / filename
        with destination.open("w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2)
            handle.write("\n")
        print(destination)


if __name__ == "__main__":
    main()
