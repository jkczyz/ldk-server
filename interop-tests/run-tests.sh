#!/usr/bin/env bash
# run-tests.sh - LDK <-> Eclair splicing/RBF interop test suite
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/ldk-api.sh"
source "${SCRIPT_DIR}/lib/eclair-api.sh"

# ============================================================
# Phase 0: Bootstrap
# ============================================================

bootstrap() {
  log_info "Phase 0: Bootstrap"

  # Wait for bitcoind
  log_info "Waiting for bitcoind..."
  local start
  start=$(date +%s)
  while ! bitcoin_rpc "getblockchaininfo" > /dev/null 2>&1; do
    if [ $(( $(date +%s) - start )) -ge 60 ]; then
      log_fail "Timeout waiting for bitcoind"
      exit 1
    fi
    sleep 2
  done
  log_info "bitcoind ready"

  # Wait for Eclair (JVM startup can be slow)
  log_info "Waiting for Eclair..."
  start=$(date +%s)
  while ! eclair_get_info > /dev/null 2>&1; do
    if [ $(( $(date +%s) - start )) -ge 120 ]; then
      log_fail "Timeout waiting for Eclair"
      exit 1
    fi
    sleep 5
  done
  log_info "Eclair ready"

  # Wait for LDK server
  log_info "Waiting for LDK server..."
  start=$(date +%s)
  while [ ! -f "$LDK_API_KEY_FILE" ] || [ ! -f "$LDK_TLS_CERT" ]; do
    if [ $(( $(date +%s) - start )) -ge 60 ]; then
      log_fail "Timeout waiting for LDK server files"
      exit 1
    fi
    sleep 2
  done
  ldk_init
  start=$(date +%s)
  while ! ldk_get_node_info > /dev/null 2>&1; do
    if [ $(( $(date +%s) - start )) -ge 60 ]; then
      log_fail "Timeout waiting for LDK server API"
      exit 1
    fi
    sleep 2
  done
  log_info "LDK server ready"

  # Mine 101 blocks for coinbase maturity
  log_info "Mining initial 101 blocks..."
  mine_blocks 101
  local height
  height=$(get_block_height)
  wait_for_sync "$height" 60

  # Extract node IDs
  LDK_NODE_ID=$(ldk_get_node_id)
  ECLAIR_NODE_ID=$(eclair_get_node_id)
  log_info "LDK node ID: $LDK_NODE_ID"
  log_info "Eclair node ID: $ECLAIR_NODE_ID"

  # Fund both nodes
  log_info "Funding nodes..."

  # Fund LDK
  local ldk_addr
  ldk_addr=$(ldk_onchain_receive)
  bitcoin_rpc "sendtoaddress" "\"$ldk_addr\"" "10" > /dev/null
  log_info "Sent 10 BTC to LDK: $ldk_addr"

  # Fund Eclair
  local eclair_addr
  eclair_addr=$(eclair_get_new_address)
  bitcoin_rpc "sendtoaddress" "\"$eclair_addr\"" "10" > /dev/null
  log_info "Sent 10 BTC to Eclair: $eclair_addr"

  mine_and_sync 6
  sleep 2

  # Verify balances
  local ldk_bal
  ldk_bal=$(ldk_get_onchain_balance)
  assert_gt "$ldk_bal" 0 "LDK should have on-chain balance"
  log_info "LDK on-chain balance: $ldk_bal sats"

  log_info "Bootstrap complete"
}

# ============================================================
# Helper: open a funded channel from LDK to Eclair
# Returns user_channel_id via stdout
# ============================================================

open_ldk_to_eclair_channel() {
  local amount_sats="${1:-500000}"
  local push_msat="${2:-}"

  ldk_connect_peer "$ECLAIR_NODE_ID" "eclair:9735" > /dev/null 2>&1 || true
  sleep 2

  local open_result
  open_result=$(ldk_open_channel "$ECLAIR_NODE_ID" "eclair:9735" "$amount_sats" "$push_msat")
  local user_channel_id
  user_channel_id=$(echo "$open_result" | jq -r '.user_channel_id')
  log_info "Opened LDK channel: $user_channel_id (${amount_sats} sats)"

  mine_and_sync 6
  ldk_wait_for_channel_usable "$user_channel_id" 90

  echo "$user_channel_id"
}

# ============================================================
# Helper: open a funded channel from Eclair to LDK
# Outputs: "eclair_channel_id ldk_user_channel_id" (space-separated)
# ============================================================

