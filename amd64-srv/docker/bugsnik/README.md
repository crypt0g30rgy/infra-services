# Bugsink — the amd64 instance

One instance per node. This is the amd64 one; the arm64 one is
[`../../../arm64-srv/docker/bugsnik/`](../../../arm64-srv/docker/bugsnik/README.md),
and that README covers everything shared: what bugsink is, how it relates to the
otel/Jaeger path, `.env` keys, email, the SQLite-vs-Postgres decision, and the
gotchas. Only the per-node differences are here.

| | arm64 instance | this one |
|---|---|---|
| Reached via | traefik on 443, two hostnames, cf tunnel for the external one | directly on `:8000` |
| Network | external docker network `internal`, shared with traefik | the project's own bridge |
| `BEHIND_HTTPS_PROXY` | `true` — required behind traefik | `false` — nothing terminates TLS here |
| Host port | 8001 (traefik owns 443) | 8000 |
| Memory limit | 768M | 512M — this node reserves 6Gi for non-Kubernetes work |
| Deployed from | `~/bugsnik/` on that host | this directory |

The compose files are separate rather than shared because the arm64 one declares
`networks: internal: external: true`, and no network named `internal` exists on
this host — applying it here fails outright.

## Two things to fix on this node

**1. The running container has no bind mount.** As of 2026-09-05 its
`/data/db.sqlite3` (684K) is in the container's writable layer, so
`docker compose down` or a forced recreate loses every recorded issue. The
compose file here adds `./data:/data`, which means the next `up` *will* replace
the container. Rescue the database first — the exact sequence is in the header of
`docker-compose.yml`.

**2. `.env` is a copy of the arm64 node's.** It carries the same
`BUGSINK_INTERNAL_HOST`, the same `SECRET_KEY`, and `SITE_TITLE=Bugsink (pi5)`,
which is why this instance is easy to mistake for the other one in a browser tab.
Before the next `up`:

- set `BUGSINK_NODE_HOST` to this node's name or address (the compose file falls
  back to `192.168.0.60`, its current LAN address, if unset)
- give it its own `SITE_TITLE`, e.g. `Bugsink (amd64)`
- generate a separate `SECRET_KEY` with `openssl rand -base64 50` — two servers
  sharing one signing key means a session cookie from either is valid on both

`.env` is gitignored, so none of this is in the repo; it has to be done on the
host.

## Why two instances at all

They are independent: separate SQLite databases, separate projects, separate
DSNs. A crash reported to one is not visible in the other, so pick per service
which node's DSN it uses and keep it consistent — usually the node the service
runs on, so an error report does not depend on the link between the two machines
being up.
