#!/usr/bin/env python3

import argparse
import json
from collections import defaultdict
from pathlib import Path


SHAPES = ((128, 64), (2048, 64), (128, 512), (2048, 512))
METRICS = ("TPUT", "TT", "E2E", "TTFT", "TPOT")


def load(paths):
    rows = []
    for path in paths:
        with Path(path).open(encoding="utf-8") as stream:
            rows.extend(json.loads(line) for line in stream if line.strip())

    indexed = {}
    for row in rows:
        key = (
            row["input_tokens"],
            row["output_tokens"],
            float(row["request_rate"]),
            row["metric"],
        )
        if key in indexed:
            raise ValueError(f"duplicate benchmark record: {key}")
        indexed[key] = row

    grouped = defaultdict(set)
    for input_tokens, output_tokens, rate, metric in indexed:
        grouped[(input_tokens, output_tokens, rate)].add(metric)
    for key, metrics in grouped.items():
        if metrics != set(METRICS):
            raise ValueError(f"incomplete metrics for {key}: {sorted(metrics)}")
    return indexed


def summarize(gpu, indexed):
    print(f"## {gpu}")
    print("| Input/output | Stable offered RPS | Achieved RPS | Low-rate p99 E2E | p99 TTFT | p99 TPOT |")
    print("|---|---:|---:|---:|---:|---:|")
    for shape in SHAPES:
        rates = sorted(
            rate
            for input_tokens, output_tokens, rate, metric in indexed
            if (input_tokens, output_tokens) == shape and metric == "TPUT"
        )
        if not rates:
            raise ValueError(f"missing request shape: {shape}")
        stable = [
            rate
            for rate in rates
            if indexed[(*shape, rate, "TPUT")]["mean"] >= 0.9 * rate
        ]
        capacity_rate = max(stable) if stable else min(rates)
        achieved = indexed[(*shape, capacity_rate, "TPUT")]["mean"]
        low_rate = min(rates)
        e2e = indexed[(*shape, low_rate, "E2E")]["P99"]
        ttft = indexed[(*shape, low_rate, "TTFT")]["P99"]
        tpot = indexed[(*shape, low_rate, "TPOT")]["P99"]
        print(
            f"| {shape[0]}/{shape[1]} | {capacity_rate:g} | {achieved:.3f} | "
            f"{e2e:.3f} | {ttft:.3f} | {tpot:.4f} |"
        )
    print()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--l20", action="append", required=True, metavar="JSONL")
    parser.add_argument("--a10", action="append", required=True, metavar="JSONL")
    args = parser.parse_args()
    summarize("L20", load(args.l20))
    summarize("A10", load(args.a10))


if __name__ == "__main__":
    main()
