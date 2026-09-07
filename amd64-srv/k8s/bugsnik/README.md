# Bugsink — the in-cluster instance

`bugsink/bugsink:2.5.1` in `monitoring` on `dell-amd64-32gb-srv`, with PostgreSQL 18 in `data`
on the pi, dumped nightly to the local MinIO. Reachable from `ingress`, `xboy`, `apps`, `mtaa`;
allowed out to DNS and its own database only. Deployed 2026-09-06, and **not running as of
2026-09-07**: no `bugsink` workload exists in the cluster, so the manifests here describe what
to re-apply, not what is live.

Two things here are deliberately not what runs: the hostname (everything says
`bugsink.example.com`; the real one is only in the cluster — `kubectl -n monitoring get
ingress bugsink`) and the credentials (`bugsink-secret.yaml` is placeholders, never applied).

What bugsink *is* — the Sentry ingest protocol, retention, `bugsink-manage` — is in the
shared reference for all three instances:
[`../../../arm64-srv/docker/bugsnik/`](../../../arm64-srv/docker/bugsnik/README.md).

| | arm64 compose | amd64 compose | this one |
|---|---|---|---|
| Runs on | pi, docker | dell, docker | k8s: web on dell, database on the pi |
| Database | SQLite bind mount | SQLite in the container layer (!) | PostgreSQL 18, StatefulSet in `data` |
| Backup | by hand | none | nightly `pg_dumpall` → local MinIO |
| Reached via | compose traefik, `bugsink.internal.example.com` | `<dell>:8000` | k8s traefik, own hostname |
| Outbound | unrestricted | unrestricted | DNS + its database |

## Files

| file | what |
|---|---|
| `bugsink-config.yaml` | `bugsink-config` in `monitoring` — every non-secret setting, i.e. the compose `.env` |
| `bugsink-secret.yaml` | **never applied**: placeholders for `bugsink-secret` (`monitoring`) and `postgres-bugsink-secret` (`data`) |
| `bugsink-postgres.yaml` | `postgres-bugsink` StatefulSet + headless Service, `data`, on the pi |
| `bugsink-deployment.yaml` | the Deployment and its Service on 8000, `monitoring`, on dell |
| `bugsink-ingress.yaml` | the UI through the k8s traefik |
| `bugsink-networkpolicy.yaml` | the deny, the four allowed namespaces, the cross-namespace pairs |
| `bugsink-backup-cronjob.yaml` | `db-backup-postgres-bugsink` in `data`, 04:15 UTC |

Keeping both Secrets in one never-applied file is what makes an `apply` of anything else
here safe: nothing in this directory can blank a live password.

## Two namespaces

Databases run on the pi, in `data` with `postgres-svc`/`postgres-ai-svc`; dell takes the
stateless half with the rest of the infrastructure ([`../../../k8s.md`](../../../k8s.md),
"Node placement"). Consequences:

- `DATABASE_URL` needs the FQDN `postgres-bugsink.data.svc.cluster.local`, and each hop needs
  a rule on both sides — `data` denies by default.
- `POSTGRES_DB`/`POSTGRES_USER`/`POSTGRES_PASSWORD` are duplicated, since no keyRef crosses
  namespaces. Change them in both places.
- An event write crosses the LAN (100 Mbps between the nodes). Ingest POSTs return before
  snappea writes, so this is dump and UI latency, not SDK latency.
- The backup job mounts `data`'s existing `db-backup-*` objects instead of a fourth copy of
  the script.

## Bring-up

