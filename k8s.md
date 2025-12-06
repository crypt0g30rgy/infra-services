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

---

## 3. Enable Addons

### Essential Addons

```bash
microk8s enable dns storage
```

### Common Optional Addons

```bash
microk8s enable ingress
microk8s enable dashboard
microk8s enable metrics-server
microk8s enable hostpath-storage
microk8s enable registry
```

List all available addons:

```bash
microk8s status --wait-ready
microk8s enable --help
```

---

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