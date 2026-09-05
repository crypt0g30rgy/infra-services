# Incident Report — Cluster-wide Pod Recreation, 2026-09-05 ~00:45–01:19 UTC

**Cluster:** MicroK8s v1.35.6, 2 nodes, context `admin-context`
**Report written:** 2026-09-05 ~08:00 UTC
**Last updated:** 2026-09-05 ~14:50 UTC — §§9–12 appended after the report was first
written: the three damaged PostgreSQL volumes (`mtaa`, `vaultwarden`, `xboy`) were
repaired and verified with no data loss, `mtaa` gained the nightly S3 backup it never
had, and every backup job in the cluster moved onto one prebuilt image. §§1–8 are the
original 08:00 analysis and are left as written; where they are now out of date the
bullet is struck through with a pointer forward.
**§13 is the one that matters:** both nodes were later reached over SSH and their
journals plus `sar` history settle the root cause. **The trigger was not the control
plane.** `dell-amd64-srv` exhausted memory and swap and collapsed into disk thrash;
everything else, the apiserver stall included, followed from that. §§1, 4 and 5 are
corrected in place with pointers to §13.
**Investigated from:** `coding-bot-webdev` (an admin workstation, **not** a cluster node — see [Investigation gaps](#8-investigation-gaps))
**Severity:** Cluster-wide disruption of all workloads on one node; ~30 min of control-plane unavailability; two monitoring volumes left damaged — and, discovered after this line was
first written, **three PostgreSQL volumes** damaged as well (§9, §11).

> All timestamps in this report are **UTC**, taken from Kubernetes API object fields
> (`creationTimestamp`, `lastTransitionTime`, `finishedAt`).
> Note that `kubectl logs --timestamps` prefixes lines with the *node's local* time,
> which is **UTC+3** on both nodes. Where a log line is quoted, the embedded
> klog timestamp (e.g. `I0905 01:09:43`) is the UTC one.

---

## 1. Executive summary

At approximately **00:45 UTC** the control plane lost contact with the worker node
`dell-amd64-srv`. Five minutes later — at **00:50:02 UTC**, exactly the default
toleration window — Kubernetes' taint-based eviction deleted **every non-DaemonSet pod
on that node**. Their controllers immediately recreated them, some onto the control-plane
node and some back onto the worker, producing the appearance that "everything restarted".

**This was neither a node reboot nor a redeployment.** The containers on the worker node
never stopped. ~~What failed was the *control plane's ability to serve requests* —
kube-apiserver / k8s-dqlite on the Raspberry Pi 5.~~ **Corrected — see §13:** what failed
first was `dell-amd64-srv` itself, which ran out of memory and swap and collapsed into
disk thrash (load average **580**, 47 tasks in `D` state, 300 MB/s of swap-in) at
**00:40–00:52 UTC**. The apiserver *did* then stall, and the reasoning in §5 about the
01:09:43 leader-election deaths is sound — but it was the second link in the chain, not
the first. The subsequent eviction and volume-reattach storm made that worse, culminating
in a hard apiserver stall at **01:09:43 UTC** that killed leader-election clients running
on the control-plane node itself. The cluster stabilised at **01:18:32 UTC**.

The same failure had already occurred **~21 hours earlier** (2026-09-04 10:42 UTC),
making this a recurring condition rather than a one-off.

~~**Root cause (high confidence, one inference outstanding):** kube-apiserver / k8s-dqlite
on `pi-5-16gb-srv-0` became unable to serve requests within timeout. The precise
sub-cause (dqlite write latency vs. resource starvation) requires node-level journals
that were not reachable from the investigation host.~~

**Root cause (confirmed from node journals and `sar`, §13):** `dell-amd64-srv` is
chronically overcommitted — `%commit` sits at ~200 % of RAM+swap — and between 00:20 and
00:52 UTC it filled all 4 GiB of swap (99.93 %), squeezed the page cache down to ~15 MB
and entered sustained direct reclaim, reading 300 MB/s off its SATA SSD purely to service
2,200 major faults/s. Userspace stopped making progress for tens of seconds: even
`systemd-journald` missed its watchdog. The Longhorn engine on that node could not answer
iSCSI NOP-outs inside the **5 s** `noop_out_timeout`, so its own sessions dropped and
ext4 aborted the journal on three attached PostgreSQL volumes; containerd/PLEG stalled
past its threshold, the kubelet went `NotReady`, and 300 s later the taint manager
evicted everything. The resulting 21-pod recreation and ~10 volume detach/attach cycles
then drove the Pi's k8s-dqlite — whose datastore lives on an **SD card** — from 14 ms to
54 ms write latency, producing `database is locked` at 00:52:08 and
`context deadline exceeded` at 01:10:10, which is what the 01:09:43 apiserver
`http: Handler timeout` and the cluster-wide leader-election failures came out of.

---

## 2. Environment

```
$ kubectl get nodes -o wide
NAME              STATUS   ROLES    AGE    VERSION   INTERNAL-IP    OS-IMAGE             KERNEL-VERSION      CONTAINER-RUNTIME
dell-amd64-srv    Ready    <none>   13d    v1.35.6   192.168.0.60   Ubuntu 24.04.4 LTS   6.8.0-138-generic   containerd://2.1.6
pi-5-16gb-srv-0   Ready    <none>   329d   v1.35.6   192.168.0.59   Ubuntu 24.04.4 LTS   6.8.0-1060-raspi    containerd://2.1.6
```

`ROLES` shows `<none>` for both because MicroK8s uses its own labels. The actual roles:

| Node | Role | Arch | Node disk | Notes |
|---|---|---|---|---|
| `pi-5-16gb-srv-0` | `node.kubernetes.io/microk8s-controlplane` | arm64 | 114.7 GiB (75.7 used) | Raspberry Pi 5, 16 GB. **Hosts the control plane.** |
| `dell-amd64-srv` | `node.kubernetes.io/microk8s-worker` | amd64 | 465.5 GiB (161.4 used) | Joined 13d ago. Worker only. |

Storage is **Longhorn**; ingress is **Traefik + cloudflared**; GitOps is **ArgoCD**;
observability is **Prometheus + Loki + Grafana + promtail + otel-collector**.
There are no static control-plane pods in `kube-system` — under MicroK8s the API server
runs as a host-level snap service (`kubelite`), with `k8s-dqlite` as the datastore.
This matters: **the control plane leaves no pod logs inside the cluster.**

---

## 3. What the two obvious explanations would have looked like — and why both are wrong

### 3.1 Not a node reboot or kubelet container loss

If `dell-amd64-srv` had rebooted, or if containerd had been restarted, every container on
it would show an incremented restart count. It does not:

```
$ kubectl get pods -A -o wide | awk '$8=="dell-amd64-srv"'
kube-system       calico-node-cqvnn                     1/1  Running  0  13d
longhorn-system   engine-image-ei-493e04e7-gpwfr        1/1  Running  0  13d
monitoring        promtail-69dws                        1/1  Running  0  9d
```

`longhorn-manager-464pp` on dell has likewise been running continuously since
`2026-08-22T17:22:40Z`. **These containers ran straight through the incident.**
The node's workloads were destroyed by the *control plane deciding the node was gone*,
not by anything happening on the node.

The set of survivors is itself the diagnosis. Every pod that survived on dell is a
**DaemonSet** pod (`calico-node`, `engine-image-ei`, `promtail`, `longhorn-csi-plugin`,
`metallb speaker`). DaemonSet pods are admitted with a toleration for
`node.kubernetes.io/not-ready:NoExecute` and **no `tolerationSeconds`** — they are never
evicted. Ordinary pods get `tolerationSeconds: 300`. That is precisely the observed
behaviour, and it dates the NotReady transition to **300 s before 00:50:02 ⇒ ~00:45:02**.

### 3.2 Not a redeploy, ArgoCD sync, or image rollout

A rollout creates a **new ReplicaSet** and bumps the Deployment revision. Every
ReplicaSet backing the recreated pods long predates the event:

```
$ kubectl get rs -A --sort-by=.metadata.creationTimestamp
monitoring   loki-6cdc487dd7                  1  1  1   9d      <- pod recreated 00:51:53
ingress      traefik-7665ccff8                1  1  1   9d      <- pod recreated 00:50:05
ingress      cloudflared-f454789c7            1  1  1   9d      <- pod recreated 00:50:03
xboy         nextjs-root-app-5769b97c6        1  1  1   6d20h   <- pod recreated 00:50:02
xboy         nextjs-foodiehub-app-8db6cbb9c   1  1  1   4d12h   <- pod recreated 00:50:05
```

StatefulSets are equally untouched (`argocd-application-controller` 183d, `mtaa/postgres`
9d, `vaultwarden/postgres` 13d) while their pods are ~7h old. **Only Pod objects are new.**
Nothing was re-templated, re-synced, or re-pulled.

### 3.3 Not a `kubectl drain`, and not the `rs-cleaner` CronJob

A drain was considered because `kubectl drain --ignore-daemonsets` would delete exactly
the same set of pods. It is ruled out because a drain **cordons** the node, yet
replacement pods were scheduled *back onto dell* at 00:51:48 — and no taints or
`unschedulable` flag exist now or are consistent with that window. A drain also would not
explain the node's `Ready` condition transitioning at 01:18:32, nor the apiserver
timeouts at 01:09:43.

The `kube-system/rs-cleaner` CronJob was also examined, since a cleanup job is an
attractive suspect. Its script was read in full: it deletes only ReplicaSets with
`spec.replicas == 0` older than 3 days, and only pods in phase `Succeeded` older than
3 days. It cannot delete a running pod. Its last run completed at **00:02:27**, 48 minutes
before the event.

---

## 4. Timeline

Reconstructed from `metadata.creationTimestamp`, the `PodScheduled` and `Ready` pod
conditions, `status.containerStatuses[].lastState.terminated`, node
`status.conditions[].lastTransitionTime`, and the Longhorn `nodes.longhorn.io` CRD.

| Time (UTC) | Event | Evidence |
|---|---|---|
| **09-04 10:42** | **Prior occurrence of the same failure.** pi-5's four node conditions all transition; Longhorn's pi-5 `Ready` transitions at 10:42:46; the Longhorn CSI controller sidecars restart with `startedAt` 10:42:11–10:42:21. | node conditions; `nodes.longhorn.io`; container `startedAt` |
| ~00:45:02 | `dell-amd64-srv` marked NotReady. **Inferred** — 300 s before the evictions. | 300 s default `tolerationSeconds` |
| **00:50:02–00:50:06** | **Taint-based eviction deletes every non-DaemonSet pod on dell.** ~21 pods deleted within a 4-second window. | 21 pods share `creationTimestamp` in this range |
| 00:50:02–00:50:27 | 15 replacements schedule **immediately onto pi-5**: `coredns`, `traefik`, `cloudflared`, all 4 `nextjs-*` apps, `postgres-root`, `postgres-foodiehub`, `grafana`, the 4 Longhorn CSI sidecars, `longhorn-driver-deployer`. | `PodScheduled` == `creationTimestamp` |
| 00:50:03–00:51:48 | 7 replacements sit **Pending for ~105 s** — dell is still NotReady, so the scheduler will not place them. `argocd-server`, `-repo-server`, `-dex-server`, `-redis`, `-notifications-controller`, `vaultwarden`, `postgres-xboy`. | `creationTimestamp` 00:50:03 vs `PodScheduled` 00:51:48 |
| **00:51:48** | **dell is Ready again** — the 7 Pending pods bind to it. (Proof dell recovered here: those pods tolerate no not-ready taint.) | `PodScheduled` 00:51:48 |
| 00:51:53–00:52:21 | StatefulSet pods recreated on dell: `argocd-application-controller-0`, `mtaa/postgres-0`, `mtaa/redis-0`, `vaultwarden/postgres-0`; Longhorn `instance-manager` recreated at 00:52:15. | `creationTimestamp` |
| 00:52:59–00:55:51 | Longhorn re-attaches ~10 volumes in sequence. | csi-attacher log: repeated `"Attaching"` / `"Attached"` |
| **01:09:43** | **kube-apiserver stalls.** All four Longhorn CSI sidecars — *running on the control-plane node itself* — lose their leader leases and exit code 1. | see §5 |
| 01:10:46 | `kubernetes-dashboard` exits code 2 (had run since 08-22). | `lastState.terminated.finishedAt` |
| ~01:11 | `grafana` restarts; becomes Ready 01:11:31. | restart count 1, `Ready` condition |
| **01:18:32 / 01:18:34** | **Recovery.** All four of dell's node conditions transition simultaneously; Longhorn records `Node dell-amd64-srv is ready`. | node conditions; `nodes.longhorn.io` |
| 01:19:00 | `prometheus` pod recreated — **has been CrashLoopBackOff ever since** (80 restarts). | see §6.1 |
| 01:19:18 | `jenkins` finally scheduled onto dell. | `creationTimestamp` |

### Note on the 01:18:32 signature

All four conditions (`Ready`, `MemoryPressure`, `DiskPressure`, `PIDPressure`) sharing one
`lastTransitionTime` is the signature of the **node-lifecycle controller having set them
all to `Unknown`** (reason `NodeStatusUnknown`, i.e. the node lease expired) and the
kubelet then reporting fresh status. It is *consistent with*, but does not prove, a
kubelet restart — and given the containers never restarted (§3.1), lease expiry is by far
the better-supported reading. Combined with 00:51:48, dell **flapped at least twice**:
NotReady ~00:45 → Ready 00:51:48 → NotReady ~01:1x → Ready 01:18:32.

---

## 5. ~~Root cause: the control plane, not the worker~~ Secondary cause: the control plane *did* stall

> **Corrected by §13.** The title of this section was wrong: the worker started it. What
> follows is still accurate as an account of the *second* stage — the apiserver really did
> stop serving requests, and the 01:09:43 evidence really does prove it was not a
> dell-local network fault. §13 supplies the missing first stage (dell's memory collapse)
> and confirms stage 2 from the Pi's own dqlite journal.

The decisive evidence is the 01:09:43 failure. All four Longhorn CSI controller sidecars
were running **on `pi-5-16gb-srv-0`, the control-plane node**, and still could not reach
the apiserver ClusterIP:

```
I0905 01:09:43.506377  leaderelection.go:454] "Failed to update lease optimistically,
  falling back to slow path" lock="longhorn-system/external-attacher-leader-driver-longhorn-io"
  err="Put \"https://10.152.183.1:443/apis/coordination.k8s.io/v1/namespaces/
  longhorn-system/leases/external-attacher-leader-driver-longhorn-io\": context deadline exceeded"
E0905 01:09:43.506512  leaderelection.go:461] "Error retrieving lease lock"
  err="client rate limiter Wait returned an error: context deadline exceeded"
I0905 01:09:43.506560  leaderelection.go:304] "Failed to renew lease" err="context deadline exceeded"
E0905 01:09:43.506635  leader_election.go:206] "Stopped leading"
```

All four died within the same second, each with `exitCode: 1`,
`finishedAt: 2026-09-05T01:09:43Z`:

| Pod (all on pi-5) | Lease lost |
|---|---|
| `csi-attacher-594db8ccb7-lchn2` | `external-attacher-leader-driver-longhorn-io` |
| `csi-provisioner-7dcd9898fc-m2m7h` | `driver-longhorn-io` |
| `csi-resizer-5b5c8d75ff-62xzw` | `external-resizer-driver-longhorn-io` |
| `csi-snapshotter-b54fd46f9-54h9t` | `external-snapshotter-leader-driver-longhorn-io` |

**A node-local network fault at dell cannot explain clients on the Pi timing out against
the Pi's own apiserver.** The API server itself was the bottleneck. `kubernetes-dashboard`
dying 63 seconds later corroborates it.

Interpretation of the causal chain (**step 1 is wrong — see §13; steps 2–6 hold**):

1. ~~kube-apiserver / k8s-dqlite on the Pi degrades past request timeouts (~00:44).~~
   Actually: **dell** collapses into swap thrash at ~00:40, and by 00:44 its own
   containerd/PLEG and Longhorn engine are stalled. The Pi was idle at this point —
   47 % memory, no swap, no slow dqlite queries.
2. dell's kubelet cannot renew its node lease → node-lifecycle controller marks it NotReady.
3. 300 s later the taint manager evicts all 21 evictable pods on dell.
4. The recreation of 21 pods + ~10 Longhorn volume detach/attach cycles imposes a heavy
   write burst on dqlite — on a Pi 5 — **amplifying the original problem** rather than
   relieving it. This is a positive feedback loop.
5. At 01:09:43 the apiserver stalls hard enough to break leader election cluster-wide.
6. Things drain and settle by 01:18:32.

### Supporting evidence: this is chronic, not novel

The same pattern occurred on 09-04 at 10:42 (see timeline). Longer-run restart counters
tell the same story of repeated apiserver unavailability:

| Pod | Restarts | Age |
|---|---|---|
| `kube-system/calico-kube-controllers` | 608 | 329d |
| `kube-system/kubernetes-dashboard` | 322 | 110d |
| `kube-system/metrics-server` | 161 | 227d |
| `metallb-system/speaker-6ss9s` | 57 | 40d |
| `metallb-system/controller` | 41 | 40d |

### What was *not* the cause

- **Node disk exhaustion.** Both nodes have ample free space:
  pi-5 `nodefs` 75.72 / 114.68 GiB used, **34.26 GiB available**, 6,083,137 inodes free;
  dell `nodefs` 161.39 / 465.49 GiB used, **280.39 GiB available**. Longhorn agrees:
  pi 66.0 % used with 39.0 GiB available, dell 34.7 % used with 304.1 GiB available.
  Both Longhorn disks report `Ready` and `Schedulable`.
- **Jenkins/buildkit saturating the worker.** Plausible on paper — dell hosts Jenkins and a
  40 GiB buildkit cache — but there is no buildkit pod, the Jenkins Deployment and
  ReplicaSet are both 15d old, and the Jenkins pod was a *victim* (scheduled 01:19:18),
  not a driver. No evidence found either way in the window; not supported.
- **Calico/CNI failure.** `calico-node-cqvnn` on dell emitted **zero log lines** after
  00:40 and has 0 restarts in 13d. The data plane was healthy throughout.

---

## 6. Outstanding problems (present at time of writing)

Ordered by severity. Items 1–4 are fallout from this incident; 5–8 are pre-existing
issues surfaced during the investigation.

### 6.1 `monitoring/prometheus` — CrashLoopBackOff, 80 restarts — **volume full**

```
level=ERROR source=main.go:1624 msg="Fatal error"
  err="opening storage failed: open /prometheus/wal/00000515: no space left on device"
```

Crashlooping continuously since it was recreated at 01:19:00. **This is the PVC being
full, not the node** — `monitoring/prometheus-data` is only **5 Gi**
(`pvc-a3294a23-a696-4e7a-899a-df8ecbcd5b1a`), while the host has 34 GiB free.
Metrics collection has been down for ~6.5 hours.

**Fix:** expand the PVC (Longhorn supports online expansion) and/or reduce
`--storage.tsdb.retention.time`. The WAL must be given headroom before Prometheus can
start; a 5 Gi volume is undersized for this cluster's series count.

### 6.2 `monitoring/loki` — storage corrupt, log history unreadable

```
$ curl -s http://127.0.0.1:3100/loki/api/v1/labels
rpc error: code = Unknown desc = mkdir /loki/tsdb-shipper-cache/index_20701: input/output error
```

An `input/output error` on the mounted Longhorn volume `monitoring/loki-data`
(`pvc-e4affc46-f596-41f1-b73c-02e6f8d32c74`). Loki's `/ready` endpoint returns `ready`,
so this is silent to any liveness probe. **This is why the incident had to be
reconstructed from live API object state rather than from logs** — the log store that
should have answered the question is itself damaged. Likely needs a filesystem check on
the volume, or discarding the index cache directory.

### 6.3 Both monitoring Longhorn volumes are `degraded`

```
pvc-a3294a23...  attached  degraded  pi-5-16gb-srv-0   5Gi   -> monitoring/prometheus-data
pvc-e4affc46...  attached  degraded  dell-amd64-srv    5Gi   -> monitoring/loki-data
```

All 13 other attached volumes are `healthy`. Degraded means a replica is missing and has
not been rebuilt. These are the same two volumes as §6.1 and §6.2 — worth treating as one
storage problem. Two further volumes are `detached`/`unknown`
(`jenkins/buildkit-cache-pvc`, one of which is a `Released` orphan under a `Retain`
policy and can be reclaimed).

### 6.4 `vaultwarden/vaultwarden-backup-29809440-655ln` — stuck `ContainerCreating` for 7h

**Direct fallout of the reshuffle, and it will never recover.** The Job's original pod was
evicted from dell; the replacement was scheduled onto **pi-5**, but the RWO volume it
mounts is attached to **dell**:

```
$ kubectl get pod -n vaultwarden vaultwarden-backup-29809440-655ln \
    -o jsonpath='node={.spec.nodeName}'
node=pi-5-16gb-srv-0
  volumes: vaultwarden-data -> pvc vaultwarden-data

$ kubectl get volumeattachment | grep 71ad96d3
csi-b311fc...  driver.longhorn.io  pvc-71ad96d3...  dell-amd64-srv  true  7h3m

$ kubectl get pod -n vaultwarden -o wide | grep -v backup
vaultwarden-64b879f94c-jr5rz   1/1  Running  0  7h6m  dell-amd64-srv
```

A cross-node ReadWriteOnce multi-attach deadlock. **Fix:** delete the pod/Job so the
CronJob can retry. **Prevent:** the backup pod must be co-scheduled with the volume — pin
it via pod affinity to the `vaultwarden` pod, or have the backup read over the network
rather than mounting the data volume. As written, this CronJob will deadlock every time
the app moves nodes.

> **Update (§11):** the pod was deleted, which released the attachment; the Job was
> re-triggered and completed. The design flaw is unchanged — the vaultwarden job still
> mounts `vaultwarden-data` to tar it, so it will deadlock again if the app moves.
> The `db-backup` CronJobs do not have this problem: they connect over the network and
> mount no PVC.

### 6.5 `apps/admin-svc` — CrashLoopBackOff, 63 restarts — **unrelated config bug**

```
ERROR [BootstrapConfig] Failed to load remote config:
  Config validation failed: RABBITMQ_BILLING_QUEUE: "RABBITMQ_BILLING_QUEUE" is required
ERROR [Admin Microservice] ❌ Bootstrapping failed: ...
```

Pod created 02:44:21, well after the incident. It fetches remote config from
`config-svc.apps.svc.cluster.local` and rejects it. This is an application/config defect,
**not** incident fallout. Also logged: `⚠️ Environment file .env.production not found,
falling back to default .env`.

### 6.6 Failing Jobs

- `mtaa/migrate` — 4 pods in `Error` (`migrate-q8fh6`, `-k7nzr`, `-47c5b`, `-h27bw`),
  most recent ~6 min before writing. **Actively failing now.**
- `xboy/db-backup-postgres-xboy-29809605` — 3 pods in `Error` at 02:45–02:47. Cause
  found later: the same `global/pg_filenode.map` I/O error, on `xboy`'s volume
  (§11). Re-triggered after the repair and it completed.
- `mtaa/backend-799b58497c-krszn` was created ~5 min before writing, suggesting an
  in-progress deployment whose migration step is failing.

### 6.7 Every HorizontalPodAutoscaler is non-functional

18+ HPAs are emitting `FailedGetResourceMetric`:

```
Warning  FailedGetResourceMetric  horizontalpodautoscaler/support-svc-hpa
  failed to get cpu utilization: missing request for cpu in container
  support-svc-container of Pod support-svc-9ffd68c68-25gdn
```

Affects `support-svc`, `audit-svc`, `call-svc`, `character-svc`, `conversation-svc`,
`notification-svc`, `billing-svc`, `profile-svc`, `config-svc`, `admin-svc`,
`ai-runtime-svc`, `llm-gateway-svc`, `memory-svc`, `media-api`, `auth-svc`, and
`transport/rabbitmq-svc-hpa`. **No CPU-based autoscaling is happening anywhere in the
cluster.** CPU-utilisation HPAs require `resources.requests.cpu` to be set; none of these
containers set it. Absent requests also mean every one of these pods is `BestEffort`
QoS — first to be killed under node pressure, and invisible to the scheduler's capacity
accounting. Worth fixing on its own merits: it directly reduces the cluster's resilience
to the kind of overload seen here.

### 6.8 Node-level warnings

- **pi-5 recurring image-GC failure:**
  `Insufficient free disk space on the node's image filesystem (70% of 114.7 GiB used).
   Failed to free sufficient space by deleting unused images (freed 1911349 bytes).`
  Kubelet is trying to garbage-collect and recovering only ~1.9 MB. Not the cause of this
  incident (34 GiB is free), but it will become one.
- **`DNSConfigForming` on both nodes:**
  `Nameserver limits were exceeded, some nameservers have been omitted, the applied
   nameserver line is: 192.168.0.59 10.2.0.1 2a07:b944::2:1` — the host has >3
   nameservers and resolv.conf is being silently truncated.
- **Longhorn node prerequisites unmet on both nodes:**
  `RequiredPackages=False` (missing `nfs-common`), `KernelModulesLoaded=False`
  (`dm_crypt` not loaded), and on dell `Multipathd=False`
  (`multipathd is running with a known issue that affects Longhorn`). The multipathd issue
  is a documented cause of Longhorn volume corruption and is worth correlating with §6.2.

---

## 7. Recommendations

### Immediate (restores observability and clears stuck work)

1. Expand `monitoring/prometheus-data` beyond 5 Gi and/or cut Prometheus retention; §6.1.
2. Repair or reinitialise `monitoring/loki-data`; §6.2. **Do this early** — without it
   there will be no log history for the next occurrence either.
3. `kubectl delete pod -n vaultwarden vaultwarden-backup-29809440-655ln` (and its Job) to
   clear the deadlock; §6.4.
4. Investigate the two degraded Longhorn volumes and let replicas rebuild; §6.3.
5. Fix `RABBITMQ_BILLING_QUEUE` in `config-svc`'s remote config for `admin-svc`; §6.5.
6. Triage the failing `mtaa/migrate` Job — it is blocking a live deployment; §6.6.

### Root cause — confirm, then fix

7. **Confirm the sub-cause** by reading the node journals (see §8 for exact commands).
8. **Move the control-plane datastore off the Raspberry Pi.** This is the substantive fix.
   The Pi 5 is carrying kube-apiserver + k8s-dqlite *and* the majority of the cluster's
   pods, on SD/USB-class storage, and has now failed this way twice in 21 hours. `dell-amd64-srv`
   has 4× the disk, 280 GiB free, and far more headroom. Options, roughly in order of effort:
   - Promote dell to control-plane and run the API server there (`microk8s add-node` /
     `microk8s join --worker=false`), leaving the Pi as a worker.
   - Migrate MicroK8s from k8s-dqlite to an external etcd on faster storage.
   - At minimum, move the dqlite data directory to a decent NVMe/SSD on the Pi.
9. **Reduce blast radius while the above is pending.** Raising
   `--default-not-ready-toleration-seconds` / `--default-unreachable-toleration-seconds`
   above the default 300 s on kube-apiserver means a transient control-plane stall no
   longer escalates into a full eviction storm. This treats the *amplification*
   (step 4 of §5) rather than the trigger, and directly breaks the feedback loop —
   but it also delays legitimate failover, so pick the value deliberately.
10. Set `resources.requests.cpu` on the `apps/*` containers; §6.7. This fixes autoscaling
    and moves those pods out of `BestEffort` QoS.

### Hygiene

11. Add alerting that survives the failure it needs to report: an apiserver-availability
    and node-`Ready` alert routed **off-cluster**. Right now both Prometheus and Loki are
    down, so nothing would have paged.
12. Add a liveness/readiness check for Loki that actually exercises storage — `/ready`
    returned `ready` while the index was unwritable.
13. Clean up pi-5's image filesystem and address the Longhorn prerequisites in §6.8.

---

## 8. Investigation gaps

> **Closed — see §13.** Both nodes were reached over SSH later the same day and every
> check listed below was run. The answers are in §13; the most important one is that the
> premise of §5 was wrong. The checklist is left here because it is the right checklist.

This investigation was conducted from `coding-bot-webdev`, which is **not** a cluster
node — only the Kubernetes API was reachable. Two consequences:

- **Control-plane logs were unavailable.** MicroK8s runs kube-apiserver and k8s-dqlite as
  host snap services, so there are no pod logs for them.
- **Loki's history was unreadable** (§6.2), and Kubernetes' own Events had already aged
  out past the default 1-hour retention.

Everything above was therefore reconstructed from live API object state: pod
creation/scheduling timestamps, `lastState.terminated` records, node and Longhorn CRD
condition transition times, and the ~20 hours of container logs still on disk.

**To confirm the sub-cause**, run on `pi-5-16gb-srv-0`:

```bash
journalctl -u snap.microk8s.daemon-kubelite    --since "2026-09-05 00:30" --until "2026-09-05 01:30"
journalctl -u snap.microk8s.daemon-k8s-dqlite  --since "2026-09-05 00:30" --until "2026-09-05 01:30"
journalctl -k                                  --since "2026-09-05 00:30" --until "2026-09-05 01:30"
```

and on `dell-amd64-srv`:

```bash
journalctl -u snap.microk8s.daemon-kubelite    --since "2026-09-05 00:30" --until "2026-09-05 01:30"
```

Look specifically for:

- dqlite `slow query` / `checkpoint` warnings, or Raft leader-election churn — would
  confirm datastore I/O latency as the trigger.
- kubelet `use of closed network connection`, `failed to update node lease`, or
  `Error updating node status` around **00:44–00:45** and **01:09** — would pin the exact
  moment dell's lease lapsed and replace the inferred `~00:45:02` with a measured value.
- OOM kills or CPU stalls on the Pi in the same window.
- The same signatures around **2026-09-04 10:42** — the earlier occurrence — to confirm
  the two events share a cause.

Also worth checking, since it would change the recommendation in §7.8:
whether an unattended `snap refresh` of MicroK8s ran in either window
(`snap changes` on both nodes).

---

## 9. Recovery log — `mtaa` PostgreSQL (executed 2026-09-05 08:31–08:41 UTC)

Scope for this pass was `mtaa` only, by explicit decision. `vaultwarden` and
`xboy` were left untouched pending review of this result.

### 9.1 Why `mtaa` was the risky one

`mtaa` is the only one of the three corrupted volumes with **no logical backup
anywhere**: there is no `db-backup-*` CronJob for it (`kubectl get cronjob -A`
lists them for `data`, `xboy` and `vaultwarden` only), no S3 credentials in the
namespace, and no Longhorn backup target configured cluster-wide. The volume was
the single copy of the data. `vaultwarden` and `xboy` both have an S3 dump from
Sep 4, so they can be repaired with a fallback available; `mtaa` could not.

### 9.2 Rollback point taken first

Longhorn `Snapshot` `mtaa-pg-prefsck-20260905` on
`pvc-e6723e9b-2ee4-486d-9d7c-9c56a94b18b3`, `readyToUse: true`,
created `2026-09-05T08:31:07Z`. This is a block-level snapshot, so it preserves
the *corrupted* state exactly — it is a rollback point, not a backup.

A raw `dd` image to `/tmp` was attempted first and **abandoned by design**: it
streamed at ~85 KB/s because `kubectl exec` proxies through the very apiserver
that failed in this incident, and the transfer would have broken anyway when the
volume detached. The snapshot plus an immediate post-repair logical dump is the
better trade.

### 9.3 Sequence

| Time (UTC) | Action | Result |
|---|---|---|
| 08:31:07 | Longhorn snapshot `mtaa-pg-prefsck-20260905` | `readyToUse: true` |
| 08:35:0x | `kubectl scale deploy/backend --replicas=0`, `sts/postgres --replicas=0` | original replicas were 1 and 1 |
| 08:35:15 | volume reached `detached` | ext4 unmounted cleanly |
| 08:35:27 | manual attachment ticket `manual-fsck-20260905` added to `lhva/pvc-e6723e9b…` (`type: longhorn-api`, `nodeID: dell-amd64-srv`, `disableFrontend: "false"`) | `/dev/longhorn/<vol>` present, **not** in `/proc/mounts` |
| 08:35:50 | `e2fsck -f -y` from `longhorn-csi-plugin-hr48g` | exit **1** = errors corrected |
| 08:35:5x | second `e2fsck -f -y` pass | exit **0**, clean |
| 08:36:36 | attachment ticket removed | volume `detached` |
| 08:36:4x | `sts/postgres --replicas=1` | `postgres-0` Ready |
| 08:38:33 | `pg_dumpall` to `/tmp` | 31,991 bytes gz, verified |
| 08:41 | `deploy/backend --replicas=1` | restored to original 1 |

Note: `mtaa` is **not** managed by ArgoCD (no `Application` targets that
namespace), so the scale-down was not self-healed. `xboy` *is*, via
`xboy-apps-production` / `xboy-infrastructure-production` with
`automated.selfHeal: true` — auto-sync must be suspended before scaling that one
down, or the change will be reverted mid-repair.

### 9.4 What e2fsck actually had to fix

```
/dev/longhorn/pvc-e6723e9b…: recovering journal
Pass 1: Checking inodes, blocks, and sizes
Pass 2: Checking directory structure
Pass 3: Checking directory connectivity
Pass 4: Checking reference counts
Pass 5: Checking group summary information
Free blocks count wrong (1252216, counted=1252296).  Fix? yes
Free inodes count wrong (326232, counted=326234).    Fix? yes
***** FILE SYSTEM WAS MODIFIED *****
1446/327680 files (6.6% non-contiguous), 58424/1310720 blocks
```

This is the best possible outcome and it confirms the §6 diagnosis. The only
real work was **replaying the journal** (`needs_recovery` was set) and correcting
two **free-space counters**. There were:

- no orphaned inodes moved to `lost+found` (`lost+found` is still empty),
- no unattached blocks or inodes,
- no multiply-claimed blocks,
- no deleted or truncated files.

Pre-repair the superblock read `Filesystem state: clean with errors`,
`FS Error count: 4`, `First error time: Sat Sep 5 01:17:35 2026`,
`First error function: __ext4_find_entry`, `First error inode #: 131073`,
`First error err: EIO`. Post-repair it reads `Filesystem state: clean` with the
error count and `needs_recovery` both cleared.

The `Last error time: Sat Sep 5 07:41:48 2026` in
`ext4_journal_check_start` is the `migrate` Job at 07:41 hitting the latched
error flag — not new corruption. That Job is terminally `Failed`
(`BackoffLimitExceeded`, 4 attempts), which is why the namespace looked like it
had freshly redeployed.

### 9.5 Verification of the data, in increasing strength

1. **Read-only mount, full file read.** Mounted `ro,noload` and `cat`-ed every
   file: **66,759,098 bytes read with zero read errors**.
   `global/pg_filenode.map` — the exact file in the user-visible
   `psql: FATAL: could not open file "global/pg_filenode.map": I/O error` — reads
   fine at 524 bytes. `PG_VERSION` = 17, `global/pg_control` intact,
   `base/{1,4,5,16384}` all present.
2. **Postgres starts and serves.** The same `psql` invocation that failed for
   6.5 h now returns normally. (It first returned
   `FATAL: role "postgres" does not exist` — the superuser is `mtaa`, from
   `POSTGRES_USER`; that is an auth error, which itself proves Postgres had
   already read `pg_filenode.map` and `pg_authid` successfully.)
3. **Every page checksum validated.** The cluster was initialised with
   `POSTGRES_INITDB_ARGS: --data-checksums`, so a full scan of every table
   forces verification of every heap page. A `plpgsql` loop over all 26 user
   tables reported `ALL TABLES FULLY READABLE, NO CHECKSUM FAILURES`,
   **701 live rows** total, in 414 ms.
4. **Logical dump round-trips.** `pg_dumpall --clean --if-exists` produced 26
   `CREATE TABLE` + 26 `COPY` blocks, 3 `PostgreSQL database dump complete`
   markers, and per-table row counts inside the dump that match the live counts
   exactly.

Row counts, live and in the dump (identical):

```
users 34   user_data 34   wallet 34   user_categories 244
categories 57   verifications 51   platform_revenue 51
products 37   deposits 37   content_stats 38   content_targets 38
content_view_logs 12   shops 6   house_amenities 3   houses 1   services 1
__diesel_schema_migrations 23
content_likes/content_saves/content_ratings/events/notifications/
product_views/product_view_logs/shop_categories/shop_queue  0
TOTAL 701
```

**Data loss: none detected by any of the four checks.**

### 9.6 Off-cluster copy

`/tmp/mtaa-pg_dumpall-20260905T083833Z.sql.gz` — 31,991 bytes,
`gunzip -t` OK, sha256 in `….sha256`:
`4648321fb6481bdaf9cd49a9f2c71f3ab5e4bd1c236ba4ad5063f1856c3b3af0`

This is **not yet in S3**, because `mtaa` has no S3 credentials in its namespace
and no backup CronJob — pushing it would have meant copying
`s3-db-backup-creds` in from another namespace, which is a separate change.
Treat this local file as the only off-cluster copy until §9.7 item 1 is done.
Note it is a `pg_dumpall`, so it contains role password hashes; keep it
accordingly.

### 9.7 Follow-ups this recovery exposed

1. ~~Create a `db-backup` CronJob for `mtaa`~~ — **done, see §10.**
2. **Re-run the `migrate` Job.** It failed only because of the I/O error. 23
   migrations are applied, latest `202609012011580000` (2026-09-01 21:08:46); the
   deployed image `mtaa-migrate:main-7baa6ac` may carry newer ones. Delete the
   failed Job and re-apply.
3. **Consider `errors=remount-ro`** for Longhorn PVCs. `errors=continue` is what
   turned a 13-second EIO burst into 6.5 h of a half-working database serving
   cached dentries. Read-only would have failed loudly and immediately.
4. **Delete the snapshot `mtaa-pg-prefsck-20260905`** once the repair is trusted;
   it pins the corrupted blocks and consumes space.
5. ~~`vaultwarden/postgres-data-postgres-0` (4 errors, 01:17:39) and
   `xboy/postgres-xboy-pvc` (2 errors, 01:17:31) are **still in the latched
   error state** and still need the same treatment.~~ — **done, see §11.** Both
   were repaired with the same procedure; ArgoCD auto-sync was suspended for
   `xboy` and restored afterwards. Their `*-prefsck-20260905` snapshots are
   pinning corrupted blocks and should be deleted alongside `mtaa`'s (item 4).
6. Everything in §7 still stands, in particular fixing `multipathd` on
   `dell-amd64-srv` (§6.x) — it remains the most likely trigger, and until it is
   fixed this can recur.

---

## 10. `mtaa` nightly backup to S3 (added 2026-09-05 09:08 UTC)

The gap that made §9 dangerous is closed. The manifests now live in the repo, at
`mtaa/k8s/data/db-backup/`, wired into `k8s/data/kustomization.yaml` — `mtaa` is
applied with `kubectl`/kustomize, not ArgoCD, so nothing would have recreated
them otherwise. (The first version was applied from `/tmp/mtaa-db-backup.yaml`;
§12 replaced its two-container shape with a single container on the shared
image, and the live CronJob now matches git.)

A CronJob of its own, deliberately separate from `vaultwarden-backup`: its own
schedule, its own S3 prefix, its own failure. One database's backup failing must
not hide or block another's.

| | |
|---|---|
| CronJob | `mtaa/db-backup-postgres-mtaa` |
| Schedule | `45 3 * * *` `Etc/UTC` — the only free slot (00:00 vaultwarden, 01:15/01:45 data, 02:15/02:45/03:15 xboy, 03:00 rs-cleaner) |
| Destination | `s3://db-backups/auto-backup/mtaa/postgres-mtaa/postgres-mtaa-<UTC>.sql.gz` + `.sha256` |
| Retention | 14 days, floor of newest 2 — identical semantics to xboy/data |
| Verified run | `postgres-mtaa-20260905T090828Z.sql.gz`, 31,567 bytes, sha256 `950781c4…c0c91e9b8` |

The S3 object layout matches `xboy` and `data` exactly, so a restore is the same
procedure in every namespace.

### 10.1 Why `mtaa` could not simply reuse the shared CronJob

Three things blocked it, each found by running it rather than by reading it.
Worth recording, because they apply to anything else deployed into `mtaa`.

**1. `mtaa` enforces PodSecurity `restricted`; `xboy` and `data` have no
PodSecurity labels at all.**

```
mtaa   enforce=restricted  warn=restricted  audit=restricted
xboy   <none>              <none>           <none>
```

The shared `backup.sh` runs `runAsUser: 0` because it does
`apk add aws-cli postgresql16-client coreutils` at container start. Under
`restricted` that pod is rejected at admission — the Job was created, then sat
for 10 minutes emitting `FailedCreate … violates PodSecurity "restricted:latest":
runAsNonRoot != true … runAsUser=0`, and never started a pod. `kubectl apply`
only warns, so this is invisible until a Job is actually triggered.

**2. The AWS CLI images do not pull on this cluster.** `docker.io/amazon/aws-cli`
and `alpine/aws-cli` both fail with
`unexpected media type text/html for sha256:… : not found` — a registry proxy
mangling those repos — and `public.ecr.aws/aws-cli/aws-cli` never completed a
pull. `minio/mc` pulls and runs fine as uid 10001, and is the better fit anyway
since the endpoint is MinIO.

**3. `default-deny-ingress`, and `allow-app-to-postgres` admits only
`app.kubernetes.io/name in (backend, migrate)`.** The backup pod resolved
`postgres` correctly — `allow-all-egress` and `allow-dns` cover outbound — then
hung on the TCP connect until `dump.sh` gave up with
`FATAL: postgres:5432 not accepting connections after 60s`. That message reads
like a database fault and is not one; the database was healthy throughout.

### 10.2 The resulting shape — **superseded, see §12**

The two-stage design below was the answer to blockers 1 and 2 as they stood at
09:08 UTC. It ran exactly one scheduled shape before being replaced: the prebuilt
`tools/s3-backup` image removed both blockers at once, so `mtaa` now runs the
same single-container CronJob and the same `backup.sh` as `xboy` and `data`.
Blocker 3 (the NetworkPolicy) is unchanged and still required.

Two stages, no runtime package installs, nothing running as root:

| Stage | Image | Does |
|---|---|---|
| initContainer `dump` | `postgres:17-alpine` | waits for the server, `pg_dumpall \| gzip -9`, verifies, writes `.sha256` and `.name` to the shared emptyDir |
| container `upload` | `minio/mc:latest` | uploads, reads back and compares sha256, prunes by retention |

Both run `runAsUser: 10001`, `runAsNonRoot: true`, `readOnlyRootFilesystem: true`,
all capabilities dropped, `seccompProfile: RuntimeDefault`, with `fsGroup: 10001`
so the second stage can read what the first wrote. The `upload` stage is not
given `PGPASSWORD` — it has no business holding the database password.

Plus `NetworkPolicy/allow-backup-to-postgres`, a separate additive policy rather
than a third entry in `allow-app-to-postgres`, so the grant lives next to the
backup instead of buried in the application manifest.

Two details carried over deliberately from the shared script, because both are
load-bearing: `pg_dumpall` rather than `pg_dump` (a new database would otherwise
be missed silently, and the backup would keep reporting success), and parking
`pg_dumpall`'s exit status in a file because `sh` has no `pipefail` and `gzip`'s
status would otherwise win — without which a dump that died a third of the way
through would still produce a valid `.gz` and still be uploaded.

One difference from the shared script: retention derives an object's age from
the timestamp in its **name** rather than from S3 `LastModified`. The `minio/mc`
image has bash, `date`, `sha256sum`, `sort` and `cut` but **no `awk`, `grep` or
`sed`**, so the parsing uses shell builtins; and since the names are fixed-width
ISO-8601 basic UTC, a string compare against a formatted cutoff replaces date
arithmetic entirely.

### 10.3 Verified end to end, not just applied

The test run passed every gate the script has:

```
DUMP_VERIFIED_OK    postgres-mtaa-20260905T090828Z.sql.gz
UPLOAD_VERIFIED_OK  s3://db-backups/auto-backup/mtaa/postgres-mtaa/… 950781c4…
[8/8] Retention: older than 14d, always keeping the newest 2
  cutoff: 20260822T090831Z
  1 dump(s) under auto-backup/mtaa/postgres-mtaa/
BACKUP_COMPLETE mtaa/postgres-mtaa postgres-mtaa-20260905T090828Z.sql.gz
```

`UPLOAD_VERIFIED_OK` is the line that matters: it is printed only after the
object is fetched back out of S3 and its sha256 compared to the local one, so it
means present, readable and byte-identical — not merely that a PUT returned 200.

### 10.4 Still open

- `s3-db-backup-creds` was copied from `xboy` into `mtaa`. The two existing
  copies (`xboy`, `data`) are byte-identical and each writes under its own
  namespace prefix, so the key is not prefix-scoped despite what `backup.sh`'s
  comments assume. If these are ever rotated, rotate all three.
- The credentials now exist in one more namespace. If that matters, issue
  `mtaa` its own MinIO key scoped to `auto-backup/mtaa/*`.
- ~~`vaultwarden` and `xboy` filesystems are still in the latched error state
  (§9.7 item 5).~~ **Resolved** — both were repaired and verified the same
  morning; see §11.

---

## 11. Recovery log — `vaultwarden` and `xboy` PostgreSQL (executed 2026-09-05 09:1x–09:4x UTC)

The other two volumes damaged at 01:17 had the same latched-error state as
`mtaa` (§9). Both were repaired with the same procedure and both came back
complete. Neither had lost data.

| | `vaultwarden` | `xboy` |
|---|---|---|
| Volume | `pvc-8fb90215-bbfc-442f-9653-720544599698` | `pvc-c6852ec0-23aa-44ac-b1f4-ba6705ebb22a` |
| Rollback snapshot | `vaultwarden-pg-prefsck-20260905` | `xboy-pg-prefsck-20260905` |
| `e2fsck` | journal replayed, free counts fixed, **`/lost+found` was missing and had to be created** | journal replayed, free counts fixed |
| Full read, volume attached read-only | 67,599,798 bytes, zero I/O errors | 47,650,557 bytes, zero I/O errors |
| Server after restart | PostgreSQL 15.19 | PostgreSQL 15.19 |
| Row-level readability | 911 live rows across all tables (593 `ciphers`, 3 `users`, 46 migrations) | `blog_db` 212 rows, `postgres` 0 rows |

Two details worth keeping:

- **`vaultwarden`'s first `e2fsck` error was on inode 2 — the root directory.**
  That is as close to the top of the filesystem as damage gets, and it is exactly
  the kind of thing a block-level replica cannot protect against.
- **Neither server has `data_checksums` enabled**, unlike `mtaa`. The
  page-checksum scan that gave §9 its strongest guarantee is simply unavailable
  here, so the strongest available check was a full sequential read of every
  table plus the byte-level read of the whole volume. Worth enabling on the next
  `initdb` for both.

Two side effects, both resolved:

- The `vaultwarden` backup pod stuck in `ContainerCreating` for 8 hours (§6.4)
  was deleted; that released the RWO attachment and unblocked its CronJob.
- `xboy`'s 02:45 scheduled backup had already failed that morning with the same
  `global/pg_filenode.map: I/O error`, so no dump reached S3 for it. Both that
  Job and `vaultwarden`'s (which had failed with `Operation timed out`, because
  its Postgres was scaled down for the repair) were re-triggered after the
  repairs and both completed.

ArgoCD auto-sync on `xboy-apps-production` and `xboy-infrastructure-production`
was suspended for the duration so it could not scale Postgres back up mid-fsck,
then restored to `{"automated":{"prune":true,"selfHeal":true}}`. The original
policies are saved in `/tmp/argocd-syncpolicy-backup.txt`.

---

## 12. Rolling the prebuilt backup image out (2026-09-05 09:4x–10:0x UTC)

`registry.internal.example.com/tools/s3-backup:2.0.0` replaces every `apk add` /
`apt-get install` in the cluster's backup jobs. Pinned by **multi-arch index
digest** `sha256:9dd96606c8b5c53a442d62b1a869469fde9692bc6b7ce08804237387640f0a4e`
— confirmed to be the index and not a per-platform manifest by resolving the tag
on both nodes and comparing the reported `imageID`, which matters because this
cluster is amd64 + arm64 and `xboy`'s jobs can land on the pi.

Contents that the manifests depend on: aws-cli 2.34.63, **pg_dumpall 18.6**,
`pg_isready`, `psql`, bash, coreutils (`date -d`), gzip, tar, sha256sum, grep,
awk, sed — and a default non-root user, uid **100:101** (`scripts`).

### 12.1 What changed, per repo

| Repo | Change |
|---|---|
| `xboy-k8s-infra` | 3 CronJobs + shared `backup.sh`: image swapped, `runAsUser: 0` → `runAsNonRoot` uid 100, `readOnlyRootFilesystem: false` → `true`, install block replaced by tool assertions |
| `meet-to-meat-services/back-end/k8s-infra` | same for 2 CronJobs; **the alpine-3.23 base-image pin is gone** (it existed only because `postgresql18-client` is absent from 3.22 and both servers are PG 18) |
| `infra-services` | `vault-warden/s3-backup-job.yaml`: placeholder `ghcr.io/your-org/…` → the real image, plus a securityContext, a `/tmp` emptyDir and `HOME=/tmp`. `s3-db-backup-cron/` marked **SUPERSEDED** (not deployed, duplicates the above) and converted anyway |
| `mtaa` | new `k8s/data/db-backup/`, single container on the shared image, superseding §10.2's two-stage design; applied live so the cluster matches git |

The `pg_dumpall` version was the unlock: 18.6 covers PG 18 (`data`), 17 (`mtaa`),
16 (`foodiehub`) and 15 (`xboy`, `root`, `vaultwarden`), so **one script and one
image now serve every server** and `backup.sh` is byte-identical in all three
repos again (`sha256 64162c29…d54a`).

Destinations were deliberately left alone: the `db-backup` CronJobs still write
to the **local** MinIO (`local-s3.internal.example.com`, bucket `db-backups`), and
the vaultwarden job still writes to its **remote** bucket from `s3-backup-env`.

### 12.2 Verified by running, in every namespace

| Namespace | Server | Result |
|---|---|---|
| `mtaa` | PG 17 | `postgres-mtaa-20260905T095459Z.sql.gz`, 31,572 B, `UPLOAD_VERIFIED_OK`, retention correct |
| `xboy` | PG 15 | `postgres-xboy-20260905T095706Z.sql.gz`, 11,638 B, `UPLOAD_VERIFIED_OK` |
| `data` | PG 18 | `postgres-svc-20260905T095715Z.sql.gz`, 8,551,056 B, `UPLOAD_VERIFIED_OK` |
| `vaultwarden` | PG 15 | 329.8 KiB `pg_dump` + 1.5 MiB `tar` of `/data`, both uploaded with checksums, as uid 100 |

`xboy` and `data` were proved with one-off Jobs built from the edited manifests
against a temporary `db-backup-scripts-v2` ConfigMap, so their live CronJobs and
ArgoCD-tracked state were left untouched; the temporary ConfigMaps and all
verification Jobs were deleted afterwards. `mtaa` and `vaultwarden` are applied
by hand, so their live objects were updated directly and now match git.

### 12.3 Still open after this

- **Nothing is pushed.** Four local commits: `xboy-k8s-infra` `1ae49f8`,
  `k8s-infra` `925db7f`, `infra-services` `d112213`, `mtaa` `ded7d22`. `xboy` and
  `data` only pick the change up when ArgoCD sees it, i.e. after a push.
- ~~`infra-services/pi5-arm64/k8s/s3-db-backup-cron/` is marked superseded and is
  waiting on a decision to delete it (with `rbac.yml`).~~ Deleted 2026-09-05 in
  the same change that renamed `pi5-arm64/` to `arm64-srv/`.
- `infra-services/arm64-srv/k8s/vault-warden/s3-backup-job.yaml` still carries a
  commented-out Secret with what look like real AWS credentials at the top of the
  file. They are in git history regardless of this change — worth rotating and
  removing.

---

## 13. Node-level root cause, from the nodes themselves (investigated 2026-09-05 ~11:30–14:50 UTC)

§8 listed what could not be checked without shell access to the nodes. Both nodes were
subsequently reached over SSH and every item on that list was run. The answer changes the
conclusion: **the control plane was a victim, not the trigger.**

### 13.1 How the nodes were reached

The sandbox this investigation ran from fakes raw TCP egress — every `connect()` succeeds
and no bytes ever flow — so the earlier "no route to the nodes" conclusion was itself an
artefact. The only working egress is an HTTP proxy at `gateway.docker.internal:3128`.
`pi-5-16gb-srv-0` was reached by tunnelling SSH through a `CONNECT` to that proxy;
`dell-amd64-srv`, for which the proxy refuses `CONNECT`, was reached through a
`direct-tcpip` channel opened on the Pi's SSH connection. Both journals and both
`/var/log/sysstat` archives were then readable, which is what settles this.

### 13.2 What actually happened on `dell-amd64-srv`: a thrash collapse

`sysstat` samples every 10 minutes and the node keeps a month of history. The node's clock
is UTC, so these are directly comparable to the rest of this report. Rates are averages
over the interval ending at the stated time.

| Time (UTC) | swap used | free RAM | majflt/s | pgsteal/s | sda read | sda `aqu-sz` | `await` | load-1 | tasks in `D` | %iowait |
|---|---|---|---|---|---|---|---|---|---|---|
| 00:10 | 65.9 % | 7,046 MB | — | — | — | — | — | — | — | — |
| 00:20 | 76.6 % | 2,279 MB | — | — | — | — | — | — | — | — |
| 00:30 | 87.5 % | **215 MB** | 94 | 1,390 | 1.9 MB/s | 0.17 | 0.53 ms | 3.11 | 0 | 1.0 |
| 00:40 | **98.8 %** | 1,596 MB | 1,044 | 46,703 | 88 MB/s | 8.57 | 3.93 ms | 49.70 | 0 | 5.5 |
| **00:51** | **99.93 %** | 226 MB | **2,208** | **154,803** | **300 MB/s** | **37.91** | 7.45 ms | **579.89** | **47** | **25.1** |
| 01:00 | 73.0 % | 206 MB | 135 | 3,032 | 18 MB/s | 0.54 | 0.55 ms | 6.58 | 1 | 12.7 |
| 01:10 | 99.2 % | 1,817 MB | 287 | 7,580 | 14 MB/s | 0.92 | 0.56 ms | 9.51 | 1 | 4.3 |
| 01:20 | 59.0 % | 4,975 MB | 1,640 | 77,096 | 157 MB/s | 18.32 | 5.34 ms | 97.36 | 2 | 15.3 |

Read that middle row again: **load average 580 on 8 cores, 47 processes stuck in
uninterruptible sleep, and 300 MB/s of reads off a SATA SSD that is doing almost no
writes.** 300 MB/s of reads with 874 kB/s of writes is not a workload; it is the machine
paging its own working set back in as fast as the disk can go. `pgscan` in that interval
is 115,090 pages/s — the kernel was in continuous direct reclaim, not background reclaim.

The kernel's own view at the 01:18:18 OOM confirms it:

```
Node 0 active_anon:7699836kB inactive_anon:6501160kB
        active_file:6136kB inactive_file:9220kB          <-- ~15 MB of page cache left
Node 0 Normal free:170044kB min:212336kB                 <-- below the min watermark
Free swap  = 0kB      Total swap = 4194300kB
oom-kill:constraint=CONSTRAINT_NONE,...,global_oom,task=argocd-applicat
Out of memory: Killed process 1884382 (argocd-applicat)
```

14.2 GB of anonymous memory on a 15.2 GB machine, 15 MB of page cache, zero swap left.
Every code page fault went to disk. `%commit` was **199–201 %** for the entire day, before
and after the incident — this node is permanently promised twice the memory it has.

Two independent witnesses that userspace genuinely stopped for tens of seconds:

```
Sep 05 00:51:35 systemd[1]: systemd-journald.service: Failed with result 'watchdog'.
Sep 05 01:18:18 systemd[1]: systemd-journald.service: Failed with result 'watchdog'.
```

`journald` failing its own watchdog is about as clear a "the whole host was wedged" signal
as Linux produces. Since boot 13 d 21 h ago this node has swapped **533 GiB in and 494 GiB
out** and taken **118,920,639** major faults.

### 13.3 Why a memory problem corrupted three PostgreSQL databases

Because Longhorn's data path on this node runs through iSCSI, and its NOP-out timeout was
**5 seconds**:

```
Sep 05 00:44:34 connection5:0: ping timeout of 5 secs expired, recv timeout 5, ...
Sep 05 00:46:50 connection5:0: detected conn error (1022)
Sep 05 00:48:03 connection8:0: ping timeout of 5 secs expired, ...
Sep 05 00:49:31 connection8:0: detected conn error (1022)
```

All nine of dell's iSCSI sessions target `10.1.32.129:3260` or `10.1.32.161:3260`, and
`ip route get 10.1.32.129` resolves to `califb372bdeff5` — a **local Calico veth** for the
pod `longhorn-system/instance-manager-ab705040685f9b8d2ffc1870545fad94` on dell itself.
**These sessions never leave the node.** The initiator and the target were the same
machine; the "ping timeout" means the target process could not be scheduled for five
seconds. No network was involved, which retires the WLAN as a candidate for *this* event
(§13.6 keeps it as a candidate for the 09-04 one).

Once the session errors, the block device under the mounted ext4 starts failing writes, and
ext4's default `errors=continue` keeps going until the journal itself fails — which is
exactly the sequence in §9/§11: `Detected aborted journal`, then
`could not open file "global/pg_filenode.map": I/O error`. The three damaged volumes were
the three PostgreSQL volumes that happened to be attached to dell and taking writes at
00:51.

### 13.4 Why the node went NotReady — the kubelet's own words

The earliest kubelet symptom actually **precedes** the iSCSI failures, which puts the CRI
stall before the storage stall:

```
Sep 05 00:38:45 E0905 eviction_manager.go:297] "Eviction manager: failed to get summary
  stats" err="failed to list pod stats: ... rpc error: code = DeadlineExceeded"
```

containerd was already missing its deadlines at 00:38:45. By 00:51 it was returning
`context deadline exceeded` and `runc did not terminate successfully: exit status 137` for
`ExecSync` calls — i.e. probes and lifecycle hooks were failing wholesale. The kubelet
then published the condition this report originally had to infer:

```
KubeletNotReady: container runtime is down, PLEG is not healthy:
  pleg was last seen active 7m18.7s ago    (posted 00:51:33; last active ≈ 00:44:14)
```

So: PLEG went silent at ~00:44:14, the node lease stopped being renewed, the control plane
marked it NotReady at ~00:45, and `tolerationSeconds: 300` fired at 00:50:02. §4's inferred
`~00:45:02` was right; the reason for it was not.

Note also `Error updating node status ... Patch "https://127.0.0.1:16443/..." : EOF` at
01:10:42 — dell talks to the apiserver through its local `apiserver-proxy`, so that line is
stage 2 arriving back at dell, not the cause of stage 1.

### 13.5 Stage 2, confirmed: dqlite on an SD card, under an eviction storm

The Pi's datastore lives on `/dev/mmcblk0p2` — the **SD card** — which is also its root
filesystem (115 GB, 70 % full; the dqlite directory itself is only 149 MB). Its `sar`
history shows what the storm did to it:

| Time (UTC) | `mmcblk0` tps | `await` | `aqu-sz` | %util | %iowait |
|---|---|---|---|---|---|
| 00:30 | 42 | 14.7 ms | 0.63 | 11.7 % | — |
| 00:40 | 61 | 18.6 ms | 1.16 | 13.7 % | 4.1 |
| 00:50 | 49 | 17.6 ms | 0.89 | 15.4 % | 4.9 |
| **01:00** | **150** | **54.2 ms** | **8.21** | **53.8 %** | **22.0** |
| 01:10 | 96 | 53.5 ms | 5.17 | 34.6 % | 14.8 |
| 01:20 | 93 | 50.1 ms | 4.70 | 28.9 % | 12.1 |

A 3× jump in write latency and an 8-deep queue, starting in the interval that begins with
the 00:50:02 eviction. k8s-dqlite says the rest:

```
Sep 05 00:52:08 k8s-dqlite: error in txn: update transaction failed for key
  /registry/longhorn.io/volumes/longhorn-system/pvc-a3294a23-...: exec (try: 500): database is locked
Sep 05 01:10:10 k8s-dqlite: failed to delete /registry/masterleases/192.168.0.59 for TTL:
  exec (try: 0): context deadline exceeded, retrying
Sep 05 01:10:10 k8s-dqlite: ... /registry/leases/longhorn-system/driver-longhorn-io: context deadline exceeded
Sep 05 01:10:10 k8s-dqlite: ... /registry/events/apps/admin-svc-hpa.18d1553f59185572: context deadline exceeded
```

and the apiserver, in the same second as the four CSI sidecar deaths in §5:

```
Sep 05 01:09:37 apiserver was unable to write a JSON response: http: Handler timeout
Sep 05 01:09:37 timeout.go:140] "Post-timeout activity" method="PUT"
  path="/apis/coordination.k8s.io/v1/namespaces/keda/leases/operator.keda.sh"
```

Note which keys are named: `masterleases`, three `leases`, and an **`/registry/events`**
row for one of the dead HPAs from §6.7. The events churn those 18 broken HPAs generate is
landing on the same SD card as the leases the cluster needs to stay alive.

Crucially, **before** 00:50 the Pi shows nothing wrong at all: memory flat at 47 % all
night, no swap configured (`pswpin 0`, `pswpout 0`), CPU 62–66 % idle, no `rcu` stall in
the 00:44 minute, no dqlite slow query, `throttled=0x0` at 73.6 °C, and eth0 at 6 % of a
100 Mb link. The Pi's own ext4 failure at 00:48:26 (`device sdd`, inode 12,
`JBD2: I/O error when updating journal superblock`) is a Longhorn volume whose peer replica
was on the collapsing node — a consequence, not a cause.

### 13.6 The Pi's two latent faults (not implicated on 09-05, one implicated on 09-04)

- **eth0 negotiates 100 Mbps/Full, always, on a Gigabit port.** Nine `Link is Up` events
  in the journal, nine at `100Mbps/Full`. Error counters are perfectly clean (0 errors,
  0 dropped, 0 carrier), which points at a cable or a switch port, not the NIC.
- **The link flaps.** Six `Link is Down/Up` pairs on Aug 26, six on Sep 03, six on
  **Sep 04 at 10:39:24–10:39:40** — followed at 10:42:34 by `rcu_preempt` stalls, kine
  `DeadlineExceeded`, and kube-controller-manager / kube-scheduler lease failures. That is
  the **09-04 10:42 incident** this report calls the earlier occurrence, and its trigger
  was the Pi's link, not dell's memory. The two events share a shape, not a cause.
- Recurring `rcu_preempt` expedited stalls appear throughout, including 00:35–00:50 on
  09-05.

For completeness, the flap dates and dell's iSCSI-timeout dates only partly overlap
(flaps: Aug 26, Sep 03, Sep 04; dell iSCSI timeouts: Aug 26 ×6, Sep 03 ×9, Sep 05 ×19),
so both failure modes are live and independent.

### 13.7 What is actually consuming `dell-amd64-srv`

8 CPUs, 15.2 GiB RAM, 4 GiB swap, and **one** SATA SSD (SK hynix SC300B 512 GB, 29,665
power-on hours, SMART `PASSED`) carrying root, 22 GB of Docker, and all of Longhorn.
Sharing it:

- **47 containerd shims** — the Kubernetes half.
- **26 Docker containers outside Kubernetes**, invisible to the scheduler: `bugsink`,
  `jaeger`, `api-gw-svc`, `auth-svc`, `config-svc`, `media-api`, `otel-collector`,
  `audit-svc`, `media-worker`, `profile-svc`, `payment-svc`, `notification-svc`,
  `redis-svc`, `rabbitmq-svc`, `prometheus`, `support-svc`, `memory-svc`,
  `ai-runtime-svc`, `llm-gateway-svc` and more. 17 `node` processes account for 1.5 GB of
  RSS between them.
- **A QEMU VM**, `qemu-system-x86`, holding **3.8 GB RSS** at the moment of the OOM. No VM
  is running now and `virsh list --all` is empty, so it was transient — and it was the
  single largest identifiable consumer in the OOM dump.
- **Jenkins** (`java`, 630 MB) plus `buildkitd`, a **13.88 GB build cache** and 11.49 GB of
  images.
- `promtail`, `loki`, `otelcol-contrib`, `tgtd`, and Longhorn's instance-manager (40
  `longhorn` processes, 381 MB).
