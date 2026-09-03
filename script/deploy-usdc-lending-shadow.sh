#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# deploy-usdc-lending-shadow.sh — Shadow (Arbitrum One shadow-mainnet) runner
# ══════════════════════════════════════════════════════════════════════════
# Dedicated, hardened entrypoint for deploying the USDC lending strategy into
# Multyr's Shadow environment. Kept entirely separate from the production
# runner (deploy-usdc-lending.sh) so a Shadow run can NEVER accidentally use a
# production RPC or key.
#
# Three-step wrapper around the UNMODIFIED production deploy script:
#   1. PreflightUsdcLendingShadow   — read-only checks, before any tx
#   2. DeployUsdcLendingStrategy    — script/DeployUsdcLendingStrategy.s.sol (untouched)
#   3. PostflightUsdcLendingShadow  — verify wiring/roles + write the manifest
#
# Guarantees enforced here, before forge is invoked:
#   - loads .env.shadow only (never .env)
#   - DEPLOY_ENV must be exactly "shadow"
#   - the live chain id behind SHADOW_RPC_URL must be 42161
#   - SHADOW_RPC_URL is the ONLY rpc used — no fallback to RPC_URL
#   - deployer key must be SHADOW_DEPLOYER_PRIVATE_KEY; a plain
#     DEPLOYER_PRIVATE_KEY in .env.shadow is rejected
#   - the derived deployer address must not appear in FORBIDDEN_DEPLOYER_ADDRESSES
#   - governance Safe + all Shadow operator addresses present, nonzero, distinct
#   - simulate by default; --broadcast required to send transactions
#   - results captured under deployments/shadow/<deployment-id>/
#   - a completed manifest at that id blocks re-broadcast unless --force
#
# Usage:
#   cp .env.shadow.example .env.shadow && fill it in
#   ./script/deploy-usdc-lending-shadow.sh --preflight     # step 1 only
#   ./script/deploy-usdc-lending-shadow.sh                 # step 1 + dry-run step 2
#   ./script/deploy-usdc-lending-shadow.sh --broadcast     # steps 1 → 2 → 3
#   ./script/deploy-usdc-lending-shadow.sh --broadcast --force   # re-run over an existing id
# ══════════════════════════════════════════════════════════════════════════

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

die() { echo "error: $*" >&2; exit 1; }

# ── Args ─────────────────────────────────────────────────────────────────
DO_BROADCAST=0
DO_FORCE=0
PREFLIGHT_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --broadcast) DO_BROADCAST=1 ;;
    --force)     DO_FORCE=1 ;;
    --preflight) PREFLIGHT_ONLY=1 ;;
    *) die "unknown argument: $arg (expected --broadcast, --force, --preflight)" ;;
  esac
done

# ── Load .env.shadow ─────────────────────────────────────────────────────
[[ -f .env.shadow ]] || die ".env.shadow not found. Copy .env.shadow.example to .env.shadow and fill it in."

# The .env.shadow FILE must not carry production names — reject them there
# (an ambient value inherited from a shell that sourced the production .env is
# fine: we clear it below and use SHADOW_* exclusively).
grep -qE '^\s*DEPLOYER_PRIVATE_KEY=' .env.shadow && die "remove DEPLOYER_PRIVATE_KEY from .env.shadow — use SHADOW_DEPLOYER_PRIVATE_KEY"
grep -qE '^\s*RPC_URL=' .env.shadow            && die "remove RPC_URL from .env.shadow — use SHADOW_RPC_URL"

# Clear any ambient production values so nothing leaks into the Shadow run.
unset DEPLOYER_PRIVATE_KEY RPC_URL

set -a
# shellcheck disable=SC1091
source .env.shadow
set +a

# ── Environment identity ────────────────────────────────────────────────
[[ "${DEPLOY_ENV:-}" == "shadow" ]] || die "DEPLOY_ENV must be exactly 'shadow' in .env.shadow (got '${DEPLOY_ENV:-<unset>}')"
[[ -n "${SHADOW_RPC_URL:-}" ]] || die "SHADOW_RPC_URL is not set"
[[ -n "${SHADOW_DEPLOYER_PRIVATE_KEY:-}" ]] || die "SHADOW_DEPLOYER_PRIVATE_KEY is not set"

