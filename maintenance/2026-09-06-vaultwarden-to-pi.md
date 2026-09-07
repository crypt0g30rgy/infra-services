# vaultwarden → the pi — 2026-09-06

`vaultwarden` and its `postgres` StatefulSet ran on `dell-amd64-srv`. They are the only
*critical* service that was on the node the cluster is allowed to lose, so both moved to
`pi-5-16gb-srv-0`. The pod was a `nodeSelector` edit; the database was a dump and a restore,
because a PostgreSQL data directory written by an x86_64 build is not portable to aarch64
(same reason as `postgres-foodiehub` in
[`2026-09-05-postgres-15-to-18.md`](2026-09-05-postgres-15-to-18.md)).

| | before | after |
|---|---|---|
| `vaultwarden` | dell | **pi** |
| `vaultwarden/postgres` | dell, 18.6 | **pi, 18.6** (fresh `initdb`, restored) |
| `vaultwarden-backup` CronJob | unpinned | **pi** — it mounts the same RWO claim as the pod |
| `postgres-data-postgres-0` | `pvc-8fb90215…` | `pvc-f48f6e13…` (new 5Gi longhorn volume) |
| `vaultwarden-data` | dell | reattached on the pi, same volume |

Row counts before and after are identical: 3 users, 597 ciphers, 25 devices, 1 folder,
1 organization, 0 attachments, 0 sends, 29 tables.

## What was done

1. Baseline counts, then `scale deploy/vaultwarden --replicas=0` — no writer while dumping.
2. `pg_dump --no-owner --no-privileges` of the `vaultwarden` database and a full `pg_dumpall`,
   both from inside the pod, checksummed. Last night's off-site backup (00:00Z, eu-west-1)
   was the second copy.
3. `delete statefulset postgres` and `delete pvc postgres-data-postgres-0`. The
   `storageClassName: longhorn` PV is **Retain**, so the old volume is still there as
   `pvc-8fb90215-bbfc-442f-9653-720544599698`, `Released`.
4. Applied the StatefulSet with the pi's `nodeSelector`; a new PVC and an empty 18.6 cluster
   came up in ~30 s, then `psql --single-transaction -v ON_ERROR_STOP=1` restored the dump.
5. Applied the Deployment (also `maxSurge: 0`, which it lacked — its `/data` claim is RWO)
   and scaled back to 1. The Longhorn volume detached from dell and attached on the pi; the
   arm64 image was not cached there, so the pull added ~90 s.
6. Verified from a pod in the cluster: `/alive` 200, `/api/config` 200,
   `/identity/accounts/prelogin` 200 (that one reads the database).
7. Ran `vaultwarden-backup` by hand from its new node: 8/8 steps, database and `/data`
   uploaded and checksummed.

Vault unreachable from 23:42 to 23:49 UTC, ~7 minutes, most of it the image pull.

## The old volume had to go, and why that is the interesting part

The new claim came up **degraded, with its only replica on dell**:
`ReplicaSchedulingFailure: insufficient storage` on the pi. Its Longhorn disk
(`/var/lib/longhorn`, 114.7Gi) reserves 60Gi, so the scheduling budget is 54.7Gi and 54.0Gi
of it was already committed across 13 replicas — including 5Gi still held by the old
vaultwarden volume. Left that way, a vault on the pi would have read every row over the Wi-Fi
link and gone down with dell, which is the dependency this move existed to remove.

So `pvc-8fb90215-…` was deleted (PV and `volumes.longhorn.io`), the replica built on the pi
within ~70 s, and the volume is `healthy` with one replica per node. Row counts and the
endpoint checks were repeated after the rebuild and still match.

That makes the rollback path the two S3 copies rather than a volume: the pre-move nightly
(00:00Z) and the post-move run, each a `pg_dump` plus a `/data` tarball with checksums. The
deleted directory was x86_64 and only a pod on dell could have read it anyway.

**The pi has ~0.7Gi of Longhorn scheduling budget left.** The next volume there fails the
same way unless the 60Gi reservation comes down or something is evicted — worth knowing
before the next database moves over.

## Capacity

Neither vaultwarden pod declares `resources`, so this added nothing to the pi's request
totals — it also means both are `BestEffort` and first in line for eviction, on a node at 95%
CPU and 82% memory requests. Giving them modest requests is the obvious follow-up; see
[`../k8s.md`](../k8s.md), "Node placement", and
[`../incidents/2026-09-05-node-hardening.md`](../incidents/2026-09-05-node-hardening.md) for
why BestEffort on a loaded node is what corrupted three databases.
