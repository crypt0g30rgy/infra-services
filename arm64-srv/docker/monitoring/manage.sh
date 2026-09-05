#!/usr/bin/env bash
#
# NOT DEPLOYED as of 2026-09-05: none of these four containers run. The live stack
# is Kubernetes - ../../k8s/monitoring/ (grafana, loki, prometheus in the
# `monitoring` namespace). Do not delete this copy yet: prometheus there is
# 0/1 with a full PVC, so this is currently the only other option.
#
set -e

STACKS=(prometheus node_exporter cadvisor grafana)

case "$1" in
  up)
    echo "Starting monitoring stack..."
    docker network inspect internal >/dev/null 2>&1 || docker network create internal
    for s in "${STACKS[@]}"; do
      echo "▶️  Starting $s..."
      (cd "$s" && docker compose up -d)
    done
    ;;
  down)
    echo "Stopping monitoring stack..."
    for s in "${STACKS[@]}"; do
      echo "⏹️  Stopping $s..."
      (cd "$s" && docker compose down)
    done
    ;;
  restart)
    "$0" down
    "$0" up
    ;;
  logs)
    for s in "${STACKS[@]}"; do
      echo "📜 Logs for $s:"
      (cd "$s" && docker compose logs --tail=20)
    done
    ;;
  *)
    echo "Usage: $0 {up|down|restart|logs}"
    exit 1
    ;;
esac
