#!/usr/bin/env python3
"""
Validate every Multyr strategy metadata file against the versioned
strategy-metadata schema, plus a set of policy lints that JSON Schema alone
cannot express.

Layout (all paths relative to the repo's `metadata/` directory):

    metadata/
      schema/strategy-metadata*.schema.json   one file per schema version
      strategies/<slug>.json                  one file per strategy
      tools/validate.py                       this script

Usage:
    python metadata/tools/validate.py                 # validate all strategies
    python metadata/tools/validate.py path/to/one.json ...

Exit code 0 = all files valid, 1 = at least one failure.

Policy (enforced by the lints below, not by the schema):
  * Static metadata only. No runtime/dynamic values: APY, APR, TVL, AUM,
    capacity, utilization, current allocations/weights, share price, holder
    counts, volumes, performance. Those live in the runtime metrics API,
    joined to this document by `id`.
  * No risk rating / risk score / safety label until a formal Multyr
    risk-rating methodology exists and gets its own schema version.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

try:
    from jsonschema import Draft202012Validator
except ImportError:  # pragma: no cover
    sys.stderr.write(
        "error: `jsonschema` is not installed.\n"
        "       pip install -r metadata/tools/requirements.txt\n"
    )
    raise SystemExit(2)

METADATA_DIR = Path(__file__).resolve().parents[1]
SCHEMA_DIR = METADATA_DIR / "schema"
STRATEGIES_DIR = METADATA_DIR / "strategies"

# ── Policy denylists ─────────────────────────────────────────────────────────
# Object KEYS that must never appear anywhere in a static metadata document.
# These are dynamic/runtime concerns. Matched case-insensitively against the
# exact key name.
FORBIDDEN_KEYS = {
    "apy", "apr", "apy7d", "apy30d", "apr7d", "apr30d", "netapy", "grossapy",
    "baseapy", "rewardapy", "yield", "yield7d", "yield30d",
    "tvl", "aum", "totalassets", "totalvaluelocked", "totalsupply", "totaldeposits",
    "shareprice", "pricepershare", "pps", "nav", "navpershare",
    "capacity", "remainingcapacity", "maxcapacity", "capacityused", "capacitybps",
    "utilization", "utilisation", "utilizationbps",
    "currentallocation", "currentallocations", "allocations", "weights",
    "currentweights", "targetweights", "positions", "positionassets",
    "balance", "balances", "availableliquidity", "deposits", "withdrawals",
    "holders", "holdercount", "depositorcount",
    "volume", "volume24h", "inflow", "outflow", "flows",
    "performance", "returns", "pnl", "drawdown", "sharpe", "apyhistory",
    "fees24h", "feespaid", "lastupdated", "updatedat", "asof", "timestamp",
    # risk-rating concerns (deferred until a formal methodology exists)
    "riskrating", "risklevel", "riskscore", "riskgrade", "risktier",
    "safetyscore", "safetyrating", "rating", "ratings", "grade", "score",
}

# Substrings that, if they appear in ANY string VALUE, indicate a performance
# claim, a guarantee, or an unsanctioned risk/safety label.
FORBIDDEN_VALUE_PATTERNS = [
    re.compile(r"\blow[\s\-]?risk\b", re.I),
    re.compile(r"\bmedium[\s\-]?risk\b", re.I),
    re.compile(r"\bhigh[\s\-]?risk\b", re.I),
    re.compile(r"\blower[\s\-]?risk\b", re.I),
    re.compile(r"\brisk[\s\-]?free\b", re.I),
    re.compile(r"\bsafe(?:st)?\b", re.I),
    re.compile(r"\bconservative\b", re.I),
    re.compile(r"\baggressive\b", re.I),
    re.compile(r"\b(?:capital|principal)[\s\-]?protected\b", re.I),
    re.compile(r"\bguaranteed\s+(?:yield|return|returns|apy|apr|profit|income)\b", re.I),
    re.compile(r"\bhighest\s+(?:yield|apy|return)\b", re.I),
    re.compile(r"\bbest[\s\-]in[\s\-]class\b", re.I),
]


class Failure(Exception):
    pass


def _load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise Failure(f"{path}: invalid JSON: {exc}")


def _discover_schemas() -> dict[str, tuple[Path, dict]]:
    """version string -> (schema path, schema dict)."""
    out: dict[str, tuple[Path, dict]] = {}
    for path in sorted(SCHEMA_DIR.glob("strategy-metadata*.schema.json")):
        schema = _load_json(path)
        const = schema.get("properties", {}).get("schemaVersion", {}).get("const")
        if not const:
            raise Failure(
                f"{path}: schema does not pin properties.schemaVersion.const"
            )
        if const in out:
            raise Failure(
                f"duplicate schema version {const!r}: {out[const][0]} and {path}"
            )
        Draft202012Validator.check_schema(schema)
        out[const] = (path, schema)
    if not out:
        raise Failure(f"no schema files found in {SCHEMA_DIR}")
    return out


def _walk(node, path="$", key=None):
    """Yield (json-path, key, value) exactly once for every node in the tree.
    `key` is the object key this node was reached through (None for the root
    and for array elements)."""
    yield path, key, node
    if isinstance(node, dict):
        for k, v in node.items():
            yield from _walk(v, f"{path}.{k}", k)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from _walk(v, f"{path}[{i}]", None)


def _policy_lint(doc: dict) -> list[str]:
    errors: list[str] = []
    for jpath, key, value in _walk(doc):
        if key is not None and key.lower() in FORBIDDEN_KEYS:
            errors.append(
                f"forbidden key {key!r} at {jpath} — dynamic/runtime data and "
                f"risk ratings must not live in static metadata"
            )
        if isinstance(value, str):
            for pat in FORBIDDEN_VALUE_PATTERNS:
                if pat.search(value):
                    errors.append(
                        f"forbidden phrase matching /{pat.pattern}/ at {jpath}: "
                        f"{value!r}"
                    )
    return errors


def _consistency_lint(doc: dict, path: Path) -> list[str]:
    errors: list[str] = []

    slug = doc.get("slug")
    if slug and path.stem != slug:
        errors.append(f"filename must be '{slug}.json' to match slug (got '{path.name}')")

    _id, _slug = doc.get("id"), doc.get("slug")
    if _id and _slug and _id != f"multyr-{_slug}":
        errors.append(f"id must be 'multyr-{_slug}' to match slug (got '{_id}')")

    disc = doc.get("disclosures", {})
    if "principalGuaranteed" in disc and "principalGuaranteed" in doc:
        if disc["principalGuaranteed"] != doc["principalGuaranteed"]:
            errors.append(
                "disclosures.principalGuaranteed disagrees with top-level "
                "principalGuaranteed"
            )
    if "yieldVariable" in disc and "yieldVariable" in doc:
        if disc["yieldVariable"] != doc["yieldVariable"]:
            errors.append(
                "disclosures.yieldVariable disagrees with top-level yieldVariable"
            )

    anchors = doc.get("anchorProtocols") or []
    protocols = set(doc.get("protocols") or [])
    for a in anchors:
        if a not in protocols:
            errors.append(f"anchorProtocols entry {a!r} is not listed in protocols")

    return errors


def validate_file(path: Path, schemas: dict[str, tuple[Path, dict]]) -> list[str]:
    doc = _load_json(path)
    if not isinstance(doc, dict):
        return [f"top-level value must be a JSON object, got {type(doc).__name__}"]

    errors: list[str] = []

    version = doc.get("schemaVersion")
    if version not in schemas:
        known = ", ".join(sorted(schemas)) or "<none>"
        return [f"unknown schemaVersion {version!r} (known: {known})"]

    schema_path, schema = schemas[version]
    validator = Draft202012Validator(schema)
    for err in sorted(validator.iter_errors(doc), key=lambda e: e.path):
        loc = "$" + "".join(f"[{p!r}]" if isinstance(p, int) else f".{p}" for p in err.path)
        errors.append(f"schema ({schema_path.name}) at {loc}: {err.message}")

    errors += _policy_lint(doc)
    errors += _consistency_lint(doc, path)

    # de-duplicate while preserving order
    seen: set[str] = set()
    return [e for e in errors if not (e in seen or seen.add(e))]


def main(argv: list[str]) -> int:
    try:
        schemas = _discover_schemas()
    except Failure as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 2

    if argv:
        targets = [Path(a) for a in argv]
    else:
        targets = sorted(STRATEGIES_DIR.glob("*.json"))

    if not targets:
        print(f"FATAL: no metadata files found under {STRATEGIES_DIR}", file=sys.stderr)
        return 2

    print(
        f"schema versions: {', '.join(sorted(schemas))}  |  "
        f"files: {len(targets)}\n"
    )

    failed = 0
    for path in targets:
        try:
            errors = validate_file(path, schemas)
        except Failure as exc:
            errors = [str(exc)]
        rel = path.relative_to(METADATA_DIR.parent) if METADATA_DIR.parent in path.resolve().parents else path
        if errors:
            failed += 1
            print(f"FAIL  {rel}")
            for e in errors:
                print(f"      - {e}")
        else:
            print(f"ok    {rel}")

    print()
    if failed:
        print(f"{failed}/{len(targets)} file(s) failed validation")
        return 1
    print(f"all {len(targets)} file(s) valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
