#!/bin/bash

echo "Cleaning up monitoring stack..."

# Delete ingress first
echo "Deleting Grafana ingress..."
kubectl delete ingress grafana -n monitoring || true

# Delete deployments
echo "Deleting Grafana deployment..."
kubectl delete deployment grafana -n monitoring || true

echo "Deleting Loki deployment..."
kubectl delete deployment loki -n monitoring || true

# Delete services
echo "Deleting services..."
kubectl delete service grafana -n monitoring || true
kubectl delete service loki -n monitoring || true

# Delete DaemonSet
echo "Deleting Promtail DaemonSet..."
kubectl delete daemonset promtail -n monitoring || true

# Delete ConfigMap
echo "Deleting Promtail ConfigMap..."
kubectl delete configmap promtail-config -n monitoring || true

# Delete ServiceAccount
echo "Deleting Promtail ServiceAccount..."
kubectl delete serviceaccount promtail -n monitoring || true

# Delete namespace
echo "Deleting namespace..."
kubectl delete namespace monitoring || true

echo "Monitoring stack cleanup completed!"