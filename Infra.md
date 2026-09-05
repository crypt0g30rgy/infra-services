# Infra SetUp

## Current: 2026-09-05

Two nodes, one MicroK8s cluster (v1.35.6), storage on Longhorn v1.12.1.

| | [`arm64-srv`](./arm64-srv/README.md) | [`amd64-srv`](./amd64-srv/README.md) |
|---|---|---|
| Role | control plane + most compose stacks | worker |
| Hostname | `pi-5-16gb-srv-0` | `dell-amd64-srv` |
| Address | 192.168.0.59 | 192.168.0.60 |
| Hardware | Raspberry Pi 5 Model B Rev 1.1 | Dell Precision 5510 |
| CPU | Cortex-A76 ×4 | Intel i7-6820HQ ×8 |
| Memory | 15,973 MB | 15,593 MB |
| Swap | none | none (disabled 2026-09-05, see below) |
| Disk | 115 G on `/dev/mmcblk0p2` (SD card) | 466 G on LVM |
| GPU | — | Quadro M1000M 2 GB + Intel HD 530 |
| Network | `eth0` — currently negotiating 100 Mbps, which is a fault | `wlp2s0` — **Wi-Fi**, no wired link |
| OS | Ubuntu 24.04.4 LTS aarch64, kernel 6.8.0-1060-raspi | Ubuntu 24.04.4 LTS x86_64, kernel 6.8.0-138-generic |
| Timezone | Europe/Moscow (UTC+3) | Etc/UTC |
| Allocatable | 9.42 GiB / 3600m | 7.5 GiB / 6500m |

The timezone difference is worth remembering when reading logs off both nodes: the
arm64 node's local timestamps are three hours ahead of the amd64 node's.

Directory names in this repo are by **architecture**, not by vendor, so swapping a
machine does not mean renaming a tree. The amd64 tree was `hp-amd64` when that
node was an HP ProDesk 400 G6 (i7-9700, 40 GB, GTX 1050 Ti); it is now a Dell
Precision 5510 and the path did not have to change.

## Node protection

Both kubelets reserve memory for the system and for Kubernetes, evict before the
kernel OOM killer can act, and the amd64 node runs without swap. These are not
defaults — they were added after the 2026-09-05 incident in which one node's swap
thrash corrupted three Postgres volumes. Before changing any of it, read
[`incidents/2026-09-05-node-hardening.md`](./incidents/2026-09-05-node-hardening.md).

Current headroom, and the reason this matters:

- **arm64-srv is nearly full**: pod requests are ~92 % of allocatable CPU and
  ~85 % of allocatable memory. Do not schedule anything new here.
- **amd64-srv reserves 6Gi for the system** because ~6.4 GB of anonymous memory
  on it belongs to processes outside Kubernetes (26 Docker containers, a rootless
  builder, a 13.88 GB build cache). Shrink that and the reservation shrinks.

## UpComming

- 3 hp elitedesk/prodesk - 3 ha cluster
- wired Ethernet for amd64-srv; a working Gigabit link for arm64-srv
- dqlite off the SD card
