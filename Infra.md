# Infra SetUp

## Current: 2026-09-07

Two nodes, one MicroK8s cluster (v1.35.6), storage on Longhorn v1.12.1.

The amd64 node was replaced on 2026-09-07: a Dell OptiPlex 7040 (`dell-amd64-32gb-srv`,
32 GB) took over from the Dell Precision 5510 (`dell-amd64-srv`, 16 GB), which was
decommissioned - see
[`maintenance/2026-09-07-amd64-node-replacement.md`](./maintenance/2026-09-07-amd64-node-replacement.md).

| | [`arm64-srv`](./arm64-srv/README.md) | [`amd64-srv`](./amd64-srv/README.md) |
|---|---|---|
| Role | control plane + most compose stacks | worker |
| Hostname | `pi-5-16gb-srv-0` | `dell-amd64-32gb-srv` |
| Address | 192.168.0.59 | 192.168.0.7 |
| Hardware | Raspberry Pi 5 Model B Rev 1.1 | Dell OptiPlex 7040 |
| CPU | Cortex-A76 ×4 | Intel i7-6700 ×8 (4 cores, 8 threads) |
| Memory | 15,973 MB | 30,991 MB |
| Swap | none | none (8 GB swapfile disabled 2026-09-07, see below) |
| Disk | 115 G on `/dev/mmcblk0p2` (SD card) | 232 G on LVM (256 GB SSD `sdb`); a second 250 GB HDD (`sda`, NTFS) is present and unused |
| GPU | — | GeForce GTX 1050 Ti (GP107) |
| Network | `eth0` — currently negotiating 100 Mbps, which is a fault | `enp0s31f6` — wired, also negotiating 100 Mbps, also a fault |
| OS | Ubuntu 24.04.4 LTS aarch64, kernel 6.8.0-1060-raspi | Ubuntu 26.04.1 LTS x86_64, kernel 7.0.0-31-generic |
| Timezone | Europe/Moscow (UTC+3) | Etc/UTC |
| Allocatable | 9.42 GiB / 3600m | 24.1 GiB / 7600m |

The timezone difference is worth remembering when reading logs off both nodes: the
arm64 node's local timestamps are three hours ahead of the amd64 node's.

Directory names in this repo are by **architecture**, not by vendor, so swapping a
machine does not mean renaming a tree. The amd64 tree was `hp-amd64` when that
node was an HP ProDesk 400 G6 (i7-9700, 40 GB, GTX 1050 Ti), then a Dell
Precision 5510, and is now a Dell OptiPlex 7040 - two machine swaps, no path
change.

## Node protection

Both kubelets reserve memory for the system and for Kubernetes, evict before the
kernel OOM killer can act, and the amd64 node runs without swap. These are not
defaults — they were added after the 2026-09-05 incident in which one node's swap
thrash corrupted three Postgres volumes. Before changing any of it, read
[`incidents/2026-09-05-node-hardening.md`](./incidents/2026-09-05-node-hardening.md).

Current headroom, and the reason this matters:

- **arm64-srv is nearly full**: pod requests are ~92 % of allocatable CPU and
  ~85 % of allocatable memory. Do not schedule anything new here.
- **amd64-srv reserves 6Gi for the system** (3Gi system-reserved, 2500Mi
  kube-reserved, 750Mi eviction threshold). That number was sized on the old box,
  where ~6.4 GB of anonymous memory belonged to processes outside Kubernetes (26
  Docker containers, a rootless builder, a 13.88 GB build cache). The OptiPlex
  carries none of those yet and has twice the RAM, so the reservation is now
  conservative rather than tight.

## UpComming

- 3 hp elitedesk/prodesk - 3 ha cluster
- a working Gigabit link on both nodes; both negotiate 100 Mbps today
- dqlite off the SD card
- the compose stacks that were on the old amd64 box (bugsink, and the
  `meet-to-meat-services/back-end/infra-dep-svc` dev stacks) are not on the
  OptiPlex - it has no Docker installed
