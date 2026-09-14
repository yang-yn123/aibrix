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
PATH=/opt/aibrix-profiling-venv/bin:$PATH \
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

The `PATH` prefix is required in this environment because the official shell
entry point invokes `python` internally. Without it, the wrapper currently
exits zero after printing `python: command not found` and produces no JSONL.
Always validate the expected five JSON records per request-rate point.

After reviewing the baseline curves and choosing an SLO, generate one profile
per Kubernetes deployment and store it in AIBrix Redis:

```bash
/opt/aibrix-profiling-venv/bin/aibrix_gen_profile \
  qwen2-5-7b-instruct-l20 \
  --benchmark "$RUN_DIR/l20.jsonl" \
  --percentile 99 --e2e E2E_SECONDS \
  --cost L20_RELATIVE_COST \
  -o 'redis://127.0.0.1:6379/?model=qwen2-5-7b-instruct'
```

Use a local port-forward from `aibrix-redis-master` to `127.0.0.1:6379`, then
repeat with deployment `qwen2-5-7b-instruct-a10` and its benchmark/cost. Keep
the raw benchmark JSONL immutable after profile generation.

Generate distinct, versioned profiles when testing E2E, TTFT, and TPOT SLOs.
The Router prioritizes TPOT, then TTFT, TPAT, and E2E if several targets are
present in one profile. For TPOT, the pinned Router compares measured mean E2E
with `TPOT * output_tokens + optional TTFT`; the generated profile does not
need a separate TPOT prediction matrix.

## Phase B baseline result (2026-09-14)

Formal runs used the dedicated L20/A10 Services, seed 0, temperature 0, 100
requests per point, and offered rates 1, 2, 4, 8, 16, 32, and 64 req/s. Low-rate
0.5 req/s refinements were added where the first formal point was at or near
capacity. Raw JSONL files are immutable and remain outside Git.

| GPU | ECC | 128/64 | 2048/64 | 128/512 | 2048/512 |
|---|---|---:|---:|---:|---:|
| L20 | Enabled | 8 | 2 | 1 | 0.5 |
| A10 | Disabled | 4 | 1 | 0.5 | 0.5 |

Values are the highest sampled offered rates where achieved throughput was at
least 90% of offered throughput. The profile's measured capacity values are in
`profiles/phase-c-validation-*.json` and are not rounded to these display
values.

The data-derived p99 E2E SLOs, in seconds, are:

| Tier | 128/64 | 2048/64 | 128/512 | 2048/512 |
|---|---:|---:|---:|---:|
| strict | 1.6 | 5.0 | 12.0 | 18.0 |
| critical | 2.2 | 6.0 | 16.0 | 31.5 |
| loose | 2.5 | 10.0 | 17.0 | 35.0 |

The target is model-wide in the AIBrix profile schema, so core experiments
must load a versioned profile for the request class and tier under test. The
initial Phase C load validation used p99 E2E = 35 seconds to ensure all four
request classes had a nonzero stable-capacity entry.

Remote raw and monitoring directories on the control node:

```text
/opt/aibrix-experiment/results/20260914T034000Z  L20 main grid
/opt/aibrix-experiment/results/20260914T040853Z  A10 main grid
/opt/aibrix-experiment/results/20260914T045801Z  L20 2048/512 at 0.5 req/s
/opt/aibrix-experiment/results/20260914T050149Z  A10 long-output refinements
/opt/aibrix-experiment/results/20260914T051052Z  L20 128/512 at 0.5 req/s
/opt/aibrix-experiment/results/20260914T051434Z  A10 2048/64 at 0.5 req/s
```

Each directory contains parameters, timestamps, SHA256, vLLM and AIBrix logs,
and a Prometheus range export covering vLLM, DCGM, node-exporter, AIBrix, and
Envoy jobs. All 25 Prometheus targets were up during the main runs.
The pre-existing `registry-proxy-test` Pod remains in `Unknown` state and was
not deleted; it is not selected by either inference Service or any monitor.

## Phase C profile load validation

Official `aibrix_gen_profile` generated both deployment profiles from derived
merged benchmark inputs and wrote these exact Redis keys:

```text
aibrix:profile_qwen2-5-7b-instruct_qwen2-5-7b-instruct-l20
aibrix:profile_qwen2-5-7b-instruct_qwen2-5-7b-instruct-a10
```

Generation artifacts and Redis before/after snapshots are under
`/opt/aibrix-experiment/profiles/20260914T051935Z`. Gateway requests with
`routing-strategy: slo` returned 200 and emitted no missing-profile, SLO-info,
or FIFO fallback warning. A staggered eight-request validation increased L20
outstanding requests from 1 to 8 but still selected L20 for every request. This
is only a path-validation observation: with `queueOverallSLO=false`, current
deployment queue time is not part of profile ranking. It is not a core Router
experiment result.

The deployed Gateway generates its own request ID instead of preserving the
client `X-Request-Id`; correlate using the response completion ID and Gateway
`request_start`/`request_end` records until collection tooling adds an explicit
experiment ID mapping.
