#!/usr/bin/env bash
# setup.sh — Start the direwolf-tcp test framework
#
# Creates two PulseAudio/PipeWire virtual audio sinks, launches two
# Direwolf instances, routes their audio streams via pactl, then
# attaches tncattach network interfaces tnc0 (10.0.0.1) and tnc1 (10.0.0.2).
#
# Usage: sudo ./scripts/setup.sh
#        (sudo required for tncattach and ifconfig)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
TNCATTACH="$ROOT/tncattach/tncattach"
LOG_DIR="$ROOT/logs"
PIDFILE="$ROOT/logs/pids"

# --- Sanity checks -----------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root (sudo ./scripts/setup.sh)" >&2
    exit 1
fi

if [[ ! -x "$TNCATTACH" ]]; then
    echo "ERROR: tncattach binary not found at $TNCATTACH" >&2
    echo "       Run:  cd tncattach && make" >&2
    exit 1
fi

for cmd in direwolf pactl ifconfig; do
    command -v "$cmd" &>/dev/null || { echo "ERROR: '$cmd' not found in PATH" >&2; exit 1; }
done

mkdir -p "$LOG_DIR"
> "$PIDFILE"

# NOTE: pactl must run as the user who owns the PipeWire session.
# When this script runs under sudo, XDG_RUNTIME_DIR belongs to the
# original user — resolve that here, before any pactl calls.
REAL_USER="${SUDO_USER:-$USER}"
REAL_UID=$(id -u "$REAL_USER")
export XDG_RUNTIME_DIR="/run/user/$REAL_UID"
PACTL_AS_USER="sudo -u $REAL_USER XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR pactl"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Wait up to $3 seconds for a condition (command in $2) to be true
wait_for() {
    local desc="$1" cmd="$2" timeout="${3:-15}"
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

# Return sink-input ID(s) for a given PID
sink_input_for_pid() {
    local pid="$1"
    $PACTL_AS_USER list sink-inputs | awk -v pid="\"$pid\"" '
        /^Sink Input #/ { id = substr($3, 2) }
        /application\.process\.id/ && index($0, pid) { print id }
    '
}

# Return source-output ID(s) for a given PID
source_output_for_pid() {
    local pid="$1"
    $PACTL_AS_USER list source-outputs | awk -v pid="\"$pid\"" '
        /^Source Output #/ { id = substr($3, 2) }
        /application\.process\.id/ && index($0, pid) { print id }
    '
}

# ---------------------------------------------------------------------------
# Step 1: Virtual audio sinks
# ---------------------------------------------------------------------------
echo "==> Creating virtual audio sinks..."

# Unload any leftover sinks from a previous run
$PACTL_AS_USER list short modules | awk '/module-null-sink.*dw_[ab]_to_[ab]/ {print $1}' \
    | xargs -r -I{} $PACTL_AS_USER unload-module {}

$PACTL_AS_USER load-module module-null-sink \
    sink_name=dw_a_to_b rate=44100 \
    sink_properties=device.description="DW_A_to_B" > /dev/null

$PACTL_AS_USER load-module module-null-sink \
    sink_name=dw_b_to_a rate=44100 \
    sink_properties=device.description="DW_B_to_A" > /dev/null

wait_for "dw_a_to_b sink visible" "$PACTL_AS_USER list short sinks | grep -q dw_a_to_b"
wait_for "dw_b_to_a sink visible" "$PACTL_AS_USER list short sinks | grep -q dw_b_to_a"

echo "  Sinks: dw_a_to_b  dw_b_to_a"
echo "  Monitors: dw_a_to_b.monitor  dw_b_to_a.monitor"

# ---------------------------------------------------------------------------
# Step 2: Direwolf A
# ---------------------------------------------------------------------------
echo ""
echo "==> Starting Direwolf A (KISS port 8001, AGW port 8000)..."

sudo -u "$REAL_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    direwolf -c "$ROOT/config/dw-a.conf" \
    > "$LOG_DIR/dw-a.log" 2>&1 &
DW_A_PID=$!
echo "$DW_A_PID" >> "$PIDFILE"

wait_for "Direwolf A KISS port 8001" "ss -tlnp | grep -q :8001"

# Route Direwolf A audio: TX → dw_a_to_b, RX ← dw_b_to_a.monitor
echo "  Routing Direwolf A audio..."
sleep 1   # give ALSA streams a moment to register in PipeWire

SI_A=$(sink_input_for_pid "$DW_A_PID")
SO_A=$(source_output_for_pid "$DW_A_PID")

if [[ -z "$SI_A" || -z "$SO_A" ]]; then
    echo "ERROR: Could not find PipeWire streams for Direwolf A (PID $DW_A_PID)" >&2
    echo "  Sink inputs:"  >&2
    $PACTL_AS_USER list sink-inputs | grep -E "Sink Input|process.id" >&2
    echo "  Source outputs:" >&2
    $PACTL_AS_USER list source-outputs | grep -E "Source Output|process.id" >&2
    exit 1
fi

$PACTL_AS_USER move-sink-input "$SI_A" dw_a_to_b
$PACTL_AS_USER move-source-output "$SO_A" dw_b_to_a.monitor
echo "  Sink-input $SI_A → dw_a_to_b (TX)"
echo "  Source-output $SO_A → dw_b_to_a.monitor (RX)"

# ---------------------------------------------------------------------------
# Step 3: Direwolf B
# ---------------------------------------------------------------------------
echo ""
echo "==> Starting Direwolf B (KISS port 8002, AGW port 8010)..."

sudo -u "$REAL_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    direwolf -c "$ROOT/config/dw-b.conf" \
    > "$LOG_DIR/dw-b.log" 2>&1 &
DW_B_PID=$!
echo "$DW_B_PID" >> "$PIDFILE"

wait_for "Direwolf B KISS port 8002" "ss -tlnp | grep -q :8002"

echo "  Routing Direwolf B audio..."
sleep 1

SI_B=$(sink_input_for_pid "$DW_B_PID")
SO_B=$(source_output_for_pid "$DW_B_PID")

if [[ -z "$SI_B" || -z "$SO_B" ]]; then
    echo "ERROR: Could not find PipeWire streams for Direwolf B (PID $DW_B_PID)" >&2
    exit 1
fi

$PACTL_AS_USER move-sink-input "$SI_B" dw_b_to_a
$PACTL_AS_USER move-source-output "$SO_B" dw_a_to_b.monitor
echo "  Sink-input $SI_B → dw_b_to_a (TX)"
echo "  Source-output $SO_B → dw_a_to_b.monitor (RX)"

# ---------------------------------------------------------------------------
# Step 4: tncattach network interfaces
# ---------------------------------------------------------------------------
echo ""
echo "==> Attaching tncattach interfaces..."

wait_for "KISS port 8001 ready for connection" "ss -tlnp | grep -q :8001"
wait_for "KISS port 8002 ready for connection" "ss -tlnp | grep -q :8002"

"$TNCATTACH" -T -H localhost -P 8001 --mtu 236 --noipv6 --noup &
TNCA_PID=$!
echo "$TNCA_PID" >> "$PIDFILE"

sleep 1
wait_for "tnc0 interface exists" "ip link show tnc0"

ifconfig tnc0 10.0.0.1 pointopoint 10.0.0.2 netmask 255.255.255.252 up
echo "  tnc0: 10.0.0.1 ↔ 10.0.0.2  (via KISS port 8001 / Direwolf A)"

"$TNCATTACH" -T -H localhost -P 8002 --mtu 236 --noipv6 --noup &
TNCB_PID=$!
echo "$TNCB_PID" >> "$PIDFILE"

sleep 1
wait_for "tnc1 interface exists" "ip link show tnc1"

ifconfig tnc1 10.0.0.2 pointopoint 10.0.0.1 netmask 255.255.255.252 up
echo "  tnc1: 10.0.0.2 ↔ 10.0.0.1  (via KISS port 8002 / Direwolf B)"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "==> Setup complete."
echo ""
echo "    tnc0  10.0.0.1/30  (Direwolf A, PID $DW_A_PID)"
echo "    tnc1  10.0.0.2/30  (Direwolf B, PID $DW_B_PID)"
echo ""
echo "    Test:  sudo ./scripts/test.sh"
echo "    Stop:  sudo ./scripts/teardown.sh"
echo ""
echo "    Logs:  $LOG_DIR/dw-a.log"
echo "           $LOG_DIR/dw-b.log"
