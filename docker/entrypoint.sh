#!/usr/bin/env bash
# Container entrypoint — calls the installed dw-iface package to bring up
# the link, then starts sshd and nginx.
#
# Environment variables (set by compose.yml):
#   NODE_ROLE   a | b
#
# /etc/dw-iface/dw-iface.conf is bind-mounted from docker/config/node-{a,b}.conf

set -euo pipefail
log() { echo "[$(date '+%H:%M:%S')] node-${NODE_ROLE}: $*"; }

# ── SSH authorized keys ───────────────────────────────────────────────────────
mkdir -p /root/.ssh && chmod 700 /root/.ssh
[[ -f /root/.ssh/authorized_keys ]] && chmod 600 /root/.ssh/authorized_keys
[[ -f /root/.ssh/id_ed25519 ]]      && chmod 600 /root/.ssh/id_ed25519

# ── Bring up the TNC link via the installed dw-iface package ─────────────────
log "calling dw-iface up"
/usr/bin/dw-iface up

# ── Wait for tnc0 to have an IP ───────────────────────────────────────────────
log "waiting for tnc0 to be configured..."
for i in $(seq 1 60); do
    ip addr show tnc0 2>/dev/null | grep -q 'inet ' && break
    sleep 2
done
ip addr show tnc0 | grep -q 'inet ' || { log "ERROR: tnc0 never got an IP"; exit 1; }
log "tnc0 up: $(ip -br addr show tnc0 | awk '{print $3}')"

# ── Start sshd ────────────────────────────────────────────────────────────────
log "starting sshd"
/usr/sbin/sshd -D &
SSH_PID=$!

# ── Start nginx (node-b only) ─────────────────────────────────────────────────
if [[ "${NODE_ROLE}" == "b" ]]; then
    log "starting nginx"
    nginx -g 'daemon off;' &
fi

# ── Keep alive: exit if direwolf dies ─────────────────────────────────────────
DW_PID_FILE=/run/dw-iface/direwolf.pid
while :; do
    if [[ -f "$DW_PID_FILE" ]] && kill -0 "$(cat "$DW_PID_FILE")" 2>/dev/null; then
        sleep 15
    else
        log "direwolf exited — shutting down container"
        kill "$SSH_PID" 2>/dev/null || true
        dw-iface down 2>/dev/null || true
        exit 1
    fi
done
