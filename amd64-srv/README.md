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
| `k8s/` | manifests for workloads intended to run on this node specifically |

Same layout as the arm64 tree, deliberately. Cluster-wide Kubernetes manifests
live under `../arm64-srv/k8s/`, because that is the node with API access; only
amd64-specific workloads belong in `k8s/` here.

## What is actually running here

Verified 2026-09-05 against `docker ps` on the host and `kubectl get all -A`.

| Path | State |
|---|---|
| `docker/bugsnik` | running — error tracking (`bugsink`), started from this path, so the compose project's config path moves when this directory does |
| `docker/ollama` | not deployed — written for the previous amd64 box and its GTX 1050 Ti |
| `k8s/ollama` | not deployed — there is no `ai` namespace in the cluster |

Most of what runs on this host is *not* in this repo: the
`meet-to-meat-services` dependency stacks (postgres, lavinmq, valkey, otel,
jaeger, prometheus) come from their own repo, and the cluster's share of pods is
scheduled here by Kubernetes. A second `bugsink` instance runs on the arm64 host
from `~/bugsnik/`; confirm that is intentional before treating either as
authoritative.

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
