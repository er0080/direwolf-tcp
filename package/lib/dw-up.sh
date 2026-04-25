#!/usr/bin/env bash
# dw-iface up — bring up the TNC network interface
set -euo pipefail

# Ensure tncattach (installed to /usr/local/sbin) is on PATH even under sudo
export PATH="/usr/local/sbin:/usr/local/bin:$PATH"

DEFAULT_CONFIG="/etc/dw-iface/dw-iface.conf"
RUN_DIR="/run/dw-iface"
LOG_DIR="/var/log/dw-iface"

log()  { echo "$(date '+%H:%M:%S') [dw-iface up] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ── Parse args ────────────────────────────────────────────────────────────────
CONFIG="$DEFAULT_CONFIG"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG="$2"; shift 2 ;;
        *) die "unknown option '$1'" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "must run as root"
[[ -f "$CONFIG" ]] || die "config not found: $CONFIG (copy dw-iface.conf.example)"

# ── Load config ───────────────────────────────────────────────────────────────
# shellcheck source=/dev/null
source "$CONFIG"

: "${MYCALL:?MYCALL must be set in $CONFIG}"
: "${AUDIO_DEVICE:?AUDIO_DEVICE must be set in $CONFIG}"
: "${IP_ADDR:?IP_ADDR must be set in $CONFIG}"
: "${MTU:=508}"
: "${KISS_PORT:=8001}"
: "${IFACE:=tnc0}"
: "${MODEM:=2400}"
: "${TXDELAY:=20}"
: "${TXTAIL:=10}"
: "${PACLEN:=512}"
: "${PERSIST:=127}"
: "${SLOTTIME:=5}"
: "${DWAIT:=0}"
: "${IL2PTX:=1}"
: "${FRACK:=3}"
: "${RETRY:=3}"
: "${MAXFRAME:=7}"
: "${EMAXFRAME:=63}"

mkdir -p "$RUN_DIR" "$LOG_DIR"

# Guard against double-up
[[ -f "$RUN_DIR/direwolf.pid" ]] && \
    kill -0 "$(cat "$RUN_DIR/direwolf.pid")" 2>/dev/null && \
    die "already running (PID $(cat "$RUN_DIR/direwolf.pid"))"

# ── Generate direwolf config ─────────────────────────────────────────────────
DW_CONF="$RUN_DIR/direwolf.conf"
cat > "$DW_CONF" <<EOF
AGWPORT 0
KISSPORT ${KISS_PORT}

ADEVICE ${AUDIO_DEVICE}
ARATE   ${AUDIO_RATE:-48000}

${PTT:+PTT ${PTT}}

CHANNEL 0
MYCALL  ${MYCALL}
MODEM   ${MODEM}
TXDELAY ${TXDELAY}
TXTAIL  ${TXTAIL}
PACLEN  ${PACLEN}
RETRY   ${RETRY}
FRACK   ${FRACK}
MAXFRAME ${MAXFRAME}
EMAXFRAME ${EMAXFRAME}
DWAIT   ${DWAIT}
IL2PTX  ${IL2PTX}
PERSIST ${PERSIST}
SLOTTIME ${SLOTTIME}
EOF

# ── Start direwolf ───────────────────────────────────────────────────────────
log "starting direwolf (modem ${MODEM}, ALSA: ${AUDIO_DEVICE})"
direwolf -c "$DW_CONF" -t 0 >> "$LOG_DIR/direwolf.log" 2>&1 &
echo $! > "$RUN_DIR/direwolf.pid"

# ── Wait for KISS port ────────────────────────────────────────────────────────
log "waiting for KISS port ${KISS_PORT}..."
for i in $(seq 1 30); do
    nc -z localhost "$KISS_PORT" 2>/dev/null && break
    sleep 1
done
nc -z localhost "$KISS_PORT" 2>/dev/null || die "direwolf KISS port never opened"

# ── Start tncattach ───────────────────────────────────────────────────────────
log "starting tncattach (mtu ${MTU})"
tncattach localhost "$KISS_PORT" --mtu "$MTU" --noipv6 -v \
    >> "$LOG_DIR/tncattach.log" 2>&1 &
echo $! > "$RUN_DIR/tncattach.pid"

# ── Wait for interface ────────────────────────────────────────────────────────
log "waiting for ${IFACE}..."
for i in $(seq 1 30); do
    ip link show "$IFACE" &>/dev/null && break
    sleep 1
done
ip link show "$IFACE" &>/dev/null || die "${IFACE} never appeared"

# ── Configure interface ────────────────────────────────────────────────────────
log "configuring ${IFACE} ${IP_ADDR}"
ip addr add "$IP_ADDR" dev "$IFACE"
ip link set "$IFACE" up

echo "$IFACE" > "$RUN_DIR/iface"
echo "$IP_ADDR" > "$RUN_DIR/ip_addr"

log "up — ${IFACE} ${IP_ADDR}"
