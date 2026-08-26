# monitoring

Namespace `monitoring` has **two owners**, and neither knows about the other. Work out
which one owns the object before editing anything:

| owned here, applied by hand | owned by `k8s-infra`, synced by ArgoCD |
| --- | --- |
| grafana, loki, promtail | prometheus, jaeger, otel-collector |
| `kubectl apply -f <dir>/` | land in `k8s-infra/infrastructure/base/monitoring/` |

Getting it the wrong way round fails in whichever direction is quietest: a `kubectl apply`
of a k8s-infra object is reverted by selfHeal within minutes, and an edit to a file in this
directory does nothing at all until somebody applies it.

```bash
kubectl apply -f pi5-arm64/k8s/monitoring/namespace.yaml
kubectl apply -f pi5-arm64/k8s/monitoring/loki/
kubectl apply -f pi5-arm64/k8s/monitoring/promtail/
kubectl apply -f pi5-arm64/k8s/monitoring/grafana/
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

- **`loki/`** — the log store. 5Gi longhorn volume, 30-day retention. See its README; the
  short version is that it had no volume at all until 2026-08-26 and was losing every log
  line on each of its 54 restarts.
- **`promtail/`** — a DaemonSet tailing `/var/log/pods` on both nodes. Two settings there
  are load-bearing and non-obvious: `HOSTNAME` must be the *node* name (promtail keeps only
  the targets whose `__host__` matches its own hostname, so with the pod name it tails
  nothing, silently, while reporting Ready), and the pipeline must use the `cri` stage, not
  `docker` — microk8s runs containerd.
- **`grafana/`** — the UI, its datasources, and the two provisioned dashboards
  ("Platform — Cluster" and "Platform — Services"). Its README covers the state on the PVC,
  the admin password, and the two different label names the same service goes by
  (`service_name` in spanmetrics, `exported_job` in the Node instrumentation).

There is no prometheus directory here any more. It was a drifted copy of the ArgoCD-owned
deployment — its scrape config still described an nginx ingress controller that has never
existed in this cluster (ingress is traefik only), and its ServiceAccount and ClusterRole
are now declared in `k8s-infra/infrastructure/base/monitoring/prometheus.yaml`, which is
what actually runs. Edit prometheus there.

There is also no loose `dashboards/` directory. It held three JSON files that nothing
loaded — Grafana provisions dashboards from ConfigMaps under `grafana/`, and only from
there — one of them for that same nonexistent nginx ingress. If a traefik dashboard is
wanted, it needs two things first: a scrape job for `ingress/traefik-metrics:8082` in
k8s-infra's `prometheus.yaml` (nothing scrapes traefik today, despite a `ServiceMonitor`
existing — there is no Prometheus Operator here), and then a ConfigMap under `grafana/`
like the other two. Git history has the old JSON as a starting point.

## Where the data lives

| what | where | size | retention |
| --- | --- | --- | --- |
| logs | `loki-data` PVC, `/loki` | 5Gi | 30 days, compactor-enforced |
| metrics | `prometheus-data` PVC (k8s-infra) | 5Gi | see `prometheus.yaml` |
| dashboards, users, annotations | `grafana-data` PVC, SQLite | 2Gi | forever |
| traces | jaeger, in memory (k8s-infra) | — | lost on restart |

All three PVCs are `longhorn` with `numberOfReplicas: 2` and a **Retain** reclaim policy:
deleting a claim leaves the volume and its data for a human to remove.
