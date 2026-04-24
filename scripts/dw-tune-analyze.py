#!/usr/bin/env python3
"""
dw-tune-analyze.py — Analyze Direwolf CSMA tuning sweep results.

Reads logs/tune/sweep.csv (produced by dw-tune-sweep.sh), computes a
composite score for each config, and prints:
  - Per-config metric table, sorted by score (best first)
  - Baseline row highlighted
  - Best config summary + delta vs baseline
  - Per-factor effect (OFAT): how each knob moved the composite score

Composite score (LOWER is better):
  1000 * max(0, ping_loss - 10)    # hard penalty for > 10% ping loss
  + ping_rtt_avg_ms / 100          # latency (scaled so a 10s RTT = 100 pts)
  + 2000 * (1 - bulk_success)      # hard penalty if bulk transfer failed
  + 100000 / max(bulk_bps, 1)      # throughput (lower bps = higher penalty)
  + frame_loss_pct * 10            # collision pressure

Usage:   scripts/dw-tune-analyze.py [csv_path]
"""

import csv
import sys
from pathlib import Path


def score(row):
    try:
        pa_loss = float(row["ping_a_loss_pct"] or 100)
        pa_rtt  = float(row["ping_a_rtt_avg_ms"] or 60000)
        pb_loss = float(row["ping_b_loss_pct"]  or 100)
        pb_rtt  = float(row["ping_b_rtt_avg_ms"] or 60000)
        bps     = max(int(row["bulk_bps"]  or 0), 1)
        bsucc   = row["bulk_success"] == "true"
        floss   = float(row["frame_loss_pct"] or 0)
        avg_loss = (pa_loss + pb_loss) / 2
        avg_rtt  = (pa_rtt  + pb_rtt)  / 2
        return (
            1000 * max(0, avg_loss - 10)
            + avg_rtt / 100
            + (0 if bsucc else 2000)
            + 100000 / bps
            + floss * 10
        )
    except (ValueError, TypeError):
        return 1e9


def load(csv_path):
    rows = []
    with open(csv_path) as f:
        for r in csv.DictReader(f):
            if r.get("run_id") == "error" or not r.get("bulk_bps"):
                continue
            r["_score"] = score(r)
            rows.append(r)
    return rows


def fmt_row(r, cols, widths):
    return "  ".join(f"{str(r.get(c,'')):>{widths[i]}}" for i, c in enumerate(cols))


def main(csv_path):
    rows = load(csv_path)
    if not rows:
        print(f"No valid rows in {csv_path}", file=sys.stderr)
        return 2

    # Display table.
    cols = [
        "tag", "dwait_ic7300", "dwait_ic705", "persist", "slottime", "txdelay",
        "ping_a_loss_pct", "ping_a_rtt_avg_ms", "ping_b_loss_pct", "ping_b_rtt_avg_ms",
        "bulk_bps", "frame_loss_pct", "_score",
    ]
    hdr = ["tag", "7300", "705", "PERS", "SLOT", "TXDL",
           "LossA%", "RTTa", "LossB%", "RTTb", "bps", "Fl%", "score"]
    widths = [max(len(h), max(len(str(r.get(c, ""))) for r in rows)) for h, c in zip(hdr, cols)]

    rows_sorted = sorted(rows, key=lambda r: r["_score"])
    baseline   = next((r for r in rows if r["tag"] == "baseline"), None)

    print("=== Sweep results (sorted by composite score; lower = better) ===\n")
    print("  " + "  ".join(f"{h:>{widths[i]}}" for i, h in enumerate(hdr)))
    print("  " + "  ".join("-" * widths[i] for i in range(len(hdr))))
    for r in rows_sorted:
        marker = "* " if r["tag"] == "baseline" else "  "
        # Round score to int for display
        disp = {**r, "_score": f"{r['_score']:.0f}"}
        print(marker + "  ".join(f"{str(disp.get(c, '')):>{widths[i]}}" for i, c in enumerate(cols)))
    print()

    best = rows_sorted[0]
    print("=== Best config ===")
    print(f"  tag:       {best['tag']}")
    print(f"  params:    DWAIT(IC-7300)={best['dwait_ic7300']}, DWAIT(IC-705)={best['dwait_ic705']}, "
          f"PERSIST={best['persist']}, SLOTTIME={best['slottime']}, TXDELAY={best['txdelay']}")
    print(f"  ping A:    loss={best['ping_a_loss_pct']}%, rtt={best['ping_a_rtt_avg_ms']}ms")
    print(f"  ping B:    loss={best['ping_b_loss_pct']}%, rtt={best['ping_b_rtt_avg_ms']}ms")
    print(f"  bulk:      {best['bulk_bps']} bps, success={best['bulk_success']}")
    print(f"  frame loss: {best['frame_loss_pct']}%")
    print(f"  score:     {best['_score']:.0f}")
    print()

    if baseline and baseline["tag"] != best["tag"]:
        delta_score = baseline["_score"] - best["_score"]
        print(f"=== Improvement over baseline ===")
        print(f"  score:   {baseline['_score']:.0f}  →  {best['_score']:.0f}   ({delta_score:+.0f})")
        try:
            d_rtt = (float(baseline["ping_a_rtt_avg_ms"] or 0) - float(best["ping_a_rtt_avg_ms"] or 0))
            d_bps = int(best["bulk_bps"]) - int(baseline["bulk_bps"])
            d_floss = float(baseline["frame_loss_pct"] or 0) - float(best["frame_loss_pct"] or 0)
            print(f"  RTT:     {baseline['ping_a_rtt_avg_ms']}ms → {best['ping_a_rtt_avg_ms']}ms "
                  f"({-d_rtt:+.0f}ms)")
            print(f"  bps:     {baseline['bulk_bps']} → {best['bulk_bps']} ({d_bps:+d})")
            print(f"  floss:   {baseline['frame_loss_pct']}% → {best['frame_loss_pct']}% "
                  f"({-d_floss:+.0f}%)")
        except (ValueError, TypeError):
            pass
        print()

    # Per-factor OFAT effect — for each factor, show score deltas.
    if baseline:
        print("=== Per-factor effect (baseline minus variant score; + is better) ===\n")
        factors = {
            "dwait_ic705": "DWAIT(IC-705)",
            "persist":     "PERSIST",
            "slottime":    "SLOTTIME",
            "txdelay":     "TXDELAY",
        }
        base_val = {f: baseline[f] for f in factors}
        for f, label in factors.items():
            variants = [r for r in rows if all(
                r[f2] == base_val[f2] for f2 in factors if f2 != f)]
            variants = sorted(variants, key=lambda r: int(r[f]))
            print(f"  {label}:")
            for r in variants:
                dlt = baseline["_score"] - r["_score"]
                flag = " *BASELINE*" if r["tag"] == "baseline" else ""
                print(f"    {r[f]:>4}  score={r['_score']:>7.0f}  delta={dlt:+7.0f}{flag}")
            print()

    return 0


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else \
        str(Path(__file__).resolve().parent.parent / "logs/tune/sweep.csv")
    sys.exit(main(path))
