# Bugsink — error tracking (Sentry-SDK compatible)

`bugsink/bugsink:2.5.1` behind traefik, SQLite on the `./data` bind mount, one
container running both gunicorn and the snappea background worker.

It speaks the **Sentry** ingest protocol, so any Sentry SDK reports to it with
nothing but a DSN change. It is **not** an OTLP endpoint — see
[Where it sits next to otel](#where-it-sits-next-to-otel).

## Bring-up

```bash
mkdir -p data && sudo chown -R 14237:14237 data   # not optional, see below
$EDITOR .env                                      # SECRET_KEY at least
docker compose up -d
docker compose exec bugsink bugsink-manage createsuperuser
```

Then `https://bugsink.internal.example.com` (or `http://<pi>:8000` before DNS and
the certificate exist).

`chown 14237` first, because the image runs as uid/gid 14237 and docker creates
a missing bind-mount source owned by root. Skip it and the container loops on
`attempt to write a readonly database` during migrate, which reads like a
corrupt database rather than a permission problem.

`SECRET_KEY` is blank in the committed `.env` — this repo is public. Generate one
with `openssl rand -base64 50`. Bugsink runs `bugsink-manage check --deploy
--fail-level WARNING` before it serves anything, so a missing or weak key stops
the boot with the reason on stdout instead of shipping a known key.

## Routing

| host | route | TLS |
|---|---|---|
| `${BUGSINK_INTERNAL_HOST}` | `bugsink-internal`, LAN | traefik, `myresolver` (DNS-01) |
| `${BUGSINK_EXTERNAL_HOST}` | `bugsink-external`, cf tunnel | cloudflare, so no certresolver on this router |
| `<pi>:8000` | published port | none |

Both names must be in `ALLOWED_HOSTS` or Django answers **400** to that host and
nothing else explains why; `docker-compose.yml` builds the list from the two
`.env` values so they are written down once. The external hostname also needs an
ingress rule in the Cloudflare dashboard — this tunnel is token-run, so its
routes are not in a file here.

**No basicauth middleware on either router**, deliberately. SDKs POST to
`/api/<project>/envelope/` with only the DSN key, and a middleware in front of
that swallows every event while the UI keeps working. Ingestion is authenticated
by the DSN; the UI has its own login.

## Sending events to it

Create a project in the UI, copy its DSN, and give it to the service:

```
SENTRY_DSN=https://<key>@bugsink.internal.example.com/<project-id>
```

The internal hostname only resolves on the LAN, so anything running off-network
(a phone build, a cloud runner) needs the external one instead.

### Where it sits next to otel

Bugsink ingests Sentry envelopes over HTTP. It does not accept OTLP, and it is
not a replacement for the otel collector → Jaeger path that the platform's
traces already take — traces stay there, crashes come here.

The two line up rather than compete: a Sentry SDK running alongside otel
instrumentation attaches the active `trace_id` to the event it sends, so an
issue in Bugsink names the trace you then open in Jaeger. Keeping both means the
tracing side never has to become an alerting product.

## Email

Alerts and password resets are SMTP. `EMAIL_HOST` blank (as committed) means
bugsink writes mail to the container log rather than sending it — alerts still
appear in the UI, so this is a usable state, not a broken one. Fill in the
`EMAIL_*` block for real delivery; `EMAIL_BACKEND` needs no setting, bugsink
switches to SMTP as soon as `EMAIL_HOST` is non-empty. `EMAIL_LOGGING=true`
prints every subject and recipient, which is how you find out whether alerts
fire at all. Full list: <https://www.bugsink.com/docs/settings/#email>.

Leave `USER_REGISTRATION_VERIFY_EMAIL=false` until mail actually sends,
otherwise an invited user is stuck behind a verification link that was only ever
logged.

## Database

SQLite, at `./data/db.sqlite3`. That is bugsink's own production default, not a
downgrade: one writer, no server, and the whole database is one file.

Postgres is staged but not running — the commented `db` service in
`docker-compose.yml` plus `DATABASE_URL` in `.env`. Switching is not a
migration: the new database starts empty and old events do not follow
(<https://www.bugsink.com/docs/postgresql/>).

Backups: copy the file with `sqlite3 data/db.sqlite3 ".backup /tmp/bugsink.db"`,
not `cp` — a plain copy of a live SQLite file can land mid-write. Retention is
per project in the UI (an event budget per project), so the file does not grow
without bound; `FILE_EVENT_STORAGE_PATH` in `.env` moves the bulky part out to
flat files if it does.

## Operating

```bash
docker compose logs -f bugsink          # gunicorn access log + snappea
docker compose exec bugsink bugsink-manage <cmd>
docker compose ps                       # healthcheck is GET /health/ready
```

Upgrades are a tag bump plus `docker compose up -d`; migrations run in the
container's own start command, so there is no separate step. Read the release
notes first — `scripts/check-image-updates.py` reports when this tag is behind,
and it never bumps it for you.

## Gotchas

- **Client IPs from the external route are the tunnel's, not the caller's.**
  `BEHIND_HTTPS_PROXY=true` makes bugsink read `X-Real-Ip`, which traefik sets
  (and strips from callers, correctly). But for tunnel traffic the caller
  traefik sees *is* cloudflared, so every external event carries cloudflared's
  container IP. LAN traffic is accurate. Switching to `X-Forwarded-For` does not
  fix it either: it needs one fixed `X_FORWARDED_FOR_PROXY_COUNT` and the two
  routes have different hop counts.
- **`BEHIND_HTTPS_PROXY` is not optional behind traefik.** Without it Django
  sees plain HTTP, and every login POST fails CSRF with `(wrong scheme)`.
- **Inline comments in `.env` are part of the value.** compose's env-file parser
  is not a shell; keep comments on their own lines.
- **Numeric settings must not be blank.** An empty `SNAPPEA_NUM_WORKERS` or
  `EMAIL_PORT` reaches `int("")` and kills the boot. Blank is only safe for the
  string settings that are explicitly optional here.
- **`CREATE_SUPERUSER` only fires when the instance has zero users**, so it is
  no use for a forgotten password. `bugsink-manage changepassword <email>` is.
