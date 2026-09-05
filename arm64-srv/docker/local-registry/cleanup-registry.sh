#!/bin/sh
# Retention for the local Docker registry: delete old manifests through the v2
# API, then garbage-collect the blobs they were holding on to.
#
# POSIX sh on purpose (no arrays, no `local`, no pipefail). This runs inside the
# `registry:3.1.1` image, whose shell is busybox ash - that image is used as the
# cleaner precisely because it is the only one that already carries the
# `registry` binary needed for the garbage-collect half of the job. See the
# registry-cleaner service in docker-compose.yml.
#
# Two knobs, and a manifest has to fail BOTH to be deleted:
#
#   KEEP_LATEST   how many of the newest manifests in a repo are never touched
#   MAX_AGE_DAYS  age below which a manifest is never touched
#
# So the default (1 / 7) means "keep the newest one forever, and keep everything
# from the last week". A manifest is deleted only when it is neither. Set
# MAX_AGE_DAYS=0 to collapse a repo to KEEP_LATEST immediately - that is what the
# one-off cleanup on 2026-08-23 used, which took the registry from 430 manifests
# to 33.
#
# Deletion is by DIGEST, which means every tag pointing at that digest goes with
# it. CI pushes both a short and a long git sha, so tag counts are roughly
# double the manifest counts and deleting "one thing" removes two names.
#
# Two protections exist because keep-newest is not the same as keep-what-is-used:
#
#   PROTECT_TAGS      never delete a manifest carrying one of these tags
#                     (default "latest" - a dangling `latest` is worse than a
#                     stale one, and nothing here republishes it)
#   PROTECT_DIGESTS_FILE  a file of digests, one per line, never to be deleted.
#                     Use it for what is actually deployed. This host cannot see
#                     the cluster, so nothing can work that out by itself; the
#                     list is produced with
#                       kubectl get pods -A -o jsonpath='...' | ...
#                     and two of the 24 images running on 2026-08-23 were NOT
#                     the newest in their repo, so this is not hypothetical.
set -eu

REGISTRY_URL="${REGISTRY_URL:-http://local-registry:5000}"
KEEP_LATEST="${KEEP_LATEST:-1}"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-7}"
PROTECT_TAGS="${PROTECT_TAGS:-latest}"
PROTECT_DIGESTS_FILE="${PROTECT_DIGESTS_FILE:-}"
DRY_RUN="${DRY_RUN:-0}"
RUN_GC="${RUN_GC:-1}"
REGISTRY_CONFIG="${REGISTRY_CONFIG:-/etc/docker/registry/config.yml}"
# Loop in-place instead of exiting, for use as a long-running compose sidecar.
LOOP="${LOOP:-0}"
CLEANUP_AT="${CLEANUP_AT:-03:30}"
RUN_ON_START="${RUN_ON_START:-1}"

# The registry is behind htpasswd (see config.yml `auth:`), so anonymous means
# 401 on everything including the catalog. Fail with a useful sentence rather
# than an empty repo list that looks like "nothing to do".
AUTH=""
if [ -n "${REGISTRY_USER:-}" ]; then
  AUTH="-u ${REGISTRY_USER}:${REGISTRY_PASSWORD:-}"
fi

CURL="curl -sS --max-time 120 $AUTH"

ACCEPT="-H Accept:application/vnd.oci.image.index.v1+json \
        -H Accept:application/vnd.docker.distribution.manifest.list.v2+json \
        -H Accept:application/vnd.oci.image.manifest.v1+json \
        -H Accept:application/vnd.docker.distribution.manifest.v2+json"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

# ISO-8601 UTC timestamps sort correctly as plain strings, so ages are compared
# without parsing dates - busybox `date -d` on an RFC3339 string with fractional
# seconds is not something to rely on. Returns true when $1 is at or before the
# cutoff. Fractional seconds make this off by at most one second, which does not
# matter at day granularity.
older_than_cutoff() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort | head -n1)" = "$1" ]
}

