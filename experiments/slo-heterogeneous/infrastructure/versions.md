# Deployed versions and digests

Recorded on 2026-09-14 after the environment smoke test.

## Cluster and model serving

- k3s: `v1.31.14+k3s1`
- NVIDIA driver: `580.126.09`
- NVIDIA Container Toolkit: `1.17.8-1`
- NVIDIA device plugin: `v0.17.4`, runtime digest `sha256:3c54348fe5a57e5700e7d8068e7531d2ef2d5f3ccb70c8f6bac0953432527abd`
- vLLM: `v0.10.2`, image index digest `sha256:607442e407b0fea97f8a132a78b787c121a996dd4de181fa08e8da06e71ec2db`
- Qwen2.5-7B-Instruct ModelScope revision: `16c174980d8a1492910551634b4969e69cdc2444`
- Model files: `../configs/model-checksums.sha256`; `git lfs fsck` passed on both GPU nodes

## AIBrix and Envoy

- AIBrix source: `7a7e7bb9ca58390f05e37fad93f59ff7052c1382`
- Gateway plugin image index: `sha256:76c0397e013b489c723ea1edd5eeb72722a67164b77ecd78b6cd43fcca238c1c`
- Gateway plugin running config digest: `sha256:0d11841bc9996d12fa82bff8ec24cd16ea032897852725513f3772c8a8c71f83`
- Controller manager: `sha256:04d84d86c662ef4e40f7ffe17efa2c9945c801649e3dd067bd5164b08726814c`
- Metadata service and GPU optimizer: `sha256:45a9ae2121283ff5274eaff66942cfed20a4d92c11e5c4ca5f4188f230137c39`
- Redis: `sha256:298e5b3bc566bade82f46ad5511777a4a07a294097ce16ada2f6a42be5239df5`
- Envoy Gateway: `v1.2.8`, digest `sha256:46057e933fa9548584116fe87491fcc8d6aa02a2289b01b00a262a76d43d140b`
- Envoy proxy: `v1.33.2`, digest `sha256:e2baf0b155d0f54881b54621fdd997e3ec81dc6454f299d4e590afe18256a176`

## Observability and profiling

- Helm: `v3.18.6`
- kube-prometheus-stack chart: `91.2.1`, package digest `sha256:575150f439f8e107645264535dfd722e51a406d8fbcddda6e30bc3ee05c32fda`
- Prometheus: `v3.14.0-distroless`, digest `sha256:50c707e96da5ade383cb1707790576480485e93de06aa60ad8802cb5f744bd0a`
- Prometheus Operator: `v0.94.0`, digest `sha256:cf153f64d6c38113fceb2cda7642365ea887f71edd7888f054e43e54cf177e55`
- node-exporter: `v1.12.1-distroless`, digest `sha256:8c9bac11973b94b59be88d6e11fee4429aa743c8846cdc75d65b18db33f6a106`
- DCGM exporter: `4.6.0-4.8.3-distroless`, index digest `sha256:613ab03c11d442fd960ff515f547e9921537454a712d08160bc8f677f89f1c35`
- AIBrix profiling virtualenv: `/opt/aibrix-profiling-venv` on the control node
- Profiling pins from the AIBrix lock: `transformers==4.48.3`, `tiktoken==0.7.0`
- Full resolved Python environment: `/opt/aibrix-profiling-requirements.freeze` on the control node

The Gateway smoke request returned HTTP 200 and recorded its target pod, timing and token
counts. Redis contains the corresponding `aibrix:qwen2-5-7b-instruct_request_trace_*`
record. No performance profile or formal benchmark has been generated yet.
