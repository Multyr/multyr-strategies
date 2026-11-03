#!/usr/bin/env python3
"""
G-transactions: Separate-transaction adapter gas calibration runner.

Launches its own local Anvil child process on a dedicated port (CREATE_NO_WINDOW
on Windows so the console is hidden). All write RPC calls are guarded: any attempt
to send eth_sendTransaction / eth_sendRawTransaction or an anvil_* method to a URL
other than http://127.0.0.1:{DEDICATED_PORT} raises a hard RuntimeError before the
request is sent.

Public RPC endpoints are consumed exclusively by Anvil as a fork source. The runner
itself talks only to its own Anvil instance for every operation (reads and writes).

Impersonation of the holder is local only (anvil_impersonateAccount). No private key
is used or read. Nothing is broadcast to a public chain.

FAIL_UNIMPLEMENTED: cases that carry status="FAIL_UNIMPLEMENTED" in cases.json are
emitted verbatim as that status. They are never coerced to PASS and never silently
omitted from the summary.

L2 note: Anvil fork does not reproduce Arbitrum ArbGasInfo (0x6c) native gas
posting/sequencer costs. gasUsed in receipts reflects EVM execution gas only.
L2-specific components require a separate real Arbitrum RPC quote.

Usage:
    python runner.py [--case <id>] [--emit-fork-hash]

Dependencies: Python standard library and installed Foundry binaries. Optional Keccak packages accelerate hashing; cast is the fallback.

Artifact paths:
    deployments/.../transaction-gas/runs/<run>/<case_id>/result.json   full per-case trace
    deployments/.../transaction-gas/runs/<run>/summary.json            aggregate run summary
"""

import argparse
import atexit
import json
import os
import pathlib
import subprocess
import sys
import time
import socket
import urllib.request
import urllib.error
import hashlib
from typing import Any, Optional

# ── Constants ─────────────────────────────────────────────────────────────────

DEDICATED_PORT: int = 18545
LOCAL_ANVIL_URL: str = f"http://127.0.0.1:{DEDICATED_PORT}"

RUNNER_DIR: pathlib.Path = pathlib.Path(__file__).parent.resolve()
# Runner lives at pb/deployments/.../G-transactions/ — four levels below project root
PROJECT_ROOT: pathlib.Path = RUNNER_DIR.parent.parent.parent.parent
ARTIFACTS_DIR: pathlib.Path = PROJECT_ROOT / "deployments/lending-full-validation-20261101/production/transaction-gas/runs" / (time.strftime("%Y%m%dT%H%M%S", time.gmtime()) + "-" + str(os.getpid()))
CASES_FILE: pathlib.Path = RUNNER_DIR / "cases.json"

# Windows: suppress console window for the Anvil child process
CREATE_NO_WINDOW: int = 0x08000000

# ── Audited RPC method allowlists ─────────────────────────────────────────────

READ_ONLY_METHODS: frozenset = frozenset({
    "eth_call",
    "eth_getBalance",
    "eth_getCode",
    "eth_getStorageAt",
    "eth_blockNumber",
    "eth_chainId",
    "eth_getTransactionCount",
    "eth_getTransactionReceipt",
    "eth_getTransactionByHash",
    "eth_getLogs",
    "eth_getBlockByNumber",
    "eth_getBlockByHash",
    "net_version",
    "eth_gasPrice",
    "eth_estimateGas",
    "web3_clientVersion",
})

WRITE_METHODS: frozenset = frozenset({
    "eth_sendRawTransaction",
    "eth_sendTransaction",
})

ANVIL_METHODS: frozenset = frozenset({
    "anvil_impersonateAccount",
    "anvil_stopImpersonatingAccount",
    "anvil_mine",
})

# ── Keccak-256 (Ethereum variant, not NIST SHA-3) ────────────────────────────

def keccak256(data: bytes) -> bytes:
    try:
        from Crypto.Hash import keccak  # pycryptodome
        k = keccak.new(digest_bits=256)
        k.update(data)
        return k.digest()
    except ImportError:
        pass
    try:
        import sha3 as _sha3  # pysha3 patches hashlib.sha3_256 → Keccak
        return _sha3.keccak_256(data).digest()
    except ImportError:
        result = subprocess.run(["cast", "keccak"], input="0x" + data.hex(),
                                text=True, capture_output=True, check=True)
        digest = bytes.fromhex(result.stdout.strip().removeprefix("0x"))
        if len(digest) != 32:
            raise RuntimeError("Invalid Keccak output")
        return digest


def fn_selector(sig: str) -> bytes:
    return keccak256(sig.encode("ascii"))[:4]


