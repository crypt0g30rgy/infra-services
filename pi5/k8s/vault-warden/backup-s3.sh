#!/usr/bin/env bash
set -euo pipefail
NAMESPACE=vaultwarden
PG_POD="$(kubectl -n $NAMESPACE get pods -l app=postgres -o jsonpath='{.items[0].metadata.name}')"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
FILE="vaultwarden-pg-${TIMESTAMP}.sql.gz"
LOCAL_TMP="/tmp/${FILE}"
S3_BUCKET="s3://my-backup-bucket/vaultwarden/"
kubectl -n "$NAMESPACE" exec -i "$PG_POD" -- pg_dump -U vaultwarden vaultwarden -F c | gzip -c > "$LOCAL_TMP"
aws s3 cp "$LOCAL_TMP" "${S3_BUCKET}${FILE}"
rm -f "$LOCAL_TMP"