```bash
# 1. credentials, generated on the host. One password, two namespaces: one connection with
#    an end in each. hex, because it goes into DATABASE_URL (urlparse).
PGPW="$(openssl rand -hex 24)"
kubectl -n monitoring create secret generic bugsink-secret \
  --from-literal=SECRET_KEY="$(openssl rand -base64 50)" \
  --from-literal=POSTGRES_PASSWORD="$PGPW"
kubectl -n data create secret generic postgres-bugsink-secret \
  --from-literal=POSTGRES_DB=bugsink --from-literal=POSTGRES_USER=bugsink \
  --from-literal=POSTGRES_PASSWORD="$PGPW"
unset PGPW

# 2. database first: bugsink migrates at boot and stays unready until 5432 answers.
kubectl apply -f bugsink-postgres.yaml
kubectl -n data rollout status statefulset/postgres-bugsink

# 3. the rest, real hostname substituted. One file per apply: sed-ing several into one
#    stream drops the `---` separators and the API server rejects it.
for f in bugsink-config.yaml bugsink-networkpolicy.yaml bugsink-deployment.yaml \
         bugsink-ingress.yaml bugsink-backup-cronjob.yaml; do
  sed 's/bugsink\.example\.com/<the real host>/g' "$f" | kubectl apply -f -
done
kubectl -n monitoring rollout status deploy/bugsink

# 4. the first user, last. CREATE_SUPERUSER fires only at zero users; after that it is
#    `bugsink-manage createsuperuser` / `changepassword <email>`.
kubectl -n monitoring patch secret bugsink-secret --type=merge \
  -p '{"stringData":{"CREATE_SUPERUSER":"you@example.com:<32 random alnum chars>"}}'
kubectl -n monitoring rollout restart deploy/bugsink
```

The real hostname is not in this repo — it is public, and a name that resolves gets scanned.
Two files carry the placeholder and change together: `bugsink-config.yaml` (`BUGSINK_HOST`,
which the Deployment turns into `BASE_URL` and `ALLOWED_HOSTS`) and `bugsink-ingress.yaml`.
`SECRET_KEY` must differ from both compose instances' — a shared signing key means a session
cookie from either is valid on both.

`traefik-external` answers 403 to anything that is not the tunnel, so before the CNAME
exists (or from a LAN machine) the only way in is
`kubectl -n monitoring port-forward svc/bugsink 8000:8000`.

## Settings

