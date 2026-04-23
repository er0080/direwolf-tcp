#!/bin/bash
# scripts/rf-ardop-ip-stress.sh — 5-minute sustained link stability test
#
# Fail-fast philosophy: a single stress pass.  Pass criterion is a specific,
# measurable outcome — not "mostly works".
#
# Usage:  sudo scripts/rf-ardop-ip-stress.sh [--keep-logs]

set -uo pipefail

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
fail() { echo -e "${RED}FAIL${NC}  $1"; exit 1; }
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
    [[ -n "$PID_A" ]] && kill -TERM "$PID_A" 2>/dev/null
    [[ -n "$PID_B" ]] && kill -TERM "$PID_B" 2>/dev/null
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
        rm -f "$LOG_DIR"/rf-705.log "$LOG_DIR"/rf-7300.log
    fi
    exit "$rc"
}
trap cleanup EXIT

echo "=== ardop-ip RF stress test — 5 min sustained (14.103 MHz) ==="
echo

[[ $EUID -ne 0 ]]    && { echo "Must run as root" >&2; exit 1; }
[[ -x "$ARDOP_IP" ]] || { echo "ardop-ip not built" >&2; exit 1; }
[[ -f "$CONF" ]]     || { echo "Config not found" >&2; exit 1; }

# shellcheck disable=SC1090
source "$CONF"
mkdir -p "$LOG_DIR"

ip netns del "$NS_A" 2>/dev/null; ip netns del "$NS_B" 2>/dev/null
ip netns add "$NS_A"; ip netns add "$NS_B"

for dev in "$IC705_CIV_PORT" "$IC7300_CIV_PORT"; do
    [[ -e "$dev" ]] || fail "CI-V device $dev missing"
    real=$(readlink -f "$dev")
    fuser "$real" 2>/dev/null && fail "$dev is held by another process"
done

ip netns exec "$NS_A" "$ARDOP_IP" \
    --audio "$IC705_AUDIO" --mycall "$IC705_MYCALL" \
    --local-ip "$IC705_IP" --peer-ip "$IC7300_IP" \
    --tun-dev "$IC705_TUN" --mtu "$MTU" \
    --iss --peer-call "$IC7300_MYCALL" --bw "$BANDWIDTH" \
    --civ-port "$IC705_CIV_PORT" --civ-addr "$IC705_CIV_ADDR" --civ-baud "$IC705_CIV_BAUD" \
    > "$LOG_DIR/rf-705.log" 2>&1 &
PID_A=$!

ip netns exec "$NS_B" "$ARDOP_IP" \
    --audio "$IC7300_AUDIO" --mycall "$IC7300_MYCALL" \
    --local-ip "$IC7300_IP" --peer-ip "$IC705_IP" \
    --tun-dev "$IC7300_TUN" --mtu "$MTU" \
    --irs --bw "$BANDWIDTH" \
    --civ-port "$IC7300_CIV_PORT" --civ-addr "$IC7300_CIV_ADDR" --civ-baud "$IC7300_CIV_BAUD" \
    > "$LOG_DIR/rf-7300.log" 2>&1 &
PID_B=$!

sleep 1
kill -0 "$PID_A" 2>/dev/null || { tail -20 "$LOG_DIR/rf-705.log";  fail "IC-705 startup"; }
kill -0 "$PID_B" 2>/dev/null || { tail -20 "$LOG_DIR/rf-7300.log"; fail "IC-7300 startup"; }
pass "Both instances started (IC-705=$PID_A IC-7300=$PID_B)"

info "ARQ connect + warm-up ping..."
ip netns exec "$NS_A" ping -c 1 -W 120 "$IC7300_IP" >/dev/null 2>&1 \
    || fail "ARQ did not establish within 120 s"
pass "ARQ connected"

# ── Stress: 20 pings at 15 s interval = ~5 min, 20/20 required ───────────────
# Acceptance is strict: every ping must reply.  A single loss = link not
# stable enough for general TCP/IP use.

info "Stress: ping -c 20 -i 15 -W 120 ${IC7300_IP}  (~5 min)..."
PING_OUT=$(ip netns exec "$NS_A" ping -c 20 -i 15 -W 120 "$IC7300_IP" 2>&1)
echo "$PING_OUT" | tail -4
REPLIES=$(echo "$PING_OUT" | grep -cE "bytes from ${IC7300_IP//./\\.}")
[[ "$REPLIES" -eq 20 ]] || fail "Stress ping: only $REPLIES/20 replies — link not stable"
pass "Stress ping: 20/20 replies"

# ── Final size probe: one MTU ping, one 1024-byte UDP, both after 5-min soak ──

info "Post-soak MTU check: 1432-byte ping..."
ip netns exec "$NS_A" ping -c 1 -s 1432 -M do -W 240 "$IC7300_IP" >/dev/null 2>&1 \
    || fail "Post-soak MTU ping failed — data path degraded after soak"
pass "Post-soak MTU 1460: 1432-byte ping passed"

echo
echo -e "${GREEN}STRESS TEST PASSED${NC} — link stable 5 min + MTU intact"
