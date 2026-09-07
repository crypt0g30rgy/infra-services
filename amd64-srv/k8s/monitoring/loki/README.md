# Loki

Single-binary Loki with filesystem storage — the log store behind the `loki` datasource in
Grafana and the Logs rows on both dashboards. Applied by hand; nothing here is reconciled
by ArgoCD, which owns prometheus, jaeger and the otel collector out of `k8s-infra`.

```bash
kubectl apply -f amd64-srv/k8s/monitoring/loki/
kubectl rollout restart deployment/loki -n monitoring    # only if loki-configmap.yaml changed
kubectl rollout status  deployment/loki -n monitoring
```

| file | what it is |
| --- | --- |
| `loki-pvc.yaml` | 5Gi longhorn claim for `/loki` — WAL, TSDB index, chunks, compactor |
| `loki-configmap.yaml` | the static config: paths, v13/tsdb schema, 30-day retention |
| `loki-deployment.yaml` | the Deployment and the `loki` Service on 3100 |

## Which node — and the half of it that is not in this directory

Pinned to `dell-amd64-srv` since 2026-09-07, with grafana and the rest of `monitoring`. It
was unpinned before that, which is worse than it sounds: the pod went wherever the scheduler
put it while its volume's replicas moved to dell, so a restart could quietly put every read
and write on the LAN.

The volume side of the pin is **not expressible in `loki-pvc.yaml`** — `numberOfReplicas`
and the replica `nodeSelector` live on the `volumes.longhorn.io` object, which no file in
this repo creates. That header comment records the current values and the command to check
them. If you move loki back to the pi, move both halves, and check first that the pi's
Longhorn disk can actually take 5Gi (it could not in September 2026 — see
[`../../../../k8s.md`](../../../../k8s.md), "Node placement").

## Validate a config change before applying it

Loki refuses to start on an invalid config, and this is a single-replica deployment with
`maxUnavailable: 1`, so a bad apply is an outage rather than a failed rollout. It validates
its own config, and that check is worth two minutes. Keep the image tag below in step with
`loki-deployment.yaml` — validating against a different binary than the one that will read
the file is most of the way to not validating at all:

```bash
kubectl apply -f amd64-srv/k8s/monitoring/loki/loki-configmap.yaml
kubectl run loki-verify -n monitoring --restart=Never --image=grafana/loki:3.7.7 --overrides='
{"spec":{"securityContext":{"runAsUser":10001,"runAsGroup":10001},"containers":[{"name":"loki-verify",
"image":"grafana/loki:3.7.7","args":["-config.file=/etc/loki/loki.yaml","-verify-config"],
"volumeMounts":[{"name":"config","mountPath":"/etc/loki"}]}],"volumes":[{"name":"config",
"configMap":{"name":"loki-config"}}]}}'
kubectl -n monitoring logs loki-verify        # empty + exit 0 = valid
kubectl -n monitoring delete pod loki-verify
```

It exits 0 and prints nothing when the config is good, so confirm the check is not vacuous
the first time you use it — deleting `compactor.delete_request_store` should produce
`CONFIG ERROR: ... should be configured when retention is enabled` and exit 1.

## What was wrong before 2026-08-26

The Deployment was fourteen lines: an image, an arg and a port. No volume, no resources, no
probes, no strategy. Consequences, in the order they matter:

- **No volume.** Everything lived on the container's writable layer, so the log store was
  destroyed on every restart — and it had restarted 54 times. Nothing surfaces this: promtail
  keeps pushing, and a Grafana panel over a wiped range renders as "No data", not an error.
- **No retention.** Harmless while the store was being wiped anyway, fatal once it persists:
  the image's built-in config has `retention_enabled: false` and `retention_period: 0s`, so
  `/loki` grows without bound and a full volume wedges the ingester instead of dropping old
  data. Persistence and retention had to arrive in the same change.
- **No probes.** The Service sent traffic to a pod that had not replayed its WAL yet. `/ready`
  is the only endpoint that answers this correctly — loki serves HTTP, and refuses pushes,
  for some seconds after start.
- **No resources.** Unbounded on a 16GB pi that also runs half the platform.

The 54 restarts stopped on 2026-08-22, and their cause was never established. Watch
`kubectl -n monitoring get pod -l app=loki` for the count going up again — with the memory
limit now in place a repeat will at least say `OOMKilled` instead of nothing.

## Retention and size

30 days (`limits_config.retention_period: 720h`), enforced by the compactor. Actual usage is
around 20 MB/day compressed, so retention rather than the 5Gi disk is the binding limit —
which is the right way round. The live value is visible as a label:

```bash
kubectl -n monitoring port-forward svc/loki 3100:3100
curl -s localhost:3100/metrics | grep loki_distributor_bytes_received_total   # retention_hours="720"
curl -s localhost:3100/ready
```

`log_level` is `warn`, not the default `info`. Loki at `info` logs a ~2 KB line per subquery,
promtail ships those back into loki, and a dashboard on a refresh timer becomes loki's own
busiest tenant. Set it back to `info` while debugging a slow query — that is where the timing
breakdown lives — then put it back.
