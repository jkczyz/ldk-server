#!/usr/bin/env bash
# common.sh - Shared utilities for interop tests

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Test tracking ---
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
TEST_RESULTS=()

# --- Logging ---

log_info() {
  echo -e "${BLUE}[INFO]${NC} $*"
}

log_pass() {
  echo -e "${GREEN}[PASS]${NC} $*"
}

log_fail() {
  echo -e "${RED}[FAIL]${NC} $*"
}

log_skip() {
  echo -e "${YELLOW}[SKIP]${NC} $*"
}

log_debug() {
  if [ "${DEBUG:-0}" = "1" ]; then
    echo -e "[DEBUG] $*" >&2
  fi
}

# --- Bitcoin RPC ---

bitcoin_rpc() {
  local method="$1"
  shift
  local params=""
  if [ $# -gt 0 ]; then
    params=$(printf '%s,' "$@")
    params="${params%,}"
  fi
  local result
  result=$(curl -sf --user rpcuser:rpcpass \
    -H 'content-type:application/json' \
    -d "{\"jsonrpc\":\"1.0\",\"id\":\"test\",\"method\":\"${method}\",\"params\":[${params}]}" \
    http://bitcoind:18443/) || { echo "bitcoin_rpc ${method} failed" >&2; return 1; }
  echo "$result" | jq '.result'
}

mine_blocks() {
  local count="${1:-1}"
  local addr
  addr=$(bitcoin_rpc "getnewaddress" | jq -r '.')
  bitcoin_rpc "generatetoaddress" "$count" "\"$addr\"" > /dev/null
}

get_block_height() {
  bitcoin_rpc "getblockcount" | jq -r '.'
}

# --- Synchronization ---

wait_for_ldk_sync() {
  local target_height="$1"
  local timeout="${2:-30}"
  local start
  start=$(date +%s)
  while true; do
    local ldk_height
    ldk_height=$(ldk_cli get-node-info 2>/dev/null | jq -r '.current_best_block.height // 0') || ldk_height=0
    if [ "$ldk_height" -ge "$target_height" ]; then
      return 0
    fi
    local elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -ge "$timeout" ]; then
      log_fail "LDK sync timeout: at height $ldk_height, target $target_height"
      return 1
    fi
    sleep 2
  done
}

wait_for_eclair_sync() {
  local target_height="$1"
  local timeout="${2:-30}"
  local start
  start=$(date +%s)
  while true; do
    local eclair_height
    eclair_height=$(eclair_api "getinfo" 2>/dev/null | jq -r '.blockHeight // 0') || eclair_height=0
    if [ "$eclair_height" -ge "$target_height" ]; then
      return 0
    fi
    local elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -ge "$timeout" ]; then
      log_fail "Eclair sync timeout: at height $eclair_height, target $target_height"
      return 1
    fi
    sleep 2
  done
}

wait_for_sync() {
  local target_height="$1"
  local timeout="${2:-30}"
  wait_for_ldk_sync "$target_height" "$timeout" || return 1
  wait_for_eclair_sync "$target_height" "$timeout" || return 1
}

mine_and_sync() {
  local count="${1:-1}"
  mine_blocks "$count"
  local height
  height=$(get_block_height)
  wait_for_sync "$height" 30
}

# --- Channel waiting ---

wait_for_ldk_usable_channel() {
  local timeout="${1:-90}"
  local start
  start=$(date +%s)
  while true; do
    local channels
    channels=$(ldk_cli list-channels 2>/dev/null) || channels='{}'
    local usable
    usable=$(echo "$channels" | jq '[.channels[]? | select(.is_usable == true)] | length')
    if [ "$usable" -gt 0 ]; then
      return 0
    fi
    local elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -ge "$timeout" ]; then
      log_fail "Timeout waiting for LDK usable channel"
      echo "$channels" | jq '.' >&2
      return 1
    fi
    # Mine a block to trigger chain processing
    mine_blocks 1
    sleep 2
  done
}

wait_for_eclair_channel_state() {
  local channel_id="$1"
  local target_state="${2:-NORMAL}"
  local timeout="${3:-90}"
  local start
  start=$(date +%s)
  while true; do
    local state
    state=$(eclair_api "channel" "-d" "channelId=$channel_id" 2>/dev/null | jq -r '.state // "UNKNOWN"') || state="UNKNOWN"
    if [ "$state" = "$target_state" ]; then
      return 0
    fi
    local elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -ge "$timeout" ]; then
      log_fail "Timeout waiting for Eclair channel $channel_id state=$target_state (current=$state)"
      return 1
    fi
    mine_blocks 1
    sleep 2
  done
}

# --- Assertions ---

assert_eq() {
  local actual="$1"
  local expected="$2"
  local msg="${3:-}"
  if [ "$actual" != "$expected" ]; then
    log_fail "assert_eq failed: expected='$expected' actual='$actual' $msg"
    return 1
  fi
}

assert_gt() {
  local actual="$1"
  local threshold="$2"
  local msg="${3:-}"
  if [ "$actual" -le "$threshold" ]; then
    log_fail "assert_gt failed: $actual <= $threshold $msg"
    return 1
  fi
}

assert_ge() {
  local actual="$1"
  local threshold="$2"
  local msg="${3:-}"
  if [ "$actual" -lt "$threshold" ]; then
    log_fail "assert_ge failed: $actual < $threshold $msg"
    return 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then
    log_fail "assert_contains failed: '$needle' not found in '$haystack' $msg"
    return 1
  fi
}

# --- Test runner ---

run_test() {
  local name="$1"
  local func="$2"
  TESTS_RUN=$((TESTS_RUN + 1))

  log_info "===== Running: $name ====="
  local logfile="/tmp/test_${TESTS_RUN}.log"

  if "$func" > "$logfile" 2>&1; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    log_pass "$name"
    TEST_RESULTS+=("PASS: $name")
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    log_fail "$name"
    TEST_RESULTS+=("FAIL: $name")
    # Dump diagnostics
    echo "--- Test log ---" >&2
    cat "$logfile" >&2
    echo "--- LDK channels ---" >&2
    ldk_cli list-channels 2>/dev/null | jq '.' >&2 || true
    echo "--- Eclair channels ---" >&2
    eclair_api "channels" 2>/dev/null | jq '.' >&2 || true
    echo "--- Mempool ---" >&2
    bitcoin_rpc "getrawmempool" 2>/dev/null | jq '.' >&2 || true
  fi
}

skip_test() {
  local name="$1"
  local reason="${2:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
  log_skip "$name: $reason"
  TEST_RESULTS+=("SKIP: $name ($reason)")
}

report_results() {
  echo ""
  echo "========================================"
  echo " Test Results"
  echo "========================================"
  for result in "${TEST_RESULTS[@]}"; do
    case "$result" in
      PASS:*) echo -e "  ${GREEN}${result}${NC}" ;;
      FAIL:*) echo -e "  ${RED}${result}${NC}" ;;
      SKIP:*) echo -e "  ${YELLOW}${result}${NC}" ;;
    esac
  done
  echo "========================================"
  echo -e " Total: $TESTS_RUN | ${GREEN}Pass: $TESTS_PASSED${NC} | ${RED}Fail: $TESTS_FAILED${NC} | ${YELLOW}Skip: $TESTS_SKIPPED${NC}"
  echo "========================================"

  if [ "$TESTS_FAILED" -gt 0 ]; then
    return 1
  fi
  return 0
}
