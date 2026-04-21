#!/usr/bin/env bash
# rf-teardown.sh — Stop the RF radio link
#
# Usage: sudo ./scripts/rf-teardown.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
PIDFILE="$ROOT/logs/rf-pids"

echo "==> Tearing down RF link..."

# Kill tracked PIDs
if [[ -f "$PIDFILE" ]]; then
    while read -r pid; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" && echo "  Killed PID $pid"
        fi
    done < "$PIDFILE"
    rm -f "$PIDFILE"
fi

# Belt-and-suspenders
pkill -x tncattach 2>/dev/null && echo "  Killed remaining tncattach processes" || true
pkill -x direwolf   2>/dev/null && echo "  Killed remaining direwolf processes"  || true

sleep 0.5

# Remove network namespaces
for ns in ns_a ns_b; do
    if ip netns list | grep -q "^$ns"; then
        ip netns del "$ns" && echo "  Deleted namespace $ns"
    fi
done

echo "==> Done."
