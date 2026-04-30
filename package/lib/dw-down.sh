#!/usr/bin/env bash
# dw-iface down — tear down the TNC link
set -euo pipefail
RUN_DIR="/run/dw-iface"

log() { echo "$(date '+%H:%M:%S') [dw-iface down] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root"

stop_pid() {
    local pidfile="$1" name="$2"
    [[ -f "$pidfile" ]] || return 0
    local pid; pid=$(cat "$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
        log "stopping $name (PID $pid)"
        kill "$pid" 2>/dev/null || true
        local i; for i in $(seq 1 10); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
}

IFACE=$(cat "$RUN_DIR/iface" 2>/dev/null || echo "tnc0")

stop_pid "$RUN_DIR/tncattach.pid" "tncattach"
stop_pid "$RUN_DIR/direwolf.pid"  "direwolf"

ip link del "$IFACE" 2>/dev/null || true
rm -f "$RUN_DIR/iface" "$RUN_DIR/ip_addr"

log "down"
