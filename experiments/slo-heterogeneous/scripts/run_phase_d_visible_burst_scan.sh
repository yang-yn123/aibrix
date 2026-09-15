#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 RUN_ROOT" >&2
  exit 2
fi

run_root=$1
model=qwen2-5-7b-instruct
input_len=128
output_len=64
profile_tput=7.685676104906891
profile_latency=1.6224382227999923
profile_consumption=$(awk -v t="$profile_tput" -v l="$profile_latency" 'BEGIN { printf "%.12f", 1 / t / l }')
repeats=${PHASE_D_BURST_REPEATS:-5}
settle_seconds=${PHASE_D_BURST_SETTLE_SECONDS:-0.20}
background_counts=${PHASE_D_BURST_COUNTS:-"0 3 6 9 10 11 12"}
probe_external_filter=${PHASE_D_PROBE_EXTERNAL_FILTER:-}
python=/opt/aibrix-profiling-venv/bin/python
probe_client=/opt/aibrix-experiment/tools/probe_client.py
prometheus_collector=/opt/aibrix-experiment/tools/collect_prometheus.py
prometheus_url=http://10.43.167.39:9090

mkdir "$run_root"
start_epoch=$(date -u +%s)
start_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s\n' "$start_utc" > "$run_root/start_utc.txt"
printf '%s\n' \
  "run_kind=gateway-visible-burst-switch-scan" \
  "request_class=${input_len}x${output_len}" \
  "background_routing_strategy=slo" \
  "background_external_filter=experiment.aibrix.ai/gpu-model=l20" \
  "probe_routing_strategy=slo" \
  "background_counts=$background_counts" \
  "probe_external_filter=${probe_external_filter:-none}" \
  "repeats=$repeats" \
  "settle_seconds=$settle_seconds" \
  "profile_tput_rps=$profile_tput" \
  "profile_latency_seconds=$profile_latency" \
  "profile_consumption_per_request=$profile_consumption" \
  "profile_run=20260915T014723Z-phase-d-quick-reload" \
  "slo_metric=E2E" \
  "slo_percentile=99" \
  "slo_seconds=2.2" \
  "l20_ecc=Enabled" \
  "a10_ecc=Disabled" > "$run_root/parameters.txt"

k3s kubectl get nodes -o wide > "$run_root/k8s_nodes_start.txt"
k3s kubectl get deploy,pod -A -o wide > "$run_root/k8s_workloads_start.txt"
curl -fsS "$prometheus_url/api/v1/targets" > "$run_root/prometheus_targets_start.json"
if [[ $(jq '[.data.activeTargets[] | select(.health == "up")] | length' "$run_root/prometheus_targets_start.json") -ne 25 ]]; then
  echo "Prometheus does not have 25 healthy targets" >&2
  exit 1
fi

redis_pod=$(k3s kubectl get pod -n aibrix-system -o name | sed -n '/redis-master/{s#pod/##;p;q}')
k3s kubectl exec -n aibrix-system "$redis_pod" -- redis-cli --scan --pattern 'aibrix:profile_*' | sort > "$run_root/redis_profile_keys.txt"
if [[ $(wc -l < "$run_root/redis_profile_keys.txt") -ne 2 ]]; then
  echo "expected two GPU profiles" >&2
  exit 1
fi
for gpu in l20 a10; do
  key=aibrix:profile_${model}_qwen2-5-7b-instruct-$gpu
  k3s kubectl exec -n aibrix-system "$redis_pod" -- redis-cli --raw get "$key" > "$run_root/profile_$gpu.json"
done

l20_service=$(k3s kubectl get service qwen2-5-7b-instruct-l20 -o jsonpath='{.spec.clusterIP}')
a10_service=$(k3s kubectl get service qwen2-5-7b-instruct-a10 -o jsonpath='{.spec.clusterIP}')

wait_for_idle() {
  local deadline=$(( $(date -u +%s) + 120 ))
  while true; do
    local values
    values=$(
      for service in "$l20_service" "$a10_service"; do
        curl -fsS "http://$service:8000/metrics" |
          sed -n 's/^vllm:num_requests_\(running\|waiting\){[^}]*} \([0-9.]*\)$/\2/p'
      done
    )
    if awk 'BEGIN { ok=1 } { if ($1 != 0) ok=0 } END { exit !ok }' <<< "$values"; then
      return 0
    fi
    if (( $(date -u +%s) >= deadline )); then
      echo "vLLM queues did not drain" >&2
      return 1
    fi
    sleep 0.2
  done
}