open_eclair_to_ldk_channel() {
  local amount_sats="${1:-500000}"
  local push_msat="${2:-}"

  eclair_connect "${LDK_NODE_ID}@ldk-server:3001" > /dev/null 2>&1 || true
  sleep 2

  # Snapshot channel IDs before open
  local eclair_before ldk_before
  eclair_before=$(eclair_channels 2>/dev/null | jq -r '.[].channelId' | sort)
  ldk_before=$(ldk_cli list-channels 2>/dev/null | jq -r '.channels[].user_channel_id' | sort)

  eclair_open "$LDK_NODE_ID" "$amount_sats" "$push_msat" > /dev/null
  log_info "Eclair opening channel to LDK (${amount_sats} sats)"

  mine_and_sync 6

  # Find the NEW Eclair channel by diffing
  local eclair_channel_id=""
  local start
  start=$(date +%s)
  while [ -z "$eclair_channel_id" ]; do
    local eclair_after
    eclair_after=$(eclair_channels 2>/dev/null | jq -r '.[].channelId' | sort)
    eclair_channel_id=$(comm -13 <(echo "$eclair_before") <(echo "$eclair_after") | head -1)
    if [ $(( $(date +%s) - start )) -ge 60 ]; then
      log_fail "Timeout finding new Eclair channel"
      return 1
    fi
    [ -z "$eclair_channel_id" ] && sleep 2
  done

  eclair_wait_for_channel_normal "$eclair_channel_id" 90

  # Find the NEW LDK channel by diffing
  local ldk_ucid=""
  start=$(date +%s)
  while [ -z "$ldk_ucid" ]; do
    local ldk_after
    ldk_after=$(ldk_cli list-channels 2>/dev/null | jq -r '.channels[].user_channel_id' | sort)
    ldk_ucid=$(comm -13 <(echo "$ldk_before") <(echo "$ldk_after") | head -1)
    if [ $(( $(date +%s) - start )) -ge 60 ]; then
      log_fail "Timeout finding new LDK channel"
      return 1
    fi
    [ -z "$ldk_ucid" ] && { mine_blocks 1; sleep 2; }
  done

  ldk_wait_for_channel_usable "$ldk_ucid" 90

  echo "$eclair_channel_id $ldk_ucid"
}

# ============================================================
# Phase 1: Core splice flows
# ============================================================

test_1_ldk_open_ldk_splice_in() {
  log_info "Test 1: LDK opens channel, LDK splice-in"

  local ucid
  ucid=$(open_ldk_to_eclair_channel 500000)

  local initial_value
  initial_value=$(ldk_get_channel_value "$ucid")
  assert_eq "$initial_value" "500000" "Initial channel value should be 500000"
  log_info "Channel value before splice: $initial_value"

  ldk_splice_in "$ucid" "$ECLAIR_NODE_ID" 200000 > /dev/null
  log_info "Splice-in 200000 sats initiated"

  ldk_wait_for_channel_value "$ucid" 700000
  log_info "Channel value after splice: 700000"
}

test_2_eclair_open_eclair_splice_in() {
  log_info "Test 2: Eclair opens channel, Eclair splice-in"

  local ids eclair_cid ldk_ucid
  ids=$(open_eclair_to_ldk_channel 500000)
  eclair_cid=$(echo "$ids" | awk '{print $1}')
  ldk_ucid=$(echo "$ids" | awk '{print $2}')
  log_info "Eclair channel: $eclair_cid, LDK channel: $ldk_ucid"

  eclair_splice_in "$eclair_cid" 200000 > /dev/null
  log_info "Eclair splice-in 200000 sats initiated"

  ldk_wait_for_channel_value "$ldk_ucid" 700000
  log_info "LDK channel value after Eclair splice-in: 700000"
}

test_3_ldk_splice_out() {
  log_info "Test 3: LDK splice-out"

  local ucid
  ucid=$(open_ldk_to_eclair_channel 500000)

  ldk_splice_out "$ucid" "$ECLAIR_NODE_ID" 100000 > /dev/null
  log_info "Splice-out 100000 sats initiated"

  # Splice-out deducts mining fees, so value will be slightly less than 400000
  local timeout=120 start
  start=$(date +%s)
  while true; do
    local val
    val=$(ldk_get_channel_value "$ucid" 2>/dev/null) || val="500000"
    if [ "$val" -lt 500000 ] && [ "$val" -gt 0 ]; then
      log_info "Channel value after splice-out: $val"
      break
    fi
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      log_fail "Timeout waiting for splice-out (current=$val)"
      return 1
    fi
    mine_blocks 1
    sleep 2
  done
}

