#!/usr/bin/env bash
# ardop-teardown.sh — Stop the ARDOP RF radio link
#
# Usage: sudo ./scripts/ardop-teardown.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
PIDFILE="$ROOT/logs/ardop-pids"

echo "==> Tearing down ARDOP RF link..."

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
pkill -x tncattach       2>/dev/null && echo "  Killed remaining tncattach processes" || true
pkill -f ardop_kiss_bridge 2>/dev/null && echo "  Killed remaining bridge processes"   || true
pkill -x ardopcf         2>/dev/null && echo "  Killed remaining ardopcf processes"   || true

sleep 0.5

# Remove network namespaces
for ns in ns_a ns_b; do
    if ip netns list | grep -q "^$ns"; then
        ip netns del "$ns" && echo "  Deleted namespace $ns"
    fi
done

echo "==> Done."
