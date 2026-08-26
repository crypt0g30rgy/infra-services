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
| `grafana-dashboard-traefik.yaml` | "Platform — Ingress (traefik)" dashboard JSON |
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

The dashboards are code: `allowUiUpdates: false`, so an edit made in the UI is reverted the
next time Grafana re-reads the directory (30s). To keep a change, either edit the ConfigMap
and re-apply, or use "Save as copy" — copies live in the database, which now persists.

Each is its own ConfigMap, projected into one directory by the `dashboards` volume in
`grafana-deployment.yaml`. **Adding a dashboard is two edits**: the new ConfigMap, and a
`sources:` entry in that volume. A ConfigMap that exists but is not listed applies cleanly,
reports healthy, and is invisible.

They are split by what they depend on:

- **Cluster** — prometheus's own scrape jobs (kubelet, cadvisor, the collector's internal
  telemetry, prometheus itself) and Loki. Still works when every application is down.
- **Services** — what the services export through the otel collector. Blank without them.
- **Ingress (traefik)** — traefik's `:8082` metrics *and* its access log in Loki. It needs
  both, and not for symmetry: traefik's prometheus output has no label for request path and
  no label for client IP, because both are unbounded cardinality, so every "top paths" /
  "top client IPs" / "top user agents" panel is a LogQL query and there is no scrape
  interval that would substitute. Latency appears twice on purpose — the prometheus
  histogram has four buckets (0.1/0.3/1.2/5s) and can only resolve to a bucket edge, while
  the panels marked "exact" unwrap the per-request `Duration` field out of the log. The
  histogram stays because it is the latency signal that survives Loki being down.

Two label names to know before editing a query, because getting them wrong produces an
empty panel rather than an error:

- spanmetrics — `traces_span_metrics_*`, derived from traces by the collector's
  spanmetrics connector — label the service as **`service_name`**.
- everything from the Node auto-instrumentation — `http_*`, `db_*`, `nodejs_*`, `v8js_*` —
  labels it as **`exported_job`**, because the collector's prometheus exporter renames
  OTLP's `job` resource attribute so it cannot collide with prometheus's own `job` label
  (which on that endpoint is always `otel-collector`).

On the ingress dashboard the equivalent trap is field names, not label names. The access log
is JSON, and the fields the panels use are `RequestPath`, `ClientHost` (the real client
address, not the tunnel's — traefik's `forwardedHeaders.trustedIPs` is what makes that
true), `RequestHost`, `DownstreamStatus`, `Duration` (nanoseconds) and
`request_User-Agent`. That last one is extracted with bracket syntax —
`| json ua="[\"request_User-Agent\"]"` — because a hyphen is not valid in a Loki label, so
a bare `| json` will not give you it under that name.

`$topk` on that dashboard is the cost control: Loki reads every matching line to rank them,
so it decides what the top-N panels cost, and it defaults to 10.

`prometheus.yml` drops most of cadvisor at ingestion with a keep-list on the metric name,
to hold the series count down on a 5Gi TSDB. A new cluster panel may need that list
widened first: `k8s-infra/infrastructure/base/monitoring/prometheus.yaml`. The traefik job
lives there too — the ingress dashboard is blank without it, and it is the one job that can
answer "is the platform up" from the outside in.
