#!/bin/bash
set -e

# --------------------------
# Parse optional flags
# --------------------------
DRY_RUN=false
FILTER_VALUE=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            ;;
        --filter)
            FILTER_VALUE="$2"
            shift
            ;;
        *)
            echo "Unknown argument: $1"
            ;;
    esac
    shift
done

# --------------------------
# Get all images from containerd
# If --filter is provided, apply it
# --------------------------
if [[ -n "$FILTER_VALUE" ]]; then
    microk8s ctr images ls name~="${FILTER_VALUE}" -q > /tmp/all_images
else
    microk8s ctr images ls -q > /tmp/all_images
fi

# --------------------------
# Get images currently used by pods
# --------------------------
microk8s kubectl get pods -A \
    -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
    | sort -u > /tmp/used_images

echo "== All images =="
cat /tmp/all_images
echo

echo "== Used images =="
cat /tmp/used_images
echo

# --------------------------
# Remove only unused images
# --------------------------
echo "== Processing images =="
while read -r img; do
    if [[ -z "$img" ]]; then
        continue
    fi

    if grep -Fxq "$img" /tmp/used_images; then
        echo "KEEP   $img (in use)"
    else
        if $DRY_RUN; then
            echo "DRYRUN remove: $img"
        else
            echo "REMOVE $img"
            microk8s ctr images rm "$img"
        fi
    fi
done < /tmp/all_images
