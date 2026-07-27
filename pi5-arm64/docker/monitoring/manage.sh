#!/usr/bin/env bash
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
