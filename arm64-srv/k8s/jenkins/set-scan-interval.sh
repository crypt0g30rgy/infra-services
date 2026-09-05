#!/bin/sh
# Give every multibranch job in this Jenkins a periodic git scan.
#
# Why this script exists at all: nothing pushes to Jenkins. The GitHub webhook on
# these repos points at Drone, and this Jenkins has no JCasC - job configuration
# lives only inside the JENKINS_HOME PVC (see deployment.yaml / pvc.yaml here).
# So "merging to main builds the service" is not true by default, and if that PVC
# is ever restored from scratch it stops being true again. Run this to make it
# true, and to keep the setting in git where the rest of this directory lives.
#
# What it sets, per job: cloudbees-folder's PeriodicFolderTrigger, which is the
# "Scan Multibranch Pipeline Triggers -> Periodically if not otherwise run" box.
# The cron spec is every minute and the interval is the real control - Jenkins
# wakes each minute and only scans if `interval` has elapsed since the last scan.
# A scan asks GitHub for each branch head and builds the branches whose head
# moved since their last build, which is the polling the webhook would have
# replaced.
#
# Deliberately NOT `triggers { pollSCM(...) }` in the shared library: that only
# starts working after a job has already built once (the trigger is registered
# when the Jenkinsfile is evaluated), and it never notices a new branch. The
# folder scan needs no prior build and does both.
#
# Usage:
#   kubectl -n jenkins port-forward svc/jenkins 18080:80 &
#   JENKINS_USER=<user> JENKINS_PASS=<password-or-api-token> \
#     [JENKINS_URL=http://127.0.0.1:18080] [INTERVAL_MS=180000] ./set-scan-interval.sh
#
# Idempotent: a job that already has a scan trigger is reported and left alone,
# and so is a job whose <triggers> block contains anything unexpected - this
# rewrites config.xml, so it refuses to guess.
#
# NOTE the size of the first scan. Every branch whose head has moved since its
# last build gets queued at once, and tdiPipeline serialises the fleet behind one
# global lock, so enabling this on 20 stale jobs means a queue that takes hours to
# drain. That is correct behaviour, but do it deliberately.
set -eu

JENKINS_URL="${JENKINS_URL:-http://127.0.0.1:18080}"
INTERVAL_MS="${INTERVAL_MS:-180000}"   # 3 minutes
: "${JENKINS_USER:?set JENKINS_USER}"
: "${JENKINS_PASS:?set JENKINS_PASS (password or API token)}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

AUTH="-u ${JENKINS_USER}:${JENKINS_PASS}"

# -g everywhere: the ?tree= queries use [ ] , which curl otherwise reads as a
# glob range and refuses ("bad range in URL").
CRUMB="$(curl -sSg $AUTH --cookie-jar "$TMP/cj" "$JENKINS_URL/crumbIssuer/api/json" | jq -r .crumb)"
[ -n "$CRUMB" ] && [ "$CRUMB" != "null" ] || { echo "could not get a CSRF crumb - wrong credentials?"; exit 1; }
CURL="curl -sSg $AUTH -b $TMP/cj -H Jenkins-Crumb:$CRUMB"

TRIG="  <triggers>
    <com.cloudbees.hudson.plugins.folder.computed.PeriodicFolderTrigger plugin=\"cloudbees-folder\">
      <spec>* * * * *</spec>
      <interval>${INTERVAL_MS}</interval>
    </com.cloudbees.hudson.plugins.folder.computed.PeriodicFolderTrigger>
  </triggers>"

for j in $(curl -sSg $AUTH "$JENKINS_URL/api/json?tree=jobs[name]" | jq -r '.jobs[].name'); do
  $CURL "$JENKINS_URL/job/$j/config.xml" -o "$TMP/cfg.xml"
  if grep -q 'PeriodicFolderTrigger' "$TMP/cfg.xml"; then
    printf '%-20s already scans, left alone\n' "$j"; continue
  fi
  if ! grep -q '^  <triggers/>$' "$TMP/cfg.xml"; then
    printf '%-20s SKIP: <triggers> is not empty, not rewriting\n' "$j"; continue
  fi
  awk -v t="$TRIG" '{ if ($0=="  <triggers/>") print t; else print }' "$TMP/cfg.xml" > "$TMP/new.xml"
  code="$($CURL -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/xml' \
          --data-binary @"$TMP/new.xml" "$JENKINS_URL/job/$j/config.xml")"
  printf '%-20s POST %s\n' "$j" "$code"
done

echo
echo "Verify (should print ${INTERVAL_MS} for every job):"
echo "  curl -sSg -u <user>:<pass> $JENKINS_URL/job/<job>/config.xml | grep -A3 PeriodicFolderTrigger"
