# amd64-srv

The amd64 node of the cluster. Currently a Dell Precision 5510 at
`192.168.0.60`, hostname `dell-amd64-srv`. It is a **worker** — the control plane
is on [`../arm64-srv`](../arm64-srv/README.md).

Directory names describe the architecture, not the box. This tree was called
`hp-amd64` while the amd64 machine was an HP ProDesk; the machine changed, the
name should not have had to. See [`../Infra.md`](../Infra.md) for current specs.

| | |
|---|---|
| `docker/` | compose stacks that run directly on this host |
| `k8s/` | manifests for workloads pinned to this node |

Same layout as the arm64 tree, deliberately. A manifest lives in the tree of the
node its `nodeSelector` names, so anything pinned to `dell-amd64-srv` is here;
cluster-wide and pi-pinned manifests stay under `../arm64-srv/k8s/`. `kubectl`
still runs from the pi either way — that is where the API server is.

## What is actually running here

Verified 2026-09-05 against `docker ps` on the host and `kubectl get all -A`.

| Path | State |
|---|---|
| `docker/bugsnik` | running — error tracking (`bugsink`), one compose instance per node; this is the amd64 one, the arm64 one is `../arm64-srv/docker/bugsnik`. **Its database is in the container layer — read the README before the next `up`.** |
| `docker/ollama` | not deployed — written for the previous amd64 box and its GTX 1050 Ti |
| `k8s/bugsnik` | running since 2026-09-06 — the in-cluster bugsink: the web pod in `monitoring` on this node, its PostgreSQL in `data` on the pi with the cluster's other databases, nightly dump. The hostname in the manifests is a placeholder; the credentials are created on the host |
| `k8s/jenkins` | deployed — `jenkins/jenkins`, pinned here since before the 2026-09-06 pass; its build agents follow it (pod template in `meet-to-meat-services/back-end/tdi-ci`) and are what fills this node's memory budget |
| `k8s/monitoring/grafana` | deployed — moved here 2026-09-06; the rest of `monitoring` is in `../arm64-srv/k8s/monitoring/` |
| `k8s/ollama` | not deployed — there is no `ai` namespace in the cluster |

Most of what runs on this host is *not* in this repo: the
`meet-to-meat-services` dependency stacks (postgres, lavinmq, valkey, otel,
jaeger, prometheus) come from their own repo, and the cluster's share of pods is
scheduled here by Kubernetes.

## Node protection

Read [`../incidents/2026-09-05-node-hardening.md`](../incidents/2026-09-05-node-hardening.md)
before changing anything about this node's memory. In short:

- **Swap is off, on purpose.** `/swap.img` is still on disk and `/etc/fstab` has
  the line commented with the reason. Swap on a Kubernetes node turned a
  single-container OOM into a host-wide thrash collapse that corrupted three
  Postgres volumes.
- **The kubelet reserves 6Gi for the system and 1Gi for Kubernetes**, leaving
  7.5 GiB allocatable of 15.2 GiB. That is not pessimism: non-Kubernetes
  processes on this host measured ~6.4 GB of anonymous memory. Reduce what runs
  outside Kubernetes here and the reservation can come down with it.
- Eviction thresholds are 750Mi hard / 1500Mi soft with a 90 s grace, so the
  kubelet acts before the kernel does.

This node is on **Wi-Fi** (`wlp2s0`), which is also worth fixing: every Longhorn
write from a pod here to a replica on the other node crosses it.