# ── Required Shadow governance / operator + core addresses ──────────────
required_vars=(
  SHADOW_GUARDIAN_ADDRESS
  SHADOW_GOVERNANCE_ADDRESS
  SHADOW_KEEPER_ADDRESS
  SHADOW_EMERGENCY_ADDRESS
  VAULT_ADDRESS
  STRATEGY_ROUTER_ADDRESS
  BUFFER_MANAGER_ADDRESS
  HEALTH_REGISTRY_ADDRESS
)
missing=()
for v in "${required_vars[@]}"; do [[ -n "${!v:-}" ]] || missing+=("$v"); done
[[ ${#missing[@]} -eq 0 ]] || { printf 'error: missing required var(s):\n'; printf '  - %s\n' "${missing[@]}"; exit 1; } >&2

# distinctness of the five operator roles (deployer derived below)
gov_addrs=("$SHADOW_GUARDIAN_ADDRESS" "$SHADOW_GOVERNANCE_ADDRESS" "$SHADOW_KEEPER_ADDRESS" "$SHADOW_EMERGENCY_ADDRESS")

# ── Live chain-id check against the Shadow RPC ──────────────────────────
command -v cast >/dev/null 2>&1 || die "cast (foundry) not found on PATH"
CHAIN_ID="$(cast chain-id --rpc-url "$SHADOW_RPC_URL" 2>/dev/null || true)"
[[ "$CHAIN_ID" == "42161" ]] || die "SHADOW_RPC_URL reports chain id '$CHAIN_ID', expected 42161 (Shadow mirrors Arbitrum One)"

# ── Derive + vet the deployer address ──────────────────────────────────
DEPLOYER_ADDR="$(cast wallet address --private-key "$SHADOW_DEPLOYER_PRIVATE_KEY")"
DEPLOYER_ADDR_LC="$(echo "$DEPLOYER_ADDR" | tr '[:upper:]' '[:lower:]')"
if [[ -n "${FORBIDDEN_DEPLOYER_ADDRESSES:-}" ]]; then
  IFS=',' read -ra forbidden <<< "$FORBIDDEN_DEPLOYER_ADDRESSES"
  for f in "${forbidden[@]}"; do
    f_lc="$(echo "$f" | xargs | tr '[:upper:]' '[:lower:]')"
    [[ -z "$f_lc" ]] && continue
    [[ "$DEPLOYER_ADDR_LC" != "$f_lc" ]] || die "Shadow deployer $DEPLOYER_ADDR is in FORBIDDEN_DEPLOYER_ADDRESSES — refusing (looks like a production key)"
  done
fi
for g in "${gov_addrs[@]}"; do
  [[ "$(echo "$g" | tr '[:upper:]' '[:lower:]')" != "$DEPLOYER_ADDR_LC" ]] || die "deployer address collides with a Shadow governance address"
done

# ── Deployment id + output dir ────────────────────────────────────────
GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
GIT_DIRTY=""
git diff --quiet 2>/dev/null || GIT_DIRTY="-dirty"
DEPLOYMENT_ID="${SHADOW_DEPLOYMENT_ID:-$(date -u +%Y%m%dT%H%M%SZ)-${GIT_COMMIT}${GIT_DIRTY}}"
OUT_DIR="deployments/shadow/${DEPLOYMENT_ID}"
MANIFEST="${OUT_DIR}/manifest.json"

if [[ -f "$MANIFEST" && $DO_BROADCAST -eq 1 && $DO_FORCE -eq 0 ]]; then
  die "a completed manifest already exists at $MANIFEST — a previous run finished for this id.
       Use a fresh SHADOW_DEPLOYMENT_ID for an isolated run, or pass --force to overwrite."
fi

export SHADOW_DEPLOYMENT_ID="$DEPLOYMENT_ID"
export DEPLOY_GIT_COMMIT="${GIT_COMMIT}${GIT_DIRTY}"
export STRATEGY_OUTPUT_JSON="${OUT_DIR}/addresses.json"

# Map SHADOW_* → the canonical names the Solidity script's _loadConfig reads.
export DEPLOYER_PRIVATE_KEY="$SHADOW_DEPLOYER_PRIVATE_KEY"
export GUARDIAN_ADDRESS="$SHADOW_GUARDIAN_ADDRESS"
export GOVERNANCE_ADDRESS="$SHADOW_GOVERNANCE_ADDRESS"
# core addresses (VAULT/ROUTER/BUFFER/HEALTH) are already canonical.

echo "── Shadow deployment ──────────────────────────────────────────────"
echo "  deployment id : $DEPLOYMENT_ID"
echo "  git commit    : ${GIT_COMMIT}${GIT_DIRTY}"
echo "  chain id      : $CHAIN_ID (verified via SHADOW_RPC_URL)"
echo "  deployer      : $DEPLOYER_ADDR"
echo "  output dir    : $OUT_DIR"
echo "  mode          : $([[ $PREFLIGHT_ONLY -eq 1 ]] && echo PREFLIGHT-ONLY || { [[ $DO_BROADCAST -eq 1 ]] && echo BROADCAST || echo 'DRY RUN (simulate)'; })"
echo "───────────────────────────────────────────────────────────────────"

mkdir -p "$OUT_DIR"

# EVM version: production/foundry.toml is "cancun". anvil forking Arbitrum with
# --hardfork cancun is broken ("Excess blob gas not set" on eth_call — Arbitrum
# blocks carry no EIP-4844 fields), so a local anvil Shadow fork must run
# --hardfork shanghai and this must compile to match. Set
# SHADOW_EVM_VERSION=shanghai in .env.shadow for that case; a hosted Shadow RPC
# needs no override.
EVM_FLAG=()
if [[ -n "${SHADOW_EVM_VERSION:-}" ]]; then
  EVM_FLAG=(--evm-version "$SHADOW_EVM_VERSION")
  echo "  evm version   : $SHADOW_EVM_VERSION (override)"
fi
FORGE_COMMON=(--rpc-url "$SHADOW_RPC_URL" ${EVM_FLAG[@]+"${EVM_FLAG[@]}"})

# ── Step 1: PRE-DEPLOYMENT ───────────────────────────────────────────
echo; echo ">>> [1/3] pre-deployment checks"
forge script script/PreflightUsdcLendingShadow.s.sol:PreflightUsdcLendingShadow \
  "${FORGE_COMMON[@]}" -vvv

if [[ $PREFLIGHT_ONLY -eq 1 ]]; then
  echo; echo "preflight only — done."; exit 0
fi

# ── Step 2: DEPLOY (unmodified production script) ────────────────────
echo; echo ">>> [2/3] deploy$([[ $DO_BROADCAST -eq 1 ]] && echo ' (BROADCAST)' || echo ' (dry run)')"
BROADCAST_FLAG=()
[[ $DO_BROADCAST -eq 1 ]] && BROADCAST_FLAG=(--broadcast)

forge script script/DeployUsdcLendingStrategy.s.sol:DeployUsdcLendingStrategy \
  "${FORGE_COMMON[@]}" \
  -vvvv \
  ${BROADCAST_FLAG[@]+"${BROADCAST_FLAG[@]}"}

if [[ $DO_BROADCAST -eq 0 ]]; then
  echo; echo "dry run complete — address book (simulated) at $STRATEGY_OUTPUT_JSON"
  echo "run with --broadcast to deploy and produce the manifest."
  exit 0
fi

# ── Step 3: POST-DEPLOYMENT verification + manifest ──────────────────
echo; echo ">>> [3/3] post-deployment verification + manifest"
forge script script/PostflightUsdcLendingShadow.s.sol:PostflightUsdcLendingShadow \
  "${FORGE_COMMON[@]}" -vvv

echo
echo "── Shadow deployment complete ─────────────────────────────────────"
echo "  $OUT_DIR/addresses.json"
echo "  $OUT_DIR/manifest.json"
