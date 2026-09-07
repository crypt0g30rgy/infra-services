# monitoring

Namespace `monitoring` has **two owners**, and neither knows about the other. Work out
which one owns the object before editing anything:

| owned here, applied by hand | owned by `k8s-infra`, synced by ArgoCD |
| --- | --- |
| grafana and loki (both in `../../../amd64-srv/k8s/monitoring/`), promtail | prometheus, jaeger, otel-collector |
| `kubectl apply -f <dir>/` | land in `k8s-infra/infrastructure/base/monitoring/` |

Getting it the wrong way round fails in whichever direction is quietest: a `kubectl apply`
of a k8s-infra object is reverted by selfHeal within minutes, and an edit to a file in this
directory does nothing at all until somebody applies it.

```bash
kubectl apply -f arm64-srv/k8s/monitoring/namespace.yaml
kubectl apply -f arm64-srv/k8s/monitoring/promtail/
kubectl apply -f amd64-srv/k8s/monitoring/loki/
# NOT the grafana directory: grafana-ingress.yaml's host is a placeholder, and applying it
# takes Grafana off the internet with everything still reporting healthy. Apply the files you
# changed, and `kubectl diff -f` first. ../../../README.md has the details.
kubectl apply -f amd64-srv/k8s/monitoring/grafana/grafana-deployment.yaml   # etc, per file
```

Order matters once, on a clean namespace: loki before promtail (promtail's pushes fail
until the endpoint exists — it retries, so this is a convenience, not a requirement), and
the datasource ConfigMaps before grafana so the pod comes up already provisioned.

A ConfigMap change is only half a deployment. None of these processes re-read their
configuration, so follow the apply with a restart of the one you touched:

```bash
kubectl rollout restart deployment/loki    -n monitoring   # loki-configmap.yaml
kubectl rollout restart deployment/grafana -n monitoring   # datasources, dashboards provider
kubectl rollout restart daemonset/promtail -n monitoring   # promtail-configmap.yaml
```

Dashboard *JSON* is the exception — Grafana's file provisioner re-reads
`/etc/grafana/dashboards` every 30s, so a re-applied dashboard ConfigMap lands on its own
(give the kubelet a minute to refresh the projected volume first).

## Components

- **`promtail/`** — a DaemonSet tailing `/var/log/pods` on both nodes. Two settings there
  are load-bearing and non-obvious: `HOSTNAME` must be the *node* name (promtail keeps only
  the targets whose `__host__` matches its own hostname, so with the pod name it tails
  nothing, silently, while reporting Ready), and the pipeline must use the `cri` stage, not
  `docker` — microk8s runs containerd.
- **`../../../amd64-srv/k8s/monitoring/grafana/`** — the UI, its datasources, and the two
  provisioned dashboards
  ("Platform — Cluster" and "Platform — Services"); it moved out of this tree when the pod
  was pinned to dell. Its README covers the state on the PVC, the admin password, and the two different label names the same service goes by
  (`service_name` in spanmetrics, `exported_job` in the Node instrumentation).
- **`../../../amd64-srv/k8s/monitoring/loki/`** — the log store. 5Gi longhorn volume,
  30-day retention. It moved out of this tree on 2026-09-07 for the same reason grafana did.
  See its README; the short version is that it had no volume at all until 2026-08-26 and was
  losing every log line on each of its 54 restarts.

## Which node

**All of `monitoring` is on the amd64 node** (`dell-amd64-32gb-srv` today; the selectors
name the architecture, not the box). That happened over two days, in three pieces,
for one reason: the pi's Longhorn disk ran out of schedulable space, so a monitoring volume there
either fails to schedule or runs degraded, and a pod separated from its volume does every
read and write over the LAN.

