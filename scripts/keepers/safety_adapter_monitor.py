"""
safety_adapter_monitor.py — off-chain monitor for the P0.7 Safety Adapter
Cap Tier.

Polls the strategy contract for the four signal families documented in
docs/SAFETY_ADAPTER_TIER.md §7:

    1. Cap utilisation        — alert when safety position >= 95% of fbCap.
    2. Mandate frequency      — alert when CapDriftMandate rate > 10/week.
    3. Cooldown saturation    — alert when > 50% of enabled non-safety in CD.
    4. Idle drag              — alert when 24h average > maxIdleBps + 200 bps.

Output is a JSON document on stdout, intended to be ingested by Grafana /
Datadog / Telegraf via cron or a sidecar. The script is deliberately
stateless: each run produces a snapshot, history is the responsibility of
the downstream pipeline.

Usage:
    python scripts/keepers/safety_adapter_monitor.py \\
        --rpc-url $ARBITRUM_RPC_URL \\
        --strategy 0x... \\
        --lookback-blocks 50000

    or via env:
        ARBITRUM_RPC_URL=https://... STRATEGY_ADDRESS=0x... \\
            python scripts/keepers/safety_adapter_monitor.py

Dependencies:
    pip install web3 eth-abi

Status: scaffold only. The web3 calls are spelled out below as docstrings
so that the deployment team can wire them to the production RPC + ABI
artefacts without re-deriving the event selectors. Replace the TODO blocks
in `_query_*` helpers with real eth_call / eth_getLogs invocations once
the strategy address is committed in `script/deploy-config.json`.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass, field
from typing import Any


# ─── Configuration ─────────────────────────────────────────────────────────

DEFAULT_LOOKBACK_BLOCKS = 50_000          # ~1 week at Arbitrum block times
ALERT_CAP_UTILISATION_BPS = 9_500          # 95% of fbCap
ALERT_MANDATE_RATE_PER_WEEK = 10
ALERT_COOLDOWN_SATURATION_PCT = 0.50
IDLE_DRAG_ALERT_OFFSET_BPS = 200            # alert if 24h avg > maxIdleBps + 200


# ─── Output schema ─────────────────────────────────────────────────────────

@dataclass
class SafetyAdapterSnapshot:
    address: str
    position_assets: int
    fb_abs_cap_bps: int
    fb_rel_cap_bps: int
    cap_utilisation_bps: int
    alert_cap_utilisation: bool

@dataclass
class MandateRateSnapshot:
    adapter: str
    hits_last_7d: int
    alert_mandate_rate: bool

@dataclass
class CooldownSnapshot:
    saturation_pct: float
    enabled_non_safety_count: int
    in_cooldown_count: int
    alert_cooldown_saturation: bool

@dataclass
class IdleDragSnapshot:
    avg_24h_idle_bps: int
    max_idle_bps_config: int
    alert_idle_drag: bool

@dataclass
class MonitorOutput:
    timestamp_unix: int = 0
    block_number: int = 0
    strategy: str = ""
    total_assets_usdc6: int = 0
    safety_adapters: list = field(default_factory=list)
    mandate_rates: list = field(default_factory=list)
    cooldown: CooldownSnapshot | None = None
    idle_drag: IdleDragSnapshot | None = None

    def to_json(self) -> str:
        return json.dumps(self, default=_dc_to_dict, indent=2)


def _dc_to_dict(obj: Any) -> Any:
    if hasattr(obj, "__dataclass_fields__"):
        return {k: getattr(obj, k) for k in obj.__dataclass_fields__}
    raise TypeError(f"unhandled type {type(obj)}")


# ─── On-chain queries (TODO: wire to web3) ──────────────────────────────────

def _query_total_assets(rpc_url: str, strategy: str) -> int:
    """Read totalAssets() from the strategy. TODO: replace with eth_call."""
    return 0


def _query_safety_adapters(rpc_url: str, strategy: str) -> list[dict]:
    """
    Iterate `safetyFallbackAdapters[i]` from 0 until OOB, then read
    `safetyFallback[a]` for each. Returns:
        [
          {"address": "0x...", "abs_cap_bps": 5000, "rel_cap_bps": 5000},
          ...
        ]
    TODO: replace with safetyFallbackAdaptersLength() + per-index queries.
    """
    return []


def _query_position(rpc_url: str, strategy: str, adapter: str) -> int:
    """Read positionAssets[adapter]. TODO: replace with eth_call."""
    return 0


def _query_mandate_events(
    rpc_url: str, strategy: str, lookback_blocks: int
) -> dict[str, int]:
    """
    Count CapDriftMandate(adapter, ...) events per adapter over the last
    `lookback_blocks` blocks. Returns {adapter_address_lc: count}.
    TODO: replace with eth_getLogs.
    """
    return {}


def _query_enabled_adapters(rpc_url: str, strategy: str) -> list[str]:
    """Read the adapters array + filter on enabled[]. TODO."""
    return []


def _query_last_mandate_ts(rpc_url: str, strategy: str, adapter: str) -> int:
    """Read lastRelCapMandateTs[adapter]. TODO."""
    return 0


def _query_mandate_cooldown_seconds(rpc_url: str, strategy: str) -> int:
    """Read mandateRedeployCooldownSeconds. TODO."""
    return 0


def _query_max_idle_bps(rpc_url: str, strategy: str) -> int:
    """Read maxIdleBps. TODO."""
    return 0


def _query_idle_drag_24h_avg_bps(rpc_url: str, strategy: str) -> int:
    """
    Compute idle / totalAssets at uniform sample points over the past 24h.
    Implementation note: easiest path is to read a chain of equity_curve
    rows from a sidecar indexer (e.g. The Graph subgraph or local DuckDB
    snapshotting the `LendingPerformanceSnapshot` event stream). For the
    scaffold we return 0 — the production wiring depends on the deployed
    indexer choice. TODO.
    """
    return 0


# ─── Snapshot assembly ─────────────────────────────────────────────────────

def build_snapshot(
    rpc_url: str, strategy: str, lookback_blocks: int
) -> MonitorOutput:
    out = MonitorOutput(strategy=strategy)

    total_assets = _query_total_assets(rpc_url, strategy)
    out.total_assets_usdc6 = total_assets

    # 1. Cap utilisation per safety adapter.
    safety = _query_safety_adapters(rpc_url, strategy)
    for sf in safety:
        addr = sf["address"]
        pos = _query_position(rpc_url, strategy, addr)
        if total_assets > 0 and sf["abs_cap_bps"] > 0:
            fb_cap_amt = (total_assets * sf["abs_cap_bps"]) // 10_000
            util_bps = (pos * 10_000) // fb_cap_amt if fb_cap_amt > 0 else 0
        else:
            util_bps = 0
        out.safety_adapters.append(SafetyAdapterSnapshot(
            address=addr,
            position_assets=pos,
            fb_abs_cap_bps=sf["abs_cap_bps"],
            fb_rel_cap_bps=sf["rel_cap_bps"],
            cap_utilisation_bps=util_bps,
            alert_cap_utilisation=(util_bps >= ALERT_CAP_UTILISATION_BPS),
        ))

    # 2. Mandate frequency per adapter (lookback window).
    mandate_events = _query_mandate_events(rpc_url, strategy, lookback_blocks)
    for adapter, count in mandate_events.items():
        out.mandate_rates.append(MandateRateSnapshot(
            adapter=adapter,
            hits_last_7d=count,
            alert_mandate_rate=(count > ALERT_MANDATE_RATE_PER_WEEK),
        ))

    # 3. Cooldown saturation across non-safety adapters.
    enabled = _query_enabled_adapters(rpc_url, strategy)
    safety_set = {s["address"].lower() for s in safety}
    non_safety = [a for a in enabled if a.lower() not in safety_set]
    cd_seconds = _query_mandate_cooldown_seconds(rpc_url, strategy)
    now_ts = _query_block_timestamp(rpc_url)
    in_cd = 0
    for a in non_safety:
        last_ts = _query_last_mandate_ts(rpc_url, strategy, a)
        if cd_seconds > 0 and last_ts > 0 and now_ts < last_ts + cd_seconds:
            in_cd += 1
    sat = (in_cd / len(non_safety)) if non_safety else 0.0
    out.cooldown = CooldownSnapshot(
        saturation_pct=sat,
        enabled_non_safety_count=len(non_safety),
        in_cooldown_count=in_cd,
        alert_cooldown_saturation=(sat > ALERT_COOLDOWN_SATURATION_PCT),
    )

    # 4. Idle drag over the prior 24h.
    avg_idle_bps = _query_idle_drag_24h_avg_bps(rpc_url, strategy)
    max_idle = _query_max_idle_bps(rpc_url, strategy)
    out.idle_drag = IdleDragSnapshot(
        avg_24h_idle_bps=avg_idle_bps,
        max_idle_bps_config=max_idle,
        alert_idle_drag=(avg_idle_bps > max_idle + IDLE_DRAG_ALERT_OFFSET_BPS),
    )

    return out


def _query_block_timestamp(rpc_url: str) -> int:
    """Read latest block timestamp via eth_getBlockByNumber. TODO."""
    return 0


# ─── CLI entry point ───────────────────────────────────────────────────────

def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--rpc-url", default=os.environ.get("ARBITRUM_RPC_URL", ""))
    p.add_argument("--strategy", default=os.environ.get("STRATEGY_ADDRESS", ""))
    p.add_argument("--lookback-blocks", type=int, default=DEFAULT_LOOKBACK_BLOCKS)
    args = p.parse_args()

    if not args.rpc_url or not args.strategy:
        print("error: --rpc-url and --strategy (or env) are required", file=sys.stderr)
        return 2

    snap = build_snapshot(args.rpc_url, args.strategy, args.lookback_blocks)
    print(snap.to_json())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
