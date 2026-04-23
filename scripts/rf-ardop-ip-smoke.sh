#!/bin/bash
# scripts/rf-ardop-ip-smoke.sh — first over-the-air smoke test for ardop-ip
#
# Reads config/ardop-ip-rf.conf, runs pre-flight checks, starts ardop-ip on
# both radios in isolated network namespaces, waits for ARQ connect, then
# fires 3 pings at 5 s interval.  Pass if ≥ 2 replies.
#
# Usage:  sudo scripts/rf-ardop-ip-smoke.sh [--keep-logs]
#
# Prereqs (manual — NOT checked in code):
#   • Both radios powered on, USB-D/DATA mode selected
#   • Both tuned to FREQ_HZ, USB sideband
#   • SSB TX filter ≥ 2.4 kHz on BOTH radios (mismatched filters cause
#     systematic FEC corrections — see CLAUDE.md)
#   • TX power ≤ 5 W recommended for same-building testing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
CONF="$ROOT/config/ardop-ip-rf.conf"
ARDOP_IP="$ROOT/ardop-ip"
LOG_DIR="$ROOT/logs"
NS_A="ns_rf_705"
NS_B="ns_rf_7300"
PID_A="" PID_B=""
KEEP_LOGS=0

[[ "${1:-}" == "--keep-logs" ]] && KEEP_LOGS=1

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}PASS${NC}  $1"; }
fail() { echo -e "${RED}FAIL${NC}  $1"; }
info() { echo -e "${YELLOW}    ${NC}  $1"; }

rescue_ptt_off() {
    # Belt-and-suspenders: send CI-V PTT OFF to both radios after processes die.
    # Frame: FE FE <addr> E0 1C 00 00 FD.
    if [[ -c /dev/ic_705_a ]]; then
        stty -F /dev/ic_705_a 115200 raw -echo 2>/dev/null || true
        printf '\xFE\xFE\xA4\xE0\x1C\x00\x00\xFD' > /dev/ic_705_a 2>/dev/null || true
    fi
    if [[ -c /dev/ic_7300 ]]; then
        stty -F /dev/ic_7300  115200 raw -echo 2>/dev/null || true
        printf '\xFE\xFE\x94\xE0\x1C\x00\x00\xFD' > /dev/ic_7300  2>/dev/null || true
    fi
}

cleanup() {
    # Preserve caller's exit status; never let cleanup turn a PASS into a fail.
    local rc=$?
    set +e
    info "Cleanup..."
    # SIGTERM first — ardop-ip's signal handler will emit CI-V PTT OFF.
    [[ -n "$PID_A" ]] && kill -TERM "$PID_A" 2>/dev/null
    [[ -n "$PID_B" ]] && kill -TERM "$PID_B" 2>/dev/null
    # Give ardop-ip up to 3 s to flush PTT-OFF and exit cleanly.
    for _ in 1 2 3; do
        sleep 1
        pgrep -f "ardop-ip" >/dev/null 2>&1 || break
    done
    # Any survivor gets SIGKILL; then we send CI-V PTT OFF directly as insurance.
    pkill -KILL -f "ardop-ip" 2>/dev/null
    sleep 0.5
    rescue_ptt_off
    ip netns del "$NS_A" 2>/dev/null
    ip netns del "$NS_B" 2>/dev/null
    if [[ $KEEP_LOGS -eq 0 ]]; then
        rm -f "$LOG_DIR"/rf-705.log "$LOG_DIR"/rf-7300.log
    fi
    exit "$rc"
}
trap cleanup EXIT

echo "=== ardop-ip RF smoke test (IC-705 ↔ IC-7300) ==="
echo

[[ $EUID -ne 0 ]]    && { echo "Must run as root" >&2; exit 1; }
[[ -x "$ARDOP_IP" ]] || { echo "ardop-ip not built — run 'make ardop-ip'" >&2; exit 1; }
[[ -f "$CONF" ]]     || { echo "Config not found: $CONF" >&2; exit 1; }

# shellcheck disable=SC1090
source "$CONF"

mkdir -p "$LOG_DIR"

# ── Pre-flight: devices present and openable ─────────────────────────────────

info "Pre-flight: device presence..."
for dev in "$IC705_CIV_PORT" "$IC7300_CIV_PORT"; do
    [[ -e "$dev" ]] || { fail "CI-V device $dev not found"; exit 1; }
done
aplay -l 2>/dev/null | grep -q CODEC_705   || { fail "IC-705 audio not present"; exit 1; }
aplay -l 2>/dev/null | grep -q CODEC_7300  || { fail "IC-7300 audio not present"; exit 1; }

# CI-V ports should NOT be held by another process (Direwolf, hamlib, etc.)
for dev in "$IC705_CIV_PORT" "$IC7300_CIV_PORT"; do
    real=$(readlink -f "$dev")
    if fuser "$real" 2>/dev/null; then
        fail "$dev is held by another process — kill it (Direwolf? hamlib?) and retry"
        exit 1
    fi
done

