#!/usr/bin/env bash
# docker/burnin.sh — RF link burn-in via Docker containers
#
# Docker-adapted analog of scripts/rf-burnin.sh.
# Uses docker exec instead of ip netns exec.
# nginx in node-b serves HTTP on port 80 (no python3 server needed).
# nc (netcat-openbsd) handles bulk transfers.
# socat not installed in image — interactive test omitted.
#
# Pre-requisites:
#   sudo docker/setup.sh          (builds image, resolves PTT devices)
#   sudo docker compose -f docker/compose.yml up -d
#
# Usage: sudo docker/burnin.sh [--duration MIN] [--bulk-kb KB] [--rate-limit N]
# Defaults: --duration 30 --bulk-kb 32 --rate-limit 1200
#
# Exit codes: 0 pass (<5% fail), 1 marginal (5-20%), 2 fail (>20%), 3 setup error

set -uo pipefail

NODE_A="dwiface-node-a"
NODE_B="dwiface-node-b"
IP_A="10.0.0.1"
IP_B="10.0.0.2"
IFACE_A="tnc0"
IFACE_B="tnc0"

HTTP_PORT=80
BULK_PORT=8767

PING_COUNT=3
PING_INT=3
PING_WAIT=20

DURATION_MIN=30
BULK_KB=32
RATE_LIMIT_BPS=1200

while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration|-d)  DURATION_MIN="$2";    shift 2 ;;
        --bulk-kb)      BULK_KB="$2";         shift 2 ;;
        --rate-limit)   RATE_LIMIT_BPS="$2";  shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "Must run as root (sudo)" >&2; exit 3; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/../logs/burnin"
mkdir -p "$LOG_DIR"
RUN_TS=$(date +%Y%m%d-%H%M%S)
LOG="$LOG_DIR/docker-burnin-${RUN_TS}.log"
CSV="$LOG_DIR/docker-burnin-${RUN_TS}.csv"

