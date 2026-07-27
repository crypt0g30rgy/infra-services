# Prometheus Component

This directory contains the deployment files for Prometheus, the metrics collection and storage system.

## Files

- `prometheus-configmap.yaml` - Prometheus configuration that includes scraping for:
  - Kubernetes API servers
  - Kubernetes nodes
  - Kubernetes pods
  - Kubernetes ingress controllers
  - NGINX ingress controller metrics (scraped from nginx-ingress.ingress.svc.cluster.local:10254)
- `prometheus-service-account.yaml` - Service account for Prometheus
- `prometheus-deployment.yaml` - Main Prometheus deployment configuration

## Configuration Details

The Prometheus configuration includes:
1. Standard Kubernetes service discovery for API servers, nodes, and pods
2. Ingress controller scraping with custom configuration to target NGINX ingress metrics
3. Specific job configuration for NGINX ingress controller at `nginx-ingress.ingress.svc.cluster.local:10254`