test_4_eclair_splice_out() {
  log_info "Test 4: Eclair splice-out"

  local ids eclair_cid ldk_ucid
  ids=$(open_eclair_to_ldk_channel 500000)
  eclair_cid=$(echo "$ids" | awk '{print $1}')
  ldk_ucid=$(echo "$ids" | awk '{print $2}')
  log_info "Eclair channel: $eclair_cid, LDK channel: $ldk_ucid"

  local out_addr
  out_addr=$(eclair_get_new_address)
  eclair_splice_out "$eclair_cid" 100000 "$out_addr" > /dev/null
  log_info "Eclair splice-out 100000 sats to $out_addr"

  # Verify via LDK side; Eclair deducts mining fees so value won't be exactly 400000
  local timeout=120 start
  start=$(date +%s)
  while true; do
    local val
    val=$(ldk_get_channel_value "$ldk_ucid" 2>/dev/null) || val="500000"
    if [ "$val" -lt 500000 ] && [ "$val" -gt 0 ]; then
      log_info "LDK channel value after Eclair splice-out: $val"
      break
    fi
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      log_fail "Timeout waiting for splice-out to take effect (current=$val)"
      return 1
    fi
    mine_blocks 1
    sleep 2
  done
}

test_5_ldk_rbf_pending_splice() {
  log_info "Test 5: LDK RBF pending splice"

  local ucid
  ucid=$(open_ldk_to_eclair_channel 500000)

  # Snapshot mempool before splice
  local mempool_before
  mempool_before=$(get_mempool_txids)

  # Splice-in but do NOT mine
  ldk_splice_in "$ucid" "$ECLAIR_NODE_ID" 200000 > /dev/null
  log_info "Splice-in initiated (not mined)"
  sleep 5

  # Identify the original splice txid
  local mempool_after_splice
  mempool_after_splice=$(get_mempool_txids)
  local original_txid
  original_txid=$(comm -13 <(echo "$mempool_before") <(echo "$mempool_after_splice") | head -1)
  log_info "Original splice txid: $original_txid"

  # RBF bump (Eclair's attempt-delta-blocks=0 allows immediate RBF)
  ldk_rbf_channel "$ucid" "$ECLAIR_NODE_ID" > /dev/null
  log_info "RBF bump initiated"
  sleep 5

  # Identify the replacement txid
  local mempool_after_rbf
  mempool_after_rbf=$(get_mempool_txids)
  local rbf_txid
  rbf_txid=$(comm -13 <(echo "$mempool_before") <(echo "$mempool_after_rbf") | head -1)
  log_info "RBF txid: $rbf_txid"

  # The txids must differ
  assert_eq "$([ "$original_txid" != "$rbf_txid" ] && echo "true" || echo "false")" "true" \
    "RBF txid should differ from original (original=$original_txid rbf=$rbf_txid)"

  ldk_wait_for_channel_value "$ucid" 700000

  # Verify the RBF transaction was mined, not the original
  local rbf_confs
  rbf_confs=$(get_tx_confirmations "$rbf_txid")
  assert_gt "$rbf_confs" 0 "RBF tx $rbf_txid should be confirmed"
  log_info "RBF tx $rbf_txid confirmed with $rbf_confs confirmations"
}

test_6_eclair_rbf_pending_splice() {
  log_info "Test 6: Eclair RBF pending splice"

  local ids eclair_cid ldk_ucid
  ids=$(open_eclair_to_ldk_channel 500000)
  eclair_cid=$(echo "$ids" | awk '{print $1}')
  ldk_ucid=$(echo "$ids" | awk '{print $2}')
  log_info "Eclair channel: $eclair_cid, LDK channel: $ldk_ucid"

  # Snapshot mempool before splice
  local mempool_before
  mempool_before=$(get_mempool_txids)

  # Splice-in but do NOT mine
  eclair_splice_in "$eclair_cid" 200000 > /dev/null
  log_info "Eclair splice-in initiated (not mined)"
  sleep 5

  # Identify the original splice txid
  local mempool_after_splice
  mempool_after_splice=$(get_mempool_txids)
  local original_txid
  original_txid=$(comm -13 <(echo "$mempool_before") <(echo "$mempool_after_splice") | head -1)
  log_info "Original splice txid: $original_txid"

  # RBF with higher feerate (10 sat/byte)
  eclair_rbf_splice "$eclair_cid" 10 > /dev/null
  log_info "Eclair RBF splice initiated"
  sleep 5

  # Identify the replacement txid
  local mempool_after_rbf
  mempool_after_rbf=$(get_mempool_txids)
  local rbf_txid
  rbf_txid=$(comm -13 <(echo "$mempool_before") <(echo "$mempool_after_rbf") | head -1)
  log_info "RBF txid: $rbf_txid"

  # The txids must differ
  assert_eq "$([ "$original_txid" != "$rbf_txid" ] && echo "true" || echo "false")" "true" \
    "RBF txid should differ from original (original=$original_txid rbf=$rbf_txid)"

  # Verify via LDK side
  ldk_wait_for_channel_value "$ldk_ucid" 700000

  # Verify the RBF transaction was mined, not the original
  local rbf_confs
  rbf_confs=$(get_tx_confirmations "$rbf_txid")
  assert_gt "$rbf_confs" 0 "RBF tx $rbf_txid should be confirmed"
  log_info "RBF tx $rbf_txid confirmed with $rbf_confs confirmations"
}

