# Grafana

Applied by hand — nothing in this directory is managed by ArgoCD (which owns prometheus,
jaeger and the otel collector from `k8s-infra/infrastructure/base/monitoring`). Apply the
whole directory after an edit:

```bash
kubectl apply -f pi5-arm64/k8s/monitoring/grafana/
```

## Files

| file | what it is |
| --- | --- |
| `grafana-pvc.yaml` | 2Gi longhorn claim for `/var/lib/grafana` — the SQLite database |
| `grafana-datasources.yaml` | Prometheus, Loki and Jaeger, provisioned with fixed uids |
| `grafana-dashboards-provider.yaml` | points Grafana at `/etc/grafana/dashboards` |
| `grafana-dashboard-cluster.yaml` | "Platform — Cluster" dashboard JSON |
| `grafana-dashboard-app.yaml` | "Platform — Services" dashboard JSON |
| `grafana-deployment.yaml` | the Deployment and Service |
| `grafana-ingress.yaml` | traefik IngressRoute |

## State

Grafana keeps everything it is not provisioned from a file in SQLite: the admin password,
users, dashboards built in the UI, annotations, alert rules. That database was on the
container filesystem until the PVC above existed, so every restart of the pod handed back
a factory-fresh Grafana — which is why the datasource had to be re-added by hand more than
once, and why the pod's 56 restarts had gone unnoticed.

The admin password is therefore whatever was set the first time somebody logged in after
the volume was created. On a brand new volume it is Grafana's default, `admin`/`admin`.
It is not in this repo and should not be; if it is ever lost, reset it in the running pod
with `grafana cli admin reset-admin-password`.

## Dashboards

The two dashboards are code: `allowUiUpdates: false`, so an edit made in the UI is
reverted the next time Grafana re-reads the directory (30s). To keep a change, either edit
the ConfigMap and re-apply, or use "Save as copy" — copies live in the database, which now
persists.

They are split by what they depend on. The cluster dashboard is built from prometheus's
own scrape jobs (kubelet, cadvisor, the collector's internal telemetry, prometheus itself)
and Loki, so it still works when every application is down. The services dashboard is
built from what the services export through the otel collector, and is blank without them.

Two label names to know before editing a query, because getting them wrong produces an
empty panel rather than an error:

- spanmetrics — `traces_span_metrics_*`, derived from traces by the collector's
  spanmetrics connector — label the service as **`service_name`**.
- everything from the Node auto-instrumentation — `http_*`, `db_*`, `nodejs_*`, `v8js_*` —
  labels it as **`exported_job`**, because the collector's prometheus exporter renames
  OTLP's `job` resource attribute so it cannot collide with prometheus's own `job` label
  (which on that endpoint is always `otel-collector`).

`prometheus.yml` drops most of cadvisor at ingestion with a keep-list on the metric name,
to hold the series count down on a 5Gi TSDB. A new cluster panel may need that list
widened first: `k8s-infra/infrastructure/base/monitoring/prometheus.yaml`.
