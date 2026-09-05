# Local Docker Registry with Image Lifecycle Cleanup

`registry:3.1.1` behind traefik, a read/write UI, and a `registry-cleaner`
sidecar that enforces retention daily.

```
docker compose up -d
```

Storage is the `./data` bind mount. Auth is htpasswd (`./.passwd`), enforced by
the registry itself on :5000, so it applies to every route including the UI's
proxy_pass and the cleaner.

## Retention

`cleanup-registry.sh`, run by the `registry-cleaner` service once on start and
then daily at `CLEANUP_AT` (03:30 UTC).

A manifest has to fail **both** of these to be deleted:

| | default | meaning |
|---|---|---|
| `KEEP_LATEST` | `1` | newest N manifests in a repo are never touched |
| `MAX_AGE_DAYS` | `7` | anything newer than this is never touched |

So: the newest image in every repo lives forever, everything from the last week
lives, and the rest goes. Two escape hatches on top:

- `PROTECT_TAGS` (default `latest`) — a manifest carrying one of these tags is
  kept regardless. Nothing here republishes `latest`, and a dangling `latest` is
  worse than a stale one.
- `PROTECT_DIGESTS_FILE` → `protect-digests.txt` — digests that are actually
  deployed. Keep-newest is not keep-what-is-running; see the comments in that
  file for how to regenerate it and why it is not optional.

Deletion is **by digest**, so every tag pointing at that digest goes with it.
CI pushes both a short and a long git sha, so one deletion usually removes two
tag names — tag counts run about double manifest counts.

### Reclaiming disk

Deleting a manifest through the v2 API only unlinks it. The blobs — where the
gigabytes are — are only freed by `registry garbage-collect`, which the sidecar
runs at the end of each pass (`RUN_GC=1`). That is why the cleaner is built on
`registry:3.1.1` and mounts `./data` read-write: it needs the `registry` binary
and the storage directory. It does **not** get `/var/run/docker.sock`; the
version this replaced used the socket to `docker exec` into the registry
container, which trades root-equivalent control of this host for one bind mount.

distribution has no locking around garbage collection, so a blob uploaded while
GC runs can be collected before its manifest is written. Hence a fixed quiet
hour rather than a run after every push. Don't move `CLEANUP_AT` into CI hours.

### Configuration

`storage.delete.enabled: true` must stay set in `config.yml` — without it every
DELETE returns 405 and the script says so explicitly.

`.env` (not committed) needs, in addition to the four host names:

```
REGISTRY_CLEANER_USER=<a user from .passwd>
REGISTRY_CLEANER_PASSWORD=<its password>
```

Unset means the cleaner runs anonymously, gets 401 on the catalog, and exits
with `FATAL: cannot reach ...` rather than quietly reporting nothing to do.

### Manual runs

Dry run, changing nothing:

```
docker compose run --rm -e DRY_RUN=1 -e LOOP=0 registry-cleaner
```

Collapse every repo to one manifest immediately, ignoring the 7-day window:

```
docker compose run --rm -e MAX_AGE_DAYS=0 -e LOOP=0 registry-cleaner
```

That one-off was run on 2026-08-23 and took the registry from 430 manifests to
35 (395 deleted, 0 failed), with the 24 in-use digests and all `latest` tags
protected. Do the `DRY_RUN=1` version first and read the KEEP lines.

Logs: `docker logs -f registry-cleaner`.