- **`llm-gateway-svc`, in a permanent crash loop:** `restartCount` **4,214** and climbing,
  `restartPolicy: unless-stopped`, exiting 1 roughly every 66 seconds — right through the
  incident window. The cause is trivial and has nothing to do with capacity:

  ```
  asyncpg.exceptions.InvalidPasswordError: password authentication failed for user "llm_gateway_user"
  ```

And the kubelet was configured to let all of this happen:

```
--fail-swap-on=false
--eviction-hard="memory.available<100Mi,nodefs.available<1Gi,imagefs.available<1Gi"
```

with **no `--system-reserved` and no `--kube-reserved`** on either node. So the kubelet
believed essentially all 15 GiB was schedulable, and its only memory backstop was 100 MiB
— a threshold a thrashing machine crosses and re-crosses without ever giving the kubelet a
chance to evict anything. `vm.swappiness` was 60 and `vm.min_free_kbytes` 66 MB, so the
kernel's own defences were also set for a desktop, not for this.

The node is *not* short of disk (164/466 GB used) and the SSD is healthy. Nothing here is
hardware failure. It is a 15 GB laptop being asked to run a Kubernetes worker, a
26-container Docker estate, a CI system with a 14 GB build cache, a replicated block store
and occasionally a VM.

### 13.8 One more thing worth knowing: every write crosses the LAN twice

