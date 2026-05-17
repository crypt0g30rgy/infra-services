#!/usr/bin/env bash

set -Eeuo pipefail

########################################
# Configuration
########################################

RANCHER_VERSION="2.14.1"
KUBE_VERSION_OVERRIDE="1.35.99"

HOSTNAME="rancher.example.com"

NAMESPACE="cattle-system"

HELM_VERSION="v4.2.0"

INGRESS_CLASS="nginx"
# INGRESS_CLASS="traefik"

########################################
# Helpers
########################################

log() {
  echo
  echo "=================================================="
  echo "[+] $1"
  echo "=================================================="
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[!] Missing required command: $1"
    exit 1
  }
}

########################################
# Checks
########################################

require_cmd kubectl
require_cmd openssl
require_cmd wget
require_cmd tar

########################################
# Install Helm (local)
########################################

log "Downloading Helm ${HELM_VERSION}"

wget -q --show-progress \
  "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"

log "Extracting Helm"

tar -xzf "helm-${HELM_VERSION}-linux-amd64.tar.gz"

chmod +x linux-amd64/helm

HELM="$(pwd)/linux-amd64/helm"

"${HELM}" version

########################################
# Create namespace
########################################

log "Creating namespace"

kubectl create namespace "${NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

########################################
# Generate TLS certificate
########################################

log "Generating self-signed TLS certificate"

openssl req \
  -x509 \
  -nodes \
  -newkey rsa:4096 \
  -keyout tls.key \
  -out tls.crt \
  -sha256 \
  -days 3650 \
  -subj "/CN=${HOSTNAME}" \
  -addext "subjectAltName=DNS:${HOSTNAME}"

########################################
# Create Rancher TLS secret
########################################

log "Creating Rancher ingress TLS secret"

kubectl -n "${NAMESPACE}" delete secret tls-rancher-ingress \
  --ignore-not-found=true

kubectl -n "${NAMESPACE}" create secret tls tls-rancher-ingress \
  --cert=tls.crt \
  --key=tls.key

########################################
# Create Rancher CA secret
########################################

log "Creating Rancher CA secret"

cp tls.crt cacerts.pem

kubectl -n "${NAMESPACE}" delete secret tls-ca \
  --ignore-not-found=true

kubectl -n "${NAMESPACE}" create secret generic tls-ca \
  --from-file=cacerts.pem

########################################
# Add Rancher Helm repo
########################################

log "Adding Rancher Helm repository"

"${HELM}" repo add rancher-stable \
  https://releases.rancher.com/server-charts/stable

"${HELM}" repo update

########################################
# Render Rancher manifests
########################################

log "Rendering Rancher manifests"

"${HELM}" template rancher rancher-stable/rancher \
  --namespace "${NAMESPACE}" \
  --version "${RANCHER_VERSION}" \
  --kube-version "${KUBE_VERSION_OVERRIDE}" \
  --set hostname="${HOSTNAME}" \
  --set replicas=1 \
  --set ingress.ingressClassName="${INGRESS_CLASS}" \
  --set ingress.tls.source=secret \
  --set privateCA=true \
  --set certmanager.version="" \
  > rancher.yaml

########################################
# Apply manifests
########################################

log "Deploying Rancher"

kubectl -n "${NAMESPACE}" apply -f rancher.yaml

########################################
# Status
########################################

log "Deployment status"

kubectl get pods -n "${NAMESPACE}"
kubectl get ingress -n "${NAMESPACE}"
kubectl get svc -n "${NAMESPACE}"

echo
echo "[+] Rancher deployment complete"
echo
echo "Hostname: https://${HOSTNAME}"
echo
echo "Cloudflare Tunnel should point to your ingress controller."
echo
echo "Example cloudflared config:"
echo
cat <<EOF
tunnel: rancher
credentials-file: /etc/cloudflared/creds.json

ingress:
  - hostname: ${HOSTNAME}
    service: https://YOUR_INGRESS_IP
    originRequest:
      noTLSVerify: true

  - service: http_status:404
EOF