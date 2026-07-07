#!/bin/bash

echo "Deploying monitoring stack..."

# Apply namespace first
echo "Applying namespace..."
kubectl apply -f namespace.yaml

# Wait a moment for the namespace to be created
sleep 2

# Apply Loki deployment
echo "Applying Loki deployment..."
kubectl apply -f loki-deployment.yaml

# Apply Grafana deployment
echo "Applying Grafana deployment..."
kubectl apply -f grafana-deployment.yaml

# Apply Promtail components
echo "Applying Promtail components..."
kubectl apply -f promtail-configmap.yaml
kubectl apply -f promtail-service-account.yaml
kubectl apply -f promtail-daemonset.yaml

# Apply Ingress
echo "Applying Grafana ingress..."
kubectl apply -f grafana-ingress.yaml

echo "Monitoring stack deployment completed!"
echo ""
echo "To access Grafana, use the URL:"
echo "  http://grafana.example.com"
echo ""
echo "Make sure to update the host in grafana-ingress.yaml with your actual domain."