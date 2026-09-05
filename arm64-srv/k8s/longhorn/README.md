# Longhorn

Longhorn is the storage layer for the microk8s cluster, replacing the
`microk8s-hostpath` provisioner. Version **1.12.1**, namespace
`longhorn-system`, configured entirely by [`values.yaml`](./values.yaml).

The reason for it is not redundancy — read the replica note below before you
assume otherwise. It is that a hostpath volume is a *directory on one machine*,
so every workload owning data was nailed to the pi. A Longhorn volume is
reachable from either node over iSCSI, so a pod can be rescheduled without its
data being left behind.

## The cluster it is running on

| Node | Arch | Cores | Role in Longhorn |
|---|---|---|---|
| `pi-5-16gb-srv-0` | arm64 | 4 | Attaches volumes. **Hosts no replicas.** |
| `dell-amd64-srv` | amd64 | 8 | The only storage node. Holds every replica. |

Only nodes labelled `node.longhorn.io/create-default-disk=true` contribute a
disk (`createDefaultDiskLabeledNodes: true`), and only dell carries that label:

```bash
kubectl label node dell-amd64-srv node.longhorn.io/create-default-disk=true
```

The pi is excluded because its root filesystem is a microSD card that also
carries a separate Docker stack and the whole microk8s image store, and has run
over 90% full. Replica write traffic there would wear the card and risk filling
the disk the control plane lives on. The pi still runs `longhorn-manager` and
the CSI plugin, so pods scheduled there attach volumes normally.

**Every volume therefore has one replica, on one disk.** That is the same
redundancy hostpath gave (none), on better media — dell's volume is on an
LVM/SSD with ~425 GB free. It is *not* a backup. To get a real second copy:
free space on the pi or attach an external SSD to it, label the node, then
raise `defaultSettings.defaultReplicaCount` to 2 — Longhorn rebuilds the extra
replicas online, no downtime.

## Install

```bash
helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system --create-namespace \
  --version 1.12.1 -f arm64-srv/k8s/longhorn/values.yaml
```

`https://charts.longhorn.io` is blocked from some networks here. The chart also
ships inside the tagged source tree, under `chart/`:

```bash
curl -sL https://codeload.github.com/longhorn/longhorn/tar.gz/refs/tags/v1.12.1 | tar xz
helm upgrade --install longhorn ./longhorn-1.12.1/chart --namespace longhorn-system ... 
```

Two things are **not** Helm values and must be applied after install — the node
label above, and the pi's CPU override below.

## Host prerequisites

Both nodes need these; they are applied and persisted already, but a rebuilt
node needs them again.

```bash
apt-get install -y open-iscsi cryptsetup
systemctl enable --now iscsid
echo iscsi_tcp > /etc/modules-load.d/longhorn.conf   # and: modprobe iscsi_tcp
```

`iscsi_tcp` is what carries the volume to the pod; without it attach fails.
`dm_crypt` is only needed for encrypted volumes but is cheap to have.

**dell also needs multipathd told to keep its hands off Longhorn's devices**,
or attach fails with `device or resource busy`. Appended to
`/etc/multipath.conf` (backup at `/etc/multipath.conf.bak-before-longhorn`):

```
blacklist {
    devnode "^sd[a-z0-9]+"
}
```

Not yet installed, and so unavailable: **`nfs-common`**. That means no RWX
(`ReadWriteMany`) volumes and no NFS backup target on either node until it is.

### There is no backup target

`defaultSettings.backupTarget` is unset — there is no S3 bucket and no NFS
share to point it at. With one replica and no backups, a dell disk failure
loses the data. This is the largest open risk in the storage layer and it is
deliberate only in the sense that it is known.

## Two microk8s-specific gotchas

**The kubelet root directory.** microk8s does not use `/var/lib/kubelet`; it
symlinks it to `/var/snap/microk8s/common/var/lib/kubelet`. Relying on the
symlink for bidirectional mount propagation is the kind of thing that
half-works, so `csi.kubeletRootDir` names the real path.

**Docker Hub is unreachable in a way that looks like corruption.** Longhorn
pulls ~19 images in parallel on install, and both nodes failed with

```
failed to pull and unpack image ...: unexpected media type text/html
short read: expected ... bytes, got ...: unexpected EOF
```

