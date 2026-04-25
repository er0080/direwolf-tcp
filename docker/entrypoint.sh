#!/usr/bin/env bash
# Container entrypoint — starts direwolf, tncattach, sshd, and optionally nginx.
#
# Environment variables (set by compose.yml):
#   NODE_ROLE     a | b
#   NODE_IP       e.g. 10.0.0.1/30
#   ALSA_DEV      plughw:Loopback,0  (node-a) | plughw:Loopback,1 (node-b)
#   KISS_PORT     8001 (node-a) | 8002 (node-b)
#   MYCALL        AX.25 callsign

set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] node-${NODE_ROLE}: $*"; }

# ── Direwolf config ──────────────────────────────────────────────────────────
# DWAIT: node-a = 0 (takes the channel first), node-b = 5 (yields to node-a)
DWAIT=0
[[ "$NODE_ROLE" == "b" ]] && DWAIT=5

cat > /etc/dw-iface/direwolf.conf <<EOF
AGWPORT 0
KISSPORT ${KISS_PORT}

ADEVICE ${ALSA_DEV}
ARATE   48000

CHANNEL 0
MYCALL  ${MYCALL}
MODEM   2400
TXDELAY 5
TXTAIL  3
PACLEN  512
RETRY   3
FRACK   3
MAXFRAME 7
EMAXFRAME 63
IL2PTX  1
PERSIST 127
SLOTTIME 5
DWAIT   ${DWAIT}
EOF

# ── SSH authorized keys ──────────────────────────────────────────────────────
mkdir -p /root/.ssh
chmod 700 /root/.ssh
# authorized_keys is bind-mounted by compose; fix permissions if present
[[ -f /root/.ssh/authorized_keys ]] && chmod 600 /root/.ssh/authorized_keys
# private key is bind-mounted for node-a; fix permissions if present
[[ -f /root/.ssh/id_ed25519 ]] && chmod 600 /root/.ssh/id_ed25519

# ── Start direwolf ───────────────────────────────────────────────────────────
log "starting direwolf (ALSA: ${ALSA_DEV}, KISS :${KISS_PORT})"
direwolf -c /etc/dw-iface/direwolf.conf -t 0 >>/var/log/direwolf.log 2>&1 &
DW_PID=$!

# ── Wait for KISS port ───────────────────────────────────────────────────────
log "waiting for KISS port ${KISS_PORT}..."
for i in $(seq 1 60); do
    nc -z localhost "$KISS_PORT" 2>/dev/null && break
    sleep 1
done
nc -z localhost "$KISS_PORT" 2>/dev/null || { log "ERROR: direwolf KISS port never opened"; exit 1; }

# ── Start tncattach ──────────────────────────────────────────────────────────
log "starting tncattach (mtu 508)"
/usr/local/sbin/tncattach localhost "$KISS_PORT" --mtu 508 --noipv6 -v >>/var/log/tncattach.log 2>&1 &
TNC_PID=$!

# ── Wait for tnc0 interface ──────────────────────────────────────────────────
log "waiting for tnc0..."
for i in $(seq 1 30); do
    ip link show tnc0 &>/dev/null && break
    sleep 1
done
ip link show tnc0 &>/dev/null || { log "ERROR: tnc0 never appeared"; exit 1; }

# ── Configure interface ──────────────────────────────────────────────────────
log "configuring tnc0 ${NODE_IP}"
ip addr add "$NODE_IP" dev tnc0
ip link set tnc0 up

# ── Start sshd ───────────────────────────────────────────────────────────────
log "starting sshd"
/usr/sbin/sshd -D &
SSH_PID=$!

# ── Start nginx (node-b only) ─────────────────────────────────────────────────
if [[ "$NODE_ROLE" == "b" ]]; then
    log "starting nginx"
    nginx -g 'daemon off;' &
    NGX_PID=$!
fi

log "ready — tnc0 ${NODE_IP}"
touch /tmp/dw-iface-ready

# ── Keep alive: exit if any critical child exits ──────────────────────────────
wait "$DW_PID" "$TNC_PID"
