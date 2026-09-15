#!/usr/bin/env python3

import argparse
import json
from collections import defaultdict
from pathlib import Path


def percentile(values: list[float], quantile: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * quantile
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def main() -> None:
    parser = argparse.ArgumentParser(description="Summarize Gateway-visible burst trials.")
    parser.add_argument("results", nargs="+", type=Path)
    parser.add_argument("--consumption", type=float, required=True)
    parser.add_argument("--slo", type=float, required=True)
    args = parser.parse_args()

    groups: dict[int, list[dict]] = defaultdict(list)
    for path in args.results:
        row = json.loads(path.read_text(encoding="utf-8"))
        groups[int(row["background_expected"])].append(row)

    print("| L20 in-flight | Normalized load | Success | L20 | A10 | p50 E2E | p95 E2E | p99 E2E | p50 TTFT | p50 TPOT | SLO violation |")
    print("|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for count in sorted(groups):
        rows = groups[count]
        successful = [row for row in rows if row["probe_success"]]
        e2e = [float(row["probe_e2e_s"]) for row in successful]
        ttft = [float(row["probe_ttft_s"]) for row in successful]
        tpot = [float(row["probe_tpot_mean_s"]) for row in successful]
        l20 = sum(row["probe_target"] == "l20" for row in successful)
        a10 = sum(row["probe_target"] == "a10" for row in successful)
        violations = sum(value > args.slo for value in e2e)
        print(
            f"| {count} | {count * args.consumption:.1%} | {len(successful)}/{len(rows)} | "
            f"{l20} | {a10} | {percentile(e2e, 0.50):.3f}s | "
            f"{percentile(e2e, 0.95):.3f}s | {percentile(e2e, 0.99):.3f}s | "
            f"{percentile(ttft, 0.50):.3f}s | {percentile(tpot, 0.50):.3f}s | "
            f"{violations}/{len(successful)} |"
        )


if __name__ == "__main__":
    main()