# The created date lives in the image config blob, one indirection away, and two
# for a multi-arch index (index -> first child manifest -> config). Prints the
# timestamp, or nothing if any hop fails.
manifest_created() {
  _repo="$1"; _ref="$2"
  _man="$($CURL $ACCEPT "$REGISTRY_URL/v2/$_repo/manifests/$_ref" 2>/dev/null || echo '{}')"
  if [ "$(echo "$_man" | jq -r 'has("manifests")')" = "true" ]; then
    _sub="$(echo "$_man" | jq -r '.manifests[0].digest // empty')"
    [ -n "$_sub" ] || return 0
    _man="$($CURL $ACCEPT "$REGISTRY_URL/v2/$_repo/manifests/$_sub" 2>/dev/null || echo '{}')"
  fi
  _cfg="$(echo "$_man" | jq -r '.config.digest // empty')"
  [ -n "$_cfg" ] || return 0
  $CURL "$REGISTRY_URL/v2/$_repo/blobs/$_cfg" 2>/dev/null | jq -r '.created // empty' || true
}

one_pass() {
  cutoff="$(date -u -d "@$(( $(date -u +%s) - MAX_AGE_DAYS * 86400 ))" +%Y-%m-%dT%H:%M:%SZ)"
  log "policy: keep newest $KEEP_LATEST per repo, keep anything newer than $cutoff" \
      "(${MAX_AGE_DAYS}d), protect tags [$PROTECT_TAGS], dry_run=$DRY_RUN"

  if ! $CURL -o /dev/null -w '' "$REGISTRY_URL/v2/"; then
    log "FATAL: cannot reach $REGISTRY_URL/v2/ - set REGISTRY_USER/REGISTRY_PASSWORD?"
    return 1
  fi

  work="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" EXIT

  deleted=0; kept=0; failed=0
  $CURL "$REGISTRY_URL/v2/_catalog?n=1000" | jq -r '.repositories[]?' | sort > "$work/repos"

  while read -r repo; do
    [ -n "$repo" ] || continue
    tags="$($CURL "$REGISTRY_URL/v2/$repo/tags/list?n=1000" | jq -r '.tags[]? // empty' || true)"
    if [ -z "$tags" ]; then
      # No tags at all: every manifest in here is already untagged, so there is
      # nothing for the API half to do. garbage-collect --delete-untagged is
      # what reclaims these.
      log "$repo: no tags, leaving to garbage-collect"
      continue
    fi

    # One line per DIGEST, not per tag: created<TAB>digest<TAB>space-separated tags
    : > "$work/manifests"
    for tag in $tags; do
      dig="$($CURL -I $ACCEPT "$REGISTRY_URL/v2/$repo/manifests/$tag" 2>/dev/null \
             | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:"{print $2}')"
      [ -n "$dig" ] || continue
      if grep -q "	$dig	" "$work/manifests" 2>/dev/null; then
        # Second tag on a digest already seen - append the name, do not re-fetch.
        awk -v d="$dig" -v t="$tag" -F'\t' 'BEGIN{OFS="\t"}
          $2==d {$3=$3" "t} {print}' "$work/manifests" > "$work/manifests.new"
        mv "$work/manifests.new" "$work/manifests"
        continue
      fi
      created="$(manifest_created "$repo" "$tag")"
      [ -n "$created" ] || created="1970-01-01T00:00:00Z"
      printf '%s\t%s\t%s\n' "$created" "$dig" "$tag" >> "$work/manifests"
    done

    # Newest first. ISO-8601 again: lexicographic order is chronological order.
    sort -r "$work/manifests" > "$work/sorted"

    i=0
    while IFS='	' read -r created dig tags_of_digest; do
      [ -n "$dig" ] || continue
      i=$((i + 1))
      reason=""
      if [ "$i" -le "$KEEP_LATEST" ]; then
        reason="newest $i/$KEEP_LATEST"
      elif ! older_than_cutoff "$created" "$cutoff"; then
        reason="newer than cutoff"
      else
        for pt in $PROTECT_TAGS; do
          for t in $tags_of_digest; do
            [ "$t" = "$pt" ] && reason="protected tag $pt" && break
          done
          [ -n "$reason" ] && break
        done
        if [ -z "$reason" ] && [ -n "$PROTECT_DIGESTS_FILE" ] && [ -f "$PROTECT_DIGESTS_FILE" ]; then
          grep -qxF "$dig" "$PROTECT_DIGESTS_FILE" && reason="protected digest (in use)"
        fi
      fi

      if [ -n "$reason" ]; then
        kept=$((kept + 1))
        log "KEEP   $repo@${dig#sha256:} [$reason] $created ($tags_of_digest)"
        continue
      fi

      if [ "$DRY_RUN" = "1" ]; then
        deleted=$((deleted + 1))
        log "WOULD  $repo@${dig#sha256:} $created ($tags_of_digest)"
        continue
      fi

      code="$($CURL -o /dev/null -w '%{http_code}' -X DELETE \
              "$REGISTRY_URL/v2/$repo/manifests/$dig" || echo 000)"
      case "$code" in
        202|404)  # 404: already gone, e.g. deleted with a sibling tag
          deleted=$((deleted + 1))
          log "DELETE $repo@${dig#sha256:} $created ($tags_of_digest) [$code]" ;;
        405)
          failed=$((failed + 1))
          log "ERROR  $repo@${dig#sha256:} 405 - storage.delete.enabled is not set in config.yml" ;;
        *)
          failed=$((failed + 1))
          log "ERROR  $repo@${dig#sha256:} HTTP $code" ;;
      esac
    done < "$work/sorted"
  done < "$work/repos"

  rm -rf "$work"
  trap - EXIT
  log "manifests: deleted=$deleted kept=$kept failed=$failed"

  # Deleting a manifest only unlinks it. Blobs - which is where the gigabytes
  # are - are only reclaimed here. --delete-untagged also collects the
  # per-platform child manifests orphaned by deleting a multi-arch index, and
  # the repos reported as "no tags" above.
  if [ "$RUN_GC" = "1" ]; then
    if ! command -v registry >/dev/null 2>&1; then
      log "SKIP gc: no registry binary in this image (run the cleaner from registry:3.x)"
    elif [ ! -f "$REGISTRY_CONFIG" ]; then
      log "SKIP gc: $REGISTRY_CONFIG not mounted"
    else
      gc_args="--delete-untagged"
      [ "$DRY_RUN" = "1" ] && gc_args="$gc_args --dry-run"
      log "garbage-collect $gc_args"
      # Note: distribution has no locking around GC. A blob uploaded while this
      # runs can be collected before its manifest is written, so this is
      # scheduled for a quiet hour (CLEANUP_AT) rather than run on every push.
      registry garbage-collect $gc_args "$REGISTRY_CONFIG" 2>&1 | tail -20
    fi
  fi
  log "pass complete"
}

if [ "$LOOP" != "1" ]; then
  one_pass
  exit $?
fi

# Sidecar mode. Sleep to the next CLEANUP_AT (UTC) rather than sleep 86400, so
# the run time does not drift into the middle of the day after a few restarts.
[ "$RUN_ON_START" = "1" ] && { one_pass || log "pass failed, continuing"; }
while :; do
  now="$(date -u +%s)"
  next="$(date -u -d "$(date -u +%Y-%m-%d) $CLEANUP_AT" +%s 2>/dev/null || echo 0)"
  if [ "$next" -le "$now" ]; then next=$((next + 86400)); fi
  log "sleeping $((next - now))s until $(date -u -d "@$next" +%Y-%m-%dT%H:%M:%SZ)"
  sleep $((next - now))
  one_pass || log "pass failed, continuing"
done
