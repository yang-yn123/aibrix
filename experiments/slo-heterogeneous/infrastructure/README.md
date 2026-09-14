# Three-node k3s infrastructure

This directory records the cluster bootstrap inputs for the heterogeneous GPU
SLO routing experiment.

- k3s: `v1.31.14+k3s1`
- control node: `aibrix-control` / `172.28.236.61` / `eth0`
- L20 node: `aibrix-l20` / `172.28.236.60` / `eth0`
- A10 node: `aibrix-a10` / `172.28.236.63` / `eth0`
- current public IPs: control `47.110.66.215`, L20 `47.98.132.205`, A10 `114.55.87.118`
- k3s system images: official `k3s-airgap-images-amd64.tar.zst`
- Docker Hub access: ordered registry mirrors in `registries.yaml`
- NVIDIA Container Toolkit: `1.17.8-1` on both GPU nodes
- gateway plugin source: `7a7e7bb9ca58390f05e37fad93f59ff7052c1382`
- gateway builder: `golang:1.22@sha256:1cf6c45ba39db9fd6db16922041d074a63c935556a05c5ccb62d181034df7f02`
- gateway runtime: `distroless/base-debian12:nonroot@sha256:7f0c72cd138b442ae0deeb69c08b1acf5525439ba251a49ad93c320a061567e5`

The k3s join token is intentionally not stored in this repository. Image
digests used by the experiment must be recorded after the images are imported
or pulled.

The NVIDIA repository key used during provisioning has fingerprint
`C95B321B61E88C1809C4F759DDCAE044F796ECB0`.

See `versions.md` for the runtime image digests recorded after deployment.
