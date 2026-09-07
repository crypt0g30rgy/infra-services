# Running Local k8s Instance [MicroK8s] (Ubuntu Server)

## 1. Install MicroK8s

Install MicroK8s as root or using sudo:

```bash
sudo snap install microk8s --classic
```

---

## 2. Add your user to the MicroK8s group

This allows running MicroK8s commands without sudo:

```bash
sudo usermod -aG microk8s $USER
sudo chown -f -R $USER ~/.kube
newgrp microk8s
```
Create a read-only account

```bash
openssl genrsa -out readonly-user.key 2048
openssl req -new -key readonly-user.key -out readonly-user.csr -subj "/CN=readonly-user/O=readers"
openssl x509 -req -in readonly-user.csr -CA /var/snap/microk8s/current/certs/ca.crt -CAkey /var/snap/microk8s/current/certs/ca.key -CAcreateserial -out readonly-user.crt -days 365   
```
---

## 3. Enable Addons

### Essential Addons

```bash
microk8s enable rbac
microk8s enable dns storage
```

### Common Optional Addons

```bash
microk8s enable ingress
microk8s enable dashboard
microk8s enable metrics-server
microk8s enable hostpath-storage
microk8s enable registry
microk8s enable metallb:192.168.1.200-192.168.1.200
```

`hostpath-storage` gives you a `PersistentVolume` that is just a directory on
one node's disk, which pins every workload owning data to that machine. Since
the cluster gained a second node it uses **Longhorn** instead — see
[`arm64-srv/k8s/longhorn`](./arm64-srv/k8s/longhorn). The hostpath addon stays
enabled and default while volumes are still being migrated across.

List all available addons:

```bash
microk8s status --wait-ready
microk8s enable --help
```

Install keda for event driven workflows

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda --namespace keda --create-namespace   
```
Install external secrets manager for auto injection of secrets 

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace
```
---

### Custom dns in cluster

- use nano 

```sh
export KUBE_EDITOR="nano"
```

- edit config 

```sh
microk8s kubectl edit configmap coredns -n kube-system
```

```json
data:
  Corefile: |
    .:53 {
        errors
        health
        ready
        
        # Add this hosts block
        hosts {
            192.168.1.50 myhost.local
            10.0.0.5 internal-api.example.com
            fallthrough
        }

        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf
        cache 30
        loop
        reload
        loadbalance
    }   
```

- restart kube dns with new dns changes

```sh
microk8s kubectl delete pod -n kube-system -l k8s-app=kube-dns   
```

- validate

```sh
microk8s kubectl run -it --rm --restart=Never --image=busybox nslookup myhost.local   
```

### Node-level DNS for `*.internal.example.com` (containerd, not coredns)

The coredns change above only fixes name resolution **inside pods**. Pulling an
image does not go through coredns — containerd on the node uses the host's own
resolver — so a registry that only exists in the LAN's DNS has to resolve on the
host too.

`pi-5-16gb-srv-0` gets this for free: its `/etc/resolv.conf` is
`nameserver 192.168.0.59`, which is AdGuard running on that same machine, and
AdGuard has rewrites for `registry.internal.example.com` and
`local-s3.internal.example.com` → `192.168.0.59`.

`dell-amd64-srv` does not. It uses `systemd-resolved` (`127.0.0.53`) with a
public upstream, which answers those names with **Cloudflare edge addresses**.
containerd then connects to Cloudflare, which has no origin for them, and the
pull dies with a message that looks like a certificate problem but is not:

```
failed to resolve image: failed to do request: Head
"https://registry.internal.example.com/v2/ci-tools/manifests/sha256:...":
remote error: tls: handshake failure
```

This surfaced when Jenkins agents moved onto dell (they follow the controller
now), because every `ci-tools` and service image lives in that registry.

Fixed by pinning both names in dell's `/etc/hosts` (backup at
`/etc/hosts.bak-before-internal-registry`):

```
192.168.0.59 registry.internal.example.com
192.168.0.59 local-s3.internal.example.com
```

