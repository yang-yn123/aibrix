#!/usr/bin/env python3

import argparse
import json
import urllib.parse
import urllib.request
from pathlib import Path


QUERIES = {
    "vllm_running": 'vllm:num_requests_running',
    "vllm_waiting": 'vllm:num_requests_waiting',
    "vllm_kv_cache": 'vllm:kv_cache_usage_perc',
    "vllm_gpu_cache": 'vllm:gpu_cache_usage_perc',
    "vllm_ttft_count": 'vllm:time_to_first_token_seconds_count',
    "vllm_tpot_count": 'vllm:time_per_output_token_seconds_count',
    "vllm_e2e_count": 'vllm:e2e_request_latency_seconds_count',
    "gpu_utilization": 'DCGM_FI_DEV_GPU_UTIL',
    "gpu_power": 'DCGM_FI_DEV_POWER_USAGE',
    "gpu_framebuffer_used": 'DCGM_FI_DEV_FB_USED',
    "gpu_memory_temperature": 'DCGM_FI_DEV_MEMORY_TEMP',
    "node_cpu_nonidle": 'sum by (instance) (rate(node_cpu_seconds_total{mode!="idle"}[1m]))',
    "node_memory_available": 'node_memory_MemAvailable_bytes',
    "gateway_normalized_pending": 'realtime_normalized_pendings',
    "gateway_running": 'realtime_num_requests_running',
    "gateway_e2e_p99": 'e2e_request_latency_seconds_p99',
    "envoy_active_requests": 'envoy_http_downstream_rq_active',
}


def main() -> None:
    parser = argparse.ArgumentParser(description="Export selected Phase D Prometheus ranges.")
    parser.add_argument("--url", required=True)
    parser.add_argument("--start", required=True)
    parser.add_argument("--end", required=True)
    parser.add_argument("--step", default="5s")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.output.exists():
        parser.error(f"refusing to overwrite existing output: {args.output}")

    exported = {}
    for name, query in QUERIES.items():
        params = urllib.parse.urlencode(
            {"query": query, "start": args.start, "end": args.end, "step": args.step}
        )
        with urllib.request.urlopen(
            f"{args.url.rstrip('/')}/api/v1/query_range?{params}", timeout=60
        ) as response:
            exported[name] = json.load(response)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8") as stream:
        json.dump(exported, stream, sort_keys=True)
        stream.write("\n")


if __name__ == "__main__":
    main()
