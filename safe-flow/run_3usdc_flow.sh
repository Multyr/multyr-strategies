#!/usr/bin/env bash
set -euo pipefail

# User-side smoke cycle after Safe batch 02:
# 3 USDC -> CoreVault -> strategy -> lending adapter -> CoreVault -> user.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

CAST_BIN="${CAST_BIN:-cast}"
RPC_URL="${RPC_URL:-}"
USER_PRIVATE_KEY="${USER_PRIVATE_KEY:-}"
USE_LEGACY_TX="${USE_LEGACY_TX:-false}"
CAST_GAS_LIMIT="${CAST_GAS_LIMIT:-}"
STRATEGY_BOOK="${STRATEGY_BOOK:-${REPO_ROOT}/broadcast/strategy-addresses.json}"

USDC="${USDC:-0xaf88d065e77c8cC2239327C5EDb3A432268e5831}"
VAULT="${VAULT:-0x685Ec439Fc62736934FF6A74301B50173E34446b}"
ROUTER="${ROUTER:-0x003BF0faD6b644536c14dcbF822b9fE1A3626b74}"
SAFE="${SAFE:-0x70ef444799D6FBbE0865bA598Bee6795e064a326}"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
command -v "${CAST_BIN}" >/dev/null 2>&1 || {
  echo "cast is required; set CAST_BIN if it is not on PATH" >&2
  exit 1
}
[[ -r "${STRATEGY_BOOK}" ]] || {
  echo "strategy address book not found: ${STRATEGY_BOOK}" >&2
  exit 1
}

STRATEGY="${STRATEGY:-$(jq -r '.strategy' "${STRATEGY_BOOK}")}"
STRATEGY_UPKEEP="${STRATEGY_UPKEEP:-$(jq -r '.strategyUpkeep' "${STRATEGY_BOOK}")}"
PROTOCOL_REGISTRY="${PROTOCOL_REGISTRY:-$(jq -r '.protocolRegistry' "${STRATEGY_BOOK}")}"

DEPOSIT_ASSETS=3000000
# abi.encode(uint8(4), uint256(0)): StrategyUpkeep OP_DEPLOY_IDLE.
DEPLOY_IDLE_DATA="0x00000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000"

if [[ -z "${RPC_URL}" || -z "${USER_PRIVATE_KEY}" ]]; then
  echo "RPC_URL and USER_PRIVATE_KEY are required" >&2
  exit 1
fi
if [[ "$("${CAST_BIN}" chain-id --rpc-url "${RPC_URL}")" != "42161" ]]; then
  echo "Refusing to run outside Arbitrum One (42161)" >&2
  exit 1
fi

# Fail closed on the legacy deployment. The production registry owner must be
# the direct governance Safe.
REGISTRY_OWNER="$(
  "${CAST_BIN}" call "${PROTOCOL_REGISTRY}" 'owner()(address)' \
    --rpc-url "${RPC_URL}" 2>/dev/null || true
)"
if [[ "$(echo "${REGISTRY_OWNER}" | tr '[:upper:]' '[:lower:]')" != \
      "$(echo "${SAFE}" | tr '[:upper:]' '[:lower:]')" ]]; then
  echo "Refusing: address book does not reference a Safe-owned production registry" >&2
  echo "Deploy the fresh strategy and generate/execute the Safe batches first" >&2
  exit 1
fi

USER="$("${CAST_BIN}" wallet address --private-key "${USER_PRIVATE_KEY}")"

read_uint() {
  "${CAST_BIN}" call "$1" "$2" "${@:3}" --rpc-url "${RPC_URL}" | awk '{print $1}'
}

send_tx() {
  local target="$1"
  local signature="$2"
  shift 2
  local extra_args=()
  local receipt

  if [[ "${USE_LEGACY_TX}" == "true" ]]; then
    extra_args+=(--legacy)
  fi
  if [[ -n "${CAST_GAS_LIMIT}" ]]; then
    extra_args+=(--gas-limit "${CAST_GAS_LIMIT}")
  fi

  receipt="$(
    "${CAST_BIN}" send "${target}" "${signature}" "$@" \
      "${extra_args[@]}" \
      --private-key "${USER_PRIVATE_KEY}" --rpc-url "${RPC_URL}" --json
  )"
  if ! grep -Eq '"status"[[:space:]]*:[[:space:]]*"0x1"' <<< "${receipt}"; then
    echo "Transaction failed: ${target} ${signature}" >&2
    echo "${receipt}" >&2
    return 1
  fi
  echo "success: ${target} ${signature}"
}

if [[ "$("${CAST_BIN}" call "${VAULT}" 'paused()(bool)' --rpc-url "${RPC_URL}")" != "false" ]]; then
  echo "CoreVault is still paused; execute Safe batch 02 first" >&2
  exit 1