`/etc/hosts` rather than `certs.d`/`skip_verify` on purpose: the registry's
certificate is publicly trusted, so once the name resolves to the pi the
handshake is normal and verification stays on. containerd re-reads this per
pull, so nothing needs restarting.

The broader fix is to point dell's resolver at AdGuard the way the pi does,
which would cover the whole internal zone instead of two names. It is not done
because it makes all of dell's DNS depend on the pi being up.

Check either node without shelling into it — `dnsPolicy: Default` is what makes
the pod use the *host's* resolver rather than coredns:

```bash
kubectl run dnscheck --rm -it --restart=Never --image=busybox:1.37 \
  --overrides='{"spec":{"nodeName":"dell-amd64-srv","hostNetwork":true,"dnsPolicy":"Default"}}' \
  -- nslookup registry.internal.example.com
```

### Node placement: which workload belongs on which node

The pi keeps everything the cluster cannot lose when dell (Wi-Fi, and it OOMed once —
[`incidents/2026-09-05-node-hardening.md`](incidents/2026-09-05-node-hardening.md)) goes
away; dell takes what can be missing for an afternoon. Expressed with
`nodeSelector: kubernetes.io/hostname: <node>`, never `kubernetes.io/arch`. As of 2026-09-07:

| | pi-5-16gb-srv-0 (arm64) | dell-amd64-srv (amd64) |
|---|---|---|
| **Databases** | all of them, `data` included | the ones still awaiting a dump/restore |
| **Critical namespaces** | `apps`, `mtaa`, `xboy`, `ingress`, `vaultwarden` | — |
| **Infrastructure and CI** | — | argocd, jenkins + agents, keda, external-secrets |
| **Monitoring** | `promtail` only (DaemonSet — it has to be on both) | **all of it**: prometheus, jaeger, otel-collector, grafana, loki, bugsink web |

Manifests live in the tree of the node they are pinned to: `amd64-srv/k8s/` for dell,
`arm64-srv/k8s/` for the pi and for anything unpinned or cluster-wide.

The monitoring row moved on 2026-09-07 and it moved because of storage, not CPU: with the pi
unable to schedule a second Longhorn replica (see the storage bullet below), every monitoring
volume ended up single-replica on dell, and a pod on the pi with its only replica on dell
does every read and write over the LAN. So the pods followed the data. Half of that change
is in `k8s-infra` (`components/monitoring-on-amd64`, which moves the three ArgoCD-owned
Deployments), half is here (`nodeSelector` on grafana and loki), and the volume side is in
neither — it is live state on the `volumes.longhorn.io` objects. Losing dell now loses the
telemetry; that is the accepted trade, and it is why nothing holding user data is
single-replica.

- Allocatable is **6500m / 7676Mi** on dell (minus a 6Gi system + 1Gi kube reservation) and
  **3600m / 9648Mi** on the pi. dell hits its *memory-request* wall first — Jenkins agents
  ask 1792Mi each, so a few builds mean `FailedScheduling ... Insufficient memory`; the pi
  hits *CPU* first, ~95% of four cores at its busiest. Memory-hungry and stateless → dell.
- Levers on that wall, cheapest first: cap concurrent builds; lower the 6Gi reservation;
  move the remaining databases to the pi (trades dell's memory for the pi's CPU).
- **Storage is the pi's other wall**: its Longhorn disk reserves 60Gi of 114.7Gi, so the
  scheduling budget is 54.7Gi and ~54Gi is committed. A new volume there gets
  `ReplicaSchedulingFailure: insufficient storage` and runs degraded with its only replica on
  dell — silently reintroducing the dependency the placement is meant to remove. Check
  `kubectl -n longhorn-system get volumes.longhorn.io` for `robustness` after every move.
  This is what moved all of `monitoring` to dell: `grafana-data`, `loki-data` and
  `prometheus-data` are now deliberately `numberOfReplicas: 1` with `nodeSelector: ["amd64"]`
  (a Longhorn *node tag*, not a k8s label), so `degraded` there would mean unschedulable
  rather than unhealthy. `k8s-infra/docs/node-pinning.md` has the patch recipe.