Every Longhorn volume in this cluster is `numberOfReplicas: 2` with
`replica-soft-anti-affinity: false`, so each volume keeps exactly one replica on each node,
and `default-data-locality` is `disabled`. Meanwhile **`dell-amd64-srv` has no Ethernet at
all** — its only interface is `wlp2s0` (Intel `iwlwifi`), with `iwlmvm power_scheme=2`
(power-saving), and the route to the Pi and the whole Calico overlay ride it. So every
synchronous write to any volume attached to dell is mirrored over WiFi to a Pi on a
flapping 100 Mb link.

This was *not* the trigger on 09-05 — dell's WLAN never disconnected, and its throughput
*fell* from 510 kB/s to 58 kB/s during the stall, i.e. it was a casualty. But it is a
standing hazard, and it is why the 5 s NOP-out timeout was so dangerous.

### 13.9 Changes applied on the nodes (2026-09-05 ~14:30 UTC)

Two low-risk, reversible mitigations, applied on both nodes / dell respectively:

1. **iSCSI NOP-out timeout 5 s → 30 s, interval 5 s → 10 s** — both nodes.
   `/etc/iscsi/iscsid.conf` (backed up to `iscsid.conf.bak-20260905`) **and** all 17
   per-target records under `/etc/iscsi/nodes/` were updated, so a 30-second host stall no
   longer drops the session and aborts an ext4 journal. `replacement_timeout` stays at 120.
   **Caveat:** `iscsiadm -m session --op=update` writes the record but does not change a
   live connection — `/sys/class/iscsi_connection/*/ping_tmo` still reads `5` for all 17
   current sessions. Each volume picks up 30 s the next time it is attached (pod restart,
   node reboot, or a deliberate detach/attach). Until then the currently-attached volumes
   still have the old 5 s exposure.
