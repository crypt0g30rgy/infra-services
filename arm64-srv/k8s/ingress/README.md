# ingress

One Traefik, one cloudflared, applied by hand. Nothing in this directory is reconciled by
ArgoCD, so editing a file here changes nothing until you apply it — and a ConfigMap change
needs a restart on top, because Traefik reads its static configuration once at start.

```bash
kubectl apply -f arm64-srv/k8s/ingress/traefik/base/ -f arm64-srv/k8s/ingress/traefik/internal/configmap.yaml
kubectl rollout restart deployment/traefik -n ingress    # only if configmap.yaml changed
kubectl rollout status  deployment/traefik -n ingress
```

## 1. What is actually running

```
                     Cloudflare edge  (terminates TLS for every public hostname)
                            │
                            │  tunnel
                     cloudflared      (Deployment, ns ingress)
                            │  http://traefik-external.ingress:80
                            ▼
                        traefik        (Deployment, 1 replica, traefik:v3.7.11)
                            │
       ┌────────────────────┼─────────────────────┐
   traefik-external    traefik-internal      traefik-metrics
   LoadBalancer        ClusterIP             ClusterIP
   192.168.1.201       80, 443               8082
   (MetalLB)
```

| file | object |
| --- | --- |
| `namespace.yaml` | ns `ingress` |
| `traefik/base/deployment.yaml` | the Deployment — one container, so a pod reads 1/1 |
| `traefik/base/service.yaml` | the three Services above |
| `traefik/base/rbac.yaml` | ServiceAccount, ClusterRole, binding |
| `traefik/base/pvc.yaml` | `traefik-data`, 1Gi RWO longhorn at `/data` — now holds only an empty `acme/` |
| `traefik/base/middleware.yaml` | `cluster-identity-header`, and an `-external` copy |
| `traefik/internal/configmap.yaml` | `traefik-config`: the whole static configuration |
| `traefik/internal/secret.yaml` | placeholder for the Cloudflare **DNS** API token; nothing consumes it — see "TLS" |
| `traefik/crds/ingressclasses.yaml` | registers the `public`, `internal` and `traefik` classes |
| `cloudflared/*` | the tunnel agent, its config and its token |

Names to read past rather than trust:

- **`internal/`** is where the *only* static config lives. There was going to be an
  external/internal Traefik pair with a kustomize base and two overlays; it was never
  built. There is no `external/` directory, no `kustomization.yaml` anywhere under this
  tree, and no `traefik-internal`/`traefik-external` Deployment — one Deployment named
  `traefik` serves both Services. `kubectl apply -k` on any of these directories fails.
- **IngressClasses.** Three are registered, two are used: `traefik` (the platform's own
  hostnames — api gateways, argocd, jenkins, grafana, vaultwarden) and `public` (the
  `xboy` namespace). `internal` is registered and unused. All three point at the same
  controller, so the choice is cosmetic; matching what the neighbouring Ingress uses is
  the whole rule.
- **Traefik CRDs** (`IngressRoute`, `Middleware`, …) are not in this repo. They come from
  upstream and are already installed:
  `kubectl apply -f https://raw.githubusercontent.com/traefik/traefik/v3.7/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml`

## 2. TLS

There is none in this cluster. Every hostname is reached through the cloudflared tunnel,
Cloudflare terminates TLS at its edge, and Traefik serves plain HTTP behind it. No Ingress
declares `spec.tls`, nothing names a `certResolver`.

`configmap.yaml` used to define a `letsencrypt-internal` ACME resolver (DNS-01 via
Cloudflare) and the Deployment used to pass it a `CF_DNS_API_TOKEN` from a
`cloudflare-api-token` secret. It never issued a certificate — `/data/acme/acme.json` was
still 0 bytes a month on — and it is gone, for a reason worth keeping in mind beyond this
one block: the secret it depended on had been deleted, a running pod does not notice
because it resolved the reference at start, and the first restart afterwards failed with
`CreateContainerConfigError`. Ingress was down for four minutes over a credential feeding
a code path with no callers.

Restore both halves together if the tunnel ever goes away, and note that the
`cloudflare-token` secret in this namespace is **not** the credential to use — that is
cloudflared's *tunnel* token, which will not solve a DNS challenge.

## 3. Ingress status and ArgoCD

`providers.kubernetesIngress.ingressEndpoint.publishedService` points at
`ingress/traefik-external` so that Traefik writes that Service's address into
`status.loadBalancer` on every Ingress it serves. Nothing in the data path needs it.
ArgoCD does: it reads an Ingress with an empty `status.loadBalancer.ingress` as "still
progressing", so without this setting `apps-production` sat permanently yellow over three
Ingresses that were routing perfectly — which is exactly how a real regression goes
unnoticed.

## 4. Metrics and the access log

Both are collected now, and they answer different questions — which is the one thing to
know before adding a panel or a query.

