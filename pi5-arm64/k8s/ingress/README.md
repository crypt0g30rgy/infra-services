# Dual Traefik Ingress Architecture (Kustomize Module)

This directory contains a production-grade, GitOps-ready **dual Traefik ingress controller architecture** in a MicroK8s cluster, fully integrated with Cloudflare Tunnels (cloudflared) and localized Let's Encrypt DNS-01 SSL generation.

All configurations are modularized under **Kustomize** to enforce strict configuration reuse while keeping external and internal controllers completely isolated.

---

## 1. Directory Structure

```
pi5-arm64/k8s/ingress/
├── README.md
│
├── cloudflared/                # Kustomize Module: Cloudflare Tunnel Agent
│   ├── configmap.yaml          # Tunnel wildcard routing definitions
│   ├── secret.yaml             # Credentials file (base64)
│   ├── deployment.yaml         # Cloudflared container spec
│   └── kustomization.yaml      # Glue file
│
└── traefik/
    ├── base/                   # Kustomize Base: Core Ingress Controller
    │   ├── rbac.yaml           # ServiceAccount, ClusterRole, binding
    │   ├── pvc.yaml            # 1Gi PVC for certificates & logs
    │   ├── deployment.yaml     # Traefik + logrotate sidecar
    │   ├── service.yaml        # Main + metrics Service
    │   ├── servicemonitor.yaml # Prometheus integration
    │   ├── middleware.yaml     # Custom response headers
    │   └── kustomization.yaml  # Glue file
    │
    ├── external/               # Kustomize Overlay: Public Controller
    │   ├── configmap.yaml      # Static plain-HTTP configuration (SSL offloaded to CF)
    │   ├── patches.yaml        # Strategic patches (removes CF API tokens, sets Local routing)
    │   └── kustomization.yaml  # Overlay configurations (sets suffix '-external')
    │
    ├── internal/               # Kustomize Overlay: Private Controller
    │   ├── configmap.yaml      # Static Let's Encrypt HTTPS configuration (DNS-01)
    │   ├── secret.yaml         # Cloudflare DNS API tokens & ACME Email
    │   ├── patches.yaml        # Strategic patches (sets MetalLB 192.168.1.200, sets Cluster routing, maps email)
    │   └── kustomization.yaml  # Overlay configurations (sets suffix '-internal')
    │
    └── crds/                   # Ingress Class Registries
        ├── ingressclasses.yaml # Registers 'public' and 'internal' classes
        └── kustomization.yaml  # Glue file
```

---

## 2. Architecture & Design

### External Traefik (`traefik/external/` overlay)
- **IngressClass**: `public`
- **TLS**: Managed completely by **Cloudflare Edge**. Cloudflare terminates TLS and proxies traffic over a secure tunnel directly on HTTP (port 80) to `traefik-external`. No ACME certificates or API tokens are loaded in this deployment.
- **IP Preservation**: Configured with `externalTrafficPolicy: Local` to retain real client source IPs.

### Cloudflared (`cloudflared/` folder)
- Connects outward to the Cloudflare network and dynamically forwards incoming requests to the external Traefik controller at `http://traefik-external.ingress.svc.cluster.local:80`.

### Internal Traefik (`traefik/internal/` overlay)
- **IngressClass**: `internal`
- **TLS**: Terminated at the pod using Let's Encrypt `DNS-01` ACME challenges (using Cloudflare DNS API) to generate valid Public CA SSL certificates without exposing any internal endpoints to the public internet.
- **Network Routing**: Bound directly to your MetalLB auto-assigned Virtual IP (**`192.168.1.200`**).
- **Security**: Heavily segregated. Only the internal instance mounts your Cloudflare API DNS secret; the external instance has zero credentials attached to it.

---

## 3. Log Rotation & Disk Retention

To prevent the local disk/PVC from filling up (1GB PVC limit), both Traefik deployments include a lightweight, unprivileged **`logrotate` sidecar container** (`alpine:3.24`).
- Access logs are written in structured JSON to `/data/logs/access.log`.
- `logrotate` runs daily, truncating files whenever they hit `100M` and preserving up to `30` log rotations (giving you exactly 30 days of retention).

---

## 4. How to Deploy (Step-by-Step)

### Step 1: Register Ingress Classes
Apply the CRDs and IngressClasses overlay:
```bash
kubectl apply -k traefik/crds/
```

### Step 2: Configure & Deploy Cloudflared Tunnel
1. Get your tunnel credentials base64-encoded string:
   ```bash
   base64 -w0 ~/.cloudflared/<tunnel-id>.json
   ```
2. Open `cloudflared/secret.yaml` and replace `REPLACE_WITH_BASE64_CREDENTIALS_JSON` with your base64 string.
3. Open `cloudflared/configmap.yaml` and replace `<tunnel-id>` with your actual Cloudflare Tunnel ID.
4. Deploy using Kustomize:
   ```bash
   kubectl apply -k cloudflared/
   ```

### Step 3: Deploy External Ingress
```bash
kubectl apply -k traefik/external/
```

### Step 4: Configure & Deploy Internal Ingress
1. Open `traefik/internal/secret.yaml` and under `stringData`:
   - Replace `REPLACE_WITH_CLOUDFLARE_API_TOKEN` with your Cloudflare API token (Zone.DNS:Edit).
   - Replace `REPLACE_WITH_ACME_EMAIL` with your Let's Encrypt registration email.
2. Deploy using Kustomize:
   ```bash
   kubectl apply -k traefik/internal/
   ```

---

## 5. Verification & Validation

1. **Verify IngressClasses**:
   ```bash
   kubectl get ingressclass
   ```
   *(Should return both `public` and `internal` referencing `traefik.io/ingress-controller`)*

2. **Verify Pod Readiness**:
   ```bash
   kubectl get pods -n ingress
   ```
   *(Ensure both `cloudflared`, `traefik-external`, and `traefik-internal` pods are running successfully with 2/2 ready containers for Traefik)*

3. **Verify LoadBalancer IP binding**:
   ```bash
   kubectl get svc -n ingress
   ```
   *(`traefik-internal` should successfully bind to `192.168.1.200` via MetalLB)*

4. **Split-Horizon Wildcard DNS Configuration**:
   Ensure your local DNS resolver (e.g. AdGuard Home) contains a wildcard rewrite pointing `*.internal.example.com` directly to `192.168.1.200`.

---

## 6. Observability Integration

Your Prometheus configuration has been updated to scrape both external and internal controllers separately. A highly advanced, production-ready dashboard combining these metrics and Loki parsed logs is available in:
📁 `pi5-arm64/k8s/monitoring/dashboards/traefik-dashboard.json`
