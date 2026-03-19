#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  echo "[demo] missing .env at repo root"
  exit 1
fi

set -a
source .env
set +a

require_var() {
  local key="$1"
  if [[ -z "${!key:-}" ]]; then
    echo "[demo] missing required env var: $key"
    exit 1
  fi
}

run_with_retry() {
  local label="$1"
  shift
  local max_attempts="${RETRY_MAX_ATTEMPTS:-5}"
  local delay_seconds="${RETRY_DELAY_SECONDS:-8}"
  local attempt=1

  while true; do
    if "$@"; then
      return 0
    fi

    if [[ "$attempt" -ge "$max_attempts" ]]; then
      echo "[demo] ${label} failed after ${attempt} attempts"
      return 1
    fi

    echo "[demo] ${label} failed on attempt ${attempt}/${max_attempts}; retrying in ${delay_seconds}s..."
    sleep "$delay_seconds"
    attempt=$((attempt + 1))
  done
}

capture_with_retry() {
  local label="$1"
  shift
  local max_attempts="${RETRY_MAX_ATTEMPTS:-5}"
  local delay_seconds="${RETRY_DELAY_SECONDS:-8}"
  local attempt=1
  local output

  while true; do
    if output="$("$@" 2>/dev/null)"; then
      printf '%s\n' "$output"
      return 0
    fi

    if [[ "$attempt" -ge "$max_attempts" ]]; then
      echo "[demo] ${label} failed after ${attempt} attempts"
      return 1
    fi

    echo "[demo] ${label} failed on attempt ${attempt}/${max_attempts}; retrying in ${delay_seconds}s..."
    sleep "$delay_seconds"
    attempt=$((attempt + 1))
  done
}

rpc_alive() {
  local rpc_url="$1"
  local payload='{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'
  local response

  response="$(curl -sS --max-time 8 -H 'content-type: application/json' -d "$payload" "$rpc_url" || true)"
  [[ -n "$response" ]] && jq -e '.result | type == "string"' >/dev/null 2>&1 <<<"$response"
}

select_rpc_url() {
  local selected=""
  local seen=""
  local url

  for url in "$@"; do
    if [[ -z "$url" ]]; then
      continue
    fi
    if grep -Fqx "$url" <<<"$seen"; then
      continue
    fi
    seen="${seen}"$'\n'"${url}"

    if rpc_alive "$url"; then
      selected="$url"
      break
    fi
  done

  if [[ -z "$selected" ]]; then
    return 1
  fi

  printf '%s\n' "$selected"
}

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