log()    { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"; }
exec_a() { docker exec "$NODE_A" "$@"; }
exec_b() { docker exec "$NODE_B" "$@"; }

printf 'timestamp,test,result,elapsed_s,bps,detail\n' > "$CSV"
record() {
    printf '%s,%s,%s,%s,%s,%s\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" "$2" "$3" "${4:-}" "${5:-}" >> "$CSV"
}

cleanup() {
    exec_b pkill -f "nc -l" 2>/dev/null || true
    exec_a tc qdisc del dev "$IFACE_A" root 2>/dev/null || true
    exec_b rm -f /tmp/recv-bulk 2>/dev/null || true
}
trap cleanup EXIT INT TERM

preflight() {
    local fail=0
    for ctr in "$NODE_A" "$NODE_B"; do
        if ! docker inspect "$ctr" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
            log "ERROR: container '$ctr' is not running"
            (( fail++ )) || true
        fi
    done
    (( fail > 0 )) && exit 3

    # Verify package installed and log version
    local ver_a ver_b
    ver_a=$(exec_a dpkg-query -W -f='${Version}' dw-iface 2>/dev/null || echo "?")
    ver_b=$(exec_b dpkg-query -W -f='${Version}' dw-iface 2>/dev/null || echo "?")
    log "  dw-iface installed: node-a=${ver_a}  node-b=${ver_b}"
    [[ "$ver_a" != "?" ]] || { log "ERROR: dw-iface not installed in node-a"; (( fail++ )) || true; }
    [[ "$ver_b" != "?" ]] || { log "ERROR: dw-iface not installed in node-b"; (( fail++ )) || true; }

    # Check tnc0 exists in both containers
    exec_a ip link show "$IFACE_A" &>/dev/null \
        || { log "ERROR: $IFACE_A not found in $NODE_A"; (( fail++ )) || true; }
    exec_b ip link show "$IFACE_B" &>/dev/null \
        || { log "ERROR: $IFACE_B not found in $NODE_B"; (( fail++ )) || true; }

    # Check nginx is running in node-b (serves the HTTP test)
    exec_b pgrep nginx &>/dev/null \
        || { log "ERROR: nginx not running in $NODE_B"; (( fail++ )) || true; }

    (( fail == 0 )) || exit 3
    log "  Pre-flight OK — both containers running dw-iface ${ver_a}"
}

wait_for_link() {
    local timeout=300
    log "  Waiting for RF link (up to ${timeout}s)..."
    local t0=$SECONDS attempts=0
    while (( SECONDS - t0 < timeout )); do
        (( attempts++ )) || true
        if exec_a ping -c 1 -W 15 "$IP_B" &>/dev/null 2>&1; then
            log "  RF link up after $(( SECONDS - t0 ))s ($attempts attempts)"
            return 0
        fi
        log "  attempt ${attempts}: no reply yet ($(( SECONDS - t0 ))s elapsed)"
        sleep 5
    done
    log "ERROR: RF link did not come up within ${timeout}s ($attempts attempts)"
    exit 3
}

apply_rate_limit() {
    [[ "${RATE_LIMIT_BPS:-0}" -gt 0 ]] || return 0
    exec_a tc qdisc add dev "$IFACE_A" root tbf \
        rate "${RATE_LIMIT_BPS}bit" burst 4096 latency 10s 2>/dev/null \
    || exec_a tc qdisc change dev "$IFACE_A" root tbf \
        rate "${RATE_LIMIT_BPS}bit" burst 4096 latency 10s 2>/dev/null \
    || { log "  WARNING: tc tbf unavailable — bulk may collide"; return 0; }
    log "  tc tbf: ${RATE_LIMIT_BPS} bps on ${NODE_A}/${IFACE_A}"
}

remove_rate_limit() {
    exec_a tc qdisc del dev "$IFACE_A" root 2>/dev/null || true
}

test_ping() {
    local t0=$SECONDS
    local timeout_s=$(( PING_COUNT * (PING_INT + PING_WAIT) + 10 ))
    local out
    out=$(timeout "$timeout_s" \
        docker exec "$NODE_A" ping -c "$PING_COUNT" -i "$PING_INT" -W "$PING_WAIT" "$IP_B" 2>&1) || true
    local elapsed=$(( SECONDS - t0 ))

    local statsline
    statsline=$(echo "$out" | grep -E '^[0-9]+ packets transmitted' | tail -1)
    local sent rec loss
    sent=$(echo "$statsline" | awk '{print $1}')
    rec=$(echo "$statsline"  | awk -F',' '{print $2}' | awk '{print $1}')
    [[ "$sent" =~ ^[0-9]+$ ]] || sent=0
    [[ "$rec"  =~ ^[0-9]+$ ]] || rec=0
    (( sent > 0 )) && loss=$(( 100 - 100 * rec / sent )) || loss=100

    local rtt_avg=0
    local rttline
    rttline=$(echo "$out" | grep -E 'min/avg/max' | tail -1)
    [[ -n "$rttline" ]] && \
        rtt_avg=$(echo "$rttline" | sed -nE 's|.*= *[0-9.]+/([0-9.]+)/.*|\1|p') || true

    local result
    (( loss == 0 )) && result="pass" || result="fail"
    log "  ping:        loss=${loss}% rtt=${rtt_avg}ms [${result}]"
    record "ping" "$result" "$elapsed" "" "loss=${loss}% rtt=${rtt_avg}ms"
    [[ "$result" == "pass" ]]
}

test_http() {
    local t0=$SECONDS
    local out
    out=$(timeout 90 docker exec "$NODE_A" curl -s \
        --connect-timeout 20 --max-time 80 \
        -o /dev/null \
        -w "%{http_code} %{size_download} %{time_total}" \
        "http://${IP_B}:${HTTP_PORT}/" 2>&1) || out="timeout"
    local elapsed=$(( SECONDS - t0 ))

    local code=0 size=0 secs=0 bps=0
    read -r code size secs <<<"$out" 2>/dev/null || true

    local result
    if [[ "$code" == "200" ]] && (( ${size:-0} > 0 )); then
        result="pass"
        bps=$(awk "BEGIN{t=${secs:-1}; print (t>0 ? int(${size:-0}*8/t) : 0)}" 2>/dev/null || echo 0)
    else
        result="fail"
    fi
    log "  http:        code=${code} ${size}B in ${secs}s = ${bps} bps [${result}]"
    record "http" "$result" "$elapsed" "$bps" "code=${code} size=${size}B"
    [[ "$result" == "pass" ]]
}

test_bulk() {
    local label="${1:-default}"
    local bytes=$(( BULK_KB * 1024 ))
    apply_rate_limit

    exec_b rm -f /tmp/recv-bulk 2>/dev/null || true

    local effective_bps=800
    if (( RATE_LIMIT_BPS > 0 && RATE_LIMIT_BPS < effective_bps )); then
        effective_bps=$RATE_LIMIT_BPS
    fi
    local xfer_timeout=$(( bytes * 8 / effective_bps * 15 / 10 + 120 ))

    # Start receiver in node-b in background (docker exec blocks until nc exits)
    exec_b sh -c "nc -l -p ${BULK_PORT} -N > /tmp/recv-bulk" &
    local recv_bgpid=$!
    sleep 1

    local t0=$SECONDS
    exec_a sh -c \
        "dd if=/dev/urandom bs=${bytes} count=1 2>/dev/null | \
         timeout ${xfer_timeout} nc -N -w ${xfer_timeout} ${IP_B} ${BULK_PORT}" \
        >/dev/null 2>&1 || true

    # Wait for receiver to drain and exit
    local waited=0
    while kill -0 "$recv_bgpid" 2>/dev/null && (( waited < xfer_timeout )); do
        sleep 2; (( waited += 2 ))
    done
    kill "$recv_bgpid" 2>/dev/null || true
    wait "$recv_bgpid" 2>/dev/null || true

    local elapsed=$(( SECONDS - t0 ))
    local recv_bytes
    recv_bytes=$(exec_b sh -c 'wc -c < /tmp/recv-bulk 2>/dev/null || echo 0' | tr -d ' \n')
    exec_b rm -f /tmp/recv-bulk 2>/dev/null || true

    local bps=0
    (( elapsed > 0 && recv_bytes > 0 )) && bps=$(( recv_bytes * 8 / elapsed )) || true

    local result
    if   (( recv_bytes == bytes ));           then result="pass"
    elif (( recv_bytes >= bytes * 9 / 10 )); then result="partial"
    else result="fail"; fi

    remove_rate_limit
    log "  bulk(${label}): ${recv_bytes}/${bytes}B in ${elapsed}s = ${bps} bps [${result}]"
    record "bulk_${label}" "$result" "$elapsed" "$bps" "recv=${recv_bytes}/${bytes}B elapsed=${elapsed}s"
    [[ "$result" != "fail" ]]
}

main() {
    log "=== Docker RF burn-in start ==="
    log "  duration=${DURATION_MIN}min  bulk=${BULK_KB}KB  rate_limit=${RATE_LIMIT_BPS}bps"
    log "  log: $LOG"
    log "  csv: $CSV"
    log ""

    preflight
    wait_for_link
    log ""

    local end_time=$(( SECONDS + DURATION_MIN * 60 ))
    local iter=0 total_tests=0 total_pass=0 total_fail=0

    while (( SECONDS < end_time )); do
        (( iter++ )) || true
        local remaining=$(( (end_time - SECONDS) / 60 ))
        log "--- Iteration ${iter} (${remaining} min remaining) ---"

        if ! test_ping; then
            log "  Link down — pausing 20s before retry"
            (( total_fail++ )) || true; (( total_tests++ )) || true
            sleep 20
            continue
        fi
        (( total_tests++ )); (( total_pass++ )) || true

        if test_http; then
            (( total_tests++ )); (( total_pass++ )) || true
        else
            (( total_tests++ )); (( total_fail++ )) || true
        fi

        if (( iter % 3 == 0 )); then
            if test_bulk "iter${iter}"; then
                (( total_tests++ )); (( total_pass++ )) || true
            else
                (( total_tests++ )); (( total_fail++ )) || true
            fi
            sleep 10
        else
            sleep 30
        fi
    done

    log ""
    log "=== Burn-in complete ==="
    log "  Iterations : ${iter}"
    log "  Tests      : ${total_tests} total, ${total_pass} pass, ${total_fail} fail"
    log "  Results    : $CSV"

    local fail_pct=0
    (( total_tests > 0 )) && fail_pct=$(( total_fail * 100 / total_tests )) || true

    if   (( fail_pct < 5  )); then log "  STATUS: PASS (${fail_pct}% fail rate)";    return 0
    elif (( fail_pct < 20 )); then log "  STATUS: MARGINAL (${fail_pct}% fail rate)"; return 1
    else                           log "  STATUS: FAIL (${fail_pct}% fail rate)";     return 2
    fi
}

main "$@"
