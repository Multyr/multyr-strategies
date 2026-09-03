#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# deploy-usdc-lending.sh — runner for DeployUsdcLendingStrategy.s.sol
# ══════════════════════════════════════════════════════════════════════════
# Loads .env, validates the required variables are present, then runs the
# Arbitrum-only USDC lending strategy deploy script.
#
# Usage:
#   cp .env.example .env && fill it in
#   ./script/deploy-usdc-lending.sh            # dry run (simulate only)
#   ./script/deploy-usdc-lending.sh --broadcast   # actually send transactions
#
# Prerequisites (not checked by this script):
#   - Core system already deployed (multyr-core/script/DeployCoreSystem.s.sol)
#   - GOVERNANCE_ADDRESS is the deployed Gnosis Safe that will directly own
#     every strategy-side admin surface. A TimelockController is not required.
#   - Deployer EOA holds >= 0.001 USDC (Euler Permit2 init dust)
# ══════════════════════════════════════════════════════════════════════════

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
else
  echo "error: .env not found. Copy .env.example to .env and fill it in first." >&2
  exit 1
fi

# ── Required variables ───────────────────────────────────────────────────
required_vars=(
  RPC_URL
  DEPLOYER_PRIVATE_KEY
  VAULT_ADDRESS
  STRATEGY_ROUTER_ADDRESS
  BUFFER_MANAGER_ADDRESS
  HEALTH_REGISTRY_ADDRESS
  GUARDIAN_ADDRESS
  GOVERNANCE_ADDRESS
)
missing=()
for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    missing+=("$var")
  fi
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "error: missing required environment variable(s):" >&2
  for var in "${missing[@]}"; do
    echo "  - $var" >&2
  done
  exit 1
fi

BROADCAST_FLAG=()
VERIFY_FLAG=()
for arg in "$@"; do
  case "$arg" in
    --broadcast) BROADCAST_FLAG=(--broadcast) ;;
    --verify) VERIFY_FLAG=(--verify) ;;
    *)
      echo "error: unknown argument: $arg (expected --broadcast and/or --verify)" >&2
      exit 1
      ;;
  esac
done

if [[ ${#BROADCAST_FLAG[@]} -eq 0 ]]; then
  echo "Running in DRY-RUN mode (simulate only, no transactions sent)."
  echo "Pass --broadcast to actually deploy."
  echo
fi

# ── Contract source verification (--verify) ──────────────────────────────
# Uses the Etherscan V2 unified API (one key covers all chains, including
# Arbitrum) -- no per-chain [etherscan] block needed in foundry.toml. This
# matches how multyr-core's own already-verified core system deploy works
# (its foundry.toml has no [etherscan] section either; the key is passed
# explicitly on the command line).
VERIFY_ARGS=()
if [[ ${#VERIFY_FLAG[@]} -gt 0 ]]; then
  if [[ -z "${ETHERSCAN_API_KEY:-}" ]]; then
    echo "error: --verify requires ETHERSCAN_API_KEY to be set (in .env, or via" >&2
    echo "  source /path/to/multyr-core/.env before running this script)." >&2
    exit 1
  fi
  VERIFY_ARGS=(--verify --etherscan-api-key "$ETHERSCAN_API_KEY" --chain 42161)
fi

forge script script/DeployUsdcLendingStrategy.s.sol:DeployUsdcLendingStrategy \
  --rpc-url "$RPC_URL" \
  -vvvv \
  ${BROADCAST_FLAG[@]+"${BROADCAST_FLAG[@]}"} \
  ${VERIFY_ARGS[@]+"${VERIFY_ARGS[@]}"}
