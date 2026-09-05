# Node hardening, 2026-09-05

Changes made to both cluster nodes after the mass pod-eviction incident of
2026-09-05 00:44–01:20 UTC. The full investigation is in
[`2026-09-05-microk8s-mass-pod-eviction.md`](./2026-09-05-microk8s-mass-pod-eviction.md);
this file is the operational record: what was changed, why that value and not
another, how to verify it, and how to undo it.

The kubelet argument files on both nodes point here in a comment, so keep the
path stable.

## What happened, in five lines

The amd64 node was running at roughly twice its memory commitment. At ~00:38 UTC
it filled all 4 GiB of swap (99.93 % used), page cache collapsed to ~15 MB, and
the kernel entered sustained direct reclaim: 2,208 major faults/s, 154,803
pages/s stolen, 300 MB/s read against 874 kB/s written, load average **579.89**,
47 tasks in `D` state. Userspace stalled for seconds at a time — `systemd-journald`
missed its watchdog twice. The node-local Longhorn iSCSI session missed its 5 s
NOP-out at 00:44:34, ext4 aborted the journal on the three attached Postgres
volumes, containerd missed its deadlines, PLEG went stale, the node went
`NotReady` at ~00:45 and the control plane evicted 21 pods at 00:50:02. The
kernel then OOM-killed rather than the kubelet evicting, because the kubelet had
been told nothing was reserved and its eviction threshold was 100Mi.

Three databases were corrupted (mtaa, vaultwarden, xboy) as a second-order
effect of a memory problem. The hardening below targets the three links in that
chain that were cheapest to break.

## 1. Swap disabled on the amd64 node

`/etc/fstab` (backup: `/etc/fstab.bak-20260905`) — swap line commented out:

```
# Disabled 2026-09-05 after the mass pod-eviction incident: on a Kubernetes node
# swap turns an out-of-memory event into a host-wide thrash collapse (load 580,
# 47 tasks in D state, iSCSI sessions dropped, three Postgres volumes corrupted).
# With swap off the kernel OOM-kills one container instead. Re-enable with
# `swapon /swap.img` + uncommenting, but only after reducing what this node holds.
# /swap.img	none	swap	sw	0	0
```

`/swap.img` was deliberately **left on disk**, so this is a one-line revert.
`swapoff -a` took 68 seconds to drain 4 GiB back into RAM and did not trigger an
OOM kill.

The reasoning: swap does not prevent an out-of-memory event on a node like this,
it converts a fast, local, single-container failure into a slow, host-wide one.
An OOM kill loses one pod and a controller restarts it. A thrash collapse loses
the kubelet's liveness, the iSCSI sessions and the filesystems behind them.

`--fail-swap-on=false` is still in the kubelet args on both nodes. That is
intentional — it is what allows the node to keep working if swap ever comes
back, and it does nothing while swap is off.

The arm64 node has no swap configured and needed no change.

## 2. Node Allocatable reservations on both nodes

Before: neither node reserved anything. The kubelet believed every byte of RAM
was schedulable, so the scheduler kept placing pods while the host was already
in reclaim, and the only backstop was `--eviction-hard=memory.available<100Mi` —
a threshold a thrashing host crosses and re-crosses faster than the kubelet's
10 s housekeeping interval can act on. That is why the kernel OOM killer fired
first: it did not race the kubelet, the kubelet was never given a usable margin.

Both files are `/var/snap/microk8s/current/args/kubelet` (backups:
`kubelet.bak-20260905`). MicroK8s runs kubelet inside `snap.microk8s.daemon-kubelite`,
so applying is `snap restart microk8s.daemon-kubelite`.

### amd64 node — 8 CPU, 15,593 MB

```
--system-reserved=cpu=1000m,memory=6Gi
--kube-reserved=cpu=500m,memory=1Gi
--eviction-hard="memory.available<750Mi,nodefs.available<2Gi,imagefs.available<2Gi"
--eviction-soft="memory.available<1500Mi"
--eviction-soft-grace-period="memory.available=1m30s"
--eviction-max-pod-grace-period=60
```

`system-reserved=6Gi` is measured, not guessed. With swap off, `user-1000.slice`
alone held 5,676 MB of **anonymous** memory (a rootless `containerd-shim` at
5,553 MB, `java` at 909 MB), and total non-Kubernetes demand came to ~6.4 GB.
This node hosts 26 Docker containers and a 13.88 GB build cache outside
Kubernetes; until that shrinks, 6Gi is what honesty requires. The alternative —
reserving less and letting the scheduler fill the gap — is exactly the state
that produced the incident.

Result: allocatable **7,860,096Ki (7.5 GiB) / 6500m**, `kubepods` cgroup capped
at **8.23 GiB**.

### arm64 node — 4 CPU, 15,973 MB, control plane

```
--system-reserved=cpu=200m,memory=3Gi
--kube-reserved=cpu=200m,memory=2500Mi
```

Eviction flags are identical to the amd64 node. `kube-reserved` is larger here
because this node runs the control plane: `kubelite` alone holds ~1.3 GB.
The CPU reservations are deliberately small — pod requests already total 3320m
on this 4-core node, and reserving more would make it unschedulable.

Result: allocatable **9,882,788Ki (9.42 GiB) / 3600m**, `kubepods` capped at
**10.16 GiB**.

