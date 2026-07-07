# Monitoring Stack

This directory contains the deployment files for Grafana and Loki monitoring stack.

## Components

1. **Namespace**: `monitoring`
2. **Loki**: Log aggregation system
3. **Grafana**: Visualization dashboard
4. **Promtail**: Log collection agent (DaemonSet)

## Deployment Order

To deploy this monitoring stack, apply the files in this order:

```bash
kubectl apply -f namespace.yaml
kubectl apply -f loki-deployment.yaml
kubectl apply -f grafana-deployment.yaml
kubectl apply -f promtail-configmap.yaml
kubectl apply -f promtail-service-account.yaml
kubectl apply -f promtail-daemonset.yaml
kubectl apply -f grafana-ingress.yaml
```

## Configuration

All deployments are configured to run at most one replica with revision history limited to 2:
- **Loki**: 1 replica (Deployment) with revisionHistoryLimit: 2
- **Grafana**: 1 replica (Deployment) with revisionHistoryLimit: 2
- **Promtail**: 1 daemon set per node (DaemonSet)

## Ingress

The Grafana dashboard will be accessible via the existing ingress controller at:
- Host: `grafana.example.com`
- Path: `/`

Make sure to update the host in `grafana-ingress.yaml` with your actual domain.

## OpenTelemetry Integration

This monitoring stack can be easily connected to OpenTelemetry (OTEL) for application observability:

1. **Loki as Log Store**: Loki can be used as a log store for OTEL collector
2. **Grafana Dashboard**: Visualize metrics and logs from your applications
3. **Promtail**: Collects logs from pods and sends them to Loki

To integrate with OTEL, you would typically:
- Configure your applications to send metrics and traces to an OTEL collector
- Use the OTEL collector to forward logs to Loki
- Create dashboards in Grafana for monitoring your applications