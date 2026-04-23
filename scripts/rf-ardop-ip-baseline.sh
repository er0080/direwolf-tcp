#!/bin/bash
# scripts/rf-ardop-ip-baseline.sh — RF baseline measurements for ardop-ip
#
# Fail-fast philosophy: each test is a single shot.  If a test fails the
# suite stops immediately so the failure can be investigated — no retries,
# no loops.  Reconnect resilience is a separate concern (own script).
#
# Usage:  sudo scripts/rf-ardop-ip-baseline.sh [--keep-logs]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
CONF="$ROOT/config/ardop-ip-rf.conf"
ARDOP_IP="$ROOT/ardop-ip"
LOG_DIR="$ROOT/logs"
NS_A="ns_rf_705"
NS_B="ns_rf_7300"
PID_A="" PID_B=""
PID_SRV=""
KEEP_LOGS=0

[[ "${1:-}" == "--keep-logs" ]] && KEEP_LOGS=1

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}PASS${NC}  $1"; }
fail() { echo -e "${RED}FAIL${NC}  $1"; exit 1; }   # fail is terminal
info() { echo -e "${YELLOW}    ${NC}  $1"; }

rescue_ptt_off() {
    [[ -c /dev/ic_705_a ]] && {
        stty -F /dev/ic_705_a 115200 raw -echo 2>/dev/null
        printf '\xFE\xFE\xA4\xE0\x1C\x00\x00\xFD' > /dev/ic_705_a 2>/dev/null
    }
    [[ -c /dev/ic_7300 ]] && {
        stty -F /dev/ic_7300  115200 raw -echo 2>/dev/null
        printf '\xFE\xFE\x94\xE0\x1C\x00\x00\xFD' > /dev/ic_7300  2>/dev/null
    }
    return 0
}

cleanup() {
    local rc=$?
    set +e
    info "Cleanup..."
    [[ -n "$PID_SRV" ]] && kill "$PID_SRV" 2>/dev/null
    [[ -n "$PID_A"   ]] && kill -TERM "$PID_A" 2>/dev/null
    [[ -n "$PID_B"   ]] && kill -TERM "$PID_B" 2>/dev/null
    for _ in 1 2 3; do
        sleep 1
        pgrep -f "ardop-ip" >/dev/null 2>&1 || break
    done
    pkill -KILL -f "ardop-ip" 2>/dev/null
    sleep 0.5
    rescue_ptt_off
    ip netns del "$NS_A" 2>/dev/null
    ip netns del "$NS_B" 2>/dev/null
    if [[ $KEEP_LOGS -eq 0 ]]; then
        rm -f "$LOG_DIR"/rf-705.log "$LOG_DIR"/rf-7300.log \
              "$LOG_DIR"/rf-tp.recv
    fi
    exit "$rc"
}
trap cleanup EXIT

echo "=== ardop-ip RF baseline (IC-705 ↔ IC-7300, 14.103 MHz) ==="
echo

[[ $EUID -ne 0 ]]    && { echo "Must run as root" >&2; exit 1; }
[[ -x "$ARDOP_IP" ]] || { echo "ardop-ip not built" >&2; exit 1; }
[[ -f "$CONF" ]]     || { echo "Config not found" >&2; exit 1; }

# shellcheck disable=SC1090
source "$CONF"
FECREPEATS="${FECREPEATS:-0}"
mkdir -p "$LOG_DIR"

# ── Startup ──────────────────────────────────────────────────────────────────

ip netns del "$NS_A" 2>/dev/null; ip netns del "$NS_B" 2>/dev/null
ip netns add "$NS_A"; ip netns add "$NS_B"

info "Pre-flight: device presence..."
for dev in "$IC705_CIV_PORT" "$IC7300_CIV_PORT"; do
    [[ -e "$dev" ]] || fail "CI-V device $dev missing"
    real=$(readlink -f "$dev")
    fuser "$real" 2>/dev/null && fail "$dev is held by another process"
done
info "Config: freq=${FREQ_HZ} Hz bw=${BANDWIDTH} Hz ${IC705_MYCALL}↔${IC7300_MYCALL}"

ip netns exec "$NS_A" "$ARDOP_IP" \
    --audio "$IC705_AUDIO" --mycall "$IC705_MYCALL" \
    --local-ip "$IC705_IP" --peer-ip "$IC7300_IP" \
    --tun-dev "$IC705_TUN" --mtu "$MTU" \
    --bw "$BANDWIDTH" --fec-repeats "$FECREPEATS" \
    --civ-port "$IC705_CIV_PORT" --civ-addr "$IC705_CIV_ADDR" --civ-baud "$IC705_CIV_BAUD" \
    > "$LOG_DIR/rf-705.log" 2>&1 &
PID_A=$!