# ── Minimal ABI encoder (static types only) ───────────────────────────────────

def abi_encode(types: list[str], values: list) -> bytes:
    out = b""
    for t, v in zip(types, values):
        if t == "uint256":
            out += int(v).to_bytes(32, "big")
        elif t == "address":
            s = str(v).lower().removeprefix("0x")
            if len(s) != 40:
                raise ValueError(f"Invalid address value: {v!r}")
            out += bytes(12) + bytes.fromhex(s)
        else:
            raise ValueError(
                f"ABI type '{t}' not in static encoder. "
                "Add support explicitly if this type is genuinely required."
            )
    return out


def encode_call(sig: str, types: list[str], values: list) -> str:
    if any(t not in ("uint256", "address") for t in types):
        result = subprocess.run(["cast", "calldata", sig, *map(str, values)],
                                capture_output=True, text=True, encoding="utf-8", check=True)
        encoded = result.stdout.strip()
        bytes.fromhex(encoded.removeprefix("0x"))
        return encoded
    data = fn_selector(sig) + abi_encode(types, values)
    return "0x" + data.hex()


def decode_uint256(hex_str: str) -> int:
    raw = bytes.fromhex(hex_str.removeprefix("0x").zfill(64))
    return int.from_bytes(raw[:32], "big")


# EIP-55 checksum address
def checksum_addr(addr: str) -> str:
    h = addr.lower().removeprefix("0x")
    digest = keccak256(h.encode("ascii")).hex()
    out = "0x" + "".join(c.upper() if int(digest[i], 16) >= 8 else c for i, c in enumerate(h))
    return out


# ── RLP / CREATE address derivation ──────────────────────────────────────────

def _rlp_uint(n: int) -> bytes:
    if n == 0:
        return b"\x80"
    if n <= 0x7F:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 + len(b)]) + b


def compute_create_address(deployer: str, nonce: int) -> str:
    addr_bytes = bytes.fromhex(deployer.lower().removeprefix("0x"))
    addr_rlp = b"\x94" + addr_bytes          # 0x80+20 = 0x94
    nonce_rlp = _rlp_uint(nonce)
    payload = addr_rlp + nonce_rlp
    if len(payload) <= 55:
        rlp_data = bytes([0xC0 + len(payload)]) + payload
    else:
        # Long list (shouldn't occur for a 20-byte addr + small nonce RLP)
        llen = (len(payload).bit_length() + 7) // 8
        rlp_data = (bytes([0xF7 + llen])
                    + len(payload).to_bytes(llen, "big")
                    + payload)
    return checksum_addr("0x" + keccak256(rlp_data).hex()[24:])


# ── Anvil process management ──────────────────────────────────────────────────

_anvil_proc: Optional[subprocess.Popen] = None  # type: ignore[type-arg]
_anvil_log = None
_anvil_log_path = None


def _kill_anvil() -> None:
    global _anvil_log
    global _anvil_proc
    if _anvil_proc is not None:
        _anvil_proc.terminate()
        try:
            _anvil_proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            _anvil_proc.kill()
        _anvil_proc = None
    if _anvil_log is not None:
        _anvil_log.close()
        _anvil_log = None


atexit.register(_kill_anvil)


def start_anvil(fork_url: str, fork_block: int) -> None:
    global _anvil_proc
    global _anvil_log, _anvil_log_path
    _kill_anvil()
    # Never reuse a service already listening on the designated write endpoint.
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", DEDICATED_PORT))

    cmd = [
        "anvil",
        "--fork-url", fork_url,
        "--fork-block-number", str(fork_block),
        "--port", str(DEDICATED_PORT),
        "--host", "127.0.0.1",
        "--compute-units-per-second", "20",
        "--fork-retry-backoff", "2000",
        "--silent",
    ]
    ARTIFACTS_DIR.mkdir(parents=True, exist_ok=True)
    _anvil_log_path = ARTIFACTS_DIR / ("anvil-" + str(fork_block) + ".log")
    _anvil_log = open(_anvil_log_path, "wb")
    popen_kwargs: dict = {"stdout": _anvil_log, "stderr": _anvil_log}
    if sys.platform == "win32":
        popen_kwargs["creationflags"] = CREATE_NO_WINDOW  # hidden on Windows

    _anvil_proc = subprocess.Popen(cmd, **popen_kwargs)

    # Wait until Anvil is ready (max 45 s)
    deadline = time.monotonic() + 45.0
    while time.monotonic() < deadline:
        if _anvil_proc.poll() is not None:
            raise RuntimeError("Anvil exited during startup; retained log: " + str(_anvil_log_path))
        try:
            resp = _rpc_raw(LOCAL_ANVIL_URL, "eth_blockNumber", [])
            if resp.get("result") is not None:
                version = _rpc_raw(LOCAL_ANVIL_URL, "web3_clientVersion", []).get("result", "")
                if "anvil" not in version.lower() or _anvil_proc.poll() is not None:
                    raise RuntimeError("Owned Anvil child identity required")
                return
        except Exception:
            pass
        time.sleep(0.3)

    raise RuntimeError("Anvil did not become ready within 45 seconds.")


