#!/usr/bin/env bash
# ardop-setup.sh — Start the RF radio link using ARDOP instead of Direwolf
#
# Architecture:
#   radio ←audio/PTT→ ardopcf ←TCP host protocol→ ardop_kiss_bridge ←KISS/TCP→ tncattach ←TAP→ ns_X
#
# Port assignments:
#   IC-705  ardopcf: cmd 8515, data 8516 | bridge KISS output: 8511
#   IC-7300 ardopcf: cmd 8615, data 8616 | bridge KISS output: 8611
#
# Usage: sudo ./scripts/ardop-setup.sh [--fecmode MODE]
#   MODE defaults to 4PSK.2000.100 (~2000 bps, ~2kHz BW — comparable to current Direwolf 2400 QPSK)
#   Other useful modes: 4PSK.500.100 (500Hz BW, more robust), 8PSK.1000.100 (1kHz BW)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
ARDOPCF="$ROOT/ardopcf/ardopcf"
BRIDGE="$ROOT/scripts/ardop_kiss_bridge.py"
TNCATTACH="$ROOT/tncattach/tncattach"
LOG_DIR="$ROOT/logs"
PIDFILE="$ROOT/logs/ardop-pids"
FECMODE="4PSK.2000.100"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fecmode) FECMODE="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root (sudo ./scripts/ardop-setup.sh)" >&2
    exit 1
fi

if [[ ! -x "$ARDOPCF" ]]; then
    echo "ERROR: ardopcf binary not found at $ARDOPCF" >&2
    echo "       Run:  cd ardopcf && make" >&2
    exit 1
fi

if [[ ! -f "$BRIDGE" ]]; then
    echo "ERROR: ardop_kiss_bridge.py not found at $BRIDGE" >&2
    exit 1
fi

if [[ ! -x "$TNCATTACH" ]]; then
    echo "ERROR: tncattach binary not found at $TNCATTACH" >&2
    echo "       Run:  cd tncattach && make" >&2
    exit 1
fi

for cmd in python3 ifconfig ss; do
    command -v "$cmd" &>/dev/null || { echo "ERROR: '$cmd' not found in PATH" >&2; exit 1; }
done

for dev in /dev/ic_705_b /dev/ic_7300; do
    [[ -e "$dev" ]] || { echo "ERROR: device $dev not found" >&2; exit 1; }
done

REAL_USER="${SUDO_USER:-$USER}"
REAL_UID=$(id -u "$REAL_USER")

mkdir -p "$LOG_DIR"
> "$PIDFILE"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

wait_for() {
    local desc="$1" cmd="$2" timeout="${3:-20}"
    local elapsed=0
    while ! eval "$cmd" &>/dev/null; do
        sleep 0.5
        elapsed=$(( elapsed + 1 ))
        if (( elapsed >= timeout * 2 )); then
            echo "ERROR: Timed out waiting for: $desc" >&2
            exit 1
        fi
    done
    echo "  OK: $desc"
}

# ---------------------------------------------------------------------------
# Step 1: ardopcf for IC-705
# No PTT flag — ardopcf sends "PTT TRUE"/"PTT FALSE" to the host (bridge).
# The bridge handles PTT via pyserial RTS on ic_705_b (the IC-705 data port).
# pyserial sets DTR=True on open, which CDC-ACM USB devices require before
# responding to RTS changes.  ardopcf's OpenCOMPort uses O_NDELAY and clears
# DTR, causing the IC-705 to ignore its own RTS assertions.
# ---------------------------------------------------------------------------
echo "==> Starting ardopcf IC-705 (cmd 8515, data 8516, bridge PTT)..."

sudo -u "$REAL_USER" \
    "$ARDOPCF" \
    --logdir "$LOG_DIR" \
    8515 \
    plughw:CARD=CODEC_705,DEV=0 \
    plughw:CARD=CODEC_705,DEV=0 \
    > "$LOG_DIR/ardop-705.log" 2>&1 &

ARDOP_705_PID=$!
echo "$ARDOP_705_PID" >> "$PIDFILE"
echo "  ardopcf IC-705 PID: $ARDOP_705_PID"

wait_for "IC-705 ardopcf cmd port 8515" "ss -tlnp | grep -q :8515"

# ---------------------------------------------------------------------------
# Step 2: ardopcf for IC-7300 — same bridge PTT approach for consistency.
# ---------------------------------------------------------------------------
echo ""
echo "==> Starting ardopcf IC-7300 (cmd 8615, data 8616, bridge PTT)..."

sudo -u "$REAL_USER" \
    "$ARDOPCF" \
    --logdir "$LOG_DIR" \
    8615 \
    plughw:CARD=CODEC_7300,DEV=0 \
    plughw:CARD=CODEC_7300,DEV=0 \
    > "$LOG_DIR/ardop-7300.log" 2>&1 &

ARDOP_7300_PID=$!
echo "$ARDOP_7300_PID" >> "$PIDFILE"
echo "  ardopcf IC-7300 PID: $ARDOP_7300_PID"