> This node is tight: pod requests are **92 % of allocatable CPU** and **85 % of
> allocatable memory**, about 280m and 1.4 GiB of headroom. It is the next thing
> to fix, either by moving workloads to the amd64 node or by correcting the
> requests that are too high.

### Why these flags produce a hard cap

`enforceNodeAllocatable` defaults to `["pods"]`, so the kubelet writes
`memory.max` on the `kubepods` cgroup — with `cgroupDriver: cgroupfs` that is
`/sys/fs/cgroup/kubepods/memory.max`. Pods can no longer collectively starve the
host: they hit their own ceiling and the kubelet evicts inside it.

Reservations were sized from `anon` in each cgroup's `memory.stat`, **not** from
`memory.current`, which includes page cache and overstates usage badly (the
arm64 node appeared to be using 13.9 GB while `free` reported 8.1 GB).

### Verify

```bash
kubectl get node <node> -o jsonpath='{.status.allocatable}{"\n"}'
kubectl get node <node> -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}'
# on the node:
cat /sys/fs/cgroup/kubepods/memory.max
free -m
```

Verify from the API, not from the journal. MicroK8s runs its daemon wrappers
under `set -x`, so the kubelite journal is full of trace lines and hex container
IDs; a naive grep for error patterns produces false positives (this cost one
unnecessary rollback during the change).

### Revert

Restore `kubelet.bak-20260905` and `snap restart microk8s.daemon-kubelite`. The
node stays `Ready` throughout; allocatable returns to full capacity within a few
seconds of the restart.

## 3. iSCSI NOP-out timeout raised, both nodes

`/etc/iscsi/iscsid.conf` (backup: `iscsid.conf.bak-20260905`) on both nodes, and
every per-target record under `/etc/iscsi/nodes/` (9 on amd64, 8 on arm64):

```
node.conn[0].timeo.noop_out_timeout = 30   # was 5
node.conn[0].timeo.noop_out_interval = 10  # was 5
```

Longhorn attaches volumes over iSCSI, and on this cluster the target is often on
the *same host* as the initiator — the traffic crosses a Calico veth, not the
LAN. Five seconds is a reasonable default for a storage network with an
independent storage controller. It is not reasonable when the initiator, the
target and the workload are all competing for the same stalled CPU: a host that
pauses for six seconds loses its own disks. Thirty seconds is long enough to
ride out a reclaim spike and still short enough to detect a genuinely dead
target.

> **Caveat: this is not live on existing sessions.** `iscsiadm --op=update`
> reported success for all 17 sessions, but `/sys/class/iscsi_connection/*/ping_tmo`
> still reads `5`. The new value applies at the next attach — i.e. after a volume
> detach/attach cycle, a Longhorn engine restart or a node reboot. Check with:
>
> ```bash
> grep . /sys/class/iscsi_connection/*/ping_tmo
> ```

## 4. Reclaim tuning, amd64 node

New file `/etc/sysctl.d/99-microk8s-longhorn.conf`:

```
vm.swappiness = 10
vm.min_free_kbytes = 262144
vm.watermark_scale_factor = 100
```

`min_free_kbytes` at 256 MB and `watermark_scale_factor` at 100 widen the gap
between the low and high watermarks, so `kswapd` starts reclaiming earlier and
in the background instead of the workload dropping into synchronous direct
reclaim. `swappiness=10` matters only if swap is ever re-enabled; it is set now
so the value is right if it is.

Not applied to the arm64 node, which never entered reclaim during the incident
(47 % memory used all night, zero swap, 62–66 % idle).

## Ranked work still open

1. **Reduce what the amd64 node holds outside Kubernetes.** 5.7 GB of anonymous
   memory in `user-1000.slice`, 26 Docker containers, 13.88 GB of build cache.
   Every gigabyte freed here is a gigabyte the scheduler can use, and the 6Gi
   reservation shrinks with it.
2. **Relieve the arm64 node.** 92 % of allocatable CPU is requested.
3. **Move the arm64 node's dqlite datastore off the SD card.** During the
   incident `/dev/mmcblk0p2` went from 14.7 ms to 54.2 ms average wait, which is
   what turned a worker-node stall into `database is locked` and apiserver
   handler timeouts.
4. **Fix the arm64 node's Ethernet link.** It negotiates 100 Mbps/Full on a
   Gigabit port, 9 attempts out of 9, with clean error counters — a cable or port
   fault. It flapped six times on 2026-09-04 at 10:39 and took the control plane
   with it.
5. **Give the amd64 node wired Ethernet**, or at minimum
   `iwlmvm.power_scheme=1`.
6. **Set `errors=remount-ro`** on the Longhorn StorageClass. `errors=continue`
   is why an aborted journal turned into Postgres reading garbage rather than a
   clean read-only failure.
7. **`default-data-locality: best-effort`** in Longhorn, so a volume's replica
   prefers the node its workload runs on and writes stop crossing the LAN twice.
8. **Requests, limits and a PriorityClass** for ArgoCD, Longhorn and monitoring.
   The pod the kernel killed was `argocd-application-controller`, BestEffort with
   `oom_score_adj 1000` — it was the most killable thing on the node, not the
   least important.
9. **Set a Longhorn backup target.** It is empty; there are no volume backups.
10. **Restore Prometheus and Loki.** Both were broken before the incident, which
    is why `sar` from `sysstat` was the only surviving metrics history — and the
    only reason this was diagnosable at all. Keep `sysstat` installed regardless.