# ── RPC client with URL guard ─────────────────────────────────────────────────

_rpc_seq: int = 0
RPC_TRACE: list = []


def _guard_rpc(url: str, method: str) -> None:
    if method in WRITE_METHODS or method in ANVIL_METHODS:
        if url != LOCAL_ANVIL_URL:
            raise RuntimeError("Local-only RPC mutation boundary")
    elif method not in READ_ONLY_METHODS:
        raise RuntimeError("RPC method not allowlisted: " + method)


def _rpc_raw(url: str, method: str, params: list) -> dict:
    _guard_rpc(url, method)
    global _rpc_seq
    _rpc_seq += 1
    payload = {"jsonrpc": "2.0", "method": method, "params": params, "id": _rpc_seq}
    entry = {"url": url, "request": payload}
    RPC_TRACE.append(entry)
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    request = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json", "User-Agent": "lending-validation/1.0"})
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=45) as response:
            body = response.read().decode("utf-8")
            status = response.status
    except urllib.error.HTTPError as error:
        entry["httpStatus"] = error.code
        entry["body"] = error.read().decode("utf-8", errors="replace")
        raise
    entry["httpStatus"] = status
    entry["body"] = body
    return json.loads(body)



def rpc(url: str, method: str, params: list) -> Any:
    """
    URL-guarded RPC dispatcher.

    Raises RuntimeError before sending if:
    - method is a write or anvil_* method AND url != LOCAL_ANVIL_URL
    - method is not in the audited allowlist (reads) and not write/anvil
    """
    is_write = method in WRITE_METHODS
    is_anvil = method in ANVIL_METHODS

    if (is_write or is_anvil) and url != LOCAL_ANVIL_URL:
        raise RuntimeError(
            f"SECURITY GUARD VIOLATION: '{method}' is a write/Anvil method.\n"
            f"  Attempted URL : {url!r}\n"
            f"  Only permitted: {LOCAL_ANVIL_URL!r}\n"
            "All writes must go to the local Anvil child process only."
        )

    if not (is_write or is_anvil) and method not in READ_ONLY_METHODS:
        raise RuntimeError(
            f"RPC method '{method}' is not in the audited read-only allowlist.\n"
            "Add it explicitly with justification."
        )

    resp = _rpc_raw(url, method, params)
    if "error" in resp:
        raise RuntimeError(f"RPC error for '{method}': {resp['error']}")
    return resp["result"]


# ── Transaction helpers ───────────────────────────────────────────────────────

def send_tx(
    from_addr: str,
    to: Optional[str],
    data: str,
    gas: Optional[int] = None,
) -> dict:
    """
    Send a transaction from an impersonated account on local Anvil.
    Returns a receipt record with gasUsed, effectiveGasPrice, calldata, etc.
    Raises if the transaction reverts.
    """
    tx: dict = {"from": from_addr, "data": data}
    if to is not None:
        tx["to"] = to
    if gas is None:
        estimate = int(rpc(LOCAL_ANVIL_URL, "eth_estimateGas", [tx]), 16)
        header = rpc(LOCAL_ANVIL_URL, "eth_getBlockByNumber", ["latest", False])
        limit = int(header["gasLimit"], 16)
        if estimate > limit:
            raise RuntimeError("Estimated transaction exceeds real fork block gas limit")
        # Estimate runs against the current header; a mined block can trigger
        # protocol accrual and extra cold storage writes. This is a resource
        # limit only: measurements always use the actual receipt's gasUsed.
        gas = min(limit, max(1_000_000, estimate * 2 + 1000))
    tx["gas"] = hex(gas)

    tx_hash: str = rpc(LOCAL_ANVIL_URL, "eth_sendTransaction", [tx])

    # Poll for receipt (Anvil auto-mines)
    deadline = time.monotonic() + 30.0
    receipt = None
    while time.monotonic() < deadline:
        receipt = rpc(LOCAL_ANVIL_URL, "eth_getTransactionReceipt", [tx_hash])
        if receipt is not None:
            break
        time.sleep(0.15)

    if receipt is None:
        raise RuntimeError(f"No receipt found within 30 s for tx {tx_hash}")

    status = int(receipt.get("status", "0x0"), 16)
    if status == 0:
        raise RuntimeError(
            f"Transaction reverted: {tx_hash}\n"
            f"  calldata prefix: {data[:66]}"
        )

    return {
        "txHash": tx_hash,
        "blockNumber": int(receipt["blockNumber"], 16),
        "gasUsed": int(receipt["gasUsed"], 16),
        "effectiveGasPrice": int(receipt.get("effectiveGasPrice", "0x0"), 16),
        "status": status,
        "logs": receipt.get("logs", []),
        "calldata": data,
    }