# Audio devices should not be in use either
if fuser /dev/snd/pcmC*D0[cp] 2>/dev/null | tr ' ' '\n' | sort -u | grep -q .; then
    info "NOTE: some ALSA PCM devices are in use — ensure CODEC_705 and CODEC_7300 are free"
fi

pass "Pre-flight OK (CI-V ports + audio cards present, not held)"

info "Config: freq=${FREQ_HZ} Hz  bw=${BANDWIDTH} Hz  ${IC705_MYCALL} (ISS) ↔ ${IC7300_MYCALL} (IRS)"

# ── Network namespaces ───────────────────────────────────────────────────────

ip netns del "$NS_A" 2>/dev/null || true
ip netns del "$NS_B" 2>/dev/null || true
ip netns add "$NS_A"
ip netns add "$NS_B"

# ── Start IC-705 (ISS) ───────────────────────────────────────────────────────

info "Starting ardop-ip on IC-705 (ISS, ${IC705_IP})..."
ip netns exec "$NS_A" "$ARDOP_IP" \
    --audio     "$IC705_AUDIO" \
    --mycall    "$IC705_MYCALL" \
    --local-ip  "$IC705_IP" \
    --peer-ip   "$IC7300_IP" \
    --tun-dev   "$IC705_TUN" \
    --mtu       "$MTU" \
    --bw        "$BANDWIDTH" \
    --civ-port  "$IC705_CIV_PORT" \
    --civ-addr  "$IC705_CIV_ADDR" \
    --civ-baud  "$IC705_CIV_BAUD" \
    > "$LOG_DIR/rf-705.log" 2>&1 &
PID_A=$!

# ── Start IC-7300 (IRS) ──────────────────────────────────────────────────────

info "Starting ardop-ip on IC-7300 (IRS, ${IC7300_IP})..."
ip netns exec "$NS_B" "$ARDOP_IP" \
    --audio     "$IC7300_AUDIO" \
    --mycall    "$IC7300_MYCALL" \
    --local-ip  "$IC7300_IP" \
    --peer-ip   "$IC705_IP" \
    --tun-dev   "$IC7300_TUN" \
    --mtu       "$MTU" \
    --bw        "$BANDWIDTH" \
    --civ-port  "$IC7300_CIV_PORT" \
    --civ-addr  "$IC7300_CIV_ADDR" \
    --civ-baud  "$IC7300_CIV_BAUD" \
    > "$LOG_DIR/rf-7300.log" 2>&1 &
PID_B=$!

sleep 1
kill -0 "$PID_A" 2>/dev/null || { fail "IC-705 instance died at startup"; tail -20 "$LOG_DIR/rf-705.log";  exit 1; }
kill -0 "$PID_B" 2>/dev/null || { fail "IC-7300 instance died at startup"; tail -20 "$LOG_DIR/rf-7300.log"; exit 1; }
pass "Both instances started (IC-705 PID=$PID_A  IC-7300 PID=$PID_B)"

# ── Wait for ARQ connect (real RF: ARQ handshake + first round-trip ~30-90s) ─

info "Waiting for ARQ connect (first ping with -W 90, up to 4 attempts)..."
connected=0
for ((i=0; i<4; i++)); do
    kill -0 "$PID_A" 2>/dev/null || { fail "IC-705 died mid-connect"; break; }
    kill -0 "$PID_B" 2>/dev/null || { fail "IC-7300 died mid-connect"; break; }
    if ip netns exec "$NS_A" ping -c 1 -W 90 "$IC7300_IP" >/dev/null 2>&1; then
        connected=1; break
    fi
    info "  ping attempt $((i+1))/4 timed out — ARQ may still be settling"
done

if [[ $connected -eq 1 ]]; then
    pass "ARQ connected (first ping succeeded)"
else
    fail "ARQ did not connect within 360 s"
    info "=== last 30 lines, IC-705 log ==="
    tail -30 "$LOG_DIR/rf-705.log"
    info "=== last 30 lines, IC-7300 log ==="
    tail -30 "$LOG_DIR/rf-7300.log"
    exit 1
fi

# ── Smoke: 3 pings at 15 s interval, 90 s timeout — ≥ 2 must reply ───────────

info "Smoke ping: 3 × ping -W 90 -i 15 ${IC7300_IP} ..."
PING_OUT=$(ip netns exec "$NS_A" ping -c 3 -i 15 -W 90 "$IC7300_IP" 2>&1 || true)
echo "$PING_OUT" | tail -8

REPLIES=$(echo "$PING_OUT" | grep -cE "bytes from ${IC7300_IP//./\\.}" || true)
if [[ "$REPLIES" -ge 2 ]]; then
    pass "Smoke ping: $REPLIES/3 replies"
else
    fail "Smoke ping: $REPLIES/3 replies (need ≥ 2)"
    info "Keep logs with --keep-logs for inspection"
    exit 1
fi

echo
echo -e "${GREEN}RF smoke test PASS${NC} — link is up on ${FREQ_HZ} Hz"
echo "  Logs: $LOG_DIR/rf-705.log  $LOG_DIR/rf-7300.log  (removed unless --keep-logs)"
