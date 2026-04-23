#!/bin/bash
# tests/run_integration.sh — ardop-ip ALSA loopback integration tests
#
# Runs two ardop-ip instances over the snd-aloop kernel loopback driver:
#   Instance A (ISS, 10.0.0.1): plughw:Loopback,0 in netns ns_ardop_a
#   Instance B (IRS, 10.0.0.2): plughw:Loopback,1 in netns ns_ardop_b
#
# Tests (in order):
#   1. ARQ connect (ISS side initiates, IRS side accepts)
#   2. ICMP echo:   ping -c 5 -W 10 10.0.0.2  → 0% loss
#   3. TCP connect: nc -zv 10.0.0.2 7  (echo port via ncat on B side)
#   4. Throughput:  iperf3 -t 30 -b 4k  → ≥ 1000 bps
#   5. MTU path:    ping -s 1200 -M do -c 3 10.0.0.2 (no fragmentation)
#
# Run as root (or with CAP_NET_ADMIN + CAP_NET_RAW).
#
# Usage:  sudo tests/run_integration.sh [--keep-logs]

set -euo pipefail

KEEP_LOGS=0
[[ "${1:-}" == "--keep-logs" ]] && KEEP_LOGS=1

ARDOP_IP="$(dirname "$0")/../ardop-ip"
LOG_DIR="$(dirname "$0")/../logs"
NS_A="ns_ardop_a"
NS_B="ns_ardop_b"
PID_A=""
PID_B=""
PID_IPERF=""
PASS=0
FAIL=0
mkdir -p "$LOG_DIR"

# ── Colours ────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC}  $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}FAIL${NC}  $1"; FAIL=$((FAIL+1)); }
info() { echo -e "${YELLOW}    ${NC}  $1"; }

# ── Cleanup ────────────────────────────────────────────────────────────────

cleanup() {
    info "Cleaning up..."
    [[ -n "$PID_A" ]]     && kill "$PID_A"     2>/dev/null || true
    [[ -n "$PID_B" ]]     && kill "$PID_B"     2>/dev/null || true
    [[ -n "$PID_IPERF" ]] && kill "$PID_IPERF" 2>/dev/null || true
    pkill -KILL -f "ardop-ip" 2>/dev/null || true
    pkill -KILL -f "nc -l"    2>/dev/null || true
    sleep 1
    ip netns del "$NS_A" 2>/dev/null || true
    ip netns del "$NS_B" 2>/dev/null || true
    if [[ $KEEP_LOGS -eq 0 ]]; then
        rm -f "$LOG_DIR"/integ-a.log "$LOG_DIR"/integ-b.log
    fi
}
trap cleanup EXIT

# ── Prerequisites ──────────────────────────────────────────────────────────

echo "=== ardop-ip integration tests ==="
echo

if [[ $EUID -ne 0 ]]; then
    echo "Must run as root (needs CAP_NET_ADMIN)" >&2
    exit 1
fi

if [[ ! -x "$ARDOP_IP" ]]; then
    echo "ardop-ip binary not found at $ARDOP_IP — run 'make ardop-ip' first" >&2
    exit 1
fi

# Load snd-aloop if not present
if ! aplay -l 2>/dev/null | grep -q Loopback; then
    modprobe snd-aloop pcm_substreams=2 || {
        echo "snd-aloop not available" >&2; exit 1
    }
    sleep 0.5
fi

LOOP_CARD=$(aplay -l 2>/dev/null | awk '/Loopback/{print $2}' | tr -d ':' | head -1)
if [[ -z "$LOOP_CARD" ]]; then
    echo "Cannot find ALSA Loopback card" >&2; exit 1
fi
DEV_A="plughw:${LOOP_CARD},0"
DEV_B="plughw:${LOOP_CARD},1"
info "ALSA loopback: card $LOOP_CARD  ($DEV_A ↔ $DEV_B)"

# Check iperf3 available
HAVE_IPERF=0
command -v iperf3 >/dev/null 2>&1 && HAVE_IPERF=1

# ── Network namespaces ─────────────────────────────────────────────────────

ip netns del "$NS_A" 2>/dev/null || true
ip netns del "$NS_B" 2>/dev/null || true
ip netns add "$NS_A"
ip netns add "$NS_B"
info "Network namespaces: $NS_A  $NS_B"

# ── Start instance A (ISS) ─────────────────────────────────────────────────

info "Starting instance A (ISS, $DEV_A) ..."
ip netns exec "$NS_A" "$ARDOP_IP" \
    --audio    "$DEV_A" \
    --mycall   KD2MYS-1 \
    --local-ip 10.0.0.1 \
    --peer-ip  10.0.0.2 \
    --tun-dev  ardop0 \
    --bw 2500 \
    > "$LOG_DIR/integ-a.log" 2>&1 &
PID_A=$!
sleep 0.5

if ! kill -0 "$PID_A" 2>/dev/null; then
    fail "Instance A failed to start (see $LOG_DIR/integ-a.log)"
    cat "$LOG_DIR/integ-a.log"
    exit 1
fi
pass "Instance A started (PID $PID_A)"

# ── Start instance B (IRS) ─────────────────────────────────────────────────

info "Starting instance B (IRS, $DEV_B) ..."
ip netns exec "$NS_B" "$ARDOP_IP" \
    --audio    "$DEV_B" \
    --mycall   KD2MYS-2 \
    --local-ip 10.0.0.2 \
    --peer-ip  10.0.0.1 \
    --tun-dev  ardop1 \
    --bw 2500 \
    > "$LOG_DIR/integ-b.log" 2>&1 &