wait_for "IC-7300 ardopcf cmd port 8615" "ss -tlnp | grep -q :8615"

# ---------------------------------------------------------------------------
# Step 3: ARDOP-KISS bridge for IC-705
# ---------------------------------------------------------------------------
echo ""
echo "==> Starting ARDOP-KISS bridge IC-705 (ardopcf 8515 → KISS 8511)..."

sudo -u "$REAL_USER" \
    python3 "$BRIDGE" \
    --ardop-port 8515 \
    --kiss-port  8511 \
    --callsign   KD2MYS-5 \
    --fecmode    "$FECMODE" \
    --ptt-port   /dev/ic_705_b \
    > "$LOG_DIR/bridge-705.log" 2>&1 &

BRIDGE_705_PID=$!
echo "$BRIDGE_705_PID" >> "$PIDFILE"
echo "  bridge IC-705 PID: $BRIDGE_705_PID"

wait_for "IC-705 KISS port 8511" "ss -tlnp | grep -q :8511"

# ---------------------------------------------------------------------------
# Step 4: ARDOP-KISS bridge for IC-7300
# ---------------------------------------------------------------------------
echo ""
echo "==> Starting ARDOP-KISS bridge IC-7300 (ardopcf 8615 → KISS 8611)..."

sudo -u "$REAL_USER" \
    python3 "$BRIDGE" \
    --ardop-port 8615 \
    --kiss-port  8611 \
    --callsign   KD2MYS-6 \
    --fecmode    "$FECMODE" \
    --ptt-port   /dev/ic_7300 \
    > "$LOG_DIR/bridge-7300.log" 2>&1 &

BRIDGE_7300_PID=$!
echo "$BRIDGE_7300_PID" >> "$PIDFILE"
echo "  bridge IC-7300 PID: $BRIDGE_7300_PID"

wait_for "IC-7300 KISS port 8611" "ss -tlnp | grep -q :8611"

# ---------------------------------------------------------------------------
# Step 5: Network namespaces
# ---------------------------------------------------------------------------
echo ""
echo "==> Creating network namespaces..."

ip netns del ns_a 2>/dev/null || true
ip netns del ns_b 2>/dev/null || true
ip netns add ns_a
ip netns add ns_b
ip netns exec ns_a ip link set lo up
ip netns exec ns_b ip link set lo up

# ---------------------------------------------------------------------------
# Step 6: tncattach — IC-705 → ns_a (tnc0 / 10.0.0.1)
# ---------------------------------------------------------------------------
echo ""
echo "==> Attaching tncattach for IC-705 (KISS 8511 → tnc0 → ns_a)..."

"$TNCATTACH" -T -H localhost -P 8511 --mtu 508 --noipv6 --noup &
TNCA_PID=$!
echo "$TNCA_PID" >> "$PIDFILE"

wait_for "tnc0 created in host namespace" "ip link show tnc0"
ip link set tnc0 netns ns_a
ip netns exec ns_a \
    ifconfig tnc0 10.0.0.1 pointopoint 10.0.0.2 netmask 255.255.255.252 up
echo "  tnc0: 10.0.0.1 ↔ 10.0.0.2  [ns_a]  (ARDOP 8511 / IC-705 KD2MYS-5)"

# ---------------------------------------------------------------------------
# Step 7: tncattach — IC-7300 → ns_b (tnc1 / 10.0.0.2)
# ---------------------------------------------------------------------------
echo ""
echo "==> Attaching tncattach for IC-7300 (KISS 8611 → tnc1 → ns_b)..."

"$TNCATTACH" -T -H localhost -P 8611 --mtu 508 --noipv6 --noup &
TNCB_PID=$!
echo "$TNCB_PID" >> "$PIDFILE"

wait_for "tnc0 created in host namespace (7300)" "ip link show tnc0"
ip link set tnc0 netns ns_b
ip netns exec ns_b ip link set tnc0 name tnc1
ip netns exec ns_b \
    ifconfig tnc1 10.0.0.2 pointopoint 10.0.0.1 netmask 255.255.255.252 up
echo "  tnc1: 10.0.0.2 ↔ 10.0.0.1  [ns_b]  (ARDOP 8611 / IC-7300 KD2MYS-6)"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "==> ARDOP RF setup complete."
echo ""
echo "    ns_a / tnc0  10.0.0.1/30  (IC-705,  ardopcf PID $ARDOP_705_PID)"
echo "    ns_b / tnc1  10.0.0.2/30  (IC-7300, ardopcf PID $ARDOP_7300_PID)"
echo "    FEC mode: $FECMODE"
echo ""
echo "    Test:   sudo ./scripts/ardop-test.sh"
echo "    Stop:   sudo ./scripts/ardop-teardown.sh"
echo ""
echo "    Logs:"
echo "      $LOG_DIR/ardop-705.log   (ardopcf IC-705)"
echo "      $LOG_DIR/ardop-7300.log  (ardopcf IC-7300)"
echo "      $LOG_DIR/bridge-705.log  (KISS bridge IC-705)"
echo "      $LOG_DIR/bridge-7300.log (KISS bridge IC-7300)"