# ── ERC-20 helpers ────────────────────────────────────────────────────────────

def erc20_balance_of(token: str, owner: str) -> int:
    data = encode_call("balanceOf(address)", ["address"], [owner])
    result = rpc(LOCAL_ANVIL_URL, "eth_call", [{"to": token, "data": data}, "latest"])
    return decode_uint256(result)


def erc20_approve(holder: str, token: str, spender: str, amount: int) -> dict:
    data = encode_call("approve(address,uint256)", ["address", "uint256"], [spender, amount])
    return send_tx(holder, token, data)


# ── Adapter state snapshot ────────────────────────────────────────────────────

def _adapter_view(adapter: str, sig: str) -> Any:
    """Call a zero-arg view returning uint256. Returns int or error string."""
    try:
        data = encode_call(sig, [], [])
        result = rpc(LOCAL_ANVIL_URL, "eth_call", [{"to": adapter, "data": data}, "latest"])
        return decode_uint256(result)
    except Exception as exc:
        return f"CALL_FAILED:{exc}"


def snapshot(underlying: str, adapter: str, holder: str, reference: dict) -> dict:
    receipt = reference["token"]
    shares = erc20_balance_of(receipt, adapter)
    kind = reference["kind"]
    if kind == "underlying_balance":
        invested = shares
    elif kind == "vtoken":
        rate = _adapter_view(receipt, "exchangeRateStored()")
        if not isinstance(rate, int):
            raise RuntimeError("Actual vToken exchange rate unavailable")
        invested = shares * rate // 10**18
    elif kind == "erc4626":
        data = encode_call("convertToAssets(uint256)", ["uint256"], [shares])
        invested = decode_uint256(rpc(LOCAL_ANVIL_URL, "eth_call", [{"to": receipt, "data": data}, "latest"]))
    else:
        raise RuntimeError("Independent receipt reference missing or unsupported")
    idle = erc20_balance_of(underlying, adapter)
    total = _adapter_view(adapter, "totalAssets()")
    if not isinstance(total, int) or abs(total - (invested + idle)) > 2:
        raise RuntimeError("Actual adapter NAV disagrees with independent receipt state")
    supply_data = encode_call("totalSupply()", [], [])
    supply = decode_uint256(rpc(LOCAL_ANVIL_URL, "eth_call", [{"to": underlying, "data": supply_data}, "latest"]))
    return {
        "holder_underlying": erc20_balance_of(underlying, holder),
        "adapter_underlying_idle": erc20_balance_of(underlying, adapter),
        "adapter_totalAssets": total,
        "independent_receipt_shares": shares,
        "independent_receipt_assets": invested,
        "underlying_totalSupply": supply,
        "underlying_native_backing": (int(rpc(LOCAL_ANVIL_URL, "eth_getBalance", [underlying, "latest"]), 16)
                                      if underlying.lower() == "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2" else None),
        "adapter_investedAssets": _adapter_view(adapter, "investedAssets()"),
        "adapter_idleAssetBalance": _adapter_view(adapter, "idleAssetBalance()"),
        "adapter_withdrawableAssets": _adapter_view(adapter, "withdrawableAssets()"),
    }


# ── forge inspect — creation bytecode ────────────────────────────────────────

def get_creation_bytecode(source_file: str, contract_name: str) -> str:
    """
    Invoke `forge inspect <source>:<contract> bytecode --root <PROJECT_ROOT>`.
    Captures stdout only (never passes bytecode via argv — avoids OS arg-length limits).
    Returns 0x-prefixed hex string.
    """
    qualified = f"{source_file}:{contract_name}"
    proc = subprocess.run(
        ["forge", "inspect", qualified, "bytecode", "--root", str(PROJECT_ROOT)],
        capture_output=True,
        text=True,
        timeout=180,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"forge inspect failed for {qualified!r}:\n"
            f"stdout: {proc.stdout[:500]}\n"
            f"stderr: {proc.stderr[:500]}"
        )
    bytecode = proc.stdout.strip()
    if not bytecode.startswith("0x"):
        bytecode = "0x" + bytecode
    if len(bytecode) < 4:
        raise RuntimeError(f"forge inspect returned empty bytecode for {qualified!r}")
    return bytecode


