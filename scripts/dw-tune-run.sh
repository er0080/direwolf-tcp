#!/usr/bin/env bash
# dw-tune-run.sh — Single measurement run for Direwolf parameter tuning.
#
# Launches two Direwolf instances with overridden CSMA/PTT params,
# runs a mixed workload (curl/ftp/ssh/git-style: small interactive pings
# + a short bulk transfer + follow-up pings), and emits a JSON result
# with latency, loss, throughput, and collision proxies.
#
# Every invocation generates fresh configs under /tmp/dw-tune-XXXX and
# tears the full stack down (radios, tncattach, netns) afterwards.  One
# run ≈ 60–90 s of radio time.
#
# Usage (all flags optional — unset = use dw-705.conf / dw-7300.conf
# default):
#   sudo scripts/dw-tune-run.sh \
#       --dwait-a 0 --dwait-b 25 \
#       --persist 127 --slottime 5 --txdelay 20 \
#       --tag baseline \
#       --out logs/tune/run-$(date +%s).json

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
TNCATTACH="$ROOT/tncattach/tncattach"
LOG_DIR="$ROOT/logs"
TUNE_DIR="$LOG_DIR/tune"
NS_A="ns_a"
NS_B="ns_b"

# ── Defaults (match current dw-705.conf / dw-7300.conf) ─────────────────────
DWAIT_A=0       # IC-7300 side (B in sweep layout, A in namespace: ns_a holds IC-705)
DWAIT_B=5       # IC-705 side — in reality dw-705.conf uses DWAIT 5, dw-7300 uses 0
PERSIST=255
SLOTTIME=1
TXDELAY=20
TAG="ad-hoc"
OUT_JSON=""

# Workload: standardised for "curl/ftp/ssh/git" — short interactive round
# trips + one modest bulk transfer.
WARMUP_PINGS=2
INTERACTIVE_PINGS=6       # ping -c1 spaced -i INTERACTIVE_INTERVAL
INTERACTIVE_INTERVAL=3    # seconds
BULK_BYTES=1024           # one small HTTP GET / ssh command output
RECOVERY_PINGS=3
PING_SIZE=56              # default ICMP payload

# ── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dwait-a)       DWAIT_A="$2"; shift 2 ;;
        --dwait-b)       DWAIT_B="$2"; shift 2 ;;
        --persist)       PERSIST="$2"; shift 2 ;;
        --slottime)      SLOTTIME="$2"; shift 2 ;;
        --txdelay)       TXDELAY="$2"; shift 2 ;;
        --tag)           TAG="$2"; shift 2 ;;
        --out)           OUT_JSON="$2"; shift 2 ;;
        --interactive-pings) INTERACTIVE_PINGS="$2"; shift 2 ;;
        --bulk-bytes)    BULK_BYTES="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "Unknown flag: $1" >&2; exit 2 ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "Must run as root" >&2; exit 1; }
[[ -x "$TNCATTACH" ]] || { echo "tncattach not built" >&2; exit 1; }

REAL_USER="${SUDO_USER:-$USER}"

mkdir -p "$TUNE_DIR"
chown "$REAL_USER" "$TUNE_DIR" 2>/dev/null || true
RUN_TMP=$(mktemp -d /tmp/dw-tune-XXXXXX)
chmod 755 "$RUN_TMP"
RUN_ID="$(date +%s)-$(printf '%04x' $RANDOM)"
LOG_705="$RUN_TMP/dw-705.log"
LOG_7300="$RUN_TMP/dw-7300.log"

# ── Config generator ────────────────────────────────────────────────────────
# One config per radio, regenerated from scratch so every knob is explicit.
gen_config() {
    local outfile="$1" agwport="$2" kissport="$3" card="$4" ptt="$5" mycall="$6" dwait="$7"
    cat > "$outfile" <<EOF
AGWPORT $agwport
KISSPORT $kissport
ADEVICE plughw:CARD=$card,DEV=0
ARATE   48000
PTT $ptt DTR
CHANNEL 0
MYCALL  $mycall
MODEM 2400
TXDELAY $TXDELAY
TXTAIL  10
PACLEN  512
RETRY 3
FRACK 3
MAXFRAME 7
EMAXFRAME 63
DWAIT $dwait
IL2PTX 1
PERSIST $PERSIST
SLOTTIME $SLOTTIME
EOF
}

