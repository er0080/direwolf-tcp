#!/usr/bin/env bash
# rf-burnin.sh — RF link burn-in with mixed simulated workload
#
# Workloads (per iteration):
#   ping        — 3-packet health check; link declared down if all fail
#   http        — curl a ~2 KB text file from a python http.server in ns_b
#   interactive — 5 separate TCP exchanges (~100 B each) at SSH keystroke pace
#   bulk        — BULK_KB transfer over nc, timed for TCP goodput (every 3rd iter)
#
# Optional:
#   --mtu-compare  binary-search for PMTU, then compare bulk goodput at two
#                  TCP MSS settings (default vs halved) via ip route advmss
#   --bbr          switch both namespaces to BBR congestion control for the run
#   --rate-limit N rate-limit bulk sender with tc tbf at N bps (default 1200)
#                  prevents KISS queue flooding that causes IC-7300 to collide
#                  with IC-705 during TXDELAY silence windows; set 0 to disable
#
# All network calls are wrapped in explicit timeout; no test can hang the script.
#
# Usage: sudo scripts/rf-burnin.sh [--duration MIN] [--bulk-kb KB]
#                                   [--mtu-compare] [--bbr] [--rate-limit N]
#        Defaults: --duration 30 --bulk-kb 32 --rate-limit 1200
#
# Exit codes:
#   0   pass     (<5% test failure rate)
#   1   marginal (5–20% failure rate)
#   2   fail     (>20% failure rate)
#   3   setup error (ns_a/ns_b absent, service failed to start)

set -uo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
NS_A="ns_a"
NS_B="ns_b"
IP_A="10.0.0.1"
IP_B="10.0.0.2"
IFACE_A="tnc0"
IFACE_B="tnc1"

HTTP_PORT=8765
IACT_PORT=8766
BULK_PORT=8767

PING_COUNT=3
PING_INT=3      # seconds between pings
PING_WAIT=20    # per-packet reply timeout (s)

# ── Defaults (overridable by args) ───────────────────────────────────────────
DURATION_MIN=30
BULK_KB=32
MTU_COMPARE=0
USE_BBR=0
RATE_LIMIT_BPS=1200   # tc tbf rate on bulk sender; 0 = disabled

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration|-d)  DURATION_MIN="$2";    shift 2 ;;
        --bulk-kb)      BULK_KB="$2";         shift 2 ;;
        --mtu-compare)  MTU_COMPARE=1;        shift ;;
        --bbr)          USE_BBR=1;            shift ;;
        --rate-limit)   RATE_LIMIT_BPS="$2";  shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { echo "Must run as root (sudo)" >&2; exit 3; }

# ── Logging setup ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
LOG_DIR="$ROOT/logs/burnin"
mkdir -p "$LOG_DIR"
RUN_TS=$(date +%Y%m%d-%H%M%S)
LOG="$LOG_DIR/burnin-${RUN_TS}.log"
CSV="$LOG_DIR/burnin-${RUN_TS}.csv"
TMP_DIR=$(mktemp -d)

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"; }

# CSV: timestamp,test,result,elapsed_s,bps,detail
printf 'timestamp,test,result,elapsed_s,bps,detail\n' > "$CSV"
record() {
    # record <test> <result> <elapsed_s> [bps] [detail]
    printf '%s,%s,%s,%s,%s,%s\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" "$2" "$3" "${4:-}" "${5:-}" >> "$CSV"
}

# ── Process tracking / cleanup ────────────────────────────────────────────────
SRV_PIDS=()

