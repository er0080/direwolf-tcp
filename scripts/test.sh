#!/usr/bin/env bash
# test.sh — Run connectivity tests over the virtual radio link
#
# Usage: sudo ./scripts/test.sh [--count N]  (default: 5 pings each direction)

set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_UID=$(id -u "$REAL_USER")
export XDG_RUNTIME_DIR="/run/user/$REAL_UID"
PACTL="sudo -u $REAL_USER XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR pactl"

COUNT=5
while [[ $# -gt 0 ]]; do
    case "$1" in
        --count|-c) COUNT="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

pass=0
fail=0

run_test() {
    local desc="$1"; shift
    printf "  %-50s " "$desc"
    if "$@" &>/dev/null; then
        echo "PASS"
        (( pass++ )) || true
    else
        echo "FAIL"
        (( fail++ )) || true
    fi
}

echo "==> Interface check"
run_test "tnc0 exists and is UP"  ip link show tnc0
run_test "tnc1 exists and is UP"  ip link show tnc1
run_test "tnc0 has address 10.0.0.1" ip addr show tnc0 | grep -q 10.0.0.1
run_test "tnc1 has address 10.0.0.2" ip addr show tnc1 | grep -q 10.0.0.2

echo ""
echo "==> KISS port check"
run_test "Direwolf A KISS port 8001 listening" ss -tlnp | grep -q :8001
run_test "Direwolf B KISS port 8002 listening" ss -tlnp | grep -q :8002

echo ""
echo "==> Audio routing check"
run_test "PipeWire sink dw_a_to_b present" bash -c "$PACTL list short sinks | grep -q dw_a_to_b"
run_test "PipeWire sink dw_b_to_a present" bash -c "$PACTL list short sinks | grep -q dw_b_to_a"

echo ""
echo "==> Ping A→B  (tnc0 10.0.0.1 → 10.0.0.2, ${COUNT} packets)"
ping -c "$COUNT" -W 10 -I tnc0 10.0.0.2
echo ""

echo "==> Ping B→A  (tnc1 10.0.0.2 → 10.0.0.1, ${COUNT} packets)"
ping -c "$COUNT" -W 10 -I tnc1 10.0.0.1
echo ""

echo "-------------------------------------------"
if (( fail == 0 )); then
    echo "All pre-flight checks passed."
else
    echo "Pre-flight: $pass passed, $fail failed."
fi
