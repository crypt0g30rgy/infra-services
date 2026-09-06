#!/bin/sh
# Give every multibranch job a periodic git scan (cloudbees-folder's PeriodicFolderTrigger;
# the cron is every minute, INTERVAL_MS is the real control). Needed because nothing pushes
# to this Jenkins - the webhooks point at Drone, there is no JCasC, and job config lives only
# in the JENKINS_HOME PVC. Not pollSCM, which registers only after a first build and never
# sees new branches. Idempotent, and it skips any job whose <triggers> holds the unexpected.
# The first scan queues every branch that moved, serialised behind tdiPipeline's global lock.
#
#   kubectl -n jenkins port-forward svc/jenkins 18080:80 &
#   JENKINS_USER=<user> JENKINS_PASS=<password-or-api-token> \
#     [JENKINS_URL=http://127.0.0.1:18080] [INTERVAL_MS=180000] ./set-scan-interval.sh
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
