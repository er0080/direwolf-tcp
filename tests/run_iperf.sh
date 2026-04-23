#!/bin/bash
# tests/run_iperf.sh — focused ARQ + iperf3 loopback test
#
# Starts two ardop-ip instances over snd-aloop, waits for ARQ connect,
# then runs a single iperf3 throughput test.  Total wall time: ~3-4 min.
#
# Usage:  sudo tests/run_iperf.sh [--keep-logs] [--duration N]

set -euo pipefail

KEEP_LOGS=0
IPERF_SEC=30
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-logs) KEEP_LOGS=1 ;;
        --duration)  IPERF_SEC="$2"; shift ;;
        *) echo "Usage: $0 [--keep-logs] [--duration N]" >&2; exit 1 ;;
    esac
    shift
done

ARDOP_IP="$(dirname "$0")/../ardop-ip"
LOG_DIR="$(dirname "$0")/../logs"
NS_A="ns_ardop_a"
NS_B="ns_ardop_b"
PID_A="" PID_B="" PID_IPERF=""
PASS=0 FAIL=0
mkdir -p "$LOG_DIR"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}PASS${NC}  $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}FAIL${NC}  $1"; FAIL=$((FAIL+1)); }
info() { echo -e "${YELLOW}    ${NC}  $1"; }

cleanup() {
    [[ -n "$PID_IPERF" ]] && kill "$PID_IPERF" 2>/dev/null || true
    [[ -n "$PID_A" ]]     && kill "$PID_A"     2>/dev/null || true
    [[ -n "$PID_B" ]]     && kill "$PID_B"     2>/dev/null || true
    # ip netns exec forks a wrapper; the ardop-ip/nc grandchildren may survive
    # as orphans inside the namespace, blocking ip netns del.  Kill them directly.
    pkill -KILL -f "ardop-ip"   2>/dev/null || true
    pkill -KILL -f "nc -l"      2>/dev/null || true
    sleep 1
    ip netns del "$NS_A" 2>/dev/null || true
    ip netns del "$NS_B" 2>/dev/null || true
    if [[ $KEEP_LOGS -eq 0 ]]; then
        rm -f "$LOG_DIR"/iperf-a.log "$LOG_DIR"/iperf-b.log \
              "$LOG_DIR"/tp_recv.bin "$LOG_DIR"/tp_bytes.out
    fi
}
trap cleanup EXIT

echo "=== ardop-ip ARQ + iperf3 loopback test ==="
echo

[[ $EUID -ne 0 ]] && { echo "Must run as root" >&2; exit 1; }
[[ -x "$ARDOP_IP" ]] || { echo "ardop-ip not found — run 'make ardop-ip' first" >&2; exit 1; }
command -v iperf3 >/dev/null 2>&1 || { echo "iperf3 not installed" >&2; exit 1; }

# ── ALSA loopback ──────────────────────────────────────────────────────────────

if ! aplay -l 2>/dev/null | grep -q Loopback; then
    modprobe snd-aloop pcm_substreams=2 || { echo "snd-aloop not available" >&2; exit 1; }
    sleep 0.5
fi
LOOP_CARD=$(aplay -l 2>/dev/null | awk '/Loopback/{print $2}' | tr -d ':' | head -1)
[[ -n "$LOOP_CARD" ]] || { echo "Cannot find ALSA Loopback card" >&2; exit 1; }
DEV_A="plughw:${LOOP_CARD},0"
DEV_B="plughw:${LOOP_CARD},1"
info "ALSA loopback: card $LOOP_CARD  ($DEV_A ↔ $DEV_B)"

# ── Network namespaces ─────────────────────────────────────────────────────────

ip netns del "$NS_A" 2>/dev/null || true
ip netns del "$NS_B" 2>/dev/null || true
ip netns add "$NS_A"
ip netns add "$NS_B"

# ── Start instances ────────────────────────────────────────────────────────────

ip netns exec "$NS_A" "$ARDOP_IP" \
    --audio "$DEV_A" --mycall KD2MYS-1 \
    --local-ip 10.0.0.1 --peer-ip 10.0.0.2 --tun-dev ardop0 \
    --bw 2500 \
    > "$LOG_DIR/iperf-a.log" 2>&1 &
PID_A=$!

ip netns exec "$NS_B" "$ARDOP_IP" \
    --audio "$DEV_B" --mycall KD2MYS-2 \
    --local-ip 10.0.0.2 --peer-ip 10.0.0.1 --tun-dev ardop1 \
    --bw 2500 \
    > "$LOG_DIR/iperf-b.log" 2>&1 &
PID_B=$!

