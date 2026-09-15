#!/usr/bin/env python3

import argparse
import asyncio
import json
import random
import time
from datetime import datetime, timezone
from pathlib import Path

import aiohttp


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def percentile(values: list[float], quantile: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * quantile
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


async def send_probe(
    session: aiohttp.ClientSession,
    endpoint: str,
    headers: dict[str, str],
    payload: dict,
    request_index: int,
    scheduled_offset: float,
) -> dict:
    started_at = utc_now()
    started = time.perf_counter()
    first_token_at = None
    previous_token_at = None
    token_times: list[float] = []
    status = None
    response_headers: dict[str, str] = {}
    error = None
    completion_tokens = None
    prompt_tokens = None

    try:
        async with session.post(endpoint, headers=headers, json=payload) as response:
            status = response.status
            response_headers = {key.lower(): value for key, value in response.headers.items()}
            buffer = b""
            async for chunk in response.content.iter_any():
                buffer += chunk
                while b"\n\n" in buffer:
                    event, buffer = buffer.split(b"\n\n", 1)
                    for line in event.splitlines():
                        if not line.startswith(b"data:"):
                            continue
                        raw = line[5:].strip()
                        if not raw or raw == b"[DONE]":
                            continue
                        try:
                            body = json.loads(raw)
                        except json.JSONDecodeError:
                            continue
                        usage = body.get("usage")
                        if usage:
                            completion_tokens = usage.get("completion_tokens")
                            prompt_tokens = usage.get("prompt_tokens")
                        choices = body.get("choices") or []
                        text = choices[0].get("text", "") if choices else ""
                        if not text:
                            continue
                        now = time.perf_counter()
                        if first_token_at is None:
                            first_token_at = now
                            previous_token_at = now
                        else:
                            token_times.append(now - previous_token_at)
                            previous_token_at = now
            if status != 200:
                error = f"HTTP {status}"
    except Exception as exc:  # Preserve individual failures without aborting the run.
        error = f"{type(exc).__name__}: {exc}"

    ended = time.perf_counter()
    return {
        "request_index": request_index,
        "scheduled_offset_s": scheduled_offset,
        "started_at_utc": started_at,
        "e2e_s": ended - started,
        "ttft_s": None if first_token_at is None else first_token_at - started,
        "tpot_mean_s": None if not token_times else sum(token_times) / len(token_times),
        "tpot_p99_s": percentile(token_times, 0.99),
        "observed_stream_events": (0 if first_token_at is None else len(token_times) + 1),
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "status_code": status,
        "success": status == 200 and error is None,
        "error": error,
        "gateway_request_id": response_headers.get("request-id"),
        "routing_strategy": response_headers.get("routing-strategy"),
        "target_pod": response_headers.get("target-pod"),
        "target_pod_ip": response_headers.get("target-pod-ip"),
    }


async def run(args: argparse.Namespace) -> list[dict]:
    rng = random.Random(args.seed)
    offsets = [0.0]
    for _ in range(1, args.num_requests):
        offsets.append(offsets[-1] + rng.expovariate(args.request_rate))

    prompt = "hi " * args.input_len
    payload = {
        "model": args.model,
        "prompt": prompt,
        "max_tokens": args.output_len,
        "temperature": args.temperature,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    headers = {
        "content-type": "application/json",
        "routing-strategy": args.routing_strategy,
        "x-experiment-run": args.experiment_run,
    }
    if args.external_filter:
        headers["external-filter"] = args.external_filter

    timeout = aiohttp.ClientTimeout(total=args.timeout_seconds)
    connector = aiohttp.TCPConnector(limit=0)
    started = time.perf_counter()
    tasks = []
    async with aiohttp.ClientSession(timeout=timeout, connector=connector) as session:
        for index, offset in enumerate(offsets):
            delay = started + offset - time.perf_counter()
            if delay > 0:
                await asyncio.sleep(delay)
            tasks.append(
                asyncio.create_task(
                    send_probe(
                        session,
                        args.endpoint,
                        headers,
                        payload,
                        index,
                        offset,
                    )
                )
            )
        return sorted(await asyncio.gather(*tasks), key=lambda row: row["request_index"])


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Collect reproducible SLO Gateway probe traces.")
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--experiment-run", required=True)
    parser.add_argument("--model", default="qwen2-5-7b-instruct")
    parser.add_argument("--routing-strategy", default="slo")
    parser.add_argument("--external-filter", default="")
    parser.add_argument("--input-len", type=int, required=True)
    parser.add_argument("--output-len", type=int, required=True)
    parser.add_argument("--num-requests", type=int, default=100)
    parser.add_argument("--request-rate", type=float, default=0.5)
    parser.add_argument("--seed", type=int, required=True)
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument("--timeout-seconds", type=float, default=3600)
    args = parser.parse_args()
    if args.output.exists():
        parser.error(f"refusing to overwrite existing output: {args.output}")
    if args.num_requests <= 0 or args.request_rate <= 0:
        parser.error("num-requests and request-rate must be positive")
    return args


def main() -> None:
    args = parse_args()
    rows = asyncio.run(run(args))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8") as stream:
        for row in rows:
            stream.write(json.dumps(row, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