# ── Adapter deployment ────────────────────────────────────────────────────────

def deploy_adapter(deployer: str, creation_bytecode: str) -> tuple[dict, str]:
    """
    Deploy adapter contract from deployer. Returns (receipt_record, deployed_address).
    Address is derived via RLP-based CREATE formula (keccak256(rlp([deployer, nonce]))[12:])
    and then verified via eth_getCode.
    """
    nonce_hex: str = rpc(LOCAL_ANVIL_URL, "eth_getTransactionCount", [deployer, "latest"])
    nonce: int = int(nonce_hex, 16)

    receipt = send_tx(deployer, None, creation_bytecode, gas=6_000_000)

    addr = compute_create_address(deployer, nonce)
    code = rpc(LOCAL_ANVIL_URL, "eth_getCode", [addr, "latest"])
    if code in ("0x", "0x0", ""):
        raise RuntimeError(
            f"No code at computed CREATE address {addr} (deployer={deployer}, nonce={nonce}). "
            "CREATE address derivation mismatch — check deployer nonce."
        )
    return receipt, addr


# ── Argument resolution ───────────────────────────────────────────────────────

def resolve_arg(raw_value: str, holder: str, adapter_addr: Optional[str], registry_addr: Optional[str] = None) -> str:
    if raw_value == "$REGISTRY":
        if registry_addr is None:
            raise RuntimeError("Registry must be genuinely deployed and configured first")
        return registry_addr
    if raw_value == "$HOLDER":
        return holder
    if raw_value == "$ADAPTER":
        if adapter_addr is None:
            raise RuntimeError("$ADAPTER referenced before adapter was deployed")
        return adapter_addr
    return raw_value


# ── Chain / fork assertions ───────────────────────────────────────────────────

def assert_chain(expected_chain_id: int) -> str:
    actual = int(rpc(LOCAL_ANVIL_URL, "eth_chainId", []), 16)
    if actual != expected_chain_id:
        raise RuntimeError(
            f"Chain ID mismatch: expected {expected_chain_id}, got {actual}. "
            "Check fork URL and chain config."
        )
    return "PASS"


def assert_fork_block_hash(fork_block: int, expected_hash: Optional[str]) -> str:
    block_info = rpc(LOCAL_ANVIL_URL, "eth_getBlockByNumber", [hex(fork_block), False])
    actual_hash: str = block_info["hash"]
    if expected_hash is None:
        raise RuntimeError("An explicit independently captured fork hash is required")
    if actual_hash.lower() != expected_hash.lower():
        raise RuntimeError(
            f"Fork block hash mismatch at block {fork_block}:\n"
            f"  expected: {expected_hash}\n"
            f"  actual  : {actual_hash}\n"
            "The fork is not pinned to the expected state. "
            "Update fork_block_hash in cases.json or verify the RPC endpoint."
        )
    return "PASS"


# ── Single case execution ─────────────────────────────────────────────────────

