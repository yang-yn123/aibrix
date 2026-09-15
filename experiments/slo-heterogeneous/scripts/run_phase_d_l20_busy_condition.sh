#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "usage: $0 RUN_ROOT LOAD_PERCENT BACKGROUND_RPS REPEAT SEED" >&2
  exit 2
fi

run_root=$1
load_percent=$2
background_rps=$3
repeat=$4
seed=$5

input_len=128
output_len=64
probe_count=${PHASE_D_PROBE_COUNT:-100}
probe_rps=${PHASE_D_PROBE_RPS:-0.5}
warmup_seconds=${PHASE_D_WARMUP_SECONDS:-120}
stabilize_seconds=${PHASE_D_STABILIZE_SECONDS:-60}
background_seconds=${PHASE_D_BACKGROUND_SECONDS:-480}
background_mode=${PHASE_D_BACKGROUND_MODE:-direct-service}
background_routing_strategy=${PHASE_D_BACKGROUND_ROUTING_STRATEGY:-slo-least-load}
model=qwen2-5-7b-instruct
profile_run=${PHASE_D_PROFILE_RUN:-20260914T145314Z}
prometheus_url=http://10.43.167.39:9090
official_benchmark=/opt/aibrix/python/aibrix/aibrix/gpu_optimizer/optimizer/profiling/gpu_benchmark.py
python=/opt/aibrix-profiling-venv/bin/python
probe_client=/opt/aibrix-experiment/tools/probe_client.py
prometheus_collector=/opt/aibrix-experiment/tools/collect_prometheus.py

condition=$(printf 'load-%03d-rep-%02d-seed-%04d' "$load_percent" "$repeat" "$seed")
condition_dir=$run_root/$condition
mkdir "$condition_dir"

if [[ "$background_mode" != "direct-service" && "$background_mode" != "gateway-visible" ]]; then
  echo "unsupported PHASE_D_BACKGROUND_MODE: $background_mode" >&2
  exit 2
fi