2. **Kernel reclaim tuning on dell**, in a new `/etc/sysctl.d/99-microk8s-longhorn.conf`
   (with the reasoning in comments, applied live):

   | Knob | Was | Now | Why |
   |---|---|---|---|
   | `vm.swappiness` | 60 | 10 | stop trading resident anon pages for page cache on a box whose cache is already gone |
   | `vm.min_free_kbytes` | 67,584 | 262,144 | 256 MB of headroom so allocations don't hit direct reclaim the moment a burst lands |
   | `vm.watermark_scale_factor` | 10 | 100 | `kswapd` starts reclaiming at 1 % rather than 0.1 % distance — background reclaim instead of the synchronous kind that produced load 580 |

   These change *how gracefully* the node degrades. They do not create memory, and the
   node is still at ~200 % commit — at the time of writing, 9.6 GB used and 2.9 GB already
   swapped. Without 13.10.1 it will thrash again.

Nothing else was altered: no service restarted, no container stopped, no kubelet argument
changed.

### 13.10 What still needs doing, in the order it matters

1. **Reduce what `dell-amd64-srv` is asked to hold.** This is the fix; everything else is
   damage limitation. The 26 Docker containers, Jenkins' build cache and the QEMU VM are
   outside Kubernetes, so the scheduler cannot see them and the kubelet cannot evict them.
   Pick any combination of: give each Docker service a `--memory` cap; move the estate
   into the cluster where it gets requests and limits; move Jenkins (or at least its
   14 GB buildkit cache) off this node; stop running VMs here. Start with the free one —
   **`docker stop llm-gateway-svc` or fix its Postgres password.** 4,214 restarts is pure
   churn, and it was churning while the node died.
