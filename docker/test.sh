#!/usr/bin/env bash
# docker/test.sh — integration tests: SSH, SCP, HTTP over the Direwolf link
#
# Requires: containers running (docker compose up -d)
# All tests execute inside node-a's network namespace so they route through
# the TNC interface — node-a has NO other network path to node-b.
#
# Exit codes: 0=all pass, 1=one or more fail, 2=setup error

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PEER_IP="10.0.0.2"
LINK_TIMEOUT=120    # seconds to wait for the Direwolf link to come up
TEST_TIMEOUT=90     # per-test timeout
PASS=0; FAIL=0

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
pass() { echo "  [PASS] $*"; (( PASS++ )) || true; }
fail() { echo "  [FAIL] $*"; (( FAIL++ )) || true; }

xec() {
    # Run command inside node-a with a timeout, return exit code
    local timeout="$1"; shift
    timeout "$timeout" docker exec dwiface-node-a "$@"
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
for ctr in dwiface-node-a dwiface-node-b; do
    docker inspect "$ctr" --format '{{.State.Running}}' 2>/dev/null | grep -q true \
        || { log "ERROR: $ctr is not running"; exit 2; }
done
log "both containers running"

# ── Wait for link ─────────────────────────────────────────────────────────────
log "waiting up to ${LINK_TIMEOUT}s for Direwolf link..."
linked=0
for i in $(seq 1 $(( LINK_TIMEOUT / 5 ))); do
    if xec 8 ping -c 1 -W 5 "$PEER_IP" &>/dev/null; then
        linked=1; break
    fi
    echo -n "."
    sleep 5
done
echo ""
(( linked )) || { log "TIMEOUT: link never came up — check direwolf logs"; exit 2; }
log "link up after ~$(( i * 5 ))s"

# ── Test 1: ICMP ping (10 packets) ───────────────────────────────────────────
log "--- ping ($PEER_IP, 10 packets) ---"
if xec "$TEST_TIMEOUT" ping -c 10 -W 20 -i 3 "$PEER_IP" 2>&1 \
        | tee /tmp/dw-ping.txt | grep -qE "^10 packets|0% packet loss"; then
    loss=$(grep -oP '\d+(?=% packet loss)' /tmp/dw-ping.txt || echo 100)
    rtt=$(grep -oP 'rtt[^=]+=\s*\K[0-9.]+' /tmp/dw-ping.txt | head -1 || echo "?")
    pass "ping: ${loss}% loss, avg RTT ${rtt}ms"
else
    loss=$(grep -oP '\d+(?=% packet loss)' /tmp/dw-ping.txt 2>/dev/null || echo "?")
    fail "ping: ${loss}% packet loss"
fi

# ── Test 2: SSH ───────────────────────────────────────────────────────────────
log "--- SSH (ssh root@${PEER_IP} hostname) ---"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=60 -o BatchMode=yes"
if result=$(xec "$TEST_TIMEOUT" ssh $SSH_OPTS "root@${PEER_IP}" hostname 2>&1); then
    pass "SSH: got hostname '${result}'"
else
    fail "SSH: $(echo "$result" | head -1)"
fi

# ── Test 3: SCP ───────────────────────────────────────────────────────────────
log "--- SCP (/etc/hostname → ${PEER_IP}:/tmp/) ---"
if xec "$TEST_TIMEOUT" scp $SSH_OPTS \
        /etc/hostname "root@${PEER_IP}:/tmp/hostname-from-a" 2>&1; then
    # Verify the file arrived
    if xec 30 ssh $SSH_OPTS "root@${PEER_IP}" \
            "test -s /tmp/hostname-from-a && cat /tmp/hostname-from-a" 2>&1; then
        pass "SCP: file transferred and verified"
    else
        fail "SCP: transfer appeared to succeed but file missing or empty"
    fi
else
    fail "SCP: transfer failed"
fi

# ── Test 4: HTTP ──────────────────────────────────────────────────────────────
log "--- HTTP (curl http://${PEER_IP}/) ---"
if result=$(xec "$TEST_TIMEOUT" curl -s --max-time 60 "http://${PEER_IP}/" 2>&1); then
    pass "HTTP: got response '$(echo "$result" | head -1)'"
else
    fail "HTTP: curl failed"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
log "=== Results: ${PASS} pass, ${FAIL} fail ==="

if (( FAIL == 0 )); then
    log "STATUS: PASS"
    exit 0
else
    log "STATUS: FAIL"
    log "Direwolf logs:"
    docker exec dwiface-node-a tail -20 /var/log/direwolf.log 2>/dev/null | sed 's/^/  [node-a] /'
    docker exec dwiface-node-b tail -20 /var/log/direwolf.log 2>/dev/null | sed 's/^/  [node-b] /'
    exit 1
fi