select_complete_broadcast_file() {
  local script_and_chain="$1"
  local dir_path="broadcast/${script_and_chain}"
  local candidate="${dir_path}/run-latest.json"
  local tx_count
  local empty_hashes

  if [[ -f "$candidate" ]]; then
    tx_count="$(jq '.transactions | length' "$candidate" 2>/dev/null || echo 0)"
    empty_hashes="$(jq '[.transactions[] | select((.hash // "") == "")] | length' "$candidate" 2>/dev/null || echo 999)"
    if [[ "$tx_count" -gt 0 && "$empty_hashes" -eq 0 ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  if [[ -d "$dir_path" ]]; then
    while IFS= read -r file_path; do
      tx_count="$(jq '.transactions | length' "$file_path" 2>/dev/null || echo 0)"
      empty_hashes="$(jq '[.transactions[] | select((.hash // "") == "")] | length' "$file_path" 2>/dev/null || echo 999)"
      if [[ "$tx_count" -gt 0 && "$empty_hashes" -eq 0 ]]; then
        printf '%s\n' "$file_path"
        return 0
      fi
    done < <(ls -1t "${dir_path}"/run-*.json 2>/dev/null || true)
  fi

  printf '%s\n' "$candidate"
}

upsert_env() {
  local key="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    BEGIN { updated = 0 }
    {
      if ($0 ~ "^" k "=") {
        print k "=" v
        updated = 1
      } else {
        print $0
      }
    }
    END {
      if (updated == 0) {
        print k "=" v
      }
    }
  ' .env > "$tmp"
  mv "$tmp" .env
}

code_exists_rpc() {
  local addr="$1"
  local rpc_url="$2"
  if [[ -z "$addr" || "$addr" == "0x0000000000000000000000000000000000000000" ]]; then
    return 1
  fi
  local code
  code="$(capture_with_retry "cast code ${addr}" cast code "$addr" --rpc-url "$rpc_url")"
  [[ -n "$code" && "$code" != "0x" ]]
}

print_artifact_tx_urls() {
  local label="$1"
  local artifact="$2"
  local explorer_base="$3"
  if [[ ! -f "$artifact" ]]; then
    return 0
  fi

  echo "$label"
  jq -r '.transactions[] | .hash // empty | select(length > 0)' "$artifact" | while read -r tx; do
    echo "  ${explorer_base}/tx/${tx}"
  done
}

extract_contract_addr() {
  local artifact="$1"
  local contract_name="$2"
  jq -r --arg name "$contract_name" '.transactions[] | select(.contractName == $name) | .contractAddress' "$artifact" | tail -n1
}

extract_contract_tx() {
  local artifact="$1"
  local contract_name="$2"
  jq -r --arg name "$contract_name" '.transactions[] | select(.contractName == $name) | .hash' "$artifact" | tail -n1
}

require_var SEPOLIA_RPC_URL
require_var SEPOLIA_PRIVATE_KEY
require_var OWNER_ADDRESS
require_var UNICHAIN_EXPLORER_BASE

UNICHAIN_PRIVATE_KEY="$SEPOLIA_PRIVATE_KEY"
RPC_FALLBACK_A="${UNICHAIN_SEPOLIA_RPC_URL:-}"
RPC_FALLBACK_B="${unichain_SEPOLIA_RPC_URL:-}"
RPC_FALLBACK_C="https://sepolia.unichain.org"
RPC_FALLBACK_D="https://unichain-sepolia.drpc.org"
UNICHAIN_RPC_URL="$(select_rpc_url "$SEPOLIA_RPC_URL" "$RPC_FALLBACK_A" "$RPC_FALLBACK_B" "$RPC_FALLBACK_C" "$RPC_FALLBACK_D")" || {
  echo "[demo] unable to find a healthy Unichain Sepolia RPC endpoint"
  exit 1
}
UNICHAIN_CHAIN_ID="${SEPOLIA_CHAIN_ID:-1301}"
UNICHAIN_EXPLORER_BASE="${UNICHAIN_EXPLORER_BASE%/}"

DEMO_ENABLE_REACTIVE="${DEMO_ENABLE_REACTIVE:-1}"
DEMO_REACTIVE_REQUIRED="${DEMO_REACTIVE_REQUIRED:-0}"
DEMO_FORCE_REACTIVE_CALLBACK_REDEPLOY="${DEMO_FORCE_REACTIVE_CALLBACK_REDEPLOY:-0}"
REACTIVE_ACTIVE="$DEMO_ENABLE_REACTIVE"
REACTIVE_EXPLORER="${REACTIVE_EXPLORER_BASE:-https://lasna.reactscan.net}"
REACTIVE_CHAIN_ID="${REACTIVE_CHAIN_ID:-5318007}"

if [[ "$DEMO_ENABLE_REACTIVE" != "0" ]]; then
  require_var REACTIVE_RPC_URL
  require_var REACTIVE_PRIVATE_KEY
  require_var SYSTEM_CONTRACT_ADDR
  require_var DESTINATION_CALLBACK_PROXY_ADDR
  require_var ORIGIN_CHAIN_ID
  require_var DESTINATION_CHAIN_ID
fi

unichain_wallet="$(cast wallet address --private-key "$UNICHAIN_PRIVATE_KEY")"
unichain_balance_wei="$(capture_with_retry "cast balance preflight (unichain)" cast balance "$unichain_wallet" --rpc-url "$UNICHAIN_RPC_URL")"

printf '\n[PHASE 0] Preflight\n'
echo "Unichain RPC:            $UNICHAIN_RPC_URL"
echo "Unichain Operator EOA:   $unichain_wallet"
echo "Unichain Balance (wei):  $unichain_balance_wei"

if [[ "$DEMO_ENABLE_REACTIVE" != "0" ]]; then
  reactive_wallet="$(cast wallet address --private-key "$REACTIVE_PRIVATE_KEY")"
  reactive_balance_wei="$(capture_with_retry "cast balance preflight (reactive)" cast balance "$reactive_wallet" --rpc-url "$REACTIVE_RPC_URL")"
  echo "Reactive RPC:            $REACTIVE_RPC_URL"
  echo "Reactive Operator EOA:   $reactive_wallet"
  echo "Reactive Balance (wei):  $reactive_balance_wei"
  if [[ -z "${LARGE_CAP_REACTIVE_EXPECTED_SENDER:-}" ]]; then
    LARGE_CAP_REACTIVE_EXPECTED_SENDER="$reactive_wallet"
    upsert_env LARGE_CAP_REACTIVE_EXPECTED_SENDER "$LARGE_CAP_REACTIVE_EXPECTED_SENDER"
  fi
  echo "Reactive expected sender (RVM ID): ${LARGE_CAP_REACTIVE_EXPECTED_SENDER}"
fi

echo
printf '[PHASE 1] Verify/deploy core contracts on Unichain Sepolia\n'

need_core_deploy=0
if ! code_exists_rpc "${LARGE_CAP_VAULT_ADDRESS:-}" "$UNICHAIN_RPC_URL"; then need_core_deploy=1; fi
if ! code_exists_rpc "${LARGE_CAP_HOOK_ADDRESS:-}" "$UNICHAIN_RPC_URL"; then need_core_deploy=1; fi
if ! code_exists_rpc "${LARGE_CAP_EXECUTOR_ADDRESS:-}" "$UNICHAIN_RPC_URL"; then need_core_deploy=1; fi

core_deploy_json="$(select_complete_broadcast_file "00_DeployLargeCapSystem.s.sol/${UNICHAIN_CHAIN_ID}")"

if [[ "$need_core_deploy" -eq 1 ]]; then
  echo "Core deployment missing or invalid. Broadcasting deploy script..."
  run_with_retry "deploy core contracts" env PRIVATE_KEY="$UNICHAIN_PRIVATE_KEY" \
    forge script script/00_DeployLargeCapSystem.s.sol:DeployLargeCapSystemScript \
    --rpc-url "$UNICHAIN_RPC_URL" --broadcast -vv

  core_deploy_json="$(select_complete_broadcast_file "00_DeployLargeCapSystem.s.sol/${UNICHAIN_CHAIN_ID}")"
  if [[ ! -f "$core_deploy_json" ]]; then
    echo "[demo] unable to locate core deployment artifact"
    exit 1
  fi

  vault_addr="$(extract_contract_addr "$core_deploy_json" "OrderBookVault")"
  hook_addr="$(extract_contract_addr "$core_deploy_json" "LargeCapExecutionHook")"
  exec_addr="$(extract_contract_addr "$core_deploy_json" "Executor")"

  vault_tx="$(extract_contract_tx "$core_deploy_json" "OrderBookVault")"
  hook_tx="$(extract_contract_tx "$core_deploy_json" "LargeCapExecutionHook")"
  exec_tx="$(extract_contract_tx "$core_deploy_json" "Executor")"

  upsert_env LARGE_CAP_VAULT_ADDRESS "$vault_addr"
  upsert_env LARGE_CAP_HOOK_ADDRESS "$hook_addr"
  upsert_env LARGE_CAP_EXECUTOR_ADDRESS "$exec_addr"
  upsert_env LARGE_CAP_DEPLOY_TX_VAULT "$vault_tx"
  upsert_env LARGE_CAP_DEPLOY_TX_HOOK "$hook_tx"
  upsert_env LARGE_CAP_DEPLOY_TX_EXECUTOR "$exec_tx"

  LARGE_CAP_VAULT_ADDRESS="$vault_addr"
  LARGE_CAP_HOOK_ADDRESS="$hook_addr"
  LARGE_CAP_EXECUTOR_ADDRESS="$exec_addr"
  LARGE_CAP_DEPLOY_TX_VAULT="$vault_tx"
  LARGE_CAP_DEPLOY_TX_HOOK="$hook_tx"
  LARGE_CAP_DEPLOY_TX_EXECUTOR="$exec_tx"

  echo "Core deployment completed and .env updated."
else
  echo "Existing core deployment detected."
fi

echo "Vault:    ${LARGE_CAP_VAULT_ADDRESS}"
echo "Hook:     ${LARGE_CAP_HOOK_ADDRESS}"
echo "Executor: ${LARGE_CAP_EXECUTOR_ADDRESS}"

for tx in "${LARGE_CAP_DEPLOY_TX_VAULT:-}" "${LARGE_CAP_DEPLOY_TX_HOOK:-}" "${LARGE_CAP_DEPLOY_TX_EXECUTOR:-}"; do
  if [[ -n "$tx" ]]; then
    echo "Core deploy tx: ${UNICHAIN_EXPLORER_BASE}/tx/${tx}"
  fi
done

reactive_callback_deploy_json=""
reactive_scheduler_deploy_json=""

if [[ "$DEMO_ENABLE_REACTIVE" != "0" ]]; then
  echo
  printf '[PHASE 2] Verify/deploy Reactive integration (Unichain callback + Reactive scheduler)\n'

  need_callback_deploy=0
  if ! code_exists_rpc "${LARGE_CAP_REACTIVE_CALLBACK_ADDRESS:-}" "$UNICHAIN_RPC_URL"; then need_callback_deploy=1; fi
  if [[ "$DEMO_FORCE_REACTIVE_CALLBACK_REDEPLOY" == "1" ]]; then need_callback_deploy=1; fi

  reactive_callback_deploy_json="$(select_complete_broadcast_file "12_DeployReactiveCallback.s.sol/${UNICHAIN_CHAIN_ID}")"

  if [[ "$need_callback_deploy" -eq 1 ]]; then
    echo "Reactive callback missing or invalid. Broadcasting deploy script..."
    if ! run_with_retry "deploy reactive callback" env PRIVATE_KEY="$UNICHAIN_PRIVATE_KEY" \
      LARGE_CAP_VAULT_ADDRESS="$LARGE_CAP_VAULT_ADDRESS" \
      LARGE_CAP_EXECUTOR_ADDRESS="$LARGE_CAP_EXECUTOR_ADDRESS" \
      OWNER_ADDRESS="$OWNER_ADDRESS" \
      DESTINATION_CALLBACK_PROXY_ADDR="$DESTINATION_CALLBACK_PROXY_ADDR" \
      forge script script/12_DeployReactiveCallback.s.sol:DeployReactiveCallbackScript \
      --rpc-url "$UNICHAIN_RPC_URL" --broadcast -vv; then
      echo "[demo] WARNING: reactive callback deployment failed; continuing with Unichain-only demo."
      REACTIVE_ACTIVE=0
    fi

    if [[ "$REACTIVE_ACTIVE" != "0" ]]; then
      reactive_callback_deploy_json="$(select_complete_broadcast_file "12_DeployReactiveCallback.s.sol/${UNICHAIN_CHAIN_ID}")"
      if [[ ! -f "$reactive_callback_deploy_json" ]]; then
        echo "[demo] unable to locate reactive callback deployment artifact"
        REACTIVE_ACTIVE=0
      fi
    fi

    if [[ "$REACTIVE_ACTIVE" != "0" ]]; then
      callback_addr="$(extract_contract_addr "$reactive_callback_deploy_json" "LargeCapReactiveCallback")"
      callback_tx="$(extract_contract_tx "$reactive_callback_deploy_json" "LargeCapReactiveCallback")"

      upsert_env LARGE_CAP_REACTIVE_CALLBACK_ADDRESS "$callback_addr"
      upsert_env LARGE_CAP_REACTIVE_CALLBACK_DEPLOY_TX "$callback_tx"

      LARGE_CAP_REACTIVE_CALLBACK_ADDRESS="$callback_addr"
      LARGE_CAP_REACTIVE_CALLBACK_DEPLOY_TX="$callback_tx"

      echo "Reactive callback deployed and .env updated."
    fi
  else
    echo "Existing reactive callback deployment detected."
  fi

  if [[ "$REACTIVE_ACTIVE" != "0" ]]; then
    need_scheduler_deploy=0
    if ! code_exists_rpc "${LARGE_CAP_REACTIVE_SCHEDULER_ADDRESS:-}" "$REACTIVE_RPC_URL"; then need_scheduler_deploy=1; fi

    reactive_scheduler_deploy_json="$(select_complete_broadcast_file "13_DeployReactiveScheduler.s.sol/${REACTIVE_CHAIN_ID}")"

    if [[ "$need_scheduler_deploy" -eq 1 ]]; then
      echo "Reactive scheduler missing or invalid. Broadcasting deploy script..."
      if ! run_with_retry "deploy reactive scheduler" env PRIVATE_KEY="$REACTIVE_PRIVATE_KEY" \
        SYSTEM_CONTRACT_ADDR="$SYSTEM_CONTRACT_ADDR" \
        ORIGIN_CHAIN_ID="$ORIGIN_CHAIN_ID" \
        DESTINATION_CHAIN_ID="$DESTINATION_CHAIN_ID" \
        LARGE_CAP_HOOK_ADDRESS="$LARGE_CAP_HOOK_ADDRESS" \
        LARGE_CAP_REACTIVE_CALLBACK_ADDRESS="$LARGE_CAP_REACTIVE_CALLBACK_ADDRESS" \
        forge script script/13_DeployReactiveScheduler.s.sol:DeployReactiveSchedulerScript \
        --rpc-url "$REACTIVE_RPC_URL" --broadcast -vv; then
        echo "[demo] WARNING: reactive scheduler deployment failed; continuing with Unichain-only demo."
        REACTIVE_ACTIVE=0
      fi

      if [[ "$REACTIVE_ACTIVE" != "0" ]]; then
        reactive_scheduler_deploy_json="$(select_complete_broadcast_file "13_DeployReactiveScheduler.s.sol/${REACTIVE_CHAIN_ID}")"
        if [[ ! -f "$reactive_scheduler_deploy_json" ]]; then
          echo "[demo] WARNING: unable to locate reactive scheduler deployment artifact; disabling reactive phase."
          REACTIVE_ACTIVE=0
        fi
      fi

      if [[ "$REACTIVE_ACTIVE" != "0" ]]; then
        scheduler_addr="$(extract_contract_addr "$reactive_scheduler_deploy_json" "LargeCapReactiveScheduler")"
        scheduler_tx="$(extract_contract_tx "$reactive_scheduler_deploy_json" "LargeCapReactiveScheduler")"

        upsert_env LARGE_CAP_REACTIVE_SCHEDULER_ADDRESS "$scheduler_addr"
        upsert_env LARGE_CAP_REACTIVE_SCHEDULER_DEPLOY_TX "$scheduler_tx"

        LARGE_CAP_REACTIVE_SCHEDULER_ADDRESS="$scheduler_addr"
        LARGE_CAP_REACTIVE_SCHEDULER_DEPLOY_TX="$scheduler_tx"

        echo "Reactive scheduler deployed and .env updated."
      fi
    else
      echo "Existing reactive scheduler deployment detected."
    fi
  fi

  if [[ "$REACTIVE_ACTIVE" != "0" && -n "${LARGE_CAP_REACTIVE_CALLBACK_ADDRESS:-}" ]]; then
    expected_sender="${LARGE_CAP_REACTIVE_EXPECTED_SENDER:-$reactive_wallet}"
    if [[ -z "$expected_sender" ]]; then
      expected_sender="${LARGE_CAP_REACTIVE_SCHEDULER_ADDRESS:-0x0000000000000000000000000000000000000000}"
    fi
    current_expected_sender="$(capture_with_retry "read expectedReactiveSender" cast call "$LARGE_CAP_REACTIVE_CALLBACK_ADDRESS" "expectedReactiveSender()(address)" --rpc-url "$UNICHAIN_RPC_URL")"
    if [[ "$(to_lower "$current_expected_sender")" != "$(to_lower "$expected_sender")" ]]; then
      echo "Configuring callback expected reactive sender..."
      set_sender_output="$(capture_with_retry "set expectedReactiveSender" cast send "$LARGE_CAP_REACTIVE_CALLBACK_ADDRESS" "setExpectedReactiveSender(address)" "$expected_sender" --rpc-url "$UNICHAIN_RPC_URL" --private-key "$UNICHAIN_PRIVATE_KEY" --async)"
      set_sender_tx="$(printf '%s\n' "$set_sender_output" | rg -o '0x[a-fA-F0-9]{64}' | head -n1 || true)"
      if [[ -n "$set_sender_tx" ]]; then
        upsert_env LARGE_CAP_REACTIVE_SET_SENDER_TX "$set_sender_tx"
        LARGE_CAP_REACTIVE_SET_SENDER_TX="$set_sender_tx"
      fi
    fi
  fi

  if [[ "$REACTIVE_ACTIVE" == "0" && "$DEMO_REACTIVE_REQUIRED" == "1" ]]; then
    echo "[demo] reactive integration required (DEMO_REACTIVE_REQUIRED=1) but deployment/configuration failed."
    exit 1
  fi

  echo "Reactive callback:  ${LARGE_CAP_REACTIVE_CALLBACK_ADDRESS:-unset}"
  echo "Reactive scheduler: ${LARGE_CAP_REACTIVE_SCHEDULER_ADDRESS:-unset}"
  echo "Reactive expected sender: ${LARGE_CAP_REACTIVE_EXPECTED_SENDER:-unset}"

  if [[ -n "${LARGE_CAP_REACTIVE_CALLBACK_DEPLOY_TX:-}" ]]; then
    echo "Reactive callback tx:  ${UNICHAIN_EXPLORER_BASE}/tx/${LARGE_CAP_REACTIVE_CALLBACK_DEPLOY_TX}"
  fi
  if [[ -n "${LARGE_CAP_REACTIVE_SET_SENDER_TX:-}" ]]; then
    echo "Callback config tx:    ${UNICHAIN_EXPLORER_BASE}/tx/${LARGE_CAP_REACTIVE_SET_SENDER_TX}"
  fi
  if [[ -n "${LARGE_CAP_REACTIVE_SCHEDULER_DEPLOY_TX:-}" ]]; then
    echo "Reactive scheduler tx: ${REACTIVE_EXPLORER%/}/tx/${LARGE_CAP_REACTIVE_SCHEDULER_DEPLOY_TX}"
  fi
fi

echo
printf '[PHASE 3] Run on-chain compare demo (user baseline vs segmented execution)\n'
if [[ "${DEMO_SKIP_BROADCAST:-0}" == "1" ]]; then
  echo "Skipping broadcast because DEMO_SKIP_BROADCAST=1"
else
  RETRY_MAX_ATTEMPTS="${DEMO_COMPARE_RETRY_MAX_ATTEMPTS:-1}" run_with_retry "run unichain compare demo" env PRIVATE_KEY="$UNICHAIN_PRIVATE_KEY" \
    LARGE_CAP_REACTIVE_CALLBACK_ADDRESS="$([[ "$REACTIVE_ACTIVE" != "0" ]] && printf '%s' "${LARGE_CAP_REACTIVE_CALLBACK_ADDRESS:-}" || printf '')" \
    LARGE_CAP_REACTIVE_SCHEDULER_ADDRESS="$([[ "$REACTIVE_ACTIVE" != "0" ]] && printf '%s' "${LARGE_CAP_REACTIVE_SCHEDULER_ADDRESS:-}" || printf '')" \
    LARGE_CAP_REACTIVE_EXPECTED_SENDER="$([[ "$REACTIVE_ACTIVE" != "0" ]] && printf '%s' "${LARGE_CAP_REACTIVE_EXPECTED_SENDER:-}" || printf '')" \
    DEMO_REACTIVE_ENFORCE_SENDER="$([[ "$REACTIVE_ACTIVE" != "0" ]] && printf '%s' "${DEMO_REACTIVE_ENFORCE_SENDER:-1}" || printf '0')" \
    forge script script/11_DemoCompareUnichain.s.sol:DemoCompareUnichainScript \
    --rpc-url "$UNICHAIN_RPC_URL" --broadcast --slow -vv
fi

demo_json="$(select_complete_broadcast_file "11_DemoCompareUnichain.s.sol/${UNICHAIN_CHAIN_ID}")"
if [[ ! -f "$demo_json" ]]; then
  echo "[demo] unable to locate demo broadcast artifact"
  exit 1
fi
echo "Using compare demo artifact: $demo_json"

echo
printf '[PHASE 4] Transaction links (judge-ready)\n'

total_txs="$(jq '.transactions | length' "$demo_json")"
vault_lc="$(to_lower "${LARGE_CAP_VAULT_ADDRESS}")"
executor_lc="$(to_lower "${LARGE_CAP_EXECUTOR_ADDRESS}")"
order_create_txs="$(jq --arg vault "$vault_lc" '[.transactions[] | select((.contractAddress // "") | ascii_downcase == $vault)] | length' "$demo_json")"
executor_txs="$(jq --arg exec "$executor_lc" '[.transactions[] | select((.contractAddress // "") | ascii_downcase == $exec)] | length' "$demo_json")"
mock_token_creates="$(jq '[.transactions[] | select(.transactionType=="CREATE" and .contractName=="MockERC20")] | length' "$demo_json")"

echo "Total compare tx count:       $total_txs"
echo "Mock token create tx count:   $mock_token_creates"
echo "Vault interaction tx count:   $order_create_txs"
echo "Executor/slice tx count:      $executor_txs"

echo
print_artifact_tx_urls "Core deployment tx URLs:" "$core_deploy_json" "$UNICHAIN_EXPLORER_BASE"
if [[ "$DEMO_ENABLE_REACTIVE" != "0" ]]; then
  print_artifact_tx_urls "Reactive callback deployment tx URLs:" "$reactive_callback_deploy_json" "$UNICHAIN_EXPLORER_BASE"
  if [[ "$REACTIVE_ACTIVE" != "0" ]]; then
    print_artifact_tx_urls "Reactive scheduler deployment tx URLs:" "$reactive_scheduler_deploy_json" "${REACTIVE_EXPLORER%/}"
  else
    echo "Reactive scheduler deployment tx URLs: unavailable (deployment failed on configured Reactive RPC)."
  fi
fi
print_artifact_tx_urls "Compare demo tx URLs:" "$demo_json" "$UNICHAIN_EXPLORER_BASE"

echo
echo "Contract URLs:"
echo "  Vault:             ${UNICHAIN_EXPLORER_BASE}/address/${LARGE_CAP_VAULT_ADDRESS}"
echo "  Hook:              ${UNICHAIN_EXPLORER_BASE}/address/${LARGE_CAP_HOOK_ADDRESS}"
echo "  Executor:          ${UNICHAIN_EXPLORER_BASE}/address/${LARGE_CAP_EXECUTOR_ADDRESS}"
if [[ "$DEMO_ENABLE_REACTIVE" != "0" ]]; then
  echo "  Reactive Callback: ${UNICHAIN_EXPLORER_BASE}/address/${LARGE_CAP_REACTIVE_CALLBACK_ADDRESS}"
  if [[ "$REACTIVE_ACTIVE" != "0" ]]; then
    echo "  Reactive Scheduler:${REACTIVE_EXPLORER%/}/address/${LARGE_CAP_REACTIVE_SCHEDULER_ADDRESS}"
  else
    echo "  Reactive Scheduler: unavailable (deployment failed on configured Reactive RPC)"
  fi
fi

echo
echo "[PHASE 5] User-perspective walkthrough"
echo "1) User submits one large order in the app (BBE or SOF) and signs token approval."
echo "2) Vault escrows input and emits OrderCreated telemetry."
echo "3) Hook enforces per-slice constraints via beforeSwap/afterSwap during each swap."
echo "4) Executor processes slices; vault tracks partial fills and remaining notional."
if [[ "$REACTIVE_ACTIVE" != "0" ]]; then
  echo "5) Reactive scheduler subscribes to hook telemetry and queues callback jobs cross-chain."
  echo "6) Callback contract executes the next eligible slice using registered pool keys."
  echo "7) User monitors progress and compares segmented realized output against baseline."
else
  echo "5) User monitors progress and compares segmented realized output against baseline."
fi

echo
echo "[demo] complete"
