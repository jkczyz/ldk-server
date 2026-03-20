#!/usr/bin/env bash
# eclair-api.sh - Eclair API wrappers via curl

ECLAIR_API_URL="http://eclair:8080"
ECLAIR_API_PASSWORD="eclairpass"

eclair_api() {
  local endpoint="$1"
  shift
  local result
  result=$(curl -sf -u ":${ECLAIR_API_PASSWORD}" \
    -X POST \
    "$@" \
    "${ECLAIR_API_URL}/${endpoint}") || { echo "eclair_api $endpoint failed" >&2; return 1; }
  echo "$result"
}

# --- Node info ---

eclair_get_info() {
  eclair_api "getinfo"
}

eclair_get_node_id() {
  eclair_api "getinfo" | jq -r '.nodeId'
}

eclair_get_block_height() {
  eclair_api "getinfo" | jq -r '.blockHeight'
}

# --- Peer management ---

eclair_connect() {
  local uri="$1"
  eclair_api "connect" -d "uri=$uri"
}

# --- On-chain ---

eclair_get_new_address() {
  eclair_api "getnewaddress" | jq -r '.'
}

# --- Channel operations ---

eclair_open() {
  local node_id="$1"
  local amount_sats="$2"
  local push_msat="${3:-}"
  local params="nodeId=$node_id&fundingSatoshis=$amount_sats&announceChannel=true"
  if [ -n "$push_msat" ]; then
    params="${params}&pushMsat=$push_msat"
  fi
  eclair_api "open" -d "$params"
}

eclair_channels() {
  eclair_api "channels"
}

eclair_channel() {
  local channel_id="$1"
  eclair_api "channel" -d "channelId=$channel_id"
}

eclair_splice_in() {
  local channel_id="$1"
  local amount_sats="$2"
  eclair_api "splicein" -d "channelId=$channel_id&amountIn=$amount_sats"
}

eclair_splice_out() {
  local channel_id="$1"
  local amount_sats="$2"
  local address="$3"
  eclair_api "spliceout" -d "channelId=$channel_id&amountOut=$amount_sats&address=$address"
}

eclair_rbf_splice() {
  local channel_id="$1"
  local target_feerate="$2"
  eclair_api "rbfsplice" -d "channelId=$channel_id&targetFeerate=$target_feerate"
}

# --- Payments ---

eclair_create_invoice() {
  local amount_msat="$1"
  local description="${2:-interop-test}"
  eclair_api "createinvoice" -d "amountMsat=$amount_msat&description=$description"
}

eclair_get_invoice() {
  local amount_msat="$1"
  local description="${2:-interop-test}"
  eclair_api "createinvoice" -d "amountMsat=$amount_msat&description=$description" | jq -r '.serialized'
}

eclair_pay_invoice() {
  local invoice="$1"
  eclair_api "payinvoice" -d "invoice=$invoice"
}

# --- Helpers ---

# Find Eclair channelId for a channel with a given counterparty
eclair_find_channel_by_peer() {
  local node_id="$1"
  eclair_api "channels" -d "nodeId=$node_id" | jq -r '.[0].channelId // empty'
}

# Wait for an Eclair channel to reach NORMAL state
eclair_wait_for_channel_normal() {
  local channel_id="$1"
  local timeout="${2:-90}"
  local start
  start=$(date +%s)
  while true; do
    local state
    state=$(eclair_channel "$channel_id" 2>/dev/null | jq -r '.state // "UNKNOWN"') || state="UNKNOWN"
    if [ "$state" = "NORMAL" ]; then
      return 0
    fi
    local elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -ge "$timeout" ]; then
      log_fail "Timeout waiting for Eclair channel $channel_id to reach NORMAL (current=$state)"
      return 1
    fi
    mine_blocks 1
    sleep 2
  done
}
