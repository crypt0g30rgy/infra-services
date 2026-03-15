#!/usr/bin/env bash
set -euo pipefail
NAMESPACE=vaultwarden
PG_POD="$(kubectl -n $NAMESPACE get pods -l app=postgres -o jsonpath='{.items[0].metadata.name}')"
BACKUP_DIR="./backups"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTFILE="${BACKUP_DIR}/vaultwarden-pg-${TIMESTAMP}.sql.gz"
mkdir -p "$BACKUP_DIR"
kubectl -n "$NAMESPACE" exec -i "$PG_POD" -- pg_dump -U vaultwarden vaultwarden -F c | gzip -c > "$OUTFILE"
