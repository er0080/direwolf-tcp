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

# Return IDs present in current stream list that are NOT in $2 (before-snapshot).
# Usage: new_stream_ids <sink-inputs|source-outputs> "$BEFORE_VAR"
new_stream_ids() {
    local type="$1" before="$2"
    $PACTL_AS_USER list short "$type" | awk '{print $1}' | while read -r id; do
        echo "$before" | grep -qx "$id" || echo "$id"
    done
}

# ---------------------------------------------------------------------------
# Step 1: Virtual audio sinks
# ---------------------------------------------------------------------------
echo "==> Creating virtual audio sinks..."

# Unload any leftover sinks from a previous run
$PACTL_AS_USER list short modules | awk '/module-null-sink.*dw_[ab]_to_[ab]/ {print $1}' \
    | xargs -r -I{} $PACTL_AS_USER unload-module {}

$PACTL_AS_USER load-module module-null-sink \
    sink_name=dw_a_to_b rate=48000 \
    sink_properties=device.description="DW_A_to_B" > /dev/null

$PACTL_AS_USER load-module module-null-sink \
    sink_name=dw_b_to_a rate=48000 \
    sink_properties=device.description="DW_B_to_A" > /dev/null

wait_for "dw_a_to_b sink visible" "$PACTL_AS_USER list short sinks | grep -q dw_a_to_b"
wait_for "dw_b_to_a sink visible" "$PACTL_AS_USER list short sinks | grep -q dw_b_to_a"

# Reduce sink volume to prevent AFSK clipping.  At 100% the monitor output
# saturates Direwolf's input (level ~199); Direwolf recommends ~50.
# 25% brings the level into the target range.
$PACTL_AS_USER set-sink-volume dw_a_to_b 65%
$PACTL_AS_USER set-sink-volume dw_b_to_a 65%

echo "  Sinks: dw_a_to_b  dw_b_to_a"
echo "  Monitors: dw_a_to_b.monitor  dw_b_to_a.monitor"

# ---------------------------------------------------------------------------
# Step 2: Direwolf A
# ---------------------------------------------------------------------------
echo ""
echo "==> Starting Direwolf A (KISS port 8001, AGW port 8000)..."

# Snapshot existing streams before launch so we can identify new ones by diff
BEFORE_SI=$($PACTL_AS_USER list short sink-inputs    | awk '{print $1}')
BEFORE_SO=$($PACTL_AS_USER list short source-outputs | awk '{print $1}')

sudo -u "$REAL_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    direwolf -c "$ROOT/config/dw-a.conf" \
    > "$LOG_DIR/dw-a.log" 2>&1 &

wait_for "Direwolf A KISS port 8001" "ss -tlnp | grep -q :8001"

DW_A_PID=$(pgrep -n -u "$REAL_USER" direwolf)
echo "$DW_A_PID" >> "$PIDFILE"
echo "  Direwolf A PID: $DW_A_PID"

# Route Direwolf A audio: TX → dw_a_to_b, RX ← dw_b_to_a.monitor
echo "  Routing Direwolf A audio..."
sleep 1   # give ALSA streams a moment to register in PipeWire

SI_A=$(new_stream_ids sink-inputs    "$BEFORE_SI" | head -1)
SO_A=$(new_stream_ids source-outputs "$BEFORE_SO" | head -1)

if [[ -z "$SI_A" || -z "$SO_A" ]]; then
    echo "ERROR: Could not find new PipeWire streams for Direwolf A" >&2
    echo "  Sink inputs now:"    >&2; $PACTL_AS_USER list short sink-inputs    >&2
    echo "  Source outputs now:" >&2; $PACTL_AS_USER list short source-outputs >&2
    exit 1
fi

$PACTL_AS_USER move-sink-input   "$SI_A" dw_a_to_b
$PACTL_AS_USER move-source-output "$SO_A" dw_b_to_a.monitor
echo "  Sink-input $SI_A → dw_a_to_b (TX)"
echo "  Source-output $SO_A → dw_b_to_a.monitor (RX)"

# ---------------------------------------------------------------------------
# Step 3: Direwolf B
# ---------------------------------------------------------------------------
echo ""
echo "==> Starting Direwolf B (KISS port 8002, AGW port 8010)..."

# Snapshot again — A's streams are now "before" for the B diff
BEFORE_SI=$($PACTL_AS_USER list short sink-inputs    | awk '{print $1}')
BEFORE_SO=$($PACTL_AS_USER list short source-outputs | awk '{print $1}')

sudo -u "$REAL_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    direwolf -c "$ROOT/config/dw-b.conf" \
    > "$LOG_DIR/dw-b.log" 2>&1 &