for count in $background_counts; do
  normalized=$(awk -v n="$count" -v c="$profile_consumption" 'BEGIN { printf "%.6f", n * c }')
  for repeat in $(seq 1 "$repeats"); do
    wait_for_idle
    trial=$(printf 'pending-%02d-norm-%0.3f-rep-%02d' "$count" "$normalized" "$repeat")
    trial_dir=$run_root/$trial
    mkdir "$trial_dir"
    trial_start=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
    printf '%s\n' "$trial_start" > "$trial_dir/start_utc.txt"
    printf '%s\n' \
      "background_count=$count" \
      "predicted_normalized_load=$normalized" \
      "repeat=$repeat" \
      "background_seed=$((20000 + count * 100 + repeat))" \
      "probe_seed=$((1200 + repeat))" > "$trial_dir/parameters.txt"

    background_pid=
    if (( count > 0 )); then
      "$python" "$probe_client" \
        --endpoint http://172.28.236.61/v1/completions \
        --output "$trial_dir/background.jsonl" \
        --experiment-run "$trial-background" \
        --model "$model" --routing-strategy slo \
        --external-filter 'experiment.aibrix.ai/gpu-model=l20' \
        --input-len "$input_len" --output-len "$output_len" \
        --num-requests "$count" --request-rate 1000 \
        --seed "$((20000 + count * 100 + repeat))" --temperature 0 \
        > "$trial_dir/background.stdout" 2> "$trial_dir/background.stderr" &
      background_pid=$!
      sleep "$settle_seconds"
    else
      : > "$trial_dir/background.jsonl"
      : > "$trial_dir/background.stdout"
      : > "$trial_dir/background.stderr"
    fi

    probe_filter_args=()
    if [[ -n "$probe_external_filter" ]]; then
      probe_filter_args=(--external-filter "$probe_external_filter")
    fi
    "$python" "$probe_client" \
      --endpoint http://172.28.236.61/v1/completions \
      --output "$trial_dir/probe.jsonl" \
      --experiment-run "$trial-probe" \
      --model "$model" --routing-strategy slo \
      "${probe_filter_args[@]}" \
      --input-len "$input_len" --output-len "$output_len" \
      --num-requests 1 --request-rate 1 \
      --seed "$((1200 + repeat))" --temperature 0 \
      > "$trial_dir/probe.stdout" 2> "$trial_dir/probe.stderr"
    if [[ -n "$background_pid" ]]; then
      wait "$background_pid"
    fi

    python3 - "$trial_dir/background.jsonl" "$trial_dir/probe.jsonl" "$count" > "$trial_dir/result.json" <<'PY'
import json
import sys

background = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
probe = json.loads(open(sys.argv[2], encoding="utf-8").readline())
expected = int(sys.argv[3])
result = {
    "background_expected": expected,
    "background_requests": len(background),
    "background_success": sum(row["success"] for row in background),
    "background_l20": sum("l20" in (row.get("target_pod") or "") for row in background),
    "background_a10": sum("a10" in (row.get("target_pod") or "") for row in background),
    "probe_success": probe["success"],
    "probe_target": "l20" if "l20" in (probe.get("target_pod") or "") else "a10" if "a10" in (probe.get("target_pod") or "") else "other",
    "probe_e2e_s": probe["e2e_s"],
    "probe_ttft_s": probe["ttft_s"],
    "probe_tpot_mean_s": probe["tpot_mean_s"],
}
print(json.dumps(result, sort_keys=True))
if len(background) != expected or result["background_success"] != expected or result["background_l20"] != expected or result["background_a10"] != 0 or not probe["success"]:
    raise SystemExit(1)
PY
    find "$trial_dir" -maxdepth 1 -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > "$trial_dir/SHA256SUMS"
    cat "$trial_dir/result.json"
  done
done

wait_for_idle
end_epoch=$(date -u +%s)
end_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s\n' "$end_utc" > "$run_root/end_utc.txt"
gateway_pod=$(k3s kubectl get pod -n aibrix-system -o name | sed -n '/gateway-plugins/{s#pod/##;p;q}')
k3s kubectl logs -n aibrix-system "$gateway_pod" --since-time="$start_utc" > "$run_root/gateway.log"
grep -Ei 'no profile|fallback to FIFO|failed to get SLO|missing profile' "$run_root/gateway.log" > "$run_root/fallback_warnings.log" || true
grep -F 'error on track request load consumption' "$run_root/gateway.log" > "$run_root/load_consumption_errors.log" || true
"$python" "$prometheus_collector" --url "$prometheus_url" \
  --start "$start_epoch" --end "$end_epoch" --step 1s \
  --output "$run_root/prometheus_range.json"
curl -fsS "$prometheus_url/api/v1/targets" > "$run_root/prometheus_targets_end.json"
k3s kubectl get deploy,pod -A -o wide > "$run_root/k8s_workloads_end.txt"
find "$run_root" -maxdepth 1 -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > "$run_root/SHA256SUMS"