Same key set as the compose `.env` ([reference](https://www.bugsink.com/docs/settings/)),
split into `bugsink-config` (non-secret, committed) and `bugsink-secret`. Both arrive by
`envFrom`, the Secret second, and the Deployment's `env:` wins over both — `PORT`, `POD_IP`,
`ALLOWED_HOSTS`, `BASE_URL` and `DATABASE_URL` are there because each is derived or a
`fieldRef`. `$(VAR)` is kubelet's expansion and does resolve `envFrom` values.

Differences from the docker instances: `DATABASE_URL` instead of `DATABASE_PATH` (replaces
the whole `DATABASES` entry, so no file and no volume); `SITE_TITLE=Bugsink (k8s)`;
`BUGSINK_HOST` instead of the internal/external pair; blank `EMAIL_HOST` and
`PHONEHOME=false` because egress denies both destinations.

An edit is an apply plus `kubectl -n monitoring rollout restart deploy/bugsink` — `envFrom`
is read once at container start. A bad value crashloops with the reason on stdout
(`check --deploy --fail-level WARNING` runs before serving); blank numeric settings reach
`int("")`.

## Why PostgreSQL when both compose instances run SQLite

The backup, not SQLite being wrong. Every other database here is dumped by one shared
`pg_dumpall` CronJob, so this puts the instance on the same nightly footing with a *verified*
dump rather than a volume snapshot. No `FILE_EVENT_STORAGE_PATH` is set, so event bodies live
in the database and the whole instance is in that dump; turning it on would put data outside
the backup. Switching is not a migration — a new database starts empty, and the compose
instances keep their own issues.

## Sending events to it

```
SENTRY_DSN=https://<key>@<public host>/<project-id>                              # what the UI shows
SENTRY_DSN=http://<key>@bugsink.monitoring.svc.cluster.local:8000/<project-id>   # what a pod uses
```

The public name resolves to Cloudflare, which egress denies — a pod using the DSN as shown
hangs. Plain HTTP to the Service is correct, not a downgrade: `BEHIND_HTTPS_PROXY` adds no
redirect and the traffic never leaves the cluster.

## Network policy

Deny outgoing, allow in from `ingress`, `xboy`, `apps`, `mtaa`. Details in
`bugsink-networkpolicy.yaml`; four things before touching it:

- **Every cross-namespace hop is two rules**, and a cross-namespace selector needs the
  `namespaceSelector` and `podSelector` in **one** list item — two items mean "any pod over
  there, or that label anywhere".
- **Nothing here uses `podSelector: {}`.** `monitoring` is shared with grafana, prometheus,
  loki, jaeger and the otel collector, so a namespace-wide deny would break scraping and
  every app's OTLP. `data` already has `data-default-deny`.
- **Two rules that "should" be edits in `xboy-k8s-infra` are additive policies instead**,
  because selfHeal reverts hand edits to tracked objects. Objects applied here are untracked
  (that Application tracks by annotation), so they survive syncs.
- **`apps` cannot be worked around that way**: its own default-deny allows this namespace on
  4317/4318 only, so an `apps` sender is dropped on the way *out*. The snippet to add there
  is in the policy file's header. `mtaa`, `ingress`, `xboy` need nothing.

Kubelet probes are unaffected — verified here: a pod with an Ingress+Egress deny went Ready
while a curl from another pod timed out. Calico does not apply workload policy to traffic
from the pod's own node.

The deny costs: no phone-home, no SMTP (alerts land in the container log, and the UI still
shows them), no outbound webhooks, no internet fetches. DNS to `kube-system` is the carve-out.

## Backup

`db-backup-postgres-bugsink`, 04:15 UTC, after the six existing dumps so no two share the
pi's CPU. Retention and the verify-by-readback are the shared script's.

```
s3://db-backups/auto-backup/data/postgres-bugsink/postgres-bugsink-<UTC ts>.sql.gz
```

```bash
kubectl -n data create job --from=cronjob/db-backup-postgres-bugsink backup-now
kubectl -n data logs -f job/backup-now && kubectl -n data delete job backup-now
```

`DUMP_VERIFIED_OK`, `UPLOAD_VERIFIED_OK`, `BACKUP_COMPLETE` are the lines that matter; the
first run did all three on 2026-09-06. The dump is **not** `--clean`, so restore into an
empty server; and `pg_dumpall` (18.6 in the image) refuses a newer server, so bumping past
18 means rebuilding `tools/s3-backup` first.

## Operating

```bash
kubectl -n monitoring logs -f deploy/bugsink            # gunicorn + snappea
kubectl -n monitoring exec -it deploy/bugsink -- bugsink-manage <cmd>
kubectl -n data exec -it statefulset/postgres-bugsink -- psql -U bugsink bugsink
```

An upgrade is a tag bump plus an apply — migrations run in the container's start command.
`scripts/check-image-updates.py` reads this directory and reports a behind tag without
bumping it. A PostgreSQL major bump is not a tag edit
([`../../../maintenance/2026-09-05-postgres-15-to-18.md`](../../../maintenance/2026-09-05-postgres-15-to-18.md)),
and neither is moving the database to dell: data directories cannot cross architectures.

`maxSurge: 0` is about migrations, not storage — a surged pod means two versions migrating
one database. `FailedScheduling ... Insufficient memory` on a restart means Jenkins agents
(1792Mi each) are holding dell's budget; it clears when they finish.

## Gotchas

- **`ALLOWED_HOSTS` must contain the pod IP.** Kubelet probes use it as the `Host` header and
  Django answers 400 to anything unlisted — the pod never goes Ready, with nothing in the
  events to say why.
- **The committed hostname is a placeholder**: applied as-is, the UI 400s on its own name.
- **The two traefiks are different proxies.** `bugsink.internal.example.com` belongs to the
  compose one on the pi; this instance must keep its own hostname.
- **`BEHIND_HTTPS_PROXY=true` is required** — TLS ends at Cloudflare, so without it every
  login POST fails CSRF with `(wrong scheme)`.
- **Client IPs from the tunnel are cloudflared's.** LAN and in-cluster senders are accurate.
- **An edited ConfigMap or Secret does nothing until a restart.**