wait_for "Direwolf B KISS port 8002" "ss -tlnp | grep -q :8002"

DW_B_PID=$(pgrep -n -u "$REAL_USER" direwolf)
echo "$DW_B_PID" >> "$PIDFILE"
echo "  Direwolf B PID: $DW_B_PID"

echo "  Routing Direwolf B audio..."
sleep 1

SI_B=$(new_stream_ids sink-inputs    "$BEFORE_SI" | head -1)
SO_B=$(new_stream_ids source-outputs "$BEFORE_SO" | head -1)

if [[ -z "$SI_B" || -z "$SO_B" ]]; then
    echo "ERROR: Could not find new PipeWire streams for Direwolf B" >&2
    echo "  Sink inputs now:"    >&2; $PACTL_AS_USER list short sink-inputs    >&2
    echo "  Source outputs now:" >&2; $PACTL_AS_USER list short source-outputs >&2
    exit 1
fi

$PACTL_AS_USER move-sink-input    "$SI_B" dw_b_to_a
$PACTL_AS_USER move-source-output "$SO_B" dw_a_to_b.monitor
echo "  Sink-input $SI_B → dw_b_to_a (TX)"
echo "  Source-output $SO_B → dw_a_to_b.monitor (RX)"

# ---------------------------------------------------------------------------
# Step 4: Network namespaces + tncattach
#
# Both tnc0 (10.0.0.1) and tnc1 (10.0.0.2) share the same /30 subnet on a
# single host.  Without isolation, the kernel short-circuits ICMP replies
# via local delivery — the reply to 10.0.0.1 never traverses the virtual
# radio chain back to tnc0, causing 100% packet loss.
#
# Fix: run tncattach normally (host namespace, localhost KISS connection),
# then move each tnc interface into its own network namespace.  TAP file
# descriptors remain valid across namespace moves, so tncattach keeps
# reading/writing packets without any changes to its own code or startup.
# The isolated routing table in each namespace has no conflicting LOCAL
# entries, so replies route correctly through the full audio chain.
# ---------------------------------------------------------------------------
echo ""
echo "==> Creating network namespaces and attaching tncattach..."

wait_for "KISS port 8001 ready for connection" "ss -tlnp | grep -q :8001"
wait_for "KISS port 8002 ready for connection" "ss -tlnp | grep -q :8002"

# Clean up any leftover namespaces from a previous run
ip netns del ns_a 2>/dev/null || true
ip netns del ns_b 2>/dev/null || true
ip netns add ns_a
ip netns add ns_b
ip netns exec ns_a ip link set lo up
ip netns exec ns_b ip link set lo up

# --- tncattach A: connect to localhost, then move tnc0 into ns_a ---
"$TNCATTACH" -T -H localhost -P 8001 --mtu 236 --noipv6 --noup &
TNCA_PID=$!
echo "$TNCA_PID" >> "$PIDFILE"

wait_for "tnc0 created in host namespace" "ip link show tnc0"
ip link set tnc0 netns ns_a
ip netns exec ns_a \
    ifconfig tnc0 10.0.0.1 pointopoint 10.0.0.2 netmask 255.255.255.252 up
echo "  tnc0: 10.0.0.1 ↔ 10.0.0.2  [ns_a]  (KISS port 8001 / Direwolf A)"

# --- tncattach B: connect to localhost, then move tnc into ns_b ---
# After tnc0 was moved to ns_a, the host namespace has no tnc0, so
# tncattach B will create tnc0 again.  Move it to ns_b and rename it tnc1.
"$TNCATTACH" -T -H localhost -P 8002 --mtu 236 --noipv6 --noup &
TNCB_PID=$!
echo "$TNCB_PID" >> "$PIDFILE"

wait_for "tnc0 created in host namespace (for B)" "ip link show tnc0"
ip link set tnc0 netns ns_b
ip netns exec ns_b ip link set tnc0 name tnc1
ip netns exec ns_b \
    ifconfig tnc1 10.0.0.2 pointopoint 10.0.0.1 netmask 255.255.255.252 up
echo "  tnc1: 10.0.0.2 ↔ 10.0.0.1  [ns_b]  (KISS port 8002 / Direwolf B)"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "==> Setup complete."
echo ""
echo "    ns_a / tnc0  10.0.0.1/30  (Direwolf A, PID $DW_A_PID)"
echo "    ns_b / tnc1  10.0.0.2/30  (Direwolf B, PID $DW_B_PID)"
echo ""
echo "    Test:  sudo ./scripts/test.sh"
echo "    Stop:  sudo ./scripts/teardown.sh"
echo ""
echo "    Logs:  $LOG_DIR/dw-a.log"
echo "           $LOG_DIR/dw-b.log"