2. **Make the kubelet defend the node.** With reservations in place the kubelet evicts a
   pod or two long before the kernel starts thrashing:

   ```
   --system-reserved=cpu=500m,memory=2Gi
   --kube-reserved=cpu=500m,memory=1Gi
   --eviction-hard=memory.available<500Mi,nodefs.available<2Gi,imagefs.available<2Gi
   --eviction-soft=memory.available<1Gi
   --eviction-soft-grace-period=memory.available=1m30s
   ```

   in `/var/snap/microk8s/current/args/kubelet`, then
   `snap restart microk8s.daemon-kubelite`. On dell this restarts only the kubelet and
   kube-proxy — pods keep running and the restart is far inside the 300 s eviction window
   — but it is a control-plane-adjacent action, so it wants a chosen moment rather than a
   drive-by. Do the same on the Pi, where the same two arguments are also missing.
   Once (1) has actually reduced the commitment, consider `swapoff -a` on dell as well:
   with no swap the kernel OOM-kills one container instead of grinding the entire host to
   a halt, which is the failure mode Kubernetes is designed for. Doing it *before* (1)
   would just OOM something immediately.
3. **Give the pods that must survive a memory reservation and a priority.**
   `argocd-application-controller` was `BestEffort` — `oom_score_adj 1000`, i.e. first in
   line — which is why it, and not one of the 26 unmanaged Docker containers, was what the
   kernel killed at 01:18:18. Requests, limits and a non-zero PriorityClass on ArgoCD,
   Longhorn's managers and the monitoring stack would make the next OOM pick something
   expendable.
