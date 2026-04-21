#!/usr/bin/env bash
# rf-test.sh — Connectivity tests for the RF radio link
#
# Usage: sudo ./scripts/rf-test.sh [--count N]  (default: 5 pings each direction)

set -euo pipefail

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
run_test "tnc0 exists in ns_a"       ip netns exec ns_a ip link show tnc0
run_test "tnc1 exists in ns_b"       ip netns exec ns_b ip link show tnc1
run_test "tnc0 has address 10.0.0.1" bash -c "ip netns exec ns_a ip addr show tnc0 | grep -q 10.0.0.1"
run_test "tnc1 has address 10.0.0.2" bash -c "ip netns exec ns_b ip addr show tnc1 | grep -q 10.0.0.2"

echo ""
echo "==> KISS port check"
run_test "IC-705  KISS port 8001 listening" bash -c "ss -tlnp | grep -q :8001"
run_test "IC-7300 KISS port 8101 listening" bash -c "ss -tlnp | grep -q :8101"

echo ""
echo "==> Serial / PTT device check"
run_test "/dev/ic_705_b present"  test -e /dev/ic_705_b
run_test "/dev/ic_7300 present"   test -e /dev/ic_7300

echo ""
echo "==> Ping A→B  (ns_a 10.0.0.1 → 10.0.0.2, ${COUNT} packets)"
ip netns exec ns_a ping -c "$COUNT" -W 15 10.0.0.2
echo ""

echo "==> Ping B→A  (ns_b 10.0.0.2 → 10.0.0.1, ${COUNT} packets)"
ip netns exec ns_b ping -c "$COUNT" -W 15 10.0.0.1
echo ""

echo "-------------------------------------------"
if (( fail == 0 )); then
    echo "All pre-flight checks passed."
else
    echo "Pre-flight: $pass passed, $fail failed."
fi