| moved | what | how |
| --- | --- | --- |
| 2026-09-06 | grafana, bugsink web | `nodeSelector` in this repo; manifests moved to [`../../../amd64-srv/k8s/`](../../../amd64-srv/k8s/) |
| 2026-09-07 | prometheus, jaeger, otel-collector | `k8s-infra`'s `components/monitoring-on-amd64` — **not** editable from here |
| 2026-09-07 | loki | `nodeSelector` in this repo; manifests moved to [`../../../amd64-srv/k8s/monitoring/loki/`](../../../amd64-srv/k8s/monitoring/loki/) |
| 2026-09-07 | all of it again | the amd64 box was replaced by `dell-amd64-32gb-srv`; Longhorn evicted the replicas across, and the pins became `kubernetes.io/arch: amd64` so the next swap needs no manifest edit |

`promtail` is the exception and stays put: it is a DaemonSet and has to run on the pi too, or
half the cluster's logs stop arriving. `namespace.yaml` stays here because it is
cluster-wide.

Volumes had to move as well, and that half is invisible from git — Longhorn's
`numberOfReplicas` and replica `nodeSelector` live on the `volumes.longhorn.io` object, not
on the claim. `grafana-data`, `loki-data` and `prometheus-data` are all one replica tagged
`amd64` as of 2026-09-07; `k8s-infra/docs/node-pinning.md` has the patch recipe. Grafana's
volume could move at all because SQLite is architecture-independent — a PostgreSQL data
directory is not. Policy: [`../../../k8s.md`](../../../k8s.md), "Node placement".

## Two directories that used to be here

Both were deleted on 2026-09-07. This section is the tombstone, so that nobody restores them
from history without knowing why they went.

**`prometheus/`** was a drifted copy of the ArgoCD-owned deployment. Its scrape config still
described an nginx ingress controller that has never existed in this cluster (ingress is
traefik only), and applying it would have been reverted by selfHeal or, worse, briefly
replaced the real config. The ServiceAccount and ClusterRole it declared now live in
`k8s-infra/infrastructure/base/monitoring/prometheus.yaml`, which is what actually runs.
Edit prometheus there.

**`dashboards/`** held three loose JSON files that nothing loaded — Grafana provisions
dashboards from ConfigMaps under `grafana/`, and only from there — one of them for that same
nonexistent nginx ingress. The other two have since been done properly: traefik *is* scraped
now (`job_name: 'traefik'` against `ingress/traefik-metrics:8082`, in k8s-infra's
`prometheus.yaml`) and the dashboard for it is
`../../../amd64-srv/k8s/monitoring/grafana/grafana-dashboard-traefik.yaml`. Note there is no
Prometheus Operator here, so a `ServiceMonitor` does nothing; a new target is a scrape job in
that file and nothing else.

## Where the data lives

| what | where | size | retention |
| --- | --- | --- | --- |
| logs | `loki-data` PVC, `/loki` | 5Gi | 30 days, compactor-enforced |
| metrics | `prometheus-data` PVC (k8s-infra) | 10Gi | see `prometheus.yaml` |
| dashboards, users, annotations | `grafana-data` PVC, SQLite | 2Gi | forever |
| traces | jaeger, in memory (k8s-infra) | — | lost on restart |

All three PVCs are `longhorn` with a **Retain** reclaim policy: deleting a claim leaves the
volume and its data for a human to remove.

Since 2026-09-07 all three are also **`numberOfReplicas: 1`, tagged `amd64`** — a Longhorn
node tag, which is why the volumes followed the box swap without editing them. They were 2
until the pi's disk could no longer schedule the second copy. So monitoring data has no
redundancy: losing that one disk loses the metrics, the logs and the dashboard database. That
is a deliberate trade for telemetry and it must not be copied onto anything holding user data.
The setting is on the `volumes.longhorn.io` object, so it is in no file here:

```bash
kubectl -n longhorn-system get volumes.longhorn.io \
  -o custom-columns='PVC:.status.kubernetesStatus.pvcName,REPLICAS:.spec.numberOfReplicas,NODES:.spec.nodeSelector,STATE:.status.robustness'
```