def run_case(case: dict, rpc_url: str) -> dict:
    result: dict = {
        "case_id": case["id"],
        "family": case["family"],
    }

    fork_block: int = case["fork_block"]
    chain_id: int = case["chain_id"]
    holder: str = case["holder"]
    underlying: str = case["underlying"]
    trace_start = len(RPC_TRACE)

    try:
        print(f"  [anvil] fork chain={chain_id} block={fork_block} port={DEDICATED_PORT}")
        start_anvil(rpc_url, fork_block)

        result["chain_id_assertion"] = assert_chain(chain_id)
        result["fork_block_hash_assertion"] = assert_fork_block_hash(
            fork_block, case.get("fork_block_hash")
        )

        # Impersonate holder — local Anvil only, no key, not broadcast
        rpc(LOCAL_ANVIL_URL, "anvil_impersonateAccount", [holder])
        result["holder_impersonation"] = {
            "address": holder,
            "disclosure": (
                "Local Anvil impersonation only. "
                "No private key used or stored. "
                "No transaction broadcast to any public chain."
            ),
        }

        # Verify holder has genuine ETH for gas (no balance manipulation)
        eth_bal_hex = rpc(LOCAL_ANVIL_URL, "eth_getBalance", [holder, "latest"])
        eth_bal = int(eth_bal_hex, 16)
        if eth_bal == 0:
            raise RuntimeError(
                f"Holder {holder} has zero ETH at fork block {fork_block}. "
                "Cannot fund gas without anvil_setBalance (which is prohibited). "
                "Choose a holder with genuine ETH balance at this block."
            )
        result["holder_eth_balance_wei"] = eth_bal

        # Verify holder has genuine underlying balance
        underlying_bal = erc20_balance_of(underlying, holder)
        min_required = sum(int(op["args"][0]["value"]) for op in case["operations"]
                           if op.get("sig") == "deposit(uint256)")
        if min_required <= 0:
            raise RuntimeError("Genuine positive deposit budget required")
        decimals = _adapter_view(underlying, "decimals()")
        if decimals != case["underlying_decimals"]:
            raise RuntimeError("Actual underlying decimals differ from case")
        if underlying_bal < min_required:
            raise RuntimeError(
                f"Holder {holder} has {underlying_bal} underlying (need >={min_required}). "
                "Choose a holder with genuine balance at this block."
            )
        result["holder_underlying_balance_raw"] = underlying_bal

        registry_addr = None
        if "registryProtocolType" in case:
            registry_code = get_creation_bytecode(
                "src/strategies/usdc-lending/registry/ProtocolRegistry.sol", "ProtocolRegistry")
            registry_code += abi_encode(["address"], [holder]).hex()
            registry_receipt, registry_addr = deploy_adapter(holder, registry_code)
            data = encode_call("addVault(uint8,address,string,uint16,uint256)",
                               ["uint8", "address", "string", "uint16", "uint256"],
                               [case["registryProtocolType"], case["receipt_reference"]["token"],
                                "actual calibration market", 1000, 2**128-1])
            configured = send_tx(holder, registry_addr, data)
            result["registry"] = {"address": registry_addr, "deploy": registry_receipt,
                                  "configuration": configured}

        # Get creation bytecode from forge (stdout capture, not argv)
        print(f"  [forge] inspect {case['adapter_contract']} bytecode")
        creation_bytecode = get_creation_bytecode(
            case["adapter_source"], case["adapter_contract"]
        )
        result["bytecode_length_bytes"] = (len(creation_bytecode) - 2) // 2
        result["creation_bytecode_sha256"] = hashlib.sha256(bytes.fromhex(creation_bytecode[2:])).hexdigest()
        result["source_utf8_lf_sha256"] = hashlib.sha256((PROJECT_ROOT / case["adapter_source"]).read_text(encoding="utf-8").replace("\r\n", "\n").encode()).hexdigest()

        # Deploy adapter
        print(f"  [deploy] {case['adapter_contract']}")
        deploy_receipt, adapter_addr = deploy_adapter(holder, creation_bytecode)
        result["deploy"] = {**deploy_receipt, "adapter_address": adapter_addr}
        runtime = rpc(LOCAL_ANVIL_URL, "eth_getCode", [adapter_addr, "latest"])
        if not (0 < (len(runtime)-2)//2 <= 23552):
            raise RuntimeError("Adapter runtime exceeds project budget or is empty")
        result["runtime_sha256"] = hashlib.sha256(bytes.fromhex(runtime[2:])).hexdigest()
        print(f"           deployed at {adapter_addr}")

        # Initialize adapter
        print(f"  [init]   {case['init_sig']}")
        init_types = [a["type"] for a in case["init_args"]]
        init_values = [
            resolve_arg(str(a["value"]), holder, adapter_addr, registry_addr)
            for a in case["init_args"]
        ]
        init_data = encode_call(case["init_sig"], init_types, init_values)
        init_receipt = send_tx(holder, adapter_addr, init_data)
        result["initialize"] = {
            **init_receipt,
            "resolved_args": list(zip(init_types, init_values)),
        }
        result["postInitialize"] = []
        for step in case.get("post_initialize_calls", []):
            types = [a["type"] for a in step.get("args", [])]
            values = [resolve_arg(str(a["value"]), holder, adapter_addr, registry_addr)
                      for a in step.get("args", [])]
            result["postInitialize"].append(send_tx(holder, adapter_addr, encode_call(step["sig"], types, values)))

        # Execute operations
        ops_out: list[dict] = []
        for op in case["operations"]:
            print(f"  [op]     {op['id']}")

            bal_before = snapshot(underlying, adapter_addr, holder, case["receipt_reference"])

            if op["op"] == "erc20_approve":
                spender = resolve_arg(op["spender"], holder, adapter_addr, registry_addr)
                amount = int(op["amount"])
                op_receipt = erc20_approve(holder, op["token"], spender, amount)

            elif op["op"] == "erc20_transfer":
                recipient = resolve_arg(op["recipient"], holder, adapter_addr, registry_addr)
                op_receipt = send_tx(holder, op["token"], encode_call(
                    "transfer(address,uint256)", ["address", "uint256"], [recipient, int(op["amount"])]))

            elif op["op"] == "adapter_call":
                sig = op["sig"]
                arg_defs = op.get("args", [])
                types = [a["type"] for a in arg_defs]
                values = [
                    resolve_arg(str(a["value"]), holder, adapter_addr, registry_addr)
                    for a in arg_defs
                ]
                call_data = encode_call(sig, types, values)
                op_receipt = send_tx(holder, adapter_addr, call_data)

            else:
                raise ValueError(f"Unknown op type: {op['op']!r}")

            bal_after = snapshot(underlying, adapter_addr, holder, case["receipt_reference"])
            if bal_before["underlying_totalSupply"] != bal_after["underlying_totalSupply"]:
                # Fluid's canonical-WETH market legitimately unwraps/wraps ETH.
                if case["chain_id"] != 1 or underlying.lower() != "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2":
                    raise RuntimeError("Unsupported underlying supply change")
                for state in [bal_before, bal_after]:
                    if state["underlying_totalSupply"] != state["underlying_native_backing"]:
                        raise RuntimeError("Canonical WETH supply must equal actual ETH backing")
                deposited_topic = "0x" + keccak256(b"Deposit(address,uint256)").hex()
                withdrawn_topic = "0x" + keccak256(b"Withdrawal(address,uint256)").hex()
                logged_change = 0
                for event in op_receipt["logs"]:
                    if event["address"].lower() != underlying.lower() or not event.get("topics"):
                        continue
                    if event["topics"][0] == deposited_topic:
                        logged_change += int(event["data"], 16)
                    elif event["topics"][0] == withdrawn_topic:
                        logged_change -= int(event["data"], 16)
                if logged_change != bal_after["underlying_totalSupply"] - bal_before["underlying_totalSupply"]:
                    raise RuntimeError("WETH supply change must exactly match real wrap/unwrap receipt events")
            delta = bal_after["holder_underlying"] - bal_before["holder_underlying"]
            if op.get("sig") == "deposit(uint256)":
                amount = int(op["args"][0]["value"])
                push = case.get("fundingMode") == "push"
                expected_delta = 0 if push else -amount
                if delta != expected_delta or bal_after["independent_receipt_shares"] <= bal_before["independent_receipt_shares"]:
                    raise RuntimeError("Deposit must transfer exact genuine funds and increase real receipts")
                if push and bal_before["adapter_underlying_idle"] - bal_after["adapter_underlying_idle"] != amount:
                    raise RuntimeError("Push deposit must invest the actual pre-transferred funds")
            elif op["op"] == "erc20_transfer":
                amount = int(op["amount"])
                if delta != -amount or bal_after["adapter_underlying_idle"] - bal_before["adapter_underlying_idle"] != amount:
                    raise RuntimeError("Actual push funding transfer must conserve exact underlying balances")
            elif op.get("sig") == "withdraw(uint256,address)":
                if delta != int(op["args"][0]["value"]):
                    raise RuntimeError("Partial withdrawal did not pay exact requested underlying")
            elif op.get("sig") == "emergencyPullAllToVault()":
                if bal_after["adapter_totalAssets"] > 2 or bal_after["independent_receipt_shares"] > 2:
                    raise RuntimeError("Full receipt recall left an actual position")
                if delta < bal_before["adapter_totalAssets"] - 2:
                    raise RuntimeError("Full recall paid less than actual prior NAV")

            ops_out.append({
                "id": op["id"],
                "op": op["op"],
                "position": op.get("position"),
                "note": op.get("note"),
                "receipt": op_receipt,
                "balances_before": bal_before,
                "balances_after": bal_after,
                "delta_holder_underlying": (
                    (bal_after["holder_underlying"] - bal_before["holder_underlying"])
                    if isinstance(bal_after["holder_underlying"], int)
                    and isinstance(bal_before["holder_underlying"], int)
                    else "N/A"
                ),
            })

        result["operations"] = ops_out
        result["status"] = "PASS"

    except Exception as exc:
        result["status"] = "FAIL"
        result["error"] = str(exc)

    finally:
        result["rpcTrace"] = RPC_TRACE[trace_start:]
        _kill_anvil()

    return result


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Adapter gas calibration runner — G-transactions"
    )
    parser.add_argument(
        "--case", metavar="ID",
        help="Run only the case with this ID (default: all cases)",
    )
    parser.add_argument(
        "--cases-file", default=str(CASES_FILE),
        help="Path to cases.json (default: sibling cases.json)",
    )
    parser.add_argument(
        "--emit-fork-hash", action="store_true",
        help="After chain assertion, print actual fork block hash to stdout for cases.json population.",
    )
    args = parser.parse_args()

    with open(args.cases_file, encoding="utf-8") as fh:
        config = json.load(fh)

    cases: list[dict] = config["cases"]
    required = {"Aave", "Comet", "Morpho", "Euler", "Fluid", "Dolomite-wrapper", "Venus"}
    if {c["family"] for c in cases} != required or len({c["id"] for c in cases}) != len(cases):
        raise RuntimeError("All seven adapter families must remain in the calibration manifest")
    family_chains = {
        family: sorted({c["chain_id"] for c in cases if c["family"] == family})
        for family in required
    }
    if any(len(chains) < 2 for chains in family_chains.values()):
        raise RuntimeError("Every adapter family requires profiles on at least two distinct chains")
    if args.case:
        cases = [c for c in cases if c["id"] == args.case]
        if not cases:
            print(f"ERROR: case {args.case!r} not found in {args.cases_file}", file=sys.stderr)
            sys.exit(1)

    ARTIFACTS_DIR.mkdir(parents=True, exist_ok=True)

    summary: list[dict] = []

    for case in cases:
        case_id: str = case["id"]
        family: str = case.get("family", "?")
        print(f"\n[case] {case_id}  family={family}")

        status_override = case.get("status")

        if status_override == "FAIL_UNIMPLEMENTED":
            result = {
                "case_id": case_id,
                "family": family,
                "status": "FAIL_UNIMPLEMENTED",
                "reason": case.get("reason", "(no reason provided)"),
            }
        else:
            rpc_url_env: str = case.get("rpc_url_env", "")
            rpc_url: str = os.environ.get(rpc_url_env, "") if rpc_url_env else ""
            if not rpc_url:
                result = {
                    "case_id": case_id,
                    "family": family,
                    "status": "FAIL_MISSING_RPC",
                    "reason": (
                        f"Environment variable {rpc_url_env!r} is not set or empty. "
                        "Set it to a full archive node URL for the correct chain."
                    ),
                }
            else:
                if args.emit_fork_hash:
                    # Special mode: just start Anvil, capture hash, print, stop
                    try:
                        start_anvil(rpc_url, case["fork_block"])
                        assert_chain(case["chain_id"])
                        block_info = rpc(
                            LOCAL_ANVIL_URL, "eth_getBlockByNumber",
                            [hex(case["fork_block"]), False]
                        )
                        print(
                            f"  fork_block_hash for {case_id} block {case['fork_block']}: "
                            f"{block_info['hash']}"
                        )
                    finally:
                        _kill_anvil()
                    result = {
                        "case_id": case_id,
                        "family": family,
                        "status": "FORK_HASH_EMITTED",
                    }
                else:
                    result = run_case(case, rpc_url)

        # Write per-case artifact
        case_dir = ARTIFACTS_DIR / case_id
        case_dir.mkdir(parents=True, exist_ok=True)
        with open(case_dir / "result.json", "w", encoding="utf-8") as fh:
            json.dump(result, fh, indent=2, default=str)

        status = result.get("status", "UNKNOWN")
        print(f"         → {status}")
        if status == "FAIL":
            print(f"           {result.get('error', '')[:200]}")

        summary.append({
            "case_id": case_id,
            "family": family,
            "status": status,
        })

    # Write aggregate summary
    summary_path = ARTIFACTS_DIR / "summary.json"
    with open(summary_path, "w", encoding="utf-8") as fh:
        json.dump({"runs": summary, "requiredFamilies": sorted(required),
                   "configuredChainsPerFamily": family_chains,
                   "scope": "SELECTED_PILOT_ONLY" if args.case else "ALL_SEVEN_FAMILIES",
                   "readiness": "NOT_PRODUCTION_READY",
                   "configuredUnimplementedFamilies": [c["family"] for c in config["cases"]
                                                        if c.get("status") == "FAIL_UNIMPLEMENTED"]}, fh, indent=2)

    # Print paths (no execution claims)
    print(f"\nArtifact root : {ARTIFACTS_DIR}")
    print(f"Summary       : {summary_path}")
    for row in summary:
        mark = "✓" if row["status"] == "PASS" else "✗"
        print(f"  {mark}  {row['case_id']:40s}  {row['status']}")

    # Non-zero exit if any case is not PASS
    non_pass = [r for r in summary if r["status"] != "PASS"]
    if non_pass:
        sys.exit(2)


if __name__ == "__main__":
    main()