**Prometheus metrics** on `:8082` (`traefik-metrics`). Scraped by the static `traefik` job
in `k8s-infra/infrastructure/base/monitoring/prometheus.yaml`, cross-namespace via
`traefik-metrics.ingress.svc.cluster.local:8082`. Request counts, status codes, a latency
histogram, throughput and open connections, labelled by entrypoint, router and service —
about 700 series.

There used to be a `servicemonitor.yaml` here instead. It has been deleted. A
`ServiceMonitor` is a Prometheus Operator CRD; the CRD is installed but **there is no
operator in this cluster** — prometheus is a plain Deployment reading a static
`scrape_configs` list — so that object was applied, healthy, and collecting nothing, for a
month. That is worse than no metrics: it reads as coverage.

**The access log** goes to **stdout** in JSON, so promtail picks it up and it lands in Loki
under `{namespace="ingress", app="traefik", container="traefik"}`. Query it with `| json`.

It has to be stdout, and there must be no `filters`, because of what the metrics cannot do:
traefik's prometheus output has **no label for request path and no label for client IP** —
deliberately, since both are unbounded cardinality. Every "top paths" / "top client IPs" /
"top user agents" question is therefore a Loki query over these lines, and it was
unanswerable while the log was a file on an RWO volume that only `kubectl exec` could read.
The `filters` block that used to be there (`statusCodes: 400-599`, `retryAttempts`,
`minDuration: 10ms`, OR'd) dropped fast successful requests, so any count taken from it was
a count of slow and failed requests wearing the label "requests".

Both feed **"Platform — Ingress (traefik)"** in Grafana
(`../../../amd64-srv/k8s/monitoring/grafana/grafana-dashboard-traefik.yaml`), which mixes the two datasources
for exactly this reason.

Worth knowing when reading any of it: **404 dominates.** This cluster is scanned
continuously through the tunnel — at the time of writing, 143 of 148 requests in twenty
minutes were 404s for paths like `/wp-json` and `/005.php`, nearly all from one address.
The dashboard has "Top 404 paths" and "Top clients hitting 404s" to separate that from real
traffic.

**Tracing** goes to `otel-collector.monitoring.svc.cluster.local:4317`. It pointed at
`jaeger.observability.svc.cluster.local:4317` until 2026-08-26 — a namespace that has never
existed in this cluster — so every span traefik produced was dropped at the exporter while
the access log carried a real `TraceId` on every line. Traces started at api-gw and were
missing the ingress hop.

## 5. Disk retention

`/data` holds an empty `acme/` and nothing else. There is no access log on it and no
`logrotate` sidecar, because the access log goes to stdout (section 4): the kubelet rotates
it and Loki retains it for 30 days.

This section is kept for the trap it records. The log was a file here, and rotation of it
failed silently twice: first the real `logrotate` package, installed at container start with
`apk add --no-cache logrotate >/dev/null 2>&1`, which on the pi could never reach
`dl-cdn.alpinelinux.org` and left a loop calling a binary that did not exist — and which
also said `su 65532 65532`, a user the alpine image does not have, so it answered `unknown
group '65532'` → `Handling 0 logs` even where the install worked. `access.log` reached
**287 MB on a 1 Gi volume** while that sidecar reported `Running`. The plain-shell rotator
that replaced it worked, but it shifted the 287 MB to `access.log.2` rather than deleting
it.

Moving to stdout removed the rotator, which is what made those files permanently stranded —
a size-triggered rotator never fires again once the file stops growing — so they were
deleted at the same time. `/data` went from 339 MB to 12 KB.

The general lesson, which cost two outages and a month of blind metrics between them: on
this cluster a sidecar reporting `Running` and a `ServiceMonitor` reporting `Synced` are
both compatible with doing absolutely nothing. Check the effect, not the status.

## 6. Verify

```bash
kubectl -n ingress get pods                    # traefik 1/1, cloudflared 1/1
kubectl -n ingress get svc                     # traefik-external holds 192.168.1.201
kubectl get ingress -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,ADDR:.status.loadBalancer.ingress
kubectl -n ingress logs deploy/traefik -c traefik | grep -E '"level":"(error|fatal)"'
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: users-api-gw.example.com' http://192.168.1.201/

# the access log is on stdout and reaching Loki
kubectl -n ingress logs deploy/traefik -c traefik --tail=5 | grep RequestPath
# prometheus is actually scraping it
kubectl -n monitoring exec deploy/prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/targets?state=active' | grep -o '"job":"traefik".\{0,60\}'
```

`level=error` lines about a middleware that "does not exist" in the first seconds after a
restart are a startup race — traefik builds routes before the `Middleware` CRDs are in its
provider cache — and resolve themselves. `/api/overview` reporting `errors: 0` is the
check that matters.

A route that Traefik has not built answers 404 from Traefik itself; anything else — 403
included — means the request reached the backend.