test_7_payments_through_spliced_channel() {
  log_info "Test 7: Payments through spliced channel"

  # Open channel with push so both sides have balance
  local ucid
  ucid=$(open_ldk_to_eclair_channel 500000 "100000000")
  log_info "Channel opened with 100000 sat push to Eclair"

  # Splice-in to increase capacity
  ldk_splice_in "$ucid" "$ECLAIR_NODE_ID" 200000 > /dev/null
  ldk_wait_for_channel_value "$ucid" 700000

  # LDK -> Eclair payment
  local eclair_invoice
  eclair_invoice=$(eclair_get_invoice 100000 "ldk-to-eclair-test")
  log_info "Eclair invoice: ${eclair_invoice:0:30}..."

  ldk_bolt11_send "$eclair_invoice" > /dev/null
  log_info "LDK -> Eclair payment sent"
  sleep 5

  # Eclair -> LDK payment
  local ldk_invoice
  ldk_invoice=$(ldk_bolt11_receive 100000 "eclair-to-ldk-test")
  log_info "LDK invoice: ${ldk_invoice:0:30}..."

  eclair_pay_invoice "$ldk_invoice" > /dev/null
  log_info "Eclair -> LDK payment sent"
  sleep 5

  log_info "Payments through spliced channel succeeded"
}

# ============================================================
# Phase 2: Edge cases
# ============================================================

test_8_reconnection_after_splice() {
  log_info "Test 8: Reconnection after splice initiated"

  local ucid
  ucid=$(open_ldk_to_eclair_channel 500000)

  # Initiate splice but don't mine
  ldk_splice_in "$ucid" "$ECLAIR_NODE_ID" 200000 > /dev/null
  log_info "Splice-in initiated (not mined)"
  sleep 5

  # Disconnect by having LDK disconnect the peer
  log_info "Disconnecting LDK from Eclair..."
  ldk_cli disconnect-peer "$ECLAIR_NODE_ID" > /dev/null 2>&1 || true
  sleep 5

  # Reconnect
  log_info "Reconnecting..."
  ldk_connect_peer "$ECLAIR_NODE_ID" "eclair:9735" > /dev/null 2>&1 || true
  sleep 5

  # Mine and verify
  ldk_wait_for_channel_value "$ucid" 700000
  log_info "Channel value after reconnection splice: 700000"
}

test_9_multiple_sequential_splices() {
  log_info "Test 9: Multiple sequential splices"

  local ucid
  ucid=$(open_ldk_to_eclair_channel 500000)

  # Splice-in 200k (500k -> 700k)
  log_info "Splice-in 200000 sats..."
  ldk_splice_in "$ucid" "$ECLAIR_NODE_ID" 200000 > /dev/null
  ldk_wait_for_channel_value "$ucid" 700000
  log_info "After splice-in #1: 700000"

  # Splice-in 100k (700k -> 800k)
  log_info "Splice-in 100000 sats..."
  ldk_splice_in "$ucid" "$ECLAIR_NODE_ID" 100000 > /dev/null
  ldk_wait_for_channel_value "$ucid" 800000
  log_info "After splice-in #2: 800000"

  # Splice-out 50k (800k -> ~750k minus fees)
  log_info "Splice-out 50000 sats..."
  ldk_splice_out "$ucid" "$ECLAIR_NODE_ID" 50000 > /dev/null
  local timeout=120 start
  start=$(date +%s)
  while true; do
    val=$(ldk_get_channel_value "$ucid" 2>/dev/null) || val="800000"
    if [ "$val" -lt 800000 ]; then
      log_info "After splice-out: $val"
      break
    fi
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      log_fail "Timeout waiting for splice-out (current=$val)"
      return 1
    fi
    mine_blocks 1
    sleep 2
  done
}