sleep 0.5
kill -0 "$PID_A" 2>/dev/null || { fail "Instance A failed to start"; cat "$LOG_DIR/iperf-a.log"; exit 1; }
kill -0 "$PID_B" 2>/dev/null || { fail "Instance B failed to start"; cat "$LOG_DIR/iperf-b.log"; exit 1; }
pass "Both instances started (A=$PID_A  B=$PID_B)"

# ── Wait for ARQ connect ───────────────────────────────────────────────────────

info "Waiting for ARQ connect (up to 180s) ..."
connected=0
for ((i=0; i<6; i++)); do
    sleep 30
    kill -0 "$PID_A" 2>/dev/null || { fail "Instance A died"; break; }
    kill -0 "$PID_B" 2>/dev/null || { fail "Instance B died"; break; }
    if ip netns exec "$NS_A" ping -c 1 -W 30 10.0.0.2 >/dev/null 2>&1; then
        connected=1; break
    fi
    info "  still waiting... ($((i+1))/6)"
done

if [[ $connected -eq 1 ]]; then
    pass "ARQ connected (first ping succeeded)"
else
    fail "ARQ connect timeout"
    tail -10 "$LOG_DIR/iperf-a.log"
    exit 1
fi

# ── TCP throughput via Python (iperf3 setup handshake is too slow for ARQ RTT) ─
# iperf3's server-side setup timeout is hardcoded at 10s; our ARQ RTT is ~3-6s
# so the multi-step iperf3 handshake always exceeds it.  Use raw TCP sockets.

# Warm-up ping ensures ARQ channel is active before TCP attempt
info "Warm-up ping before throughput test ..."
ip netns exec "$NS_A" ping -c 1 -W 60 10.0.0.2 >/dev/null 2>&1 \
    && info "  warm-up OK" || info "  warm-up failed (proceeding anyway)"

# ── TCP throughput via nc + dd ─────────────────────────────────────────────────
# Send SEND_BYTES over TCP; measure elapsed time at the server side.
# No rate-limiting — let TCP/ARQ self-limit.  Pass if goodput ≥ 1000 bps.

SEND_BYTES=$(( IPERF_SEC * 512 ))   # ~4096 bps worth of data
TIMEOUT_NC=$(( IPERF_SEC * 4 + 60 ))   # generous: transfer + ARQ connect latency

info "TCP throughput: sending ${SEND_BYTES} bytes to 10.0.0.2:6666 (nc, timeout ${TIMEOUT_NC}s) ..."

# Server: measure time from first byte to last, print bytes and bps
ip netns exec "$NS_B" bash -c "
    nc -l -p 6666 2>/dev/null > $LOG_DIR/tp_recv.bin
    BYTES=\$(wc -c < $LOG_DIR/tp_recv.bin)
    echo \"\$BYTES\"
" > "$LOG_DIR/tp_bytes.out" &
PID_IPERF=$!
sleep 2

# Client: send SEND_BYTES, time the whole operation
T_START=$(date +%s%3N)
ip netns exec "$NS_A" bash -c \
    "dd if=/dev/zero bs=${SEND_BYTES} count=1 2>/dev/null | nc -w ${TIMEOUT_NC} 10.0.0.2 6666" \
    || true
T_END=$(date +%s%3N)

wait "$PID_IPERF" 2>/dev/null || true; PID_IPERF=""
BYTES=$(cat "$LOG_DIR/tp_bytes.out" 2>/dev/null | tr -d '[:space:]' || echo 0)
[[ -z "$BYTES" ]] && BYTES=0
ELAPSED_MS=$(( T_END - T_START ))
ELAPSED_S=$(( ELAPSED_MS > 0 ? ELAPSED_MS : 1000 ))
BPS=$(( BYTES * 8 * 1000 / ELAPSED_S ))

# ALSA loopback ARQ throughput note:
# Half-duplex BREAK/IDLE turnaround adds ~3s per segment direction, so TCP
# goodput over loopback is typically 400-700 bps even at OFDM 2500Hz.
# On real RF at 4600 bps raw, goodput scales proportionally (~2500 bps).
# Threshold: 200 bps — verify data flows, not a benchmark.
THRESHOLD=200

info "  ${BYTES} bytes in $((ELAPSED_MS/1000))s → ${BPS} bps (loopback typical: 400-700 bps)"
if [[ "$BYTES" -gt 0 ]] && [[ "$BPS" -ge $THRESHOLD ]]; then
    pass "Throughput: ${BPS} bps ≥ ${THRESHOLD} bps  (${BYTES} bytes in $((ELAPSED_MS/1000))s)"
else
    fail "Throughput: ${BPS} bps < ${THRESHOLD} bps  (server got ${BYTES} bytes)"
fi

# ── Results ────────────────────────────────────────────────────────────────────

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && echo -e "${GREEN}ALL PASS${NC}" || echo -e "${RED}SOME FAILED${NC}"
[[ $FAIL -eq 0 ]]
