#!/usr/bin/env bash
# ardop-test.sh — Connectivity tests for the ARDOP RF radio link
#
# Usage: sudo ./scripts/ardop-test.sh [--count N] [--interval S]
#   --count N     number of ping packets each direction (default: 5)
#   --interval S  ping interval in seconds (default: 12)
#
# NOTE: 4PSK.2000.100 frame time ~4.5s + POST_TX_YIELD 2s + holdoffs → RTT ~12s.
# Use --interval >= 15 to stay safely below RTT with the yield overhead.

set -euo pipefail

COUNT=5
INTERVAL=15

while [[ $# -gt 0 ]]; do
    case "$1" in
        --count|-c)    COUNT="$2";    shift 2 ;;
        --interval|-i) INTERVAL="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

pass=0
fail=0

run_test() {
    local desc="$1"; shift
    printf "  %-55s " "$desc"
    if "$@" &>/dev/null; then
        echo "PASS"
        (( pass++ )) || true
    else
        echo "FAIL"
        (( fail++ )) || true
    fi
}

echo "==> Interface check"
run_test "tnc0 exists in ns_a"       ip netns exec ns_a ip link show tnc0
run_test "tnc1 exists in ns_b"       ip netns exec ns_b ip link show tnc1
run_test "tnc0 has address 10.0.0.1" bash -c "ip netns exec ns_a ip addr show tnc0 | grep -q 10.0.0.1"
run_test "tnc1 has address 10.0.0.2" bash -c "ip netns exec ns_b ip addr show tnc1 | grep -q 10.0.0.2"

echo ""
echo "==> ardopcf port check"
run_test "IC-705  ardopcf cmd port 8515"  bash -c "ss -tlnp | grep -q :8515"
run_test "IC-705  ardopcf data port 8516" bash -c "ss -tlnp | grep -q :8516"
run_test "IC-7300 ardopcf cmd port 8615"  bash -c "ss -tlnp | grep -q :8615"
run_test "IC-7300 ardopcf data port 8616" bash -c "ss -tlnp | grep -q :8616"

echo ""
echo "==> ARDOP-KISS bridge KISS port check"
run_test "IC-705  KISS port 8511 (bridge output)" bash -c "ss -tlnp | grep -q :8511"
run_test "IC-7300 KISS port 8611 (bridge output)" bash -c "ss -tlnp | grep -q :8611"

echo ""
echo "==> Serial / PTT device check"
run_test "/dev/ic_705_b present (bridge PTT)" test -e /dev/ic_705_b
run_test "/dev/ic_7300 present"              test -e /dev/ic_7300

echo ""
echo "==> Ping A→B  (ns_a 10.0.0.1 → 10.0.0.2, ${COUNT} packets, interval ${INTERVAL}s)"
ip netns exec ns_a ping -c "$COUNT" -i "$INTERVAL" -W 30 10.0.0.2
echo ""

echo "==> Ping B→A  (ns_b 10.0.0.2 → 10.0.0.1, ${COUNT} packets, interval ${INTERVAL}s)"
ip netns exec ns_b ping -c "$COUNT" -i "$INTERVAL" -W 30 10.0.0.1
echo ""

echo "-------------------------------------------"
if (( fail == 0 )); then
    echo "All pre-flight checks passed."
else
    echo "Pre-flight: $pass passed, $fail failed."
fi
