#!/usr/bin/env bash
# Bring AdGuard Home up from this directory alone on a machine that has never run it,
# shaped after ../monitoring/manage.sh. `up` is safe to run twice: AdGuard owns the live
# AdGuardHome.yaml, so the seed here is only ever a starting point. See README.md.
set -euo pipefail

cd "$(dirname "$0")"

SEED=AdGuardHome.seed.yaml
LIVE=config/AdGuardHome.yaml
MASK='s#^( *password: ).*#\1"$2a$10$REPLACE_WITH_REAL_BCRYPT_HASH_SEE_README"#'

# Read the live config out of the container rather than off disk: AdGuard writes
# it as root mode 600, so `cat config/AdGuardHome.yaml` needs sudo and this does
# not. Masked, so the admin hash never lands in a terminal scrollback or a CI log.
live_config() {
  docker exec adguardhome cat /opt/adguardhome/conf/AdGuardHome.yaml | sed -E "$MASK"
}

case "${1:-}" in
  up)
    if [[ ! -f .env ]]; then
      echo "✋ .env is missing (it is gitignored). Create it with:"
      echo "     ADGUARD_INTERNAL_HOST=adguard.internal.xboy.me"
      echo "   traefik's router rule is built from it; compose will otherwise"
      echo "   substitute an empty Host() and traefik will reject the router."
      exit 1
    fi

    docker network inspect internal >/dev/null 2>&1 || docker network create internal

    mkdir -p config work
    if [[ -f "$LIVE" ]]; then
      echo "ℹ️  $LIVE exists — leaving it alone. \`$0 diff\` compares it to the seed."
    else
      echo "🌱 No live config; seeding from $SEED"
      install -m 600 "$SEED" "$LIVE"
      echo "   The admin password hash in it is a placeholder, so the web UI on"
      echo "   :3000 will refuse every login until you paste the real hash in or"
      echo "   delete the \`users:\` block to get the setup wizard. DNS works now."
    fi

    docker compose up -d
    echo
    echo "🔎 Checking it answers on the LAN address the cluster forwards to:"
    # Not `dig version.bind`: blocked_hosts drops that by design and it looks
    # like a dead server. Any real name will do.
    docker run --rm --network host alpine:3.23 \
      sh -c 'apk add -q bind-tools && dig +short +time=3 +tries=1 @192.168.0.59 example.com' \
      || echo "⚠️  no answer from 192.168.0.59:53 — check \`$0 logs\`"
    ;;

  down)
    docker compose down
    echo "State kept: ./config (the configuration) and ./work (query log, stats,"
    echo "filter lists). \`$0 up\` resumes exactly where this left off."
    ;;

  restart)
    "$0" down
    "$0" up
    ;;

  logs)
    docker compose logs --tail="${2:-50}" -f
    ;;

  diff)
    # One-way by design: the seed carries the comments and AdGuard strips them whenever it
    # rewrites the live file. Empty output means the two agree on every value that matters.
    diff <(sed -E "$MASK" "$SEED") <(live_config) && echo "✅ live config matches the seed"
    ;;

  pull)
    # Prints the live config, masked. Port real changes into the seed by hand so
    # the comments survive — do not just redirect this over the seed.
    live_config
    ;;

  *)
    echo "Usage: $0 {up|down|restart|logs [n]|diff|pull}"
    exit 1
    ;;
esac