- A Longhorn RWO volume is not a reason to stay — it reattaches on the other node in
  seconds (grafana, SQLite, ~45 s), but keep `maxSurge: 0` or two pods race the attach. A
  PostgreSQL data directory *is*: crossing architectures is a `pg_dumpall` and a restore,
  which is why `postgres-mtaa` and `postgres-{root,xboy,foodiehub}` are still on dell.
  `vaultwarden/postgres` took that path on 2026-09-06 and is on the pi
  ([`maintenance/2026-09-06-vaultwarden-to-pi.md`](maintenance/2026-09-06-vaultwarden-to-pi.md));
  it was the only critical service left on dell.
- Not changeable from this repo: keda's `nodeSelector` (ArgoCD `k8s-infra`, selfHeal reverts
  patches), external-secrets' (Helm — needs `--set
  nodeSelector."kubernetes\.io/hostname"=dell-amd64-srv`), and the Jenkins *agent* pod
  template (`meet-to-meat-services/back-end/tdi-ci`; `kubernetes.io/arch: amd64` plus a
  podAffinity to the controller, so agents follow it and cannot land on the pi).

## 4. Check Cluster Status

```bash
microk8s status --wait-ready
microk8s kubectl get nodes
```

Expected output:

```
NAME       STATUS   ROLES    AGE   VERSION
ubuntu     Ready    <none>   5m    v1.30.x
```

---

## 5. Get Kubeconfig (Local)

To view the config:

```bash
microk8s config
```

Or save it to a file:

```bash
microk8s config > config
```

---

## 6. Remote kubectl Setup

### Install kubectl

```bash
sudo apt install -y kubectl
```

### Set Up kubeconfig

On your workstation:

```bash
mkdir -p ~/.kube
cd ~/.kube
```

Copy the config file from the MicroK8s host:

```bash
scp user@<microk8s-server-ip>:/home/user/config ~/.kube/config
```

Verify connectivity:

```bash
kubectl get nodes
```

---

## 7. Enable External API Access (Optional)

By default, MicroK8s API server only listens on localhost. To allow remote access:

Edit API server args:

```bash
sudo nano /var/snap/microk8s/current/args/kube-apiserver
```

Add or modify:

```
--bind-address=0.0.0.0
--advertise-address=<your-server-ip>
```

Restart MicroK8s:

```bash
sudo microk8s stop
sudo microk8s start
```

Verify:

```bash
sudo netstat -tunlp | grep 16443
```

---

## 8. Enable Kubernetes Dashboard

Enable:

```bash
microk8s enable dashboard
```

Get access token:

```bash
token=$(microk8s kubectl -n kube-system get secret | grep default-token | awk '{print $1}')
microk8s kubectl -n kube-system describe secret $token
```

Start proxy:

```bash
microk8s kubectl proxy
```

Access:

```
http://127.0.0.1:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/
```

---

## 9. Verify System Pods

```bash
microk8s kubectl get pods -A
```

Check for:

* `kube-system` components
* Addon pods (ingress, dashboard, registry, etc.)

---

## 10. Reset or Remove MicroK8s (Optional)

Reset cluster:

```bash
microk8s reset
```

Uninstall MicroK8s:

```bash
sudo snap remove microk8s
```

---

## Summary of Key Commands

| Task             | Command                                            |
| ---------------- | -------------------------------------------------- |
| Install MicroK8s | `sudo snap install microk8s --classic`             |
| Enable Addons    | `microk8s enable dns storage ingress dashboard`    |
| Check Status     | `microk8s status --wait-ready`                     |
| Get kubeconfig   | `microk8s config > config`                         |
| Remote Connect   | `scp user@server:/home/user/config ~/.kube/config` |
| List all pods    | `microk8s kubectl get pods -A`                     |
-------------------------------------------------------------------------