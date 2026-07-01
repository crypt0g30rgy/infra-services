#!/bin/bash
set -euo pipefail

# -----------------------
# Configuration
# -----------------------
REGISTRY_URL="http://local-registry:5000"
KEEP_LATEST=2
MAX_AGE_DAYS=15

now=$(date +%s)

echo "===== REGISTRY CLEANUP LOG ====="

# Get list of repositories
repos=$(curl -s ${REGISTRY_URL}/v2/_catalog | jq -r '.repositories[]')

for repo in $repos; do
    echo "Repository: $repo"

    tags=$(curl -s ${REGISTRY_URL}/v2/${repo}/tags/list | jq -r '.tags[]?' || true)
    if [ -z "$tags" ]; then
        echo "  No tags found."
        continue
    fi

    declare -A tag_info

    # Get digest and age for each tag
    for tag in $tags; do
        # HEAD request to get digest and last-modified
        headers=$(curl -sI -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
            ${REGISTRY_URL}/v2/${repo}/manifests/${tag})

        digest=$(echo "$headers" | awk '/Docker-Content-Digest/ {print $2}' | tr -d '\r')

        last_modified=$(echo "$headers" | awk -F": " '/Last-Modified/ {print $2}' | tr -d '\r')
        if [ -z "$last_modified" ]; then
            age_days="N/A"
            created_ts=0
        else
            created_ts=$(date -d "$last_modified" +%s)
            age_days=$(( (now - created_ts) / 86400 ))
        fi

        tag_info["$tag"]="$created_ts|$digest|$age_days"
    done

    # Sort tags newest first
    sorted_tags=$(for t in "${!tag_info[@]}"; do echo "$t ${tag_info[$t]}"; done | sort -k2 -nr)

    i=0
    while read -r tag data; do
        created_ts=$(echo "$data" | cut -d'|' -f1)
        digest=$(echo "$data" | cut -d'|' -f2)
        age_days=$(echo "$data" | cut -d'|' -f3)

        if [ $i -lt $KEEP_LATEST ]; then
            state="KEEP"
        elif [ "$age_days" != "N/A" ] && [ $age_days -gt $MAX_AGE_DAYS ]; then
            state="DELETE"
            # Uncomment the following line to actually delete
            curl -s -X DELETE ${REGISTRY_URL}/v2/${repo}/manifests/${digest}
        else
            state="KEEP"
        fi

        echo "  Tag: $tag | Age: $age_days days | State: $state"
        i=$((i+1))
    done <<< "$sorted_tags"

done

echo "===== END OF LOG ====="