cleanup() {
    for pid in "${SRV_PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait "${SRV_PIDS[@]:-}" 2>/dev/null || true
    # Belt-and-suspenders: pattern kill for known server processes
    ip netns exec "$NS_B" pkill -f "python3.*http.server.*${HTTP_PORT}" 2>/dev/null || true
    ip netns exec "$NS_B" pkill -f "socat.*TCP-LISTEN:${IACT_PORT}"    2>/dev/null || true
    # Remove any /32 host routes added for the MTU comparison test
    ip netns exec "$NS_A" ip route del "${IP_B}/32" dev "$IFACE_A" 2>/dev/null || true
    ip netns exec "$NS_B" ip route del "${IP_A}/32" dev "$IFACE_B" 2>/dev/null || true
    # Remove rate-limit qdisc if still in place
    ip netns exec "$NS_A" tc qdisc del dev "$IFACE_A" root 2>/dev/null || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

# ── Pre-flight checks ─────────────────────────────────────────────────────────
preflight() {
    local fail=0
    for ns in "$NS_A" "$NS_B"; do
        if ! ip netns exec "$ns" true 2>/dev/null; then
            log "ERROR: network namespace '$ns' not found — run rf-setup.sh first"
            (( fail++ )) || true
        fi
    done
    if ! ip netns exec "$NS_A" ip link show "$IFACE_A" &>/dev/null; then
        log "ERROR: $IFACE_A not found in $NS_A"
        (( fail++ )) || true
    fi
    if ! ip netns exec "$NS_B" ip link show "$IFACE_B" &>/dev/null; then
        log "ERROR: $IFACE_B not found in $NS_B"
        (( fail++ )) || true
    fi
    (( fail == 0 )) || exit 3
}

# ── Service startup ────────────────────────────────────────────────────────────
HAVE_SOCAT=0

start_services() {
    # HTTP content: ~2 KB of compressible text (simulates a small web page)
    local web_dir="$TMP_DIR/web"
    mkdir -p "$web_dir"
    python3 - <<'PYEOF' > "$web_dir/index.html"
import random, textwrap
words = ['radio','link','test','packet','transfer','direwolf','tnc',
         'amateur','station','data','modem','digital','signal','noise',
         'frequency','bandwidth','latency','throughput','collision']
body = ' '.join(random.choices(words, k=500))
print('<html><body><pre>')
for line in textwrap.wrap(body, 72):
    print(line)
print('</pre></body></html>')
PYEOF

    # HTTP server in ns_b
    ip netns exec "$NS_B" python3 -m http.server "$HTTP_PORT" \
        --directory "$web_dir" --bind "$IP_B" \
        >>"$LOG" 2>&1 &
    SRV_PIDS+=($!)

    # Socat echo server in ns_b (interactive test).
    # fork: each accepted connection spawns a child process running cat (echo).
    # reuseaddr: lets successive test runs bind immediately.
    if command -v socat &>/dev/null; then
        ip netns exec "$NS_B" socat \
            "TCP-LISTEN:${IACT_PORT},bind=${IP_B},fork,reuseaddr" \
            EXEC:"cat" \
            >>"$LOG" 2>&1 &
        SRV_PIDS+=($!)
        HAVE_SOCAT=1
    else
        log "  socat not installed — interactive test disabled (apt install socat)"
    fi

    # Allow services time to bind
    sleep 3

    # Verify HTTP is up before proceeding
    if ! ip netns exec "$NS_B" ss -tlnp 2>/dev/null | grep -q ":${HTTP_PORT}"; then
        log "ERROR: HTTP server failed to start on ${IP_B}:${HTTP_PORT}"
        exit 3
    fi
    log "  Services ready: HTTP :${HTTP_PORT}  echo :${IACT_PORT} (socat=${HAVE_SOCAT})"
}

# ── Bulk sender rate limit (tc tbf) ──────────────────────────────────────────
# Prevents KISS queue flooding during bulk transfers. Without this, IC-705
# queues 64+ frames back-to-back; between each frame the TXDELAY creates
# 200ms of silence during which IC-7300 (DWAIT=5) may key up to ACK —
# then IC-705's audio starts and they collide. Throttling the input rate
# creates natural gaps so IC-7300 can ACK without fighting for the channel.
#
# burst: must be >= MTU (508 B). 1024 B allows one full frame to drain at
# wire rate before the token bucket throttles the next one.
apply_rate_limit() {
    [[ "${RATE_LIMIT_BPS:-0}" -gt 0 ]] || return 0
    ip netns exec "$NS_A" tc qdisc add dev "$IFACE_A" root tbf \
        rate "${RATE_LIMIT_BPS}bit" burst 1024 latency 1s 2>/dev/null \
    || ip netns exec "$NS_A" tc qdisc change dev "$IFACE_A" root tbf \
        rate "${RATE_LIMIT_BPS}bit" burst 1024 latency 1s 2>/dev/null \
    || { log "  WARNING: tc tbf unavailable — bulk may collide without rate limit"; return 0; }
    log "  tc tbf rate limit: ${RATE_LIMIT_BPS} bps on ${NS_A}/${IFACE_A}"
}

remove_rate_limit() {
    ip netns exec "$NS_A" tc qdisc del dev "$IFACE_A" root 2>/dev/null || true
}

# ── Congestion control ─────────────────────────────────────────────────────────
apply_bbr() {
    [[ "$USE_BBR" -eq 1 ]] || return 0
    if ! modprobe tcp_bbr 2>/dev/null; then
        log "  WARNING: tcp_bbr module unavailable — skipping BBR"
        USE_BBR=0; return 0
    fi
    ip netns exec "$NS_A" sysctl -qw net.ipv4.tcp_congestion_control=bbr 2>/dev/null \
        || log "  WARNING: BBR not settable in $NS_A"
    ip netns exec "$NS_B" sysctl -qw net.ipv4.tcp_congestion_control=bbr 2>/dev/null \
        || log "  WARNING: BBR not settable in $NS_B"
    log "  TCP congestion control: BBR enabled in both namespaces"
}

# ── Test: Ping (link health) ──────────────────────────────────────────────────
test_ping() {
    local t0=$SECONDS
    local timeout_s=$(( PING_COUNT * (PING_INT + PING_WAIT) + 10 ))
    local out
    out=$(timeout "$timeout_s" \
        ip netns exec "$NS_A" ping -c "$PING_COUNT" -i "$PING_INT" \
            -W "$PING_WAIT" "$IP_B" 2>&1) || true

    local elapsed=$(( SECONDS - t0 ))
    # Derive loss from transmitted/received counts — avoids locale % parsing issues
    local statsline
    statsline=$(echo "$out" | grep -E '^[0-9]+ packets transmitted' | tail -1)
    local sent rec loss
    sent=$(echo "$statsline" | awk '{print $1}')
    rec=$(echo "$statsline" | awk -F',' '{print $2}' | awk '{print $1}')
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

# ── Test: HTTP fetch (curl-like) ──────────────────────────────────────────────
test_http() {
    local t0=$SECONDS
    # Hard outer timeout + curl's own --max-time as belt-and-suspenders
    local out
    out=$(timeout 90 ip netns exec "$NS_A" curl -s \
        --connect-timeout 20 --max-time 80 \
        -o /dev/null \
        -w "%{http_code} %{size_download} %{time_total}" \
        "http://${IP_B}:${HTTP_PORT}/index.html" 2>&1) || out="timeout"

    local elapsed=$(( SECONDS - t0 ))
    local code=0 size=0 secs=0 bps=0
    read -r code size secs <<<"$out" 2>/dev/null || true

    local result
    if [[ "$code" == "200" ]] && (( ${size:-0} > 0 )); then
        result="pass"
        bps=$(python3 -c "t=${secs:-1}; print(int(${size:-0}*8/t) if t>0 else 0)" 2>/dev/null || echo 0)
    else
        result="fail"
    fi
    log "  http:        code=${code} ${size}B in ${secs}s = ${bps} bps [${result}]"
    record "http" "$result" "$elapsed" "$bps" "code=${code} size=${size}B"
    [[ "$result" == "pass" ]]
}

# ── Test: Interactive TCP (SSH console-like) ──────────────────────────────────
# Opens 5 separate short-lived TCP connections, each carrying a ~100-byte payload,
# spaced 2 s apart — simulates SSH keystroke echo at a slow interactive pace.
# Requires socat echo server (HAVE_SOCAT=1).
test_interactive() {
    [[ "$HAVE_SOCAT" -eq 1 ]] || return 0
    local t0=$SECONDS
    local sent=0 echoed=0

    for i in $(seq 1 5); do
        # Build a ~100-byte deterministic message: easy to verify round-trip
        local msg
        msg=$(printf 'MSG%02d|%s\n' "$i" \
            "$(dd if=/dev/urandom bs=72 count=1 2>/dev/null | base64 | tr -d '\n' | head -c 72)")
        local reply
        # timeout 30 outer guard + nc -w 25 idle guard
        reply=$(printf '%s\n' "$msg" | \
            timeout 30 ip netns exec "$NS_A" nc -N -w 25 "$IP_B" "$IACT_PORT" 2>/dev/null \
            || echo "")
        (( sent++ )) || true
        [[ "$reply" == "$msg" ]] && (( echoed++ )) || true
        sleep 2
    done

    local elapsed=$(( SECONDS - t0 ))
    local result
    (( echoed >= 4 )) && result="pass" || result="fail"  # tolerate 1 drop
    log "  interactive: ${echoed}/${sent} echoed in ${elapsed}s [${result}]"
    record "interactive" "$result" "$elapsed" "" "echoed=${echoed}/${sent}"
    [[ "$result" == "pass" ]]
}

# ── Test: Bulk TCP transfer (SCP-like) ───────────────────────────────────────
# Sends BULK_KB random bytes over a fresh TCP connection; measures wire goodput.
# Uses nc -N (half-close on EOF) so both sides exit promptly when done.
# Applies tc tbf rate limit before the transfer and removes it after so the
# KISS queue can't be flooded faster than the radio can drain it.
test_bulk() {
    local label="${1:-default}"
    local bytes=$(( BULK_KB * 1024 ))
    apply_rate_limit
    local recv_file="$TMP_DIR/recv-${label}"
    # Generous timeout: 32 KB at 800 bps ≈ 328 s; add 25% headroom
    local xfer_timeout=$(( bytes * 10 / 800 * 12 / 10 + 60 ))

    # Start receiver first; -N causes it to exit when sender closes
    timeout "$xfer_timeout" ip netns exec "$NS_B" nc -l -p "$BULK_PORT" -N \
        > "$recv_file" 2>/dev/null &
    local recv_pid=$!
    sleep 1  # ensure listener is bound before sender connects

    local t0=$SECONDS
    ip netns exec "$NS_A" bash -c \
        "dd if=/dev/urandom bs=${bytes} count=1 2>/dev/null | \
         timeout ${xfer_timeout} nc -N -w 120 ${IP_B} ${BULK_PORT}" \
        >/dev/null 2>&1 || true

    # After sender exits, wait for receiver to drain (up to 60 s extra)
    local waited=0
    while kill -0 "$recv_pid" 2>/dev/null && (( waited < 60 )); do
        sleep 2; (( waited += 2 ))
    done
    kill "$recv_pid" 2>/dev/null || true
    wait "$recv_pid" 2>/dev/null || true

    local elapsed=$(( SECONDS - t0 ))
    local recv_bytes
    recv_bytes=$(wc -c < "$recv_file" 2>/dev/null || echo 0)
    rm -f "$recv_file"

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

# ── MTU discovery + TCP MSS comparison ───────────────────────────────────────
run_mtu_compare() {
    log ""
    log "=== MTU / TCP MSS comparison ==="

    # Binary search for maximum non-fragmenting ping payload (PMTU)
    log "  Finding PMTU via ping -M do (binary search 100..508) ..."
    local lo=100 hi=508 pmtu=100
    while (( lo <= hi )); do
        local mid=$(( (lo + hi) / 2 ))
        if timeout 30 ip netns exec "$NS_A" \
                ping -c 1 -W 20 -s "$mid" -M do "$IP_B" &>/dev/null; then
            pmtu=$mid; lo=$(( mid + 1 ))
        else
            hi=$(( mid - 1 ))
        fi
    done
    local tcp_mss_default=$(( pmtu - 40 ))
    log "  PMTU = ${pmtu} bytes  →  TCP MSS = ${tcp_mss_default} bytes"
    record "pmtu" "info" 0 "" "pmtu=${pmtu} default_mss=${tcp_mss_default}"

    # Bulk goodput at default advmss
    log "  Bulk goodput at default MSS (${tcp_mss_default}) — 3 runs:"
    local sum_default=0
    for i in 1 2 3; do
        test_bulk "mss_default_r${i}" || true
        local bps; bps=$(tail -1 "$CSV" | cut -d, -f5); bps=${bps:-0}
        sum_default=$(( sum_default + bps ))
        (( i < 3 )) && sleep 15
    done
    local avg_default=$(( sum_default / 3 ))
    log "  Average at default MSS: ${avg_default} bps"

    # Install /32 host routes to advertise halved MSS to TCP
    local mss_half=$(( tcp_mss_default / 2 ))
    log "  Installing host routes: advmss=${mss_half} ..."
    ip netns exec "$NS_A" ip route add "${IP_B}/32" dev "$IFACE_A" advmss "$mss_half" 2>/dev/null \
        || ip netns exec "$NS_A" ip route change "${IP_B}/32" dev "$IFACE_A" advmss "$mss_half" 2>/dev/null \
        || log "  WARNING: could not set advmss in $NS_A (results may be unchanged)"
    ip netns exec "$NS_B" ip route add "${IP_A}/32" dev "$IFACE_B" advmss "$mss_half" 2>/dev/null \
        || ip netns exec "$NS_B" ip route change "${IP_A}/32" dev "$IFACE_B" advmss "$mss_half" 2>/dev/null \
        || log "  WARNING: could not set advmss in $NS_B (results may be unchanged)"

    log "  Bulk goodput at halved MSS (${mss_half}) — 3 runs:"
    local sum_half=0
    for i in 1 2 3; do
        test_bulk "mss_half_r${i}" || true
        local bps; bps=$(tail -1 "$CSV" | cut -d, -f5); bps=${bps:-0}
        sum_half=$(( sum_half + bps ))
        (( i < 3 )) && sleep 15
    done
    local avg_half=$(( sum_half / 3 ))
    log "  Average at half MSS: ${avg_half} bps"

    # Remove test routes (cleanup also handles this, but be explicit)
    ip netns exec "$NS_A" ip route del "${IP_B}/32" dev "$IFACE_A" 2>/dev/null || true
    ip netns exec "$NS_B" ip route del "${IP_A}/32" dev "$IFACE_B" 2>/dev/null || true
    log "  advmss routes removed"

    # Verdict
    log "  --- MSS comparison: default ${avg_default} bps  vs  half ${avg_half} bps ---"
    if (( avg_default >= avg_half )); then
        log "  Verdict: keep PACLEN 512 / advmss ${tcp_mss_default} (default wins or ties)"
    elif (( (avg_half - avg_default) * 10 >= avg_default )); then
        log "  Verdict: halved MSS wins by >10% — consider PACLEN 256 in dw-*.conf"
        log "           and --mtu 252 in rf-setup.sh tncattach invocations"
    else
        log "  Verdict: halved MSS marginally better (<10%) — keep PACLEN 512"
    fi
    log ""
}

# ── Main burn-in loop ──────────────────────────────────────────────────────────
main() {
    log "=== RF burn-in start ==="
    log "  duration=${DURATION_MIN}min  bulk=${BULK_KB}KB  rate_limit=${RATE_LIMIT_BPS}bps  mtu_compare=${MTU_COMPARE}  bbr=${USE_BBR}"
    log "  log: $LOG"
    log "  csv: $CSV"
    log ""

    preflight
    start_services
    apply_bbr

    [[ "$MTU_COMPARE" -eq 1 ]] && run_mtu_compare

    local end_time=$(( SECONDS + DURATION_MIN * 60 ))
    local iter=0 total_tests=0 total_pass=0 total_fail=0

    while (( SECONDS < end_time )); do
        (( iter++ )) || true
        local remaining=$(( (end_time - SECONDS) / 60 ))
        log "--- Iteration ${iter} (${remaining} min remaining) ---"

        # Ping is the gatekeeper: if the link is completely down, skip other tests
        if ! test_ping; then
            log "  Link down — pausing 20s before retry"
            (( total_fail++ )) || true; (( total_tests++ )) || true
            sleep 20
            continue
        fi
        (( total_tests++ )); (( total_pass++ )) || true

        # HTTP fetch (curl-like)
        if test_http; then
            (( total_tests++ )); (( total_pass++ )) || true
        else
            (( total_tests++ )); (( total_fail++ )) || true
        fi

        # Interactive TCP (SSH console-like) — only if socat is available
        if [[ "$HAVE_SOCAT" -eq 1 ]]; then
            if test_interactive; then
                (( total_tests++ )); (( total_pass++ )) || true
            else
                (( total_tests++ )); (( total_fail++ )) || true
            fi
        fi

        # Bulk (SCP-like) every 3rd iteration to keep overall pacing manageable
        if (( iter % 3 == 0 )); then
            if test_bulk "iter${iter}"; then
                (( total_tests++ )); (( total_pass++ )) || true
            else
                (( total_tests++ )); (( total_fail++ )) || true
            fi
            sleep 10   # brief cool-down after a long bulk run
        else
            sleep 30   # standard inter-iteration gap
        fi
    done

    log ""
    log "=== Burn-in complete ==="
    log "  Iterations : ${iter}"
    log "  Tests      : ${total_tests} total, ${total_pass} pass, ${total_fail} fail"
    log "  Results    : $CSV"

    local fail_pct=0
    (( total_tests > 0 )) && fail_pct=$(( total_fail * 100 / total_tests )) || true

    if   (( fail_pct < 5  )); then log "  STATUS: PASS (${fail_pct}% fail rate)";     return 0
    elif (( fail_pct < 20 )); then log "  STATUS: MARGINAL (${fail_pct}% fail rate)";  return 1
    else                           log "  STATUS: FAIL (${fail_pct}% fail rate)";      return 2
    fi
}

main "$@"