fi
if [[ "$("${CAST_BIN}" call "${ROUTER}" 'isStrategyEnabled(address)(bool)' \
  "${STRATEGY}" --rpc-url "${RPC_URL}")" != "true" ]]; then
  echo "Strategy is not enabled in StrategyRouter" >&2
  exit 1
fi

USDC_BEFORE="$(read_uint "${USDC}" 'balanceOf(address)(uint256)' "${USER}")"
SHARES_BEFORE="$(read_uint "${VAULT}" 'balanceOf(address)(uint256)' "${USER}")"
if (( USDC_BEFORE < DEPOSIT_ASSETS )); then
  echo "User ${USER} needs at least 3 USDC" >&2
  exit 1
fi

if [[ "${1:-}" != "--execute" ]]; then
  echo "Preflight passed for ${USER}. Re-run with --execute to broadcast."
  exit 0
fi

echo "1/6 Approve and deposit 3 USDC into CoreVault"
send_tx "${USDC}" 'approve(address,uint256)' "${VAULT}" "${DEPOSIT_ASSETS}"
send_tx "${VAULT}" 'deposit(uint256,address)' "${DEPOSIT_ASSETS}" "${USER}"

SHARES_AFTER="$(read_uint "${VAULT}" 'balanceOf(address)(uint256)' "${USER}")"
NEW_SHARES=$((SHARES_AFTER - SHARES_BEFORE))
if (( NEW_SHARES <= 0 )); then
  echo "Deposit minted no shares" >&2
  exit 1
fi

echo "2/6 Route up to 3 USDC from CoreVault to the strategy"
STRATEGY_BEFORE="$(read_uint "${STRATEGY}" 'totalAssets()(uint256)')"
send_tx "${VAULT}" 'deployToStrategies(uint256)' "${DEPOSIT_ASSETS}"
STRATEGY_AFTER_ROUTE="$(read_uint "${STRATEGY}" 'totalAssets()(uint256)')"
if (( STRATEGY_AFTER_ROUTE <= STRATEGY_BEFORE )); then
  echo "CoreVault did not route funds to the strategy" >&2
  exit 1
fi

echo "3/6 Ask StrategyUpkeep to deploy idle cash to a lending adapter"
IDLE_BEFORE="$(read_uint "${STRATEGY}" 'idleCash()(uint256)')"
send_tx "${STRATEGY_UPKEEP}" 'performUpkeep(bytes)' "${DEPLOY_IDLE_DATA}"
IDLE_AFTER="$(read_uint "${STRATEGY}" 'idleCash()(uint256)')"
if (( IDLE_AFTER >= IDLE_BEFORE )); then
  echo "StrategyUpkeep did not reduce idle cash; inspect UpkeepErrored events" >&2
  exit 1
fi

echo "4/6 Realize 3 USDC from strategy back into CoreVault"
VAULT_CASH_BEFORE="$(read_uint "${USDC}" 'balanceOf(address)(uint256)' "${VAULT}")"
STRATEGY_BEFORE_REALIZE="$(read_uint "${STRATEGY}" 'totalAssets()(uint256)')"
send_tx "${VAULT}" 'realizeForQueue(uint256)' "${DEPOSIT_ASSETS}"
VAULT_CASH_AFTER="$(read_uint "${USDC}" 'balanceOf(address)(uint256)' "${VAULT}")"
STRATEGY_AFTER_REALIZE="$(read_uint "${STRATEGY}" 'totalAssets()(uint256)')"
if (( VAULT_CASH_AFTER <= VAULT_CASH_BEFORE )); then
  echo "Realization returned no USDC to CoreVault" >&2
  exit 1
fi
if (( STRATEGY_AFTER_REALIZE >= STRATEGY_BEFORE_REALIZE )); then
  echo "Realization did not reduce strategy assets" >&2
  exit 1
fi

echo "5/6 Exit the newly minted position through instant withdrawal"
send_tx "${VAULT}" 'requestInstantWithdrawal(uint256)' "${NEW_SHARES}"

echo "6/6 Verify the smoke position was fully consumed"
SHARES_FINAL="$(read_uint "${VAULT}" 'balanceOf(address)(uint256)' "${USER}")"
USDC_FINAL="$(read_uint "${USDC}" 'balanceOf(address)(uint256)' "${USER}")"
if (( SHARES_FINAL != SHARES_BEFORE )); then
  echo "Unexpected residual shares: before=${SHARES_BEFORE}, final=${SHARES_FINAL}" >&2
  exit 1
fi
if (( USDC_FINAL <= USDC_BEFORE - DEPOSIT_ASSETS )); then
  echo "Withdrawal returned no USDC; it may have fallen back to the epoch queue" >&2
  exit 1
fi

echo "Round trip complete. USDC before=${USDC_BEFORE}, after=${USDC_FINAL}."
