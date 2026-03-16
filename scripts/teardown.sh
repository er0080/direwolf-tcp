#!/usr/bin/env bash
# teardown.sh — Stop the direwolf-tcp test framework
#
# Kills tncattach and direwolf processes, removes virtual audio sinks.
#
# Usage: sudo ./scripts/teardown.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
PIDFILE="$ROOT/logs/pids"

REAL_USER="${SUDO_USER:-$USER}"
REAL_UID=$(id -u "$REAL_USER")
export XDG_RUNTIME_DIR="/run/user/$REAL_UID"
PACTL_AS_USER="sudo -u $REAL_USER XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR pactl"

echo "==> Tearing down direwolf-tcp..."

# Kill tracked PIDs
if [[ -f "$PIDFILE" ]]; then
    while read -r pid; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" && echo "  Killed PID $pid"
        fi
    done < "$PIDFILE"
    rm -f "$PIDFILE"
fi

# Belt-and-suspenders: kill any remaining instances by name
pkill -x tncattach 2>/dev/null && echo "  Killed remaining tncattach processes" || true
pkill -x direwolf   2>/dev/null && echo "  Killed remaining direwolf processes"  || true

sleep 0.5

# Remove network namespaces (tnc interfaces are deleted with them)
for ns in ns_a ns_b; do
    if ip netns list | grep -q "^$ns"; then
        ip netns del "$ns" && echo "  Deleted namespace $ns"
    fi
done

# Remove virtual audio sinks
$PACTL_AS_USER list short modules \
    | awk '/module-null-sink.*dw_[ab]_to_[ab]/ {print $1}' \
    | while read -r mod; do
        $PACTL_AS_USER unload-module "$mod" && echo "  Unloaded PulseAudio module $mod"
    done

# Fallback: unload all module-null-sink instances named dw_*
for sink in dw_a_to_b dw_b_to_a; do
    if $PACTL_AS_USER list short sinks | grep -q "$sink"; then
        $PACTL_AS_USER unload-module module-null-sink 2>/dev/null || true
    fi
done

echo "==> Done."
