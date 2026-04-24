#!/usr/bin/env bash
# dw-tune-sweep.sh — OFAT parameter sweep for Direwolf CSMA/PTT tuning.
#
# Runs dw-tune-run.sh once per parameter point, appending the result to
# logs/tune/sweep.csv.  OFAT (one-factor-at-a-time) starts from the current
# config's defaults and varies one knob at a time, so the total run count
# stays small (~14) and each factor's main effect is directly readable.
#
# Resumable: if logs/tune/sweep.csv already has a row for a given
# (tag, params) tuple, the run is skipped.  Delete the CSV to re-run
# everything.
#
# Usage:   sudo scripts/dw-tune-sweep.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
RUN="$SCRIPT_DIR/dw-tune-run.sh"
TUNE_DIR="$ROOT/logs/tune"
CSV="$TUNE_DIR/sweep.csv"

[[ $EUID -eq 0 ]] || { echo "Must run as root" >&2; exit 1; }
[[ -x "$RUN" ]]    || { echo "dw-tune-run.sh missing" >&2; exit 1; }

mkdir -p "$TUNE_DIR"

# CSV header
if [[ ! -s "$CSV" ]]; then
    cat > "$CSV" <<EOF
tag,run_id,dwait_ic7300,dwait_ic705,persist,slottime,txdelay,ping_a_loss_pct,ping_a_rtt_avg_ms,ping_b_loss_pct,ping_b_rtt_avg_ms,bulk_bps,bulk_success,tx_total,rx_total,frames_lost,frame_loss_pct,busy_deferrals,elapsed_s,json_path
EOF
fi

# OFAT plan — baseline + 1 factor varied at a time.
# Factor 1 (DWAIT_705 asymmetry): tests collision-window priority.
# Factor 2 (PERSIST): tests p-persistence randomness.
# Factor 3 (SLOTTIME): tests slot granularity.
# Factor 4 (TXDELAY): tests leader gap.
#
# Each row: tag|dwait_a(7300)|dwait_b(705)|persist|slottime|txdelay
SWEEP_POINTS=(
    "baseline|0|5|255|1|20"

    "dwait_b_15|0|15|255|1|20"
    "dwait_b_25|0|25|255|1|20"
    "dwait_b_35|0|35|255|1|20"

    "persist_191|0|5|191|1|20"
    "persist_127|0|5|127|1|20"
    "persist_63|0|5|63|1|20"

    "slot_5|0|5|255|5|20"
    "slot_10|0|5|255|10|20"

    "txdelay_15|0|5|255|1|15"
    "txdelay_30|0|5|255|1|30"

    "combo_best|0|25|127|5|20"
)

row_exists() {
    local tag="$1"
    grep -q "^$tag," "$CSV" 2>/dev/null
}

extract_jq() {
    # Extract a numeric field from a JSON file using python (avoid jq dependency).
    local file="$1" path="$2"
    python3 -c "
import json,sys
with open('$file') as f: d=json.load(f)
cur=d
for p in '$path'.split('.'): cur=cur[p]
print(cur)
" 2>/dev/null || echo "0"
}

run_one() {
    local tag="$1" dwait_a="$2" dwait_b="$3" persist="$4" slottime="$5" txdelay="$6"
    if row_exists "$tag"; then
        echo "SKIP $tag (already in $CSV)"
        return 0
    fi
    echo "==> $tag  (ic7300 DWAIT=$dwait_a, ic705 DWAIT=$dwait_b, PERSIST=$persist, SLOT=$slottime, TXDELAY=$txdelay)"
    local out="$TUNE_DIR/sweep-$tag.json"
    if ! "$RUN" \
        --tag "$tag" --out "$out" \
        --dwait-a "$dwait_a" --dwait-b "$dwait_b" \
        --persist "$persist" --slottime "$slottime" --txdelay "$txdelay"
    then
        echo "    run failed — recorded as error"
        echo "$tag,error,$dwait_a,$dwait_b,$persist,$slottime,$txdelay,,,,,,,,,,,," >> "$CSV"
        return 1
    fi
    local run_id=$(extract_jq "$out" "run_id")
    local pa_loss=$(extract_jq "$out" "ping_a_to_b.loss_pct")
    local pa_rtt=$(extract_jq "$out" "ping_a_to_b.rtt_avg_ms")
    local pb_loss=$(extract_jq "$out" "ping_b_to_a.loss_pct")
    local pb_rtt=$(extract_jq "$out" "ping_b_to_a.rtt_avg_ms")
    local bps=$(extract_jq "$out" "bulk.bps")
    local bsuccess=$(extract_jq "$out" "bulk.success")
    local txt_705=$(extract_jq "$out" "direwolf.ic705.tx")
    local txt_7300=$(extract_jq "$out" "direwolf.ic7300.tx")
    local rxt_705=$(extract_jq "$out" "direwolf.ic705.rx")
    local rxt_7300=$(extract_jq "$out" "direwolf.ic7300.rx")
    local busy_705=$(extract_jq "$out" "direwolf.ic705.busy_deferrals")
    local busy_7300=$(extract_jq "$out" "direwolf.ic7300.busy_deferrals")
    local floss_pct=$(extract_jq "$out" "derived.frame_loss_pct")
    local elapsed=$(extract_jq "$out" "elapsed_s")
    local tx_total=$((txt_705 + txt_7300))
    local rx_total=$((rxt_705 + rxt_7300))
    local frames_lost=$(extract_jq "$out" "derived.frames_lost_a_to_b")
    local flost_b=$(extract_jq "$out" "derived.frames_lost_b_to_a")
    frames_lost=$((frames_lost + flost_b))
    local busy_total=$((busy_705 + busy_7300))

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$tag" "$run_id" "$dwait_a" "$dwait_b" "$persist" "$slottime" "$txdelay" \
        "$pa_loss" "$pa_rtt" "$pb_loss" "$pb_rtt" "$bps" "$bsuccess" \
        "$tx_total" "$rx_total" "$frames_lost" "$floss_pct" "$busy_total" "$elapsed" "$out" \
        >> "$CSV"

    echo "    pingA loss=${pa_loss}% rtt=${pa_rtt}ms | pingB loss=${pb_loss}% rtt=${pb_rtt}ms | bulk=${bps}bps | floss=${floss_pct}%"
}

# ── Execute sweep ───────────────────────────────────────────────────────────
echo "Sweep plan: ${#SWEEP_POINTS[@]} points, CSV -> $CSV"
echo

for point in "${SWEEP_POINTS[@]}"; do
    IFS='|' read -r tag dwait_a dwait_b persist slottime txdelay <<<"$point"
    run_one "$tag" "$dwait_a" "$dwait_b" "$persist" "$slottime" "$txdelay" \
        || echo "    continuing despite error"
    # Cool-down between runs (lets audio/PTT fully settle, and gives the
    # band a chance to recover from any stuck keyup).
    sleep 5
done

echo
echo "=== Sweep complete. ==="
column -s, -t < "$CSV" | head -30 || cat "$CSV"
