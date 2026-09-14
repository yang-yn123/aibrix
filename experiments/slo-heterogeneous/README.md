# AIBrix heterogeneous GPU SLO experiment

This directory contains reproducible deployment and measurement inputs for an
L20/A10 SLO Router experiment. It does not modify the AIBrix Router.

The experiment follows AIBrix's heterogeneous-GPU workflow where it affects the
router under test:

- inference instances use one Deployment per GPU type and share one
  `model.aibrix.ai/name`, as in `samples/heterogeneous`;
- request-pattern collection uses Gateway optimizer tracing and AIBrix Redis;
- baselines and profiles use the official `aibrix_benchmark` and
  `aibrix_gen_profile` entry points from the pinned checkout.

Replica counts stay fixed at one per GPU during this router experiment. The
optimizer-driven PodAutoscalers from the heterogeneous autoscaling example are
intentionally excluded because changing replica counts would confound routing
results. AIBrix is the control plane rather than the inference engine, so the
Deployments run the same pinned vLLM image directly, following the AIBrix
quickstart.

## Pinned inputs

- AIBrix source: `7a7e7bb9ca58390f05e37fad93f59ff7052c1382`
- Gateway image: `aibrix/gateway-plugins:7a7e7bb9`, built from that source
- Model: `Qwen/Qwen2.5-7B-Instruct`
- ModelScope revision: `16c174980d8a1492910551634b4969e69cdc2444`
- vLLM image: `vllm/vllm-openai:v0.10.2`
- vLLM image index digest: `sha256:607442e407b0fea97f8a132a78b787c121a996dd4de181fa08e8da06e71ec2db`
- vLLM linux/amd64 manifest: `sha256:df2607b26bdda2875de4832f4d08da0055b4b6e3570347f3a849bcc652771dd6`

Both GPU nodes store the model at `/opt/models/Qwen2.5-7B-Instruct`. The two
vLLM deployments use the same FP16, TP=1, 4096-token context, 16-sequence and
0.90 GPU-memory-utilization configuration, with prefix caching disabled.
Both checkouts must pass `git lfs fsck` and match `configs/model-checksums.sha256`.
The deployments follow the AIBrix quickstart's direct-vLLM layout. An AIBrix
runtime sidecar is not used because ModelAdapter and ModelClaim are outside this
router experiment and the gateway reads vLLM health and metrics directly.

## Official AIBrix profiling workflow

Run profiling from the control node with the Python environment installed at
`/opt/aibrix-profiling-venv`. Keep L20 and A10 results in separate, newly
created run directories. Do not benchmark both GPUs through the shared Service.

```bash
RUN_DIR="/opt/aibrix-experiment/results/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RUN_DIR"
```

For each GPU, port-forward its dedicated Service to the port expected by the
AIBrix benchmark tool:

```bash
k3s kubectl port-forward service/qwen2-5-7b-instruct-l20 8010:8000
```

Use `aibrix_benchmark` from the pinned AIBrix checkout. Four invocations with
exact start/limit pairs produce the 2x2 request-size matrix without adding
unrequested intermediate sizes:

```bash
/opt/aibrix-profiling-venv/bin/aibrix_benchmark \
  --model qwen2-5-7b-instruct \
  --output "$RUN_DIR/l20.jsonl" \
  --input-start 128 --input-limit 128 \
  --output-start 64 --output-limit 64 \
  --rate-start 1 --rate-limit 64 --temperature 0
```

Repeat for `(2048, 64)`, `(128, 512)` and `(2048, 512)`, appending to the same
new JSONL file. Repeat the complete process through the A10-specific Service.
The official script sends 100 requests at each point and doubles request rate
from the configured start to limit.

After reviewing the baseline curves and choosing an SLO, generate one profile
per Kubernetes deployment and store it in AIBrix Redis:

```bash
/opt/aibrix-profiling-venv/bin/aibrix_gen_profile \
  qwen2-5-7b-instruct-l20 \
  --benchmark "$RUN_DIR/l20.jsonl" \
  --percentile 99 --ttft TTFT_SECONDS --tpot TPOT_SECONDS \
  --cost L20_RELATIVE_COST \
  -o 'redis://127.0.0.1:6379/?model=qwen2-5-7b-instruct'
```

Use a local port-forward from `aibrix-redis-master` to `127.0.0.1:6379`, then
repeat with deployment `qwen2-5-7b-instruct-a10` and its benchmark/cost. Keep
the raw benchmark JSONL immutable after profile generation.
