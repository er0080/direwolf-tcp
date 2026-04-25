#!/usr/bin/env bash
# dw-iface status — show interface state
set -uo pipefail
RUN_DIR="/run/dw-iface"

ok()   { printf "  %-20s \e[32mOK\e[0m  %s\n" "$1" "${2:-}"; }
warn() { printf "  %-20s \e[33mWARN\e[0m %s\n" "$1" "${2:-}"; }
bad()  { printf "  %-20s \e[31mDOWN\e[0m %s\n" "$1" "${2:-}"; }

echo "=== dw-iface status ==="

# direwolf
if [[ -f "$RUN_DIR/direwolf.pid" ]] && kill -0 "$(cat "$RUN_DIR/direwolf.pid")" 2>/dev/null; then
    ok "direwolf" "PID $(cat "$RUN_DIR/direwolf.pid")"
else
    bad "direwolf" "not running"
fi

# tncattach
if [[ -f "$RUN_DIR/tncattach.pid" ]] && kill -0 "$(cat "$RUN_DIR/tncattach.pid")" 2>/dev/null; then
    ok "tncattach" "PID $(cat "$RUN_DIR/tncattach.pid")"
else
    bad "tncattach" "not running"
fi

# interface
IFACE=$(cat "$RUN_DIR/iface" 2>/dev/null || echo "tnc0")
if ip link show "$IFACE" &>/dev/null; then
    IP=$(ip -br addr show "$IFACE" | awk '{print $3}')
    STATE=$(ip -br link show "$IFACE" | awk '{print $2}')
    [[ "$STATE" == "UP" ]] && ok "$IFACE" "$IP" || warn "$IFACE" "$STATE $IP"
else
    bad "$IFACE" "interface absent"
fi