4. **Move the Pi's dqlite datastore off the SD card.** `/dev/mmcblk0p2` went from 15 ms to
   54 ms of write latency under load and that is what turned an eviction storm into
   cluster-wide leader-election failure. The datastore is 149 MB; the Pi already has SATA
   devices attached. Relocating
   `/var/snap/microk8s/current/var/kubernetes/backend` to real storage (bind mount or
   symlink, with MicroK8s stopped) is the single best control-plane fix available. While
   there: the 18 dead HPAs from §6.7 are writing events straight onto that card.
5. **Fix the Pi's link.** 100 Mbps/Full on a Gigabit port with 18 flaps in 10 days is a
   cable or a switch port. It caused the 09-04 10:42 event outright. Replace the cable,
   move ports, confirm `1000Mbps/Full` in `ethtool`.
6. **Get dell onto Ethernet, or at least stop its WiFi from sleeping.** All Calico overlay
   and all Longhorn replication traffic currently rides `wlp2s0` with
   `iwlmvm power_scheme=2`. A USB 3 Gigabit adapter costs nothing and removes an entire
   class of latency spike; failing that, `iwlmvm.power_scheme=1` disables power saving.
7. **Make ext4 fail safe on Longhorn volumes.** Add `errors=remount-ro` to the StorageClass
   `mountOptions` so the next stalled session gives a read-only filesystem — recoverable,
   loud, no `fsck` — instead of an aborted journal and a corrupt `pg_filenode.map`.
8. **Reduce cross-node replication where it buys nothing.** Set
   `default-data-locality: best-effort` so reads stay local; move
   `jenkins/buildkit-cache-pvc` to `local-path` (it is CI scratch on a replicated volume,
   and both of its 40 GiB volumes are detached and orphaned right now — delete them); then
   deal with the two still-degraded volumes, `monitoring/prometheus-data` and
   `monitoring/loki-data`, and set a Longhorn `backup-target`, which is still empty.
9. **Restore monitoring.** Prometheus is crashlooping on a full 5 Gi PVC and Loki's store
   is corrupt (§6.1, §6.2), which is why none of the above was visible while it was
   happening. `sar` on the two nodes is currently the only usable history — it is also
   what solved this incident, so keep `sysstat` installed and consider raising its
   retention.
