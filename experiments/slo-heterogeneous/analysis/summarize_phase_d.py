#!/usr/bin/env python3

import argparse
import json
import math
from collections import Counter
from pathlib import Path


def percentile(values: list[float], quantile: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * quantile
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def main() -> None:
    parser = argparse.ArgumentParser(description="Summarize Phase D probe JSONL files.")
    parser.add_argument("jsonl", nargs="+", type=Path)
    parser.add_argument("--slo", type=float, required=True)
    args = parser.parse_args()

    print("| File | Requests | Success | L20 | A10 | Other | p50 E2E | p95 E2E | p99 E2E | p50 TTFT | p50 TPOT | SLO violation |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for path in args.jsonl:
        rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]
        successful = [row for row in rows if row["success"]]
        targets = Counter(
            "l20" if "l20" in (row.get("target_pod") or "") else
            "a10" if "a10" in (row.get("target_pod") or "") else "other"
            for row in successful
        )
        e2e = [float(row["e2e_s"]) for row in successful]
        ttft = [float(row["ttft_s"]) for row in successful if row.get("ttft_s") is not None]
        tpot = [float(row["tpot_mean_s"]) for row in successful if row.get("tpot_mean_s") is not None]
        violations = sum(value > args.slo for value in e2e)
        def fmt(value: float) -> str:
            return f"{value:.3f}" if math.isfinite(value) else "n/a"
        values = [percentile(e2e, q) if e2e else math.nan for q in (0.5, 0.95, 0.99)]
        ttft_p50 = percentile(ttft, 0.5) if ttft else math.nan
        tpot_p50 = percentile(tpot, 0.5) if tpot else math.nan
        violation_rate = violations / len(successful) if successful else math.nan
        print(
            f"| {path} | {len(rows)} | {len(successful)} | {targets['l20']} | "
            f"{targets['a10']} | {targets['other']} | {fmt(values[0])} | {fmt(values[1])} | "
            f"{fmt(values[2])} | {fmt(ttft_p50)} | {fmt(tpot_p50)} | {violation_rate:.1%} |"
        )


if __name__ == "__main__":
    main()
