# ingress

One Traefik, one cloudflared, applied by hand. Nothing in this directory is reconciled by
ArgoCD, so editing a file here changes nothing until you apply it — and a ConfigMap change
needs a restart on top, because Traefik reads its static configuration once at start.

```bash
kubectl apply -f pi5-arm64/k8s/ingress/traefik/base/ -f pi5-arm64/k8s/ingress/traefik/internal/configmap.yaml
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
| `traefik/base/deployment.yaml` | the Deployment: traefik + a `logrotate` sidecar (so a pod reads 2/2) |
| `traefik/base/service.yaml` | the three Services above |
| `traefik/base/rbac.yaml` | ServiceAccount, ClusterRole, binding |
| `traefik/base/pvc.yaml` | `traefik-data`, 1Gi RWO longhorn, mounted at `/data` for access logs |
| `traefik/base/middleware.yaml` | `cluster-identity-header`, and an `-external` copy |
| `traefik/base/servicemonitor.yaml` | see "Metrics" below — this object does nothing today |
| `traefik/internal/configmap.yaml` | `traefik-config`: the whole static configuration |
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

## 4. Metrics

Traefik exposes prometheus metrics on `:8082` (`traefik-metrics`), and **nothing scrapes
them.** `servicemonitor.yaml` creates a `ServiceMonitor`, and the CRD exists, but there is
no Prometheus Operator here: prometheus is a plain Deployment with a static
`scrape_configs` list in `k8s-infra/infrastructure/base/monitoring/prometheus.yaml`, which
has no traefik job. Either add the job there or stop applying this file; leaving both is
what makes a `ServiceMonitor` look like coverage.

The unprovisioned dashboard JSON in `../monitoring/dashboards/` is from the same
misunderstanding. The dashboards that are actually loaded are ConfigMaps under
`../monitoring/grafana/`.

## 5. Log rotation and disk retention

Access logs are written in structured JSON to `/data/logs/access.log` on the 1Gi
`traefik-data` PVC. A sidecar named `logrotate` keeps that bounded: it checks the file
every 5 minutes and, above **50 MiB**, copy-truncates it to `access.log.1`, keeping **3**
archives. Worst case on disk is roughly 250 MiB including one in-flight copy.

It is a plain `sh` loop in `traefik/base/deployment.yaml`, not the `logrotate` package, and
runs as 65532 with a read-only root filesystem. It reports each rotation on stdout, so
`kubectl logs deploy/traefik -c logrotate` is the place to look.

**Why not the actual `logrotate` tool.** It was, until 2026-08-22, and it had rotated
nothing since the day it was deployed — `access.log` reached **287 MB on a 1 Gi volume**
while the sidecar sat there reporting `Running`. Two independent faults, either of which
was enough:

- It installed the package at container start with
  `apk add --no-cache logrotate >/dev/null 2>&1`. On the pi that silently failed — every
  Cloudflare IPv4 edge is unreachable from that host and `dl-cdn.alpinelinux.org` is behind
  it — leaving a loop that called a binary that did not exist, with the error discarded.
- Its config said `su 65532 65532`. `logrotate` resolves those through
  `getpwnam`/`getgrnam`, the alpine image has no such user or group, and it answered
  `unknown group '65532'` → `skipping` → `Handling 0 logs`. So it rotated nothing even on a
  node where the install worked.

The shell version has nothing to install and no name to resolve. Verify a change to it the
way this was caught, rather than trusting `Running`:

```bash
kubectl -n ingress logs deploy/traefik -c logrotate
kubectl -n ingress exec deploy/traefik -c logrotate -- sh -c 'df -h /data; ls -la /data/logs'
```

That 287 MB file is still on the volume as `access.log.2` — the rotation that fixed this
shifted it rather than deleting it, and it ages out after two more rotations. Reclaim it
early with `kubectl -n ingress exec deploy/traefik -c logrotate -- rm /data/logs/access.log.2`.

## 6. Verify

```bash
kubectl -n ingress get pods                    # traefik 2/2, cloudflared 1/1
kubectl -n ingress get svc                     # traefik-external holds 192.168.1.201
kubectl get ingress -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,ADDR:.status.loadBalancer.ingress
kubectl -n ingress logs deploy/traefik -c traefik | grep -E 'level=(error|fatal)'
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: users-api-gw.xboy.me' http://192.168.1.201/
```

A route that Traefik has not built answers 404 from Traefik itself; anything else — 403
included — means the request reached the backend.