which is an HTML error page arriving where a blob should be. On dell it was
Docker Hub's anonymous rate limit under the parallel pull storm; on the pi it
was worse — *every* Cloudflare IPv4 edge is unreachable from that host, and
Hub's auth (`auth.docker.io`) and blob CDN
(`production.cloudflare.docker.com`) are both Cloudflare-fronted, so no Hub
pull could ever succeed. Fixed on both nodes by putting Google's read-through
mirror first in `/var/snap/microk8s/current/args/certs.d/docker.io/hosts.toml`
(backups alongside as `.bak-before-mirror`):

```toml
server = "https://docker.io"

[host."https://mirror.gcr.io"]
  capabilities = ["pull", "resolve"]

[host."https://registry-1.docker.io"]
  capabilities = ["pull", "resolve"]
```

containerd re-reads this per pull — no restart needed. Hosts are tried in
order.

## The pi's instance-manager CPU reservation

The engine process for a volume runs on the node the **pod** is on, not the
node the replica is on. So the pi needs a running `instance-manager` even
though it hosts no replicas, and if it does not have one, every attach there
fails:

```
FailedAttachVolume ... rpc error: code = DeadlineExceeded
desc = volume pvc-... failed to attach to node pi-5-16gb-srv-0
```

with the real cause two layers down, on the instance-manager pod:

```
Warning OutOfcpu  Node didn't have enough resource: cpu,
requested: 480, used: 3670, capacity: 4000
```

`guaranteedInstanceManagerCPU` is 12% of node capacity — right for dell (960m
of 8 cores) and impossible for the pi, which has ~3670m of its 4000m already
requested by pinned workloads. Override it for the pi alone:

```bash
kubectl patch nodes.longhorn.io -n longhorn-system pi-5-16gb-srv-0 \
  --type=merge -p '{"spec":{"instanceManagerCPURequest":200}}'
```

Millicores, and a *request* with no matching limit — a scheduler floor, not a
cap, so engines still burst when a volume is busy. `0` means "use the global
percentage".

Longhorn backs off 2 minutes between instance-manager pod attempts. To stop
waiting after a fix, delete the CR and let the node controller rebuild it:

```bash
kubectl delete instancemanagers.longhorn.io -n longhorn-system <name>
```

## Migrating a hostpath volume to Longhorn

**The migration is finished.** All ten volumes are on Longhorn, and
`persistence.defaultClass` is now `true`, so a PVC with no `storageClassName`
lands on Longhorn rather than back on a directory on the pi. The section below
is kept because it is how the next one gets done - a rebuilt node, a restored
backup, or a volume that arrives on hostpath by accident.

| Namespace | Claim | Now on |
|---|---|---|
| `data` | `postgres-svc-pvc`, `postgres-ai-svc-pvc` | longhorn |
| `jenkins` | `jenkins-home`, `buildkit-cache-pvc` | longhorn |
| `vaultwarden` | `vaultwarden-data`, `postgres-data-postgres-0` | longhorn |
| `xboy` | `postgres-root-pvc`, `postgres-xboy-pvc`, `postgres-foodiehub-pvc` | longhorn |
| `ingress` | `traefik-data` | longhorn |

[`migrate-pvc-to-longhorn.sh`](./migrate-pvc-to-longhorn.sh) does one volume,
keeping the claim's name so no workload manifest has to change:

```bash
./migrate-pvc-to-longhorn.sh -n xboy -c postgres-root-pvc -w deploy/postgres-root
```

It refuses to start if the source PV is not `Retain` or if any pod still has the
claim mounted, and it refuses to rebind unless the copy verified. The steps it
runs, and why each one is there, are below.

**Before anything else, make every PV undeletable.** The hostpath PVs were
created with `persistentVolumeReclaimPolicy: Delete`, which means a fumbled
`kubectl delete pvc` takes the data with it:

```bash
kubectl get pv -o name | xargs -I{} kubectl patch {} \
  -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

Then, one volume at a time, never two:

1. **Scale the workload to 0** and confirm no pod holds the volume. A live
   database being copied under itself produces a corrupt copy that verifies
   fine.
2. **Create the destination PVC** — same size, `storageClassName: longhorn`,
   named `<old>-lh`.
3. **Run the copy job.** It must be pinned to the pi, because that is where the
   source directory physically is. It `cp -a`s and then compares four digests
   between source and destination — entry count, name/type/owner/mode
   metadata, file contents, and symlink targets — and fails the job on any
   mismatch. `lost+found` is removed from the destination first; it is an
   artefact of the fresh ext4 volume and would otherwise count as a
   difference.
4. **Require `COPY_VERIFIED_OK` in the job log.** No shortcuts here.
5. **Cut over** the workload to the new claim and scale back up.
6. **Confirm the application is healthy**, not just that the pod is Running.
7. Only then start the next volume.

The old hostpath directory is left in place as the rollback, which is what the
`Retain` patch in step 0 is for. Reclaim it later, deliberately.

### The rollback copies have been reclaimed

Done on 2026-08-22, after the new volumes had been exercised. **There are no
hostpath PVs left and `/var/snap/microk8s/common/default-storage/` is empty** —
so the rollback described above no longer exists, and the Longhorn volumes are
now the only copy of all of this data. See "There is no backup target" above;
that risk went from theoretical to the whole story.

10.1 GB came back on the pi's microSD (83.5 → 73.5 GB used, 76% → 67%), 8.9 GB
of it the Jenkins buildkit cache.

If it ever has to be done again, the order matters, and it is two steps because
`Retain` deliberately decouples them:

```bash
# 1. what exists, and where on disk
kubectl get pv -o json | jq -r '
  .items[] | select(.spec.storageClassName=="microk8s-hostpath")
  | [.metadata.name, .status.phase, .spec.hostPath.path] | @tsv'

# 2. delete the PV objects - with reclaimPolicy Retain this frees NO disk
kubectl delete pv <names...>

# 3. then remove the directories on the pi. There is no shell on the node from
#    the tooling side, so do it through a pod that mounts the parent:
kubectl run reclaim -n utils --rm -it --restart=Never --image=busybox:1.37 \
  --overrides='{"spec":{"nodeName":"pi-5-16gb-srv-0","securityContext":{"runAsUser":0},
    "containers":[{"name":"h","image":"busybox:1.37","stdin":true,"tty":true,
    "command":["sh"],"volumeMounts":[{"name":"ds","mountPath":"/ds"}]}],
    "volumes":[{"name":"ds","hostPath":{"path":"/var/snap/microk8s/common/default-storage","type":"Directory"}}]}}'
```

Check the replacement claim is `Bound` on `longhorn` **and** its Longhorn volume
is `healthy` before deleting anything. One caveat on that check: a volume only
mounted by an ephemeral pod - `buildkit-cache-pvc`, mounted solely by Jenkins
agents - reads `detached` / `robustness: unknown` between builds, which is normal
and not a fault. Confirm it by its replica instead: `failedAt` empty and the
volume's `Scheduled` condition `True`.

The `microk8s-hostpath` StorageClass and its provisioner are left in place, just
no longer the default and no longer used by anything. Note that the provisioner
Deployment has been crash-looping for months (899 restarts) - harmless now that
nothing asks it for a volume, but that is why it is not worth trusting again.

Two shapes need extra care:

- **ArgoCD-managed workloads.** `automated: {prune, selfHeal}` reverts the
  scale-to-zero out from under the migration, and `prune` will happily delete a
  PVC that momentarily does not exist in git. Pause auto-sync **first**:

  ```bash
  kubectl -n argocd patch application <app> --type=json \
    -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
  ```

  Then migrate, *then* land the `storageClassName` change in git, then restore
  the app. That order matters: with the change in git while the old claim is
  still bound, ArgoCD tries to patch an immutable field on a bound PVC and the
  sync fails.

  The app also needs `ignoreDifferences` on `/spec/volumeName` **and**
  `RespectIgnoreDifferences=true` in `syncOptions`, because the migrated claim is
  pre-bound to a generated PV name that cannot live in git. Without the second
  one the sync keeps sending `volumeName: ""` and the API server keeps rejecting
  it - `ignoreDifferences` alone only hides the field from the *diff*, not from
  the apply. Working examples: `clusters/production/infra.yaml` in both the
  `k8s-infra` and `xboy-k8s-infra` repos.
- **StatefulSets.** `volumeClaimTemplates` is immutable, so changing the
  storage class needs `kubectl delete statefulset --cascade=orphan` and a
  recreate — the pods keep running while you do it.

## Checking on it

```bash
kubectl -n longhorn-system get volumes.longhorn.io          # state, robustness
kubectl -n longhorn-system get replicas.longhorn.io -o wide # which node
kubectl -n longhorn-system get instancemanagers.longhorn.io # must be running
kubectl -n longhorn-system get nodes.longhorn.io            # schedulable, disk
```

The UI is one pod (`longhorn-ui`) with no ingress; reach it with
`kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80`. It has
**no authentication**, which is why it is not exposed.

When a volume will not attach, the useful order is: volume `conditions`
(is it `Scheduled`?) → replica `currentState` and its node → engine
`currentState` and its node → the instance-manager on *that* node → that pod's
events.
