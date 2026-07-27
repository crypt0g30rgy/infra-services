# Monitoring Stack

This directory contains the deployment files for Grafana, Loki, and Prometheus monitoring stack.

## Components

1. **Namespace**: `monitoring`
2. **Loki**: Log aggregation system
3. **Grafana**: Visualization dashboard
4. **Promtail**: Log collection agent (DaemonSet)
5. **Prometheus**: Metrics collection and storage system

## Directory Structure

The monitoring stack is organized into separate folders for each component:

- `loki/` - Loki log aggregation deployment
- `grafana/` - Grafana visualization deployment  
- `promtail/` - Promtail log collection components
- `prometheus/` - Prometheus metrics collection deployment

## Deployment Order

To deploy this monitoring stack, apply the files in this order:

```bash
kubectl apply -f namespace.yaml
kubectl apply -f loki/loki-deployment.yaml
kubectl apply -f grafana/grafana-deployment.yaml
kubectl apply -f promtail/promtail-configmap.yaml
kubectl apply -f promtail/promtail-service-account.yaml
kubectl apply -f promtail/promtail-daemonset.yaml
kubectl apply -f prometheus/prometheus-configmap.yaml
kubectl apply -f prometheus/prometheus-service-account.yaml
kubectl apply -f prometheus/prometheus-deployment.yaml
kubectl apply -f grafana/grafana-ingress.yaml
```

## Configuration

All deployments are configured to run at most one replica with revision history limited to 2:
- **Loki**: 1 replica (Deployment) with revisionHistoryLimit: 2 and imagePullPolicy: IfNotPresent
- **Grafana**: 1 replica (Deployment) with revisionHistoryLimit: 2 and imagePullPolicy: IfNotPresent
- **Promtail**: 1 daemon set per node (DaemonSet) with imagePullPolicy: IfNotPresent
- **Prometheus**: 1 replica (Deployment) with revisionHistoryLimit: 2 and imagePullPolicy: IfNotPresent

## Prometheus Metrics Configuration

The Prometheus deployment is configured to scrape metrics from:
1. Kubernetes API servers, nodes, and pods (standard Kubernetes metrics)
2. NGINX ingress controller metrics at `nginx-ingress.ingress.svc.cluster.local:10254`
   - This configuration allows for comprehensive monitoring of both logs (via Loki) and metrics (via Prometheus)
   - The NGINX ingress controller must be configured to expose metrics on the `/metrics` endpoint at port 10254

## Ingress

The Grafana dashboard will be accessible via the existing ingress controller at:
- Host: `grafana.example.com`
- Path: `/`

Make sure to update the host in `grafana-ingress.yaml` with your actual domain.

## NGINX Ingress Dashboard

A pre-configured Grafana dashboard for monitoring NGINX ingress controller logs is included in this deployment:

1. **Dashboard File**: `nginx-ingress-dashboard.json`
2. **Dashboard UID**: `nginx-ingress-logs`

### How to Import the Dashboard

After deploying the monitoring stack, follow these steps to import the NGINX ingress dashboard:

1. Access Grafana at your configured URL (e.g., `http://grafana.example.com`)
2. Click on the "Create" button in the left sidebar
3. Select "Import" 
4. Upload the `nginx-ingress-dashboard.json` file from this directory
5. Choose the Loki data source when prompted

### Dashboard Features

The NGINX ingress dashboard provides insights into:
- Request volume over time
- Request rate (5-minute average)
- Status code distribution
- Ingress usage patterns
- Namespace distribution
- HTTP method distribution
- Top requested URIs
- Top hosts
- Top status codes
- Country distribution

### Troubleshooting

If you encounter issues importing the dashboard, ensure that:
1. The nginx-ingress-dashboard.json file is properly formatted (no extra characters)
2. Loki data source is correctly configured in Grafana
3. Promtail is successfully collecting logs from your NGINX ingress controller

## OpenTelemetry Integration

This monitoring stack can be easily connected to OpenTelemetry (OTEL) for application observability:

1. **Loki as Log Store**: Loki can be used as a log store for OTEL collector
2. **Grafana Dashboard**: Visualize metrics and logs from your applications
3. **Promtail**: Collects logs from pods and sends them to Loki

To integrate with OTEL, you would typically:
- Configure your applications to send metrics and traces to an OTEL collector
- Use the OTEL collector to forward logs to Loki
- Create dashboards in Grafana for monitoring your applications