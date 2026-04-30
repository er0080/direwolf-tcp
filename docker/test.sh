#!/usr/bin/env bash
# docker/test.sh — end-to-end tests over the real RF link
#
# All commands run inside node-a's network namespace (docker exec).
# node-a has NO network path to node-b other than through the radio.
#
# Exit codes: 0=all pass, 1=one or more tests failed, 2=setup/link error

set -uo pipefail

PEER_IP="10.0.0.2"
LINK_TIMEOUT=180    # seconds to wait for the RF link to come up
SSH_TIMEOUT=300     # per SSH/SCP test timeout (RF handshake alone takes ~80s)
HTTP_TIMEOUT=90     # per HTTP test timeout
PASS=0; FAIL=0

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
pass() { echo "  [PASS] $*"; (( PASS++ )) || true; }
fail() { echo "  [FAIL] $*"; (( FAIL++ )) || true; }

xec() {
    # Run a command inside node-a; first arg is timeout in seconds
    local t="$1"; shift
    timeout "$t" docker exec dwiface-node-a "$@"
}

# ── Pre-flight ─────────────────────────────────────────────────────────────────
for ctr in dwiface-node-a dwiface-node-b; do
    docker inspect "$ctr" --format '{{.State.Running}}' 2>/dev/null \
        | grep -q true \
        || { log "ERROR: $ctr is not running — start with: docker compose up -d"; exit 2; }
done
log "both containers running"

# ── Wait for RF link ──────────────────────────────────────────────────────────
log "waiting up to ${LINK_TIMEOUT}s for RF link (first ping may take 30-60s)..."
linked=0
elapsed=0
while (( elapsed < LINK_TIMEOUT )); do
    if xec 15 ping -c 1 -W 10 "$PEER_IP" &>/dev/null; then
        linked=1; break
    fi
    echo -n "."
    sleep 10
    (( elapsed += 10 )) || true
done
echo ""
(( linked )) || { log "TIMEOUT: RF link never came up"; \
    log "Check: docker exec dwiface-node-a cat /var/log/dw-iface/direwolf.log"; exit 2; }
log "RF link up after ~${elapsed}s"

# ── Test 1: ICMP ping (10 packets, 3s interval) ───────────────────────────────
log "--- ping ($PEER_IP, 10 × -i 3) ---"
if result=$(xec 90 ping -c 10 -i 3 -W 20 "$PEER_IP" 2>&1); then
    loss=$(echo "$result" | grep -oP '\d+(?=% packet loss)' || echo 0)
    rtt=$(echo "$result"  | grep -oP 'rtt[^=]+=\s*\K[0-9.]+' | head -1 || echo "?")
    if (( ${loss:-100} <= 20 )); then
        pass "ping: ${loss}% loss, avg RTT ${rtt}ms"
    else
        fail "ping: ${loss}% packet loss (>20% threshold)"
    fi
else
    fail "ping: command failed"
fi

# ── Test 2: SSH ───────────────────────────────────────────────────────────────
log "--- SSH (ssh root@${PEER_IP} hostname) ---"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=60 -o BatchMode=yes"
if result=$(xec "$SSH_TIMEOUT" ssh $SSH_OPTS "root@${PEER_IP}" hostname 2>&1); then
    pass "SSH: got hostname '${result}'"
else
    fail "SSH: ${result:-connection failed}"
fi

# ── Test 3: SCP ───────────────────────────────────────────────────────────────
log "--- SCP (/etc/hostname → ${PEER_IP}:/tmp/) ---"
if xec "$SSH_TIMEOUT" scp $SSH_OPTS \
        /etc/hostname "root@${PEER_IP}:/tmp/hostname-from-a" 2>/dev/null; then
    # Verify file arrived on node-b via docker exec (avoids a second RF SSH round-trip)
    remote=$(docker exec dwiface-node-b cat /tmp/hostname-from-a 2>/dev/null || echo "")
    if [[ -n "$remote" ]]; then
        pass "SCP: file arrived on node-b (content: '${remote}')"
    else
        fail "SCP: scp exited 0 but file is missing or empty on node-b"
    fi
else
    fail "SCP: transfer failed"
fi

# ── Test 4: HTTP ──────────────────────────────────────────────────────────────
log "--- HTTP (curl http://${PEER_IP}/) ---"
if result=$(xec "$HTTP_TIMEOUT" \
        curl -s --max-time 60 "http://${PEER_IP}/" 2>&1); then
    pass "HTTP: got response '$(echo "$result" | head -1)'"
else
    fail "HTTP: curl failed"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
log "=== Results: ${PASS} pass, ${FAIL} fail ==="

if (( FAIL == 0 )); then
    log "STATUS: PASS — RF link carries SSH, SCP, and HTTP cleanly"
    exit 0
else
    log "STATUS: FAIL — see above"
    log "Direwolf log (node-a tail):"
    docker exec dwiface-node-a tail -20 /var/log/dw-iface/direwolf.log 2>/dev/null \
        | sed 's/^/  [a] /' || true
    exit 1
fi
