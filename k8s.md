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
[`pi5-arm64/k8s/longhorn`](./pi5-arm64/k8s/longhorn). The hostpath addon stays
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

### Node-level DNS for `*.internal.xboy.me` (containerd, not coredns)

The coredns change above only fixes name resolution **inside pods**. Pulling an
image does not go through coredns — containerd on the node uses the host's own
resolver — so a registry that only exists in the LAN's DNS has to resolve on the
host too.

`pi-5-16gb-srv-0` gets this for free: its `/etc/resolv.conf` is
`nameserver 192.168.0.59`, which is AdGuard running on that same machine, and
AdGuard has rewrites for `registry.internal.xboy.me` and
`local-s3.internal.xboy.me` → `192.168.0.59`.

`dell-amd64-srv` does not. It uses `systemd-resolved` (`127.0.0.53`) with a
public upstream, which answers those names with **Cloudflare edge addresses**.
containerd then connects to Cloudflare, which has no origin for them, and the
pull dies with a message that looks like a certificate problem but is not:

```
failed to resolve image: failed to do request: Head
"https://registry.internal.xboy.me/v2/ci-tools/manifests/sha256:...":
remote error: tls: handshake failure
```

This surfaced when Jenkins agents moved onto dell (they follow the controller
now), because every `ci-tools` and service image lives in that registry.

Fixed by pinning both names in dell's `/etc/hosts` (backup at
`/etc/hosts.bak-before-internal-registry`):

```
192.168.0.59 registry.internal.xboy.me
192.168.0.59 local-s3.internal.xboy.me
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
  -- nslookup registry.internal.xboy.me
```

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