# ── Rescue: drop DTR on both serial PTT devices so a stuck radio unkeys ─────
rescue_ptt_off() {
    # Direwolf uses DTR as the PTT line.  On hard kill DTR can stay high.
    # stty -clocal drops DTR on close; reopen + close unconditionally.
    for dev in /dev/ic_705_b /dev/ic_7300; do
        [[ -c "$dev" ]] || continue
        stty -F "$dev" 1200 -clocal 2>/dev/null || true
        # Touch the device to force a close-with-drop.
        exec 9<>"$dev" 2>/dev/null && exec 9<&- 2>/dev/null || true
    done
}

cleanup() {
    local rc=$?
    set +e
    # Kill tncattach first so the TUN fds close before direwolf exits.
    pkill -TERM -x tncattach 2>/dev/null
    sleep 0.3
    pkill -KILL -x tncattach 2>/dev/null
    pkill -TERM -x direwolf  2>/dev/null
    # Direwolf wants a moment to drop DTR; give it 0.5 s, then SIGKILL.
    sleep 0.5
    pkill -KILL -x direwolf  2>/dev/null
    rescue_ptt_off
    ip netns del "$NS_A" 2>/dev/null
    ip netns del "$NS_B" 2>/dev/null
    # Keep the run log on failure for post-mortem.
    if [[ "$rc" -eq 0 ]]; then
        rm -rf "$RUN_TMP"
    else
        cp "$RUN_TMP"/*.log "$TUNE_DIR/failed-$RUN_ID/" 2>/dev/null \
            || { mkdir -p "$TUNE_DIR/failed-$RUN_ID" && \
                 cp "$RUN_TMP"/*.log "$TUNE_DIR/failed-$RUN_ID/" 2>/dev/null; }
        rm -rf "$RUN_TMP"
        echo "Run failed, logs at $TUNE_DIR/failed-$RUN_ID" >&2
    fi
    exit "$rc"
}
trap cleanup EXIT

# ── Generate configs ────────────────────────────────────────────────────────
CONF_705="$RUN_TMP/dw-705.conf"
CONF_7300="$RUN_TMP/dw-7300.conf"
gen_config "$CONF_705"  8000 8001 CODEC_705  /dev/ic_705_b NE2H-5 "$DWAIT_B"
gen_config "$CONF_7300" 8100 8101 CODEC_7300 /dev/ic_7300  NE2H-6 "$DWAIT_A"
chmod 644 "$CONF_705" "$CONF_7300"

# ── Launch Direwolf × 2 ─────────────────────────────────────────────────────
sudo -u "$REAL_USER" direwolf -c "$CONF_705"  > "$LOG_705"  2>&1 &
sudo -u "$REAL_USER" direwolf -c "$CONF_7300" > "$LOG_7300" 2>&1 &

# Wait for both KISS ports to be listening, bounded.
wait_port() {
    local port="$1" deadline=$((SECONDS + 15))
    until ss -tln | grep -q ":$port "; do
        (( SECONDS > deadline )) && { echo "port $port never came up" >&2; return 1; }
        sleep 0.2
    done
}
wait_port 8001 || exit 3
wait_port 8101 || exit 3

# ── Netns + tncattach ───────────────────────────────────────────────────────
ip netns del "$NS_A" 2>/dev/null; ip netns del "$NS_B" 2>/dev/null
ip netns add "$NS_A"; ip netns add "$NS_B"
ip netns exec "$NS_A" ip link set lo up
ip netns exec "$NS_B" ip link set lo up

"$TNCATTACH" -T -H localhost -P 8001 --mtu 508 --noipv6 --noup &
TNC_A_PID=$!
until ip link show tnc0 >/dev/null 2>&1; do sleep 0.2; done
ip link set tnc0 netns "$NS_A"
ip netns exec "$NS_A" ifconfig tnc0 10.0.0.1 pointopoint 10.0.0.2 netmask 255.255.255.252 up

"$TNCATTACH" -T -H localhost -P 8101 --mtu 508 --noipv6 --noup &
TNC_B_PID=$!
until ip link show tnc0 >/dev/null 2>&1; do sleep 0.2; done
ip link set tnc0 netns "$NS_B"
ip netns exec "$NS_B" ip link set tnc0 name tnc1
ip netns exec "$NS_B" ifconfig tnc1 10.0.0.2 pointopoint 10.0.0.1 netmask 255.255.255.252 up

# ── Workload ────────────────────────────────────────────────────────────────
T_START_EPOCH=$(date +%s)

# Truncate logs so we only count this run's activity.
true > "$LOG_705"; true > "$LOG_7300"

# Warm-up (not measured — gets CSMA state stabilised).
ip netns exec "$NS_A" ping -c "$WARMUP_PINGS" -i 3 -W 20 10.0.0.2 >/dev/null 2>&1 || true

# Phase 1: interactive-pattern pings A→B.
PING_OUT_A=$(ip netns exec "$NS_A" \
    ping -c "$INTERACTIVE_PINGS" -i "$INTERACTIVE_INTERVAL" -s "$PING_SIZE" -W 20 10.0.0.2 2>&1)
# Phase 2: bulk transfer A→B (simulates one short HTTP GET).
# Use -N on both sides so nc half-closes on stdin EOF instead of
# lingering for its idle timeout.  This turns a ~60 s close-wait into
# a ~1 s FIN handshake and makes bulk_bps reflect real throughput.
ip netns exec "$NS_B" timeout 180 nc -l -p 6666 -N > "$RUN_TMP/bulk.recv" 2>/dev/null &
NC_PID=$!
sleep 1
BULK_START_MS=$(date +%s%3N)
ip netns exec "$NS_A" bash -c \
    "dd if=/dev/urandom bs=$BULK_BYTES count=1 2>/dev/null | nc -N -w 90 10.0.0.2 6666" \
    >/dev/null 2>&1 || true
# wait for nc server to close (client sends FIN)
wait "$NC_PID" 2>/dev/null
BULK_END_MS=$(date +%s%3N)
BULK_BYTES_RECV=$(wc -c < "$RUN_TMP/bulk.recv" 2>/dev/null; true)
BULK_ELAPSED_MS=$((BULK_END_MS - BULK_START_MS))

# Phase 3: recovery pings B→A (opposite direction, checks both sides still talk).
PING_OUT_B=$(ip netns exec "$NS_B" \
    ping -c "$RECOVERY_PINGS" -i "$INTERACTIVE_INTERVAL" -s "$PING_SIZE" -W 20 10.0.0.1 2>&1)

T_END_EPOCH=$(date +%s)

# ── Metric extraction ──────────────────────────────────────────────────────
extract_ping() {
    # Emit: sent received loss_pct rtt_min_ms rtt_avg_ms rtt_max_ms
    # Parses the "--- ping statistics ---" block of iputils-ping.  Computes
    # loss from sent/recv directly to avoid locale/format quirks with the
    # percentage column (newer iputils uses "16.67% packet loss" which
    # broke a literal regex on the % field).
    local out="$1"
    local sent rec loss rttmin rttavg rttmax
    local statsline rttline
    statsline=$(echo "$out" | grep -E '^[0-9]+ packets transmitted' | tail -1)
    sent=$(echo "$statsline" | awk '{print $1}')
    rec=$(echo "$statsline" | awk -F',' '{print $2}' | awk '{print $1}')
    [[ -z "$sent" || ! "$sent" =~ ^[0-9]+$ ]] && sent=0
    [[ -z "$rec"  || ! "$rec"  =~ ^[0-9]+$ ]] && rec=0
    if (( sent > 0 )); then
        # Integer percentage loss.  Rounds down.
        loss=$(( 100 - (100 * rec / sent) ))
    else
        loss=100
    fi
    rttline=$(echo "$out" | grep -E 'min/avg/max' | tail -1)
    if [[ -n "$rttline" ]]; then
        # Extract the 4 numbers between "= " and " ms".  Works with or
        # without the trailing ", pipe N" ping suffix.
        local rttnums
        rttnums=$(echo "$rttline" | sed -nE 's|.*= *([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+).*|\1 \2 \3 \4|p')
        if [[ -n "$rttnums" ]]; then
            read -r rttmin rttavg rttmax _ <<<"$rttnums"
        fi
    fi
    printf '%s %s %s %s %s %s\n' \
        "${sent:-0}" "${rec:-0}" "${loss:-100}" \
        "${rttmin:-0}" "${rttavg:-0}" "${rttmax:-0}"
}

read -r A_SENT A_RECV A_LOSS A_RTT_MIN A_RTT_AVG A_RTT_MAX <<<"$(extract_ping "$PING_OUT_A")"
read -r B_SENT B_RECV B_LOSS B_RTT_MIN B_RTT_AVG B_RTT_MAX <<<"$(extract_ping "$PING_OUT_B")"

# Direwolf log events — simple counts.
# [0L] = local TX event; [0.1] = RX from the air (valid frame).
# "Transmit channel busy" means CSMA deferred a TX — an indirect
# indicator of how often the CSMA logic inhibits a keying attempt.
tx_705=$(grep -c '^\[0L\]'   "$LOG_705"  2>/dev/null; true)
rx_705=$(grep -c '^\[0\.1\]' "$LOG_705"  2>/dev/null; true)
busy_705=$(grep -c 'channel busy' "$LOG_705" 2>/dev/null; true)
tx_7300=$(grep -c '^\[0L\]'   "$LOG_7300" 2>/dev/null; true)
rx_7300=$(grep -c '^\[0\.1\]' "$LOG_7300" 2>/dev/null; true)
busy_7300=$(grep -c 'channel busy' "$LOG_7300" 2>/dev/null; true)

# FX.25 correction activity (non-zero hex after "FX.25") — FEC kicked in.
fx25_705=$(grep -cE 'FX\.25 +[0-9a-fA-F]{4}' "$LOG_705" 2>/dev/null; true)
fx25_7300=$(grep -cE 'FX\.25 +[0-9a-fA-F]{4}' "$LOG_7300" 2>/dev/null; true)

# "Collision proxy": frames one side transmitted that the other side did
# not receive.  TX_A - RX_B should be close to 0 on a clean channel.
# Negative value means B received frames A didn't claim to send — usually
# the warmup is still bleeding in; clamp to zero.
lost_a_to_b=$(( tx_705  - rx_7300 )); ((lost_a_to_b < 0)) && lost_a_to_b=0
lost_b_to_a=$(( tx_7300 - rx_705  )); ((lost_b_to_a < 0)) && lost_b_to_a=0
tx_total=$((tx_705 + tx_7300))
lost_total=$((lost_a_to_b + lost_b_to_a))
if (( tx_total > 0 )); then
    frame_loss_pct=$(( 100 * lost_total / tx_total ))
else
    frame_loss_pct=0
fi

# Bulk transfer throughput.
if (( BULK_ELAPSED_MS > 0 )); then
    BULK_BPS=$(( BULK_BYTES_RECV * 8 * 1000 / BULK_ELAPSED_MS ))
else
    BULK_BPS=0
fi
BULK_SUCCESS=$([[ "$BULK_BYTES_RECV" -eq "$BULK_BYTES" ]] && echo true || echo false)

# ── Emit JSON ───────────────────────────────────────────────────────────────
[[ -z "$OUT_JSON" ]] && OUT_JSON="$TUNE_DIR/run-$RUN_ID.json"
cat > "$OUT_JSON" <<EOF
{
  "run_id": "$RUN_ID",
  "tag": "$TAG",
  "timestamp_start": $T_START_EPOCH,
  "timestamp_end": $T_END_EPOCH,
  "elapsed_s": $((T_END_EPOCH - T_START_EPOCH)),
  "params": {
    "dwait_ic7300": $DWAIT_A,
    "dwait_ic705":  $DWAIT_B,
    "persist":      $PERSIST,
    "slottime":     $SLOTTIME,
    "txdelay":      $TXDELAY
  },
  "workload": {
    "interactive_pings": $INTERACTIVE_PINGS,
    "interactive_interval_s": $INTERACTIVE_INTERVAL,
    "bulk_bytes": $BULK_BYTES,
    "recovery_pings": $RECOVERY_PINGS,
    "ping_size": $PING_SIZE
  },
  "ping_a_to_b": {
    "sent": $A_SENT, "recv": $A_RECV, "loss_pct": $A_LOSS,
    "rtt_min_ms": $A_RTT_MIN, "rtt_avg_ms": $A_RTT_AVG, "rtt_max_ms": $A_RTT_MAX
  },
  "ping_b_to_a": {
    "sent": $B_SENT, "recv": $B_RECV, "loss_pct": $B_LOSS,
    "rtt_min_ms": $B_RTT_MIN, "rtt_avg_ms": $B_RTT_AVG, "rtt_max_ms": $B_RTT_MAX
  },
  "bulk": {
    "bytes_sent": $BULK_BYTES,
    "bytes_recv": $BULK_BYTES_RECV,
    "elapsed_ms": $BULK_ELAPSED_MS,
    "bps": $BULK_BPS,
    "success": $BULK_SUCCESS
  },
  "direwolf": {
    "ic705":  { "tx": $tx_705,  "rx": $rx_705,  "busy_deferrals": $busy_705,  "fx25_events": $fx25_705 },
    "ic7300": { "tx": $tx_7300, "rx": $rx_7300, "busy_deferrals": $busy_7300, "fx25_events": $fx25_7300 }
  },
  "derived": {
    "frames_lost_a_to_b": $lost_a_to_b,
    "frames_lost_b_to_a": $lost_b_to_a,
    "frame_loss_pct": $frame_loss_pct
  }
}
EOF

echo "$OUT_JSON"
