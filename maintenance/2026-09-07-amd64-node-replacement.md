# the amd64 node was replaced — 2026-09-07

`dell-amd64-srv` (Dell Precision 5510, 16 GB, Wi-Fi only, `192.168.0.60`) was retired and
`dell-amd64-32gb-srv` (Dell OptiPlex 7040, 32 GB, wired, `192.168.0.7`) took over as the
cluster's amd64 worker. Same architecture, so this was a *move*, not a rebuild: every pinned
workload changed one `nodeSelector` and every Longhorn replica was evicted onto the new disk
before the old node was drained and removed.

Having edited a hostname in ~25 places to do that, the pins are now
`kubernetes.io/arch: amd64|arm64` instead — see [below](#the-pins-are-by-architecture-now).

| | old | new |
|---|---|---|
| hostname | `dell-amd64-srv` | `dell-amd64-32gb-srv` |
| address | 192.168.0.60 | 192.168.0.7 |
| box | Dell Precision 5510, i7-6820HQ | Dell OptiPlex 7040, i7-6700 |
| allocatable | 6.5 CPU / 7.5 GiB | 7.6 CPU / 24.1 GiB |
| link | `wlp2s0`, Wi-Fi | `enp0s31f6`, wired — still 100 Mbps |
| Longhorn disk | `/var/lib/longhorn`, 14 GiB used | `default-disk-32gb`, 231.2 GiB, 40 GiB reserved |

The trigger was memory: 25 pods on a 7.5 GiB node, with Jenkins agents on top, is what the
[2026-09-05 hardening incident](../incidents/2026-09-05-node-hardening.md) was about. The new
box has three times the allocatable memory and a cable instead of Wi-Fi.

## Order of work, and why that order

1. **Prepare the host before it holds data.** Swap off and the `/etc/fstab` line commented
   (same reason as the old node); `open-iscsi`, `nfs-common`, `cryptsetup` installed and
   `iscsid` enabled; `iscsi_tcp` loaded and written to `/etc/modules-load.d/longhorn.conf`;
   `multipathd` given a `devnode "^sd[a-z0-9]+"` blacklist so it cannot claim Longhorn's
   block devices; `mirror.gcr.io` put first in containerd's `certs.d/docker.io/hosts.toml`;
   kubelet reservations set to 3Gi system / 2500Mi Kubernetes. Backups of every file edited.
2. **Give Longhorn a disk and a tag.** `createDefaultDiskLabeledNodes` only fires at node
   registration and no node carries that label, so the disk was added by patching
   `nodes.longhorn.io/dell-amd64-32gb-srv` directly. The `amd64` **tag** matters as much as the
   disk: `grafana-data`, `prometheus-data` and `loki-data` are single-replica volumes with
   `spec.nodeSelector: ["amd64"]`, which matches Longhorn tags, not Kubernetes labels — without
   the tag their replicas had nowhere to go and eviction would have sat there failing to
   schedule. Recipes are in [`../arm64-srv/k8s/longhorn/README.md`](../arm64-srv/k8s/longhorn/README.md).
3. **Delete the build cache instead of copying it.** The 15 volumes totalled 41.94 GiB
   actual, and 26.49 GiB of that was `jenkins/buildkit-cache-pvc` — a cache, documented as
   disposable, `reclaimPolicy: Delete`. Deleting the claim took the PV and the Longhorn volume
   with it and cut the migration to ~15.5 GiB. It was recreated empty on the new node
   afterwards; the first build refetches in 5-8 minutes.
4. **Force the rebuilds onto the new node.** `allowScheduling: false` on the *pi's* Longhorn
   node for the duration, so no evicted replica landed on the SD card. Then
   `allowScheduling: false` + `evictionRequested: true` on the old node — Longhorn rejects the
   eviction flag on a node that still accepts scheduling.
5. **Move the pods**, in the order below.
6. **Drain and remove the node**, re-enable scheduling on the pi.

```bash
kubectl drain dell-amd64-srv --ignore-daemonsets --delete-emptydir-data
# on the departing node:
sudo microk8s leave
# then on the control plane, to clear the leftover Node object:
sudo microk8s remove-node dell-amd64-srv
```

`longhorn-system/instance-manager-*` has a PodDisruptionBudget and refuses eviction until its
last replica is gone, so a drain that hangs there means the eviction in step 4 is not actually
finished — `kubectl -n longhorn-system get replicas.longhorn.io -o wide | grep <node>` should
be empty. Longhorn removed its own `nodes.longhorn.io` object when the Node disappeared; no
manual delete was needed.

State at the end: two nodes `Ready`, every pod `Running` and ready, all 16 volumes `healthy`
with 16 replicas on the new node and 12 on the pi. The one exception is the freshly recreated
`jenkins/buildkit-cache-pvc` — `detached`/`unknown` until the next build attaches it, which is
what an empty cache looks like.

## What moved

16 workloads named the old node in a `nodeSelector`:

| what | how it was moved |
|---|---|
| `jenkins/jenkins` | this repo — [`../amd64-srv/k8s/jenkins/deployment.yaml`](../amd64-srv/k8s/jenkins/deployment.yaml) |
| `monitoring/grafana`, `monitoring/loki` | this repo, `amd64-srv/k8s/monitoring/*` |
| `monitoring/prometheus`, `monitoring/jaeger`, `monitoring/otel-collector` | **not here** — ArgoCD owns them via `k8s-infra`'s `components/monitoring-on-amd64`; the hostname was changed in git and `infrastructure-production` self-healed |
| `argocd` ×7 (6 Deployments + the `argocd-application-controller` StatefulSet) | live `kubectl patch` — ArgoCD is installed from upstream manifests, not from a repo here |
| `external-secrets` ×3 | live `kubectl patch`. The Helm release has *no* user-supplied values (`helm get values` is `null`), so the pins were never Helm's to begin with |

Three more were unpinned and would have been scheduled anywhere, including onto arm64:

- `mtaa/backend` — image is `linux/amd64` only,
- `mtaa/postgres` and `xboy/postgres-root` — PGDATA written on amd64.

They were given `nodeSelector: kubernetes.io/arch: amd64` in their own repos (`mtaa`,
`xboy-k8s-infra`), and `xboy/postgres-xboy` / `xboy/postgres-foodiehub` were pinned to
`arm64` for the same reason in the other direction. A cross-architecture reschedule of a
PostgreSQL data directory is an outage, and a node drain is exactly when it happens — see
[`2026-09-06-vaultwarden-to-pi.md`](2026-09-06-vaultwarden-to-pi.md) for the dump-and-restore
that costs.

## The pins are by architecture now

Every one of those `nodeSelector`s named a hostname, so a box swap meant editing ~25
manifests across two repos plus ten live objects — for a move that changed no property any of
those workloads actually cares about. The reasons the pins exist are architectural: arm64-only
and amd64-only images, hostpath volumes on the pi's disk, PGDATA that cannot cross
architectures. So they are now `kubernetes.io/arch`, in both repos and live:

- `infra-services` — jenkins, grafana, loki, bugsink web → `amd64`; bugsink's postgres and its
  backup CronJob, vaultwarden, its postgres and its S3 job → `arm64`.
- `k8s-infra` — `components/pin-to-pi-node` (4 patch files) → `arm64`,
  `components/monitoring-on-amd64` → `amd64`. **Both components must use the same selector
  key**: a strategic merge on `nodeSelector` overrides a key it also sets, so arch here and
  hostname there would leave every monitoring pod asking for both and scheduling nowhere.
- `mtaa`, `xboy-k8s-infra` — the arch pins described above.
- live `kubectl patch` for argocd ×7 and external-secrets ×3, with
  `"kubernetes.io/hostname": null` in the same patch to drop the old key.

Two caveats, both written into the repos: this stops being a pin the day a second node of an
architecture joins, and when replacing a box of an architecture that already has one,
**`kubectl cordon` the outgoing node first** — otherwise `arch: amd64` matches both and the
scheduler is free to put the pod straight back.

It is not free. Changing the selector rewrites every pod template, so pushing the `k8s-infra`
commit restarted all of `apps` and `data` at once; the pi sits at ~9.3 GiB of 9.4 GiB memory
requests, so several pods were briefly `Pending` on `Insufficient memory` while the outgoing
ones released their requests. It settled without intervention in about five minutes, but it is
a restart wave, not a no-op — do it deliberately, not at the end of a long day.

## Calico was autodetecting its address by pinging the node being removed

The one thing that would have broken the cluster *after* the old box was already gone, found
by sweeping for its address rather than its name:

```
IP_AUTODETECTION_METHOD = can-reach=192.168.0.60
```

That is how every `calico-node` picks the address it advertises for its own node. It is
evaluated **at calico-node startup**, so nothing breaks while the pods keep running — the
cluster looks fine right up until a pod restart, a kubelet restart or a reboot, at which point
the surviving node cannot autodetect an address and its networking does not come up. A
node-removal checklist that only greps for the *hostname* misses it completely.

Changed to `kubernetes-internal-ip` (Calico ≥ v3.21; this cluster is v3.28.1), which takes the
address straight off the Node object's `InternalIP` and so names no machine at all:

```bash
kubectl -n kube-system set env ds/calico-node IP_AUTODETECTION_METHOD=kubernetes-internal-ip
```

**Also edit `/var/snap/microk8s/current/args/cni-network/cni.yaml` on the control plane**
(backup: `cni.yaml.bak-before-node-removal-20260907`) — MicroK8s re-applies that file on
start, so a live-only patch is reverted by the next `microk8s stop/start`. Both nodes kept the
same `projectcalico.org/IPv4Address` and VXLAN tunnel address across the rolling restart, and
cross-node pod traffic was unaffected.

## Three things that bit, worth knowing before the next move

**A replica being evicted holds the volume attached to the old node.** The eviction
controller takes its own attachment ticket, so when `xboy/postgres-root` was rescheduled
mid-eviction its new pod sat in `Multi-Attach error` / `the volume is currently attached to
different node` until eviction finished. Deleting the old node's replica for that one volume
released the ticket immediately — safe because the pi's replica was healthy and `RW`, and
losing a replica is what eviction was doing anyway. ~9 minutes down (18:12-18:21 UTC), most
of it the wait and the image pull. **Move the pod after its volume's replicas have moved, or
not at all until the drain.**

**Rebuilds are serialised and the link is 100 Mbps.** `concurrent-replica-rebuild-per-node-limit`
is 1, so ~15.5 GiB went across one volume at a time at ~5 MB/s. Ten simultaneous image pulls
onto the new node competed with it. This is the whole reason the migration took hours rather
than minutes, and the reason both nodes' Gigabit links are still on the list in
[`../Infra.md`](../Infra.md).

**A failed rebuild does not retry — it sits at its last percentage forever.**
`postgres-root-pvc`'s second replica stalled at 55 % and stayed there for half an hour. The
`ssync` transfer had died at 18:49 (`Failed to write data ... unexpected EOF`, then
`Shutting down the server since it is idle for 5m0s` in the receiving `instance-manager`),
almost certainly starved by the concurrent image pulls, but the engine still reported
`isRebuilding: true`, so every reconcile logged *"Skipped rebuilding of replica because there
is another rebuild in progress"* and nothing ever restarted it. `robustness: degraded` with a
frozen `rebuildStatus.progress` is the signature. Deleting the `WO` replica cleared it and the
fresh one completed in under a minute:

```bash
kubectl -n longhorn-system get engines.longhorn.io -o json \
  | jq -r '.items[] | select(.status.rebuildStatus != {}) | "\(.spec.volumeName) \(.status.rebuildStatus)"'
# progress not moving after a few minutes? drop the WO replica, keep the RW one:
kubectl -n longhorn-system delete replicas.longhorn.io <the WO replica>
```

Check the replica directory on the receiving node if in doubt — `du -sm
/var/lib/longhorn/replicas/<volume>-*` not growing is the same signal without trusting status.

## What did not come with the cluster

The old box also ran things Kubernetes never knew about, and they died with it:

- `docker/bugsnik` — Bugsink, whose SQLite database was **in the container layer**, not a
  volume ([`../amd64-srv/docker/bugsnik/README.md`](../amd64-srv/docker/bugsnik/README.md)).
- the `meet-to-meat-services` dependency stack — `postgres-svc` (:5432), `postgres-ai-svc`
  (:5433), `redis-svc` (:6379), `rabbitmq-svc` (:5672/:15672), `otel-collector`
  (:4317/:4318), `jaeger` (:16686) and `prometheus` (:9095), ~2.7 GB of Docker volumes.
- `/home/agent/webdev` — 5.7 G of working copies, served to the coding sandbox over virtiofs.
  Everything relevant is pushed; `bb-tool-api`'s three trees had uncommitted changes.
- a 14.17 GB Docker build cache and two dev database volumes (`db_postgres_data_mm` 143.7 MB,
  `db_postgres_ai_data_mm` 80.52 MB). The cache is disposable; the two volumes are the compose
  copies of what `data` already runs in-cluster.

The OptiPlex has no Docker installed, deliberately: the compose stacks were the old box's
job and the in-cluster `data` namespace already carries the versions that matter.
