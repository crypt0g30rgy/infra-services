# Setting up Prometheus Data Source in Grafana

When importing the NGINX ingress dashboard, you may encounter an error about invalid dashboard schema or missing data sources. This is because the dashboard references a Prometheus data source that needs to be configured.

## Prerequisites

1. Grafana is deployed and accessible
2. Prometheus is deployed and scraping metrics from your cluster (including NGINX ingress controller)
3. You have admin access to Grafana

## Steps to Configure Prometheus Data Source

### Method 1: Using Grafana UI

1. Access Grafana at `http://localhost:3000` (or your configured URL)
2. Login with admin credentials (default: admin/admin)
3. Click on the "Configuration" gear icon in the left sidebar
4. Select "Data Sources"
5. Click "Add data source"
6. Select "Prometheus" from the list
7. In the "URL" field, enter: `http://prometheus.monitoring.svc.cluster.local:9090`
8. Click "Save & Test" - you should see a confirmation message

### Method 2: Using Grafana API (Automation)

```bash
# Get Grafana admin password
GRAFANA_PASSWORD=$(kubectl get secret -n monitoring grafana -o jsonpath="{.data.admin-password}" | base64 --decode)

# Add Prometheus data source using curl
curl -X POST "http://localhost:3000/api/datasources" \
  -H "Content-Type: application/json" \
  -u admin:$GRAFANA_PASSWORD \
  -d '{
    "name": "Prometheus",
    "type": "prometheus",
    "url": "http://prometheus.monitoring.svc.cluster.local:9090",
    "access": "proxy",
    "isDefault": false
  }'
```

## Verification

After adding the data source:

1. Go back to the data sources list in Grafana
2. Find "Prometheus" in the list
3. Click on it and verify that the status shows "OK"
4. The dashboard should now import successfully

## Dashboard Import Instructions

Once Prometheus is configured as a data source, you can import the NGINX ingress dashboard:

1. In Grafana, go to "Dashboards" → "Create" → "Import"
2. Upload the `nginx-ingress-dashboard.json` file
3. Select "Prometheus" as the data source when prompted
4. Click "Import"

## Troubleshooting

If you still encounter issues:

1. **Verify Prometheus is running**: 
   ```bash
   kubectl get pods -n monitoring | grep prometheus
   ```

2. **Check Prometheus service is accessible**:
   ```bash
   kubectl get svc -n monitoring prometheus
   ```

3. **Verify metrics are being collected**:
   ```bash
   # Test if you can query Prometheus directly
   kubectl port-forward -n monitoring svc/prometheus 9090:9090
   # Then visit http://localhost:9090 and try querying "nginx_ingress_controller_requests"
   ```

4. **Check Grafana logs** for more specific error details:
   ```bash
   kubectl logs -n monitoring -l app=grafana
   ```