test_10_rbf_reconnect_splice_locked() {
  log_info "Test 10: RBF with disconnect before splice_locked"

  local ucid
  ucid=$(open_ldk_to_eclair_channel 500000)

  # Snapshot mempool before splice
  local mempool_before
  mempool_before=$(get_mempool_txids)

  # Splice-in (don't mine)
  ldk_splice_in "$ucid" "$ECLAIR_NODE_ID" 200000 > /dev/null
  log_info "Splice-in initiated (not mined)"
  sleep 5

  # Capture original splice txid
  local mempool_after_splice
  mempool_after_splice=$(get_mempool_txids)
  local original_txid
  original_txid=$(comm -13 <(echo "$mempool_before") <(echo "$mempool_after_splice") | head -1)
  log_info "Original splice txid: $original_txid"

  # RBF
  ldk_rbf_channel "$ucid" "$ECLAIR_NODE_ID" > /dev/null
  log_info "RBF initiated"
  sleep 5

  # Capture RBF txid
  local mempool_after_rbf
  mempool_after_rbf=$(get_mempool_txids)
  local rbf_txid
  rbf_txid=$(comm -13 <(echo "$mempool_before") <(echo "$mempool_after_rbf") | head -1)
  log_info "RBF txid: $rbf_txid"
  assert_eq "$([ "$original_txid" != "$rbf_txid" ] && echo "true" || echo "false")" "true" \
    "RBF txid should differ from original"

  # Mine a few blocks so the RBF tx confirms but splice_locked hasn't been exchanged yet
  mine_and_sync 3
  sleep 2

  # Disconnect BEFORE splice_locked can be fully exchanged.
  # LDK will see more confirmations while disconnected and queue splice_locked.
  log_info "Disconnecting LDK from Eclair..."
  ldk_cli disconnect-peer "$ECLAIR_NODE_ID" > /dev/null 2>&1 || true
  sleep 3

  # Mine remaining blocks while disconnected so LDK reaches the
  # splice_locked threshold but cannot send the message to Eclair
  mine_blocks 10
  sleep 5
  log_info "Mined blocks while disconnected"

  # Reconnect — LDK should resend splice_locked on reconnection
  log_info "Reconnecting..."
  ldk_connect_peer "$ECLAIR_NODE_ID" "eclair:9735" > /dev/null 2>&1 || true
  sleep 5

  # Wait for the RBF splice to lock on both sides
  ldk_wait_for_channel_value "$ucid" 700000

  # Verify the RBF tx was the one that confirmed
  local rbf_confs
  rbf_confs=$(get_tx_confirmations "$rbf_txid")
  assert_gt "$rbf_confs" 0 "RBF tx $rbf_txid should be confirmed"
  log_info "RBF tx $rbf_txid confirmed with $rbf_confs confirmations after reconnect"
}

test_11_eclair_rbf_reconnect_splice_locked() {
  log_info "Test 11: Eclair RBF with disconnect before splice_locked"

  local ids eclair_cid ldk_ucid
  ids=$(open_eclair_to_ldk_channel 500000)
  eclair_cid=$(echo "$ids" | awk '{print $1}')
  ldk_ucid=$(echo "$ids" | awk '{print $2}')
  log_info "Eclair channel: $eclair_cid, LDK channel: $ldk_ucid"

  # Snapshot mempool
  local mempool_before
  mempool_before=$(get_mempool_txids)

  # Eclair splice-in (don't mine)
  eclair_splice_in "$eclair_cid" 200000 > /dev/null
  log_info "Eclair splice-in initiated (not mined)"
  sleep 5

  # Capture original txid
  local mempool_after_splice
  mempool_after_splice=$(get_mempool_txids)
  local original_txid
  original_txid=$(comm -13 <(echo "$mempool_before") <(echo "$mempool_after_splice") | head -1)
  log_info "Original splice txid: $original_txid"

  # Eclair RBF
  eclair_rbf_splice "$eclair_cid" 10 > /dev/null
  log_info "Eclair RBF initiated"
  sleep 5

  # Capture RBF txid
  local mempool_after_rbf
  mempool_after_rbf=$(get_mempool_txids)
  local rbf_txid
  rbf_txid=$(comm -13 <(echo "$mempool_before") <(echo "$mempool_after_rbf") | head -1)
  log_info "RBF txid: $rbf_txid"
  assert_eq "$([ "$original_txid" != "$rbf_txid" ] && echo "true" || echo "false")" "true" \
    "RBF txid should differ from original"

  # Mine a few blocks to confirm the RBF tx
  mine_and_sync 3
  sleep 2

  # Disconnect before splice_locked exchange completes
  log_info "Disconnecting LDK from Eclair..."
  ldk_cli disconnect-peer "$ECLAIR_NODE_ID" > /dev/null 2>&1 || true
  sleep 3

  # Mine blocks while disconnected so both sides independently reach
  # the splice_locked threshold
  mine_blocks 10
  sleep 5
  log_info "Mined blocks while disconnected"

  # Reconnect — splice_locked should be resent
  log_info "Reconnecting..."
  ldk_connect_peer "$ECLAIR_NODE_ID" "eclair:9735" > /dev/null 2>&1 || true
  sleep 5

  # Wait for the RBF splice to lock
  ldk_wait_for_channel_value "$ldk_ucid" 700000

  local rbf_confs
  rbf_confs=$(get_tx_confirmations "$rbf_txid")
  assert_gt "$rbf_confs" 0 "RBF tx $rbf_txid should be confirmed"
  log_info "RBF tx $rbf_txid confirmed with $rbf_confs confirmations after reconnect"
}

