# arm64-srv

The arm64 node of the cluster. Currently a Raspberry Pi 5 (16 GB) at
`192.168.0.59`, hostname `pi-5-16gb-srv-0`. It is the **MicroK8s control plane**,
and it also runs most of the standalone compose stacks.

Directory names describe the architecture, not the box, so replacing the
hardware does not mean renaming anything. See [`../Infra.md`](../Infra.md) for
current specs.

| | |
|---|---|
| `docker/` | compose stacks that run directly on this host, from `~/<stack>/` |
| `k8s/` | manifests applied to the cluster from this node (it holds the API server) |

`k8s/` lives here rather than in a shared directory because this is the node with
cluster access; the manifests themselves are cluster-wide unless they carry a
`nodeSelector`. Workloads pinned to a specific node do say so — see
`k8s/jenkins/deployment.yaml`, `k8s/vault-warden/*`, `k8s/rancher/rancher.yaml`.

## What is actually running here

Verified 2026-09-05 against `docker ps` on the host and `kubectl get all -A`.
Anything marked *not deployed* also carries a header comment in its own files.

### Compose stacks

| Stack | State |
|---|---|
| `docker/adguard` | running — DNS for the whole LAN, so treat its ports carefully |
| `docker/bugsnik` | running — error tracking, from `~/bugsnik/`; one instance per node, the amd64 one is `../amd64-srv/docker/bugsnik` |
| `docker/cloudflared` | running — host-level tunnel (there is a second, separate tunnel in `k8s/ingress/cloudflared`) |
| `docker/local-registry` | running — `registry.internal.example.com`, plus its UI and the digest cleaner |
| `docker/portainer` | running |
| `docker/private-registries` | running — verdaccio (npm) |
| `docker/traefik` | running — host-level proxy (the cluster has its own in `k8s/ingress/traefik`) |
| `docker/drone-ci` | not deployed — CI is Jenkins in Kubernetes |
| `docker/gitea` | not deployed |
| `docker/homepage` | not deployed |
| `docker/jenkins` | not deployed — runs in `k8s/jenkins` |
| `docker/local-cloud` | not deployed |
| `docker/mobsf` | not deployed |
| `docker/monitoring` | not deployed — the live stack is `k8s/monitoring`, but keep this until Prometheus there is fixed |
| `docker/nginx-server` | not deployed |
| `docker/open-vpn` | not deployed |
| `docker/ubuntu-tools` | not deployed |
| `docker/vault-warden` | not deployed — runs in `k8s/vault-warden` |

Some containers on this host have no directory here at all: `minio-s3`,
`open-webui`, `scopanator`, `verdaccio`, `discord-autodelete-bot` and a buildx
builder. They are deployed from elsewhere or by hand.

### Kubernetes

| Path | State |
|---|---|
| `k8s/ingress` | deployed — traefik + cloudflared in the `ingress` namespace |
| `k8s/jenkins` | deployed — `jenkins/jenkins` |
| `k8s/longhorn` | deployed — `longhorn-system`, v1.12.1, the cluster's storage |
| `k8s/monitoring` | deployed — grafana, loki, prometheus (prometheus is 0/1, PVC full) |
| `k8s/vault-warden` | deployed — vaultwarden + postgres + nightly `vaultwarden-backup` |
| `k8s/replicasets-cleaner` | deployed — `rs-cleaner` CronJob in `kube-system` |
| `k8s/cluster-role.yaml`, `k8s/cluster-role-binding.yaml` | loose RBAC, applied by hand |
| `k8s/drone-ci` | not deployed — no drone namespace |
| `k8s/echo-app` | not deployed — connectivity test app |
| `k8s/local-registry` | not deployed — the registry runs as a compose stack, above |
| `k8s/nginx` | not deployed |
| `k8s/rancher` | not deployed — no rancher/cattle-system namespace |

## Node protection

This node's kubelet reserves memory and CPU for the system and the control
plane, and evicts before the kernel OOM killer gets involved. Do not remove
those flags without reading
[`../incidents/2026-09-05-node-hardening.md`](../incidents/2026-09-05-node-hardening.md)
— they were added after an incident that corrupted three databases.

It is currently **tight**: pod requests are ~92 % of allocatable CPU and ~85 % of
allocatable memory. Assume there is no room here for anything new.