background_pid=
cleanup() {
  if [[ -n "$background_pid" ]] && kill -0 "$background_pid" 2>/dev/null; then
    kill "$background_pid" 2>/dev/null || true
    wait "$background_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

capture_logs() {
  local output=$1
  shift
  local attempt
  for attempt in 1 2 3; do
    if timeout 60 k3s kubectl logs "$@" > "$output"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

start_epoch=$(date -u +%s)
start_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s\n' "$start_utc" > "$condition_dir/start_utc.txt"
printf '%s\n' \
  "phase=phase-d-l20-busy-a10-no-background" \
  "request_class=${input_len}x${output_len}" \
  "slo_metric=E2E" \
  "slo_percentile=99" \
  "slo_seconds=2.2" \
  "profile_run=$profile_run" \
  "background_mode=$background_mode" \
  "background_target=$(if [[ "$background_mode" == "direct-service" ]]; then echo dedicated-l20-service; else echo gateway-${background_routing_strategy}-external-filter-l20; fi)" \
  "background_routing_strategy=$(if [[ "$background_mode" == "direct-service" ]]; then echo none; else echo "$background_routing_strategy"; fi)" \
  "background_load_percent=$load_percent" \
  "background_request_rate=$background_rps" \
  "background_duration_seconds=$background_seconds" \
  "probe_target=aibrix-gateway" \
  "probe_routing_strategy=slo" \
  "probe_requests=$probe_count" \
  "probe_request_rate=$probe_rps" \
  "arrival=poisson" \
  "seed=$seed" \
  "temperature=0" \
  "warmup_seconds=$warmup_seconds" \
  "stabilize_seconds=$stabilize_seconds" \
  "l20_ecc=Enabled" \
  "a10_ecc=Disabled" > "$condition_dir/parameters.txt"

k3s kubectl get nodes -o wide > "$condition_dir/k8s_nodes_start.txt"
k3s kubectl get deploy,pod -A -o wide > "$condition_dir/k8s_workloads_start.txt"
k3s kubectl get hpa -A > "$condition_dir/k8s_hpa_start.txt"
k3s kubectl get podautoscaler -A > "$condition_dir/k8s_podautoscaler_start.txt" 2>&1 || true
curl -fsS "$prometheus_url/api/v1/targets" > "$condition_dir/prometheus_targets_start.json"
if [[ $(jq '[.data.activeTargets[] | select(.health == "up")] | length' "$condition_dir/prometheus_targets_start.json") -ne 25 ]]; then
  echo "Prometheus does not have 25 healthy targets" >&2
  exit 1
fi

redis_pod=$(k3s kubectl get pod -n aibrix-system -o name | sed -n '/redis-master/{s#pod/##;p;q}')
k3s kubectl exec -n aibrix-system "$redis_pod" -- redis-cli --scan --pattern 'aibrix:profile_*' | sort > "$condition_dir/redis_profile_keys.txt"
if [[ $(wc -l < "$condition_dir/redis_profile_keys.txt") -ne 2 ]]; then
  echo "expected two GPU profiles" >&2
  exit 1
fi
for deployment in qwen2-5-7b-instruct-l20 qwen2-5-7b-instruct-a10; do
  key=aibrix:profile_${model}_${deployment}
  k3s kubectl exec -n aibrix-system "$redis_pod" -- redis-cli --raw get "$key" > "$condition_dir/profile_${deployment##*-}.json"
done

l20_service=$(k3s kubectl get service qwen2-5-7b-instruct-l20 -o jsonpath='{.spec.clusterIP}')
a10_service=$(k3s kubectl get service qwen2-5-7b-instruct-a10 -o jsonpath='{.spec.clusterIP}')
for service in "$l20_service" "$a10_service"; do
  metrics=$(curl -fsS "http://$service:8000/metrics")
  running=$(sed -n 's/^vllm:num_requests_running{[^}]*} \([0-9.]*\)$/\1/p' <<< "$metrics")
  waiting=$(sed -n 's/^vllm:num_requests_waiting{[^}]*} \([0-9.]*\)$/\1/p' <<< "$metrics")
  if [[ "$running" != "0.0" || "$waiting" != "0.0" ]]; then
    echo "vLLM queue is not empty at condition start: $service running=$running waiting=$waiting" >&2
    exit 1
  fi
done

background_requests=0
if [[ "$background_rps" != "0" && "$background_rps" != "0.0" ]]; then
  background_requests=$(awk -v rate="$background_rps" -v duration="$background_seconds" 'BEGIN { print int(rate * duration + 0.999999) }')
  if [[ "$background_mode" == "direct-service" ]]; then
    "$python" "$official_benchmark" \
      --backend vllm --host "$l20_service" --port 8000 --model "$model" \
      --request-rate "$background_rps" --num-prompts "$background_requests" \
      --input-len "$input_len" --output-len "$output_len" --api-key unused \
      --seed "$seed" --temperature 0 --stream --trace \
      > "$condition_dir/background_l20.jsonl" 2> "$condition_dir/background_l20.stderr" &
  else
    "$python" "$probe_client" \
      --endpoint http://172.28.236.61/v1/completions \
      --output "$condition_dir/background_l20.jsonl" \
      --experiment-run "$condition-background" \
      --model "$model" --routing-strategy "$background_routing_strategy" \
      --external-filter 'experiment.aibrix.ai/gpu-model=l20' \
      --input-len "$input_len" --output-len "$output_len" \
      --num-requests "$background_requests" --request-rate "$background_rps" \
      --seed "$((seed + 10000))" --temperature 0 \
      > "$condition_dir/background_stdout.log" 2> "$condition_dir/background_l20.stderr" &
  fi
  background_pid=$!
else
  : > "$condition_dir/background_l20.jsonl"
  : > "$condition_dir/background_l20.stderr"
fi

sleep "$warmup_seconds"
printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$condition_dir/warmup_end_utc.txt"
sleep "$stabilize_seconds"
probe_start_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s\n' "$probe_start_utc" > "$condition_dir/probe_start_utc.txt"
"$python" "$probe_client" \
  --endpoint http://172.28.236.61/v1/completions \
  --output "$condition_dir/probes.jsonl" \
  --experiment-run "$condition" \
  --model "$model" --routing-strategy slo \
  --input-len "$input_len" --output-len "$output_len" \
  --num-requests "$probe_count" --request-rate "$probe_rps" \
  --seed "$seed" --temperature 0 \
  > "$condition_dir/probe_stdout.log" 2> "$condition_dir/probe_stderr.log"
printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$condition_dir/probe_end_utc.txt"

if [[ -n "$background_pid" ]]; then
  wait "$background_pid"
  background_pid=
fi

drain_deadline=$(( $(date -u +%s) + 900 ))
while true; do
  l20_metrics=$(curl -fsS "http://$l20_service:8000/metrics")
  a10_metrics=$(curl -fsS "http://$a10_service:8000/metrics")
  queue_values=$(printf '%s\n%s\n' "$l20_metrics" "$a10_metrics" | sed -n 's/^vllm:num_requests_\(running\|waiting\){[^}]*} \([0-9.]*\)$/\2/p')
  if awk 'BEGIN { ok=1 } { if ($1 != 0) ok=0 } END { exit !ok }' <<< "$queue_values"; then
    break
  fi
  if (( $(date -u +%s) >= drain_deadline )); then
    echo "queues did not drain within 900 seconds" >&2
    exit 1
  fi
  sleep 5
done

end_epoch=$(date -u +%s)
end_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s\n' "$end_utc" > "$condition_dir/end_utc.txt"
gateway_pod=$(k3s kubectl get pod -n aibrix-system -o name | sed -n '/gateway-plugins/{s#pod/##;p;q}')
capture_logs "$condition_dir/gateway.log" -n aibrix-system "$gateway_pod" --since-time="$start_utc"
for deployment in qwen2-5-7b-instruct-l20 qwen2-5-7b-instruct-a10; do
  pod=$(k3s kubectl get pod -l app="$deployment" --field-selector=status.phase=Running -o name | sed -n '1{s#pod/##;p}')
  capture_logs "$condition_dir/vllm_${deployment##*-}.log" "$pod" --since-time="$start_utc"
done
"$python" "$prometheus_collector" --url "$prometheus_url" \
  --start "$start_epoch" --end "$end_epoch" --step 5s \
  --output "$condition_dir/prometheus_range.json"
curl -fsS "$prometheus_url/api/v1/targets" > "$condition_dir/prometheus_targets_end.json"
k3s kubectl get deploy,pod -A -o wide > "$condition_dir/k8s_workloads_end.txt"

grep -Ei 'no profile|fallback to FIFO|failed to get SLO|missing profile' "$condition_dir/gateway.log" > "$condition_dir/fallback_warnings.log" || true
grep -F 'error on track request load consumption' "$condition_dir/gateway.log" > "$condition_dir/load_consumption_errors.log" || true
python3 - "$condition_dir/probes.jsonl" > "$condition_dir/result_counts.json" <<'PY'
import collections
import json
import sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
targets = collections.Counter("l20" if "l20" in (row.get("target_pod") or "") else "a10" if "a10" in (row.get("target_pod") or "") else "other" for row in rows)
print(json.dumps({"requests": len(rows), "success": sum(row["success"] for row in rows), "targets": targets}, sort_keys=True))
PY
if [[ "$background_mode" == "gateway-visible" ]]; then
  python3 - "$condition_dir/background_l20.jsonl" "$background_requests" > "$condition_dir/background_counts.json" <<'PY'
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
expected = int(sys.argv[2])
l20 = sum("l20" in (row.get("target_pod") or "") for row in rows)
a10 = sum("a10" in (row.get("target_pod") or "") for row in rows)
success = sum(row["success"] for row in rows)
print(json.dumps({"expected": expected, "requests": len(rows), "success": success, "l20": l20, "a10": a10}, sort_keys=True))
if len(rows) != expected or success != expected or l20 != expected or a10 != 0:
    raise SystemExit(1)
PY
else
  printf '%s\n' '{"validation":"official-direct-service-output"}' > "$condition_dir/background_counts.json"
fi

if [[ -s "$condition_dir/fallback_warnings.log" || -s "$condition_dir/load_consumption_errors.log" ]]; then
  echo "Gateway profile fallback or load-consumption error detected" >&2
  exit 1
fi

find "$condition_dir" -maxdepth 1 -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > "$condition_dir/SHA256SUMS"
trap - EXIT
cat "$condition_dir/result_counts.json"
cat "$condition_dir/background_counts.json"