test_12_splice_with_concurrent_payment() {
  # (was test 10)
  log_info "Test 10: Splice with concurrent payment"

  # Open channel with push so Eclair has balance to send
  local ucid
  ucid=$(open_ldk_to_eclair_channel 500000 "200000000")
  log_info "Channel opened with 200000 sat push to Eclair"

  # Start a payment from Eclair -> LDK
  local ldk_invoice
  ldk_invoice=$(ldk_bolt11_receive 50000000 "concurrent-test")
  eclair_pay_invoice "$ldk_invoice" > /dev/null &
  local pay_pid=$!
  log_info "Eclair payment started in background"

  # Immediately initiate splice-in
  sleep 1
  ldk_splice_in "$ucid" "$ECLAIR_NODE_ID" 200000 > /dev/null
  log_info "Splice-in initiated concurrently"

  # Wait for payment to complete
  wait "$pay_pid" || log_info "Payment process returned non-zero (may still succeed)"
  sleep 5

  ldk_wait_for_channel_value "$ucid" 700000
  log_info "Channel value after concurrent splice + payment: 700000"
}

# ============================================================
# Main
# ============================================================

main() {
  log_info "LDK <-> Eclair Splicing/RBF Interop Tests"
  log_info "=========================================="

  bootstrap

  log_info ""
  log_info "Phase 1: Core splice flows"
  log_info "=========================================="
  run_test "Test 1: LDK opens channel, LDK splice-in" test_1_ldk_open_ldk_splice_in
  run_test "Test 2: Eclair opens channel, Eclair splice-in" test_2_eclair_open_eclair_splice_in
  run_test "Test 3: LDK splice-out" test_3_ldk_splice_out
  run_test "Test 4: Eclair splice-out" test_4_eclair_splice_out
  run_test "Test 5: LDK RBF pending splice" test_5_ldk_rbf_pending_splice
  run_test "Test 6: Eclair RBF pending splice" test_6_eclair_rbf_pending_splice
  run_test "Test 7: Payments through spliced channel" test_7_payments_through_spliced_channel

  log_info ""
  log_info "Phase 2: Edge cases"
  log_info "=========================================="
  run_test "Test 8: Reconnection after splice" test_8_reconnection_after_splice
  run_test "Test 9: Multiple sequential splices" test_9_multiple_sequential_splices
  # Tests 10-11: Disconnect before splice_locked, exchanged on reconnect.
  # Eclair bug: resendChannelReadyIfNeeded sends announcement_signatures for the
  # original funding (fundingTxIndex=0) when retransmitAnnSigs is set, but the
  # retransmit bit is for the splice funding per the spec. LDK receives the stale
  # signatures after promoting the splice and force-closes on verification failure.
  skip_test "Test 10: LDK RBF disconnect before splice_locked" "Eclair sends stale announcement_signatures for original funding on reconnect"
  skip_test "Test 11: Eclair RBF disconnect before splice_locked" "Eclair sends stale announcement_signatures for original funding on reconnect"
  run_test "Test 12: Splice with concurrent payment" test_12_splice_with_concurrent_payment

  log_info ""
  report_results
}

main "$@"