ip netns exec "$NS_B" "$ARDOP_IP" \
    --audio "$IC7300_AUDIO" --mycall "$IC7300_MYCALL" \
    --local-ip "$IC7300_IP" --peer-ip "$IC705_IP" \
    --tun-dev "$IC7300_TUN" --mtu "$MTU" \
    --bw "$BANDWIDTH" --fec-repeats "$FECREPEATS" \
    --civ-port "$IC7300_CIV_PORT" --civ-addr "$IC7300_CIV_ADDR" --civ-baud "$IC7300_CIV_BAUD" \
    > "$LOG_DIR/rf-7300.log" 2>&1 &
PID_B=$!

sleep 1
kill -0 "$PID_A" 2>/dev/null || { tail -20 "$LOG_DIR/rf-705.log";  fail "IC-705 startup";  }
kill -0 "$PID_B" 2>/dev/null || { tail -20 "$LOG_DIR/rf-7300.log"; fail "IC-7300 startup"; }
pass "Both instances started (IC-705=$PID_A IC-7300=$PID_B)"

# ── Warm-up: single ping, 120 s budget for ARQ connect + round-trip ──────────

info "ARQ connect + warm-up ping (one shot, 120 s)..."
ip netns exec "$NS_A" ping -c 1 -W 120 "$IC7300_IP" >/dev/null 2>&1 \
    || fail "ARQ did not establish within 120 s"
pass "ARQ connected (warm-up ping replied)"

# ── Test 1: Ping reliability (10 pings at 15 s interval, need 10/10) ─────────

info "Test 1: ping reliability — 10 × -W 90 -i 15 ${IC7300_IP}..."
PING_OUT=$(ip netns exec "$NS_A" ping -c 10 -i 15 -W 90 "$IC7300_IP" 2>&1)
echo "$PING_OUT" | tail -3
REPLIES=$(echo "$PING_OUT" | grep -cE "bytes from ${IC7300_IP//./\\.}")
[[ "$REPLIES" -eq 10 ]] || fail "Ping reliability: only $REPLIES/10 replies (need 10/10)"
pass "Ping reliability: 10/10 replies"

# ── Test 2: TCP connect ──────────────────────────────────────────────────────

info "Test 2: TCP connect to ${IC7300_IP}:7777 (nc -zv, 120 s timeout)..."
ip netns exec "$NS_B" nc -l -p 7777 >/dev/null 2>&1 &
PID_SRV=$!
sleep 2
ip netns exec "$NS_A" nc -zv -w 120 "$IC7300_IP" 7777 2>&1 | grep -q succeeded \
    || fail "TCP connect to ${IC7300_IP}:7777"
kill "$PID_SRV" 2>/dev/null; PID_SRV=""
pass "TCP connect to ${IC7300_IP}:7777"

# ── Test 3: UDP throughput (single 1024-byte datagram) ───────────────────────

SEND_BYTES=1024
info "Test 3: UDP throughput — 1 × ${SEND_BYTES}-byte datagram A→B..."
rm -f "$LOG_DIR/rf-tp.recv"
ip netns exec "$NS_B" timeout 360 nc -u -l -p 6666 > "$LOG_DIR/rf-tp.recv" 2>/dev/null &
PID_SRV=$!
sleep 2
T_START=$(date +%s%3N)
ip netns exec "$NS_A" bash -c \
    "dd if=/dev/zero bs=${SEND_BYTES} count=1 2>/dev/null | nc -u -w 5 $IC7300_IP 6666" \
    || true
# Wait up to 240 s for arrival (ARDOP at OFDM.2500 ≈ 5-10 bps/ACK).
for _ in $(seq 1 48); do
    sleep 5
    [[ -s "$LOG_DIR/rf-tp.recv" ]] && break
done
T_END=$(date +%s%3N)
kill "$PID_SRV" 2>/dev/null; PID_SRV=""
BYTES=$(wc -c < "$LOG_DIR/rf-tp.recv" 2>/dev/null || echo 0)
ELAPSED_S=$(( (T_END - T_START) / 1000 ))
[[ "$ELAPSED_S" -le 0 ]] && ELAPSED_S=1
BPS=$(( BYTES * 8 / ELAPSED_S ))
info "  ${BYTES}/${SEND_BYTES} bytes in ${ELAPSED_S} s → ${BPS} bps"
[[ "$BYTES" -eq "$SEND_BYTES" ]] || fail "UDP throughput: ${BYTES}/${SEND_BYTES} bytes arrived"
pass "UDP throughput: ${SEND_BYTES}/${SEND_BYTES} bytes in ${ELAPSED_S} s → ${BPS} bps"

# ── Test 4: MTU (1432-byte payload = 1460 B IP packet, no fragmentation) ─────

info "Test 4: MTU — ping -s 1432 -M do -c 1 -W 240..."
ip netns exec "$NS_A" ping -c 1 -s 1432 -M do -W 240 "$IC7300_IP" >/dev/null 2>&1 \
    || fail "MTU 1460: 1432-byte payload failed"
pass "MTU 1460: 1432-byte payload passed without fragmentation"

# ── Summary ──────────────────────────────────────────────────────────────────

echo
echo -e "${GREEN}ALL BASELINE TESTS PASSED${NC} on 14.103 MHz"