PID_B=$!
sleep 0.5

if ! kill -0 "$PID_B" 2>/dev/null; then
    fail "Instance B failed to start (see $LOG_DIR/integ-b.log)"
    cat "$LOG_DIR/integ-b.log"
    exit 1
fi
pass "Instance B started (PID $PID_B)"

# ── Wait for ARQ connection ────────────────────────────────────────────────
# ARQ loopback RTT is ~10-20s (even over ALSA null-sink, audio frames take
# real time to encode/decode).  Poll every 30s with a 30s ping timeout.

info "Waiting for ARQ connect (up to 180s, ping -W 30 every 30s) ..."
CONNECT_TIMEOUT=6   # 6 × 30s = 180s max
connected=0
for ((i=0; i<CONNECT_TIMEOUT; i++)); do
    sleep 30
    if ! kill -0 "$PID_A" 2>/dev/null; then fail "Instance A died"; break; fi
    if ! kill -0 "$PID_B" 2>/dev/null; then fail "Instance B died"; break; fi
    if ip netns exec "$NS_A" ping -c 1 -W 30 10.0.0.2 >/dev/null 2>&1; then
        connected=1
        break
    fi
    info "  still waiting... ($((i+1)) of $CONNECT_TIMEOUT tries)"
done

if [[ $connected -eq 1 ]]; then
    pass "ARQ connected (first ping succeeded)"
else
    fail "ARQ connect timeout after $((CONNECT_TIMEOUT * 30))s"
    info "Instance A log tail:"
    tail -20 "$LOG_DIR/integ-a.log"
    info "Instance B log tail:"
    tail -20 "$LOG_DIR/integ-b.log"
    exit 1
fi

# ── Tests 2-5: run while OFDM quality is highest (before long ICMP soak) ──────
# ALSA loopback quality degrades after ~200s; MTU/iperf3 run first.

# ── Test 2: MTU path discovery ────────────────────────────────────────────────

info "Test 2: MTU ping -s 600 -M do -W 90 (no fragmentation) ..."
if ip netns exec "$NS_A" ping -c 1 -s 600 -M do -W 90 10.0.0.2 >/dev/null 2>&1; then
    pass "MTU: 600-byte ping passed without fragmentation"
else
    fail "MTU: 600-byte ping failed (fragmentation or loss)"
fi

# ── Test 3: TCP connect ────────────────────────────────────────────────────────

info "Test 3: TCP connect ..."
ip netns exec "$NS_B" nc -l -p 7777 >/dev/null 2>&1 &
LISTENER_PID=$!
sleep 2
if ip netns exec "$NS_A" nc -zv -w 120 10.0.0.2 7777 >/dev/null 2>&1; then
    pass "TCP: connection to 10.0.0.2:7777 succeeded"
else
    fail "TCP: connection to 10.0.0.2:7777 failed"
fi
kill $LISTENER_PID 2>/dev/null || true

# ── Test 4: Throughput (run before ICMP soak to ensure fresh OFDM quality) ────

if [[ $HAVE_IPERF -eq 1 ]]; then
    info "Test 4: iperf3 throughput (30s, 4k target) ..."
    ip netns exec "$NS_B" iperf3 -s >/dev/null 2>&1 & PID_IPERF=$!
    sleep 2
    TP_OUT=$(ip netns exec "$NS_A" iperf3 -c 10.0.0.2 -t 30 -b 4k --connect-timeout 30000 2>&1) || true
    # Extract the sender summary line; convert K/M/G prefix to integer bps
    GOODPUT=$(echo "$TP_OUT" | grep -oP '\d+(\.\d+)?\s+[KMG]?bits/sec' | tail -1 || true)
    BPS=$(echo "$GOODPUT" | awk '{
        v=$1; u=$2;
        if (u ~ /G/) v=v*1000000000;
        else if (u ~ /M/) v=v*1000000;
        else if (u ~ /K/) v=v*1000;
        print int(v)
    }' || true)
    if [[ -n "$BPS" ]] && [[ "$BPS" -ge 1000 ]]; then
        pass "Throughput: $GOODPUT ≥ 1000 bps"
    else
        fail "Throughput: ${GOODPUT:-no output} (wanted ≥ 1000 bps)"
        info "iperf3 raw: $(echo "$TP_OUT" | tail -5)"
    fi
    kill "$PID_IPERF" 2>/dev/null || true; PID_IPERF=""
else
    info "Test 4: iperf3 not installed — skipped"
fi

# ── Test 5: ICMP echo (long soak — runs last as quality may degrade) ──────────

info "Test 5: ICMP ping -c 5 -i 30 -W 60 ..."
PING_OUT=$(ip netns exec "$NS_A" ping -c 5 -i 30 -W 60 10.0.0.2 2>&1)
if echo "$PING_OUT" | grep -q "0% packet loss"; then
    pass "ICMP: 5/5 ping replies, 0% loss"
else
    LOSS=$(echo "$PING_OUT" | grep -oP '\d+% packet loss' || echo "?% loss")
    fail "ICMP: $LOSS"
fi

# ── Results ────────────────────────────────────────────────────────────────

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && echo -e "${GREEN}ALL PASS${NC}" || echo -e "${RED}SOME FAILED${NC}"
[[ $FAIL -eq 0 ]]
