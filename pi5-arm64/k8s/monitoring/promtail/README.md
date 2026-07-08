# Promtail Component

This directory contains the deployment files for Promtail, the log collection agent.

## Files

- `promtail-configmap.yaml` - Main Promtail configuration that collects logs from pods
- `promtail-service-account.yaml` - Service account for Promtail
- `promtail-daemonset.yaml` - Promtail DaemonSet configuration that runs on each node

## Configuration Details

The Promtail configuration:
- Collects logs from all pods in the cluster
- Uses Kubernetes service discovery to automatically discover new pods
- Labels logs appropriately for filtering and querying in Loki
- Sends collected logs to Loki via the configured Loki URL