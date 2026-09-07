# amd64-srv

The amd64 node of the cluster. Currently a Dell OptiPlex 7040 at `192.168.0.7`,
hostname `dell-amd64-32gb-srv`. It is a **worker** — the control plane is on
[`../arm64-srv`](../arm64-srv/README.md). It replaced the Dell Precision 5510
(`dell-amd64-srv`, `192.168.0.60`) on 2026-09-07; see
[`../maintenance/2026-09-07-amd64-node-replacement.md`](../maintenance/2026-09-07-amd64-node-replacement.md).

Directory names describe the architecture, not the box. This tree was called
`hp-amd64` while the amd64 machine was an HP ProDesk; the machine has changed
twice since and the name has not. See [`../Infra.md`](../Infra.md) for current
specs.

| | |
|---|---|
| `docker/` | compose stacks that run directly on this host |
| `k8s/` | manifests for workloads pinned to this node |

Same layout as the arm64 tree, deliberately. A manifest lives in the tree of the
node its `nodeSelector` names, so anything pinned to `dell-amd64-32gb-srv` is here;
cluster-wide and pi-pinned manifests stay under `../arm64-srv/k8s/`. `kubectl`
still runs from the pi either way — that is where the API server is.

## What is actually running here

Verified 2026-09-07 against `kubectl get all -A`, after the node replacement.

| Path | State |
|---|---|
| `docker/bugsnik` | **not running** — this stack was up on the old amd64 box and stayed there; the OptiPlex has no Docker installed. One compose instance per node was the intent; the arm64 one (`../arm64-srv/docker/bugsnik`) still runs. **Its database is in the container layer — read the README before the next `up`.** |
| `docker/ollama` | not deployed — and this box does have a GTX 1050 Ti, the GPU it was written for |
| `k8s/bugsnik` | **not deployed** — no `bugsink` workload exists in the cluster as of 2026-09-07. When it is applied: web pod in `monitoring` on this node, PostgreSQL in `data` on the pi with the cluster's other databases, nightly dump. The hostname in the manifests is a placeholder; the credentials are created on the host |
| `k8s/jenkins` | deployed — `jenkins/jenkins`, pinned here since before the 2026-09-06 pass; its build agents follow it (pod template in `meet-to-meat-services/back-end/tdi-ci`) and are what fills this node's memory budget |
| `k8s/monitoring/grafana` | deployed — moved here 2026-09-06 |
| `k8s/monitoring/loki` | deployed — moved here 2026-09-07, following its Longhorn volume. `promtail` and the namespace stay in `../arm64-srv/k8s/monitoring/`, which is also where the namespace overview README lives |
| `k8s/ollama` | not deployed — there is no `ai` namespace in the cluster |

The `meet-to-meat-services` dependency compose stacks (postgres, lavinmq, valkey,
otel, jaeger, prometheus) and `docker/bugsnik` ran on the *old* amd64 box and did
not move with the cluster: the OptiPlex has no Docker installed. Everything else
here is Kubernetes scheduling pods onto the node.

## Node protection

Read [`../incidents/2026-09-05-node-hardening.md`](../incidents/2026-09-05-node-hardening.md)
before changing anything about this node's memory. In short:

- **Swap is off, on purpose.** `/swap.img` is still on disk and `/etc/fstab` has
  the line commented with the reason. Swap on a Kubernetes node turned a
  single-container OOM into a host-wide thrash collapse that corrupted three
  Postgres volumes.
- **The kubelet reserves 3Gi for the system and 2500Mi for Kubernetes**, leaving
  24.1 GiB allocatable of 30.3 GiB. The numbers were sized on the old 16 GB box,
  where non-Kubernetes processes measured ~6.4 GB of anonymous memory; on this
  machine, with 32 GB and no Docker, they are simply generous.
- Eviction thresholds are 750Mi hard / 1500Mi soft with a 90 s grace, so the
  kubelet acts before the kernel does.

This node has a wired link (`enp0s31f6`) — an improvement on the old box's Wi-Fi —
but it negotiates **100 Mbps**, so every Longhorn write from a pod here to a
replica on the pi still crosses a slow hop. Worth fixing (cable or switch port).
