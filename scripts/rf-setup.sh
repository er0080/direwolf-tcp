#!/usr/bin/env bash
# rf-setup.sh — Start the RF radio link (IC-705 ↔ IC-7300)
#
# Launches two Direwolf instances against real radio hardware,
# creates network namespaces, and attaches tncattach interfaces.
# No PipeWire / virtual audio involved.
#
# Usage: sudo ./scripts/rf-setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
TNCATTACH="$ROOT/tncattach/tncattach"
LOG_DIR="$ROOT/logs"
PIDFILE="$ROOT/logs/rf-pids"

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root (sudo ./scripts/rf-setup.sh)" >&2
    exit 1
fi

if [[ ! -x "$TNCATTACH" ]]; then
    echo "ERROR: tncattach binary not found at $TNCATTACH" >&2
    echo "       Run:  cd tncattach && make" >&2
    exit 1
fi

for cmd in direwolf ifconfig ss; do
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

# ---------------------------------------------------------------------------
# Step 1: Direwolf for IC-705
# ---------------------------------------------------------------------------
echo "==> Starting Direwolf IC-705 (KISS port 8001, AGW port 8000)..."

sudo -u "$REAL_USER" \
    direwolf -c "$ROOT/config/dw-705.conf" \
    > "$LOG_DIR/dw-705.log" 2>&1 &

wait_for "IC-705 KISS port 8001" "ss -tlnp | grep -q :8001"

DW_705_PID=$(pgrep -n -u "$REAL_USER" direwolf)
echo "$DW_705_PID" >> "$PIDFILE"
echo "  Direwolf IC-705 PID: $DW_705_PID"

# ---------------------------------------------------------------------------
# Step 2: Direwolf for IC-7300
# ---------------------------------------------------------------------------
echo ""
echo "==> Starting Direwolf IC-7300 (KISS port 8101, AGW port 8100)..."

sudo -u "$REAL_USER" \
    direwolf -c "$ROOT/config/dw-7300.conf" \
    > "$LOG_DIR/dw-7300.log" 2>&1 &

wait_for "IC-7300 KISS port 8101" "ss -tlnp | grep -q :8101"

DW_7300_PID=$(pgrep -n -u "$REAL_USER" direwolf)
echo "$DW_7300_PID" >> "$PIDFILE"
echo "  Direwolf IC-7300 PID: $DW_7300_PID"

# ---------------------------------------------------------------------------
# Step 3: Network namespaces
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
# Step 4: tncattach — IC-705 → ns_a (tnc0 / 10.0.0.1)
#
# PACLEN 512 in dw-705.conf → --mtu 508 (PACLEN − 4)
# ---------------------------------------------------------------------------
echo ""
echo "==> Attaching tncattach for IC-705 (tnc0 → ns_a)..."

"$TNCATTACH" -T -H localhost -P 8001 --mtu 508 --noipv6 --noup &
TNCA_PID=$!
echo "$TNCA_PID" >> "$PIDFILE"

wait_for "tnc0 created in host namespace" "ip link show tnc0"
ip link set tnc0 netns ns_a
ip netns exec ns_a \
    ifconfig tnc0 10.0.0.1 pointopoint 10.0.0.2 netmask 255.255.255.252 up
echo "  tnc0: 10.0.0.1 ↔ 10.0.0.2  [ns_a]  (KISS 8001 / IC-705 KD2MYS-5)"

# ---------------------------------------------------------------------------
# Step 5: tncattach — IC-7300 → ns_b (tnc1 / 10.0.0.2)
# ---------------------------------------------------------------------------
echo ""
echo "==> Attaching tncattach for IC-7300 (tnc1 → ns_b)..."

"$TNCATTACH" -T -H localhost -P 8101 --mtu 508 --noipv6 --noup &
TNCB_PID=$!
echo "$TNCB_PID" >> "$PIDFILE"

wait_for "tnc0 created in host namespace (7300)" "ip link show tnc0"
ip link set tnc0 netns ns_b
ip netns exec ns_b ip link set tnc0 name tnc1
ip netns exec ns_b \
    ifconfig tnc1 10.0.0.2 pointopoint 10.0.0.1 netmask 255.255.255.252 up
echo "  tnc1: 10.0.0.2 ↔ 10.0.0.1  [ns_b]  (KISS 8101 / IC-7300 KD2MYS-6)"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "==> RF setup complete."
echo ""
echo "    ns_a / tnc0  10.0.0.1/30  (IC-705,  PID $DW_705_PID)"
echo "    ns_b / tnc1  10.0.0.2/30  (IC-7300, PID $DW_7300_PID)"
echo ""
echo "    Test:  sudo ./scripts/rf-test.sh"
echo "    Stop:  sudo ./scripts/rf-teardown.sh"
echo ""
echo "    Logs:  $LOG_DIR/dw-705.log"
echo "           $LOG_DIR/dw-7300.log"
