# 1. CRDs first
kubectl apply -f https://raw.githubusercontent.com/traefik/traefik/v3.7/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml

# 2. Then your manifest (ConfigMap, RBAC, Deployment, Services, ServiceMonitor)
kubectl apply -f traefik-full.yaml

# 3. Confirm they're registered
kubectl get crd | grep traefik.io