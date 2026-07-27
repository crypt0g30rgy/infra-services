
#!/bin/bash
set -euo pipefail

REGISTRY_URL="http://pi-local-registry:5000"
KEEP_LATEST=2
MAX_AGE_DAYS=30

now=$(date +%s)

repos=$(curl -s ${REGISTRY_URL}/v2/_catalog | jq -r '.repositories[]')

for repo in $repos; do
  tags=$(curl -s ${REGISTRY_URL}/v2/${repo}/tags/list | jq -r '.tags[]?' || true)
  [ -z "$tags" ] && continue

  declare -A meta

  for tag in $tags; do
    headers=$(curl -sI -H "Accept: application/vnd.docker.distribution.manifest.v2+json"       ${REGISTRY_URL}/v2/${repo}/manifests/${tag})

    digest=$(echo "$headers" | awk '/Docker-Content-Digest/ {print $2}' | tr -d '\r')

    created=$(curl -s -H "Accept: application/vnd.docker.distribution.manifest.v2+json"       ${REGISTRY_URL}/v2/${repo}/manifests/${tag}       | jq -r '.config.digest'       | xargs -I {} curl -s ${REGISTRY_URL}/v2/${repo}/blobs/{}       | jq -r '.created')

    ts=$(date -d "$created" +%s)
    meta["$tag"]="$ts|$digest"
  done

  sorted=$(for t in "${!meta[@]}"; do echo "$t ${meta[$t]}"; done | sort -k2 -nr)

  i=0
  while read -r tag data; do
    ts=$(echo "$data" | cut -d'|' -f1)
    digest=$(echo "$data" | cut -d'|' -f2)
    age=$(( (now - ts) / 86400 ))

    if [ $i -lt $KEEP_LATEST ]; then
      :
    elif [ $age -gt $MAX_AGE_DAYS ]; then
      curl -s -X DELETE ${REGISTRY_URL}/v2/${repo}/manifests/${digest}
    fi
    i=$((i+1))
  done <<< "$sorted"
done
