#!/usr/bin/env bash
# ldk-api.sh - LDK server API wrappers via ldk-server-cli

LDK_API_KEY=""
LDK_TLS_CERT="/data/ldk-server/tls.crt"
LDK_API_KEY_FILE="/data/ldk-server/regtest/api_key"
LDK_BASE_URL="ldk-server:3002"

ldk_init() {
  # Read API key (raw bytes -> hex)
  if [ ! -f "$LDK_API_KEY_FILE" ]; then
    echo "ERROR: LDK API key file not found at $LDK_API_KEY_FILE" >&2
    return 1
  fi
  LDK_API_KEY=$(xxd -p "$LDK_API_KEY_FILE" | tr -d '\n')

  if [ ! -f "$LDK_TLS_CERT" ]; then
    echo "ERROR: LDK TLS cert not found at $LDK_TLS_CERT" >&2
    return 1
  fi
  log_info "LDK API initialized (key=${LDK_API_KEY:0:8}...)"
}

ldk_cli() {
  local result
  result=$(ldk-server-cli \
    --base-url "$LDK_BASE_URL" \
    --api-key "$LDK_API_KEY" \
    --tls-cert "$LDK_TLS_CERT" \
    "$@" 2>&1) || { echo "ldk_cli $* failed: $result" >&2; return 1; }
  echo "$result"
}

# --- Node info ---

ldk_get_node_info() {
  ldk_cli get-node-info
}

ldk_get_node_id() {
  ldk_cli get-node-info | jq -r '.node_id'
}

ldk_get_block_height() {
  ldk_cli get-node-info | jq -r '.current_best_block.height'
}

# --- Balances ---

ldk_get_balances() {
  ldk_cli get-balances
}

ldk_get_onchain_balance() {
  ldk_cli get-balances | jq -r '.spendable_onchain_balance_sats'
}

# --- On-chain ---

ldk_onchain_receive() {
  ldk_cli onchain-receive | jq -r '.address'
}

# --- Channels ---

ldk_list_channels() {
  ldk_cli list-channels
}

ldk_get_channel_value() {
  local user_channel_id="$1"
  ldk_cli list-channels | jq -r \
    --arg ucid "$user_channel_id" \
    '.channels[] | select(.user_channel_id == $ucid) | .channel_value_sats'
}

ldk_is_channel_usable() {
  local user_channel_id="$1"
  ldk_cli list-channels | jq -r \
    --arg ucid "$user_channel_id" \
    '.channels[] | select(.user_channel_id == $ucid) | .is_usable'
}

# --- Peer management ---

ldk_connect_peer() {
  local node_id="$1"
  local address="$2"
  ldk_cli connect-peer "$node_id" "$address" --persist
}

# --- Channel operations ---

ldk_open_channel() {
  local node_id="$1"
  local address="$2"
  local amount_sats="$3"
  local push_msat="${4:-}"
  local args=("open-channel" "$node_id" "$address" "${amount_sats}sat" "--announce-channel")
  if [ -n "$push_msat" ]; then
    args+=("--push-to-counterparty" "${push_msat}msat")
  fi
  ldk_cli "${args[@]}"
}

ldk_splice_in() {
  local user_channel_id="$1"
  local counterparty_node_id="$2"
  local amount_sats="$3"
  ldk_cli splice-in "$user_channel_id" "$counterparty_node_id" "${amount_sats}sat"
}

ldk_splice_out() {
  local user_channel_id="$1"
  local counterparty_node_id="$2"
  local amount_sats="$3"
  ldk_cli splice-out "$user_channel_id" "$counterparty_node_id" "${amount_sats}sat"
}

ldk_rbf_channel() {
  local user_channel_id="$1"
  local counterparty_node_id="$2"
  ldk_cli rbf-channel "$user_channel_id" "$counterparty_node_id"
}

# --- Payments ---

ldk_bolt11_receive() {
  local amount_msat="$1"
  local description="${2:-interop-test}"
  ldk_cli bolt11-receive "${amount_msat}msat" --description "$description" | jq -r '.invoice'
}

ldk_bolt11_send() {
  local invoice="$1"
  ldk_cli bolt11-send "$invoice"
}

# --- Helpers ---

# Wait for a specific LDK channel to become usable
ldk_wait_for_channel_usable() {
  local user_channel_id="$1"
  local timeout="${2:-90}"
  local start
  start=$(date +%s)
  while true; do
    local usable
    usable=$(ldk_is_channel_usable "$user_channel_id" 2>/dev/null) || usable="false"
    if [ "$usable" = "true" ]; then
      return 0
    fi
    local elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -ge "$timeout" ]; then
      log_fail "Timeout waiting for LDK channel $user_channel_id to become usable"
      ldk_list_channels | jq '.' >&2
      return 1
    fi
    mine_blocks 1
    sleep 2
  done
}

# Get the LDK user_channel_id for a channel with a given counterparty
ldk_find_channel_by_peer() {
  local counterparty_node_id="$1"
  ldk_cli list-channels | jq -r \
    --arg cpid "$counterparty_node_id" \
    '.channels[] | select(.counterparty_node_id == $cpid) | .user_channel_id' | head -1
}
