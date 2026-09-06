#!/usr/bin/env bash
#
# Move one microk8s-hostpath PVC to Longhorn under the same claim name, so no workload
# manifest changes. One volume at a time: it refuses to run while anything has the source
# mounted, copies, verifies four digests, then rebinds. The hostpath PV is left Released as
# the rollback - no source data is deleted. Reasoning per step is in ./README.md.
#
#   ./migrate-pvc-to-longhorn.sh -n xboy -c postgres-root-pvc -w deploy/postgres-root
#
set -euo pipefail

NS=""
CLAIM=""
WORKLOAD=""
SRC_NODE="pi-5-16gb-srv-0"   # where every hostpath directory physically is
# Needs GNU find (-printf) and coreutils (chown --reference); busybox/alpine silently
# degrade the verification.
HELPER_IMAGE="debian:stable-slim"
KEEP_JOB=false

usage() {
  cat >&2 <<EOF
usage: $0 -n <namespace> -c <pvc-name> -w <workload> [-N <source-node>] [-k]

  -n  namespace of the PVC and the workload
  -c  PVC to migrate; keeps this exact name afterwards
  -w  workload holding it, as kubectl scale takes it (deploy/x, statefulset/x)
  -N  node the hostpath directory lives on (default: ${SRC_NODE})
  -k  keep the copy Job afterwards instead of deleting it
EOF
  exit 2
}

while getopts ':n:c:w:N:k' opt; do
  case "$opt" in
    n) NS=$OPTARG ;;
    c) CLAIM=$OPTARG ;;
    w) WORKLOAD=$OPTARG ;;
    N) SRC_NODE=$OPTARG ;;
    k) KEEP_JOB=true ;;
    *) usage ;;
  esac
done
[ -n "$NS" ] && [ -n "$CLAIM" ] && [ -n "$WORKLOAD" ] || usage

TMP_CLAIM="${CLAIM}-lh"
JOB="migrate-${CLAIM}"

say() { printf '\n=== %s\n' "$*"; }
kc()  { kubectl -n "$NS" "$@"; }

# ---------------------------------------------------------------- 0. inspect
say "source claim"
SRC_PV=$(kc get pvc "$CLAIM" -o jsonpath='{.spec.volumeName}')
SIZE=$(kc get pvc "$CLAIM" -o jsonpath='{.spec.resources.requests.storage}')
SRC_SC=$(kc get pvc "$CLAIM" -o jsonpath='{.spec.storageClassName}')
printf '%s/%s  %s  sc=%s  pv=%s\n' "$NS" "$CLAIM" "$SIZE" "$SRC_SC" "$SRC_PV"

if [ "$SRC_SC" = "longhorn" ]; then
  echo "already on longhorn - nothing to do" >&2
  exit 0
fi

# A Delete policy here turns the `kubectl delete pvc` in step 6 into data loss.
# README step 0 patches every PV to Retain; verify rather than assume.
POLICY=$(kubectl get pv "$SRC_PV" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')
if [ "$POLICY" != "Retain" ]; then
  echo "REFUSING: source PV $SRC_PV has reclaimPolicy=$POLICY, must be Retain" >&2
  exit 1
fi

# --------------------------------------------------- 1. quiesce the workload
say "scaling $WORKLOAD to 0"
kc scale "$WORKLOAD" --replicas=0

# By claim name, not the workload's selector: scaled to 0 is not the same as the pod being
# gone, and some other pod may hold the claim. A copy taken under any writer verifies clean
# and restores corrupt.
for _ in $(seq 1 60); do
  HOLDERS=$(kc get pods -o json | python3 -c '
import json,sys
c=sys.argv[1]
print(" ".join(p["metadata"]["name"] for p in json.load(sys.stdin)["items"]
      for v in p["spec"].get("volumes",[])
      if v.get("persistentVolumeClaim",{}).get("claimName")==c))' "$CLAIM")
  [ -z "$HOLDERS" ] && break
  echo "waiting for pods to release $CLAIM: $HOLDERS"
  sleep 5
done
if [ -n "$HOLDERS" ]; then
  echo "REFUSING: still mounted by: $HOLDERS" >&2
  exit 1
fi
echo "no pod holds $CLAIM"

# ------------------------------------------------- 2. destination claim
say "creating $TMP_CLAIM on longhorn ($SIZE)"
kc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${TMP_CLAIM}
  labels:
    app.kubernetes.io/managed-by: migrate-pvc-to-longhorn
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources:
    requests:
      storage: ${SIZE}
EOF
kc wait --for=jsonpath='{.status.phase}'=Bound "pvc/${TMP_CLAIM}" --timeout=300s

# ------------------------------------------------------------- 3. copy + verify
say "running copy job (pinned to $SRC_NODE)"
kc delete job "$JOB" --ignore-not-found >/dev/null
kc apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      # The hostpath source is a directory on this one machine.
      nodeSelector:
        kubernetes.io/hostname: ${SRC_NODE}
      # Root, so cp -a can actually preserve the uid/gid a database cares about.
      securityContext:
        runAsUser: 0
      containers:
        - name: copy
          image: ${HELPER_IMAGE}
          command: ["/bin/sh", "-eu", "-c"]
          args:
            - |
              # Artefact of a fresh ext4 volume; would count as a difference.
              rm -rf /dst/lost+found

              echo "--- copying"
              cp -a /src/. /dst/
              # cp -a does not touch the destination mount point itself.
              chown --reference=/src /dst 2>/dev/null || chown "\$(stat -c %u:%g /src)" /dst
              chmod "\$(stat -c %a /src)" /dst
              sync

              # Four digests because each alone misses something: contents miss
              # ownership, metadata misses contents, neither sees a retargeted symlink.
              d() {
                cd "\$1"
                COUNT=\$(find . | wc -l)
                META=\$(find . -printf '%p|%y|%U|%G|%m\n' | sort | md5sum | cut -d' ' -f1)
                DATA=\$(find . -type f -print0 | sort -z | xargs -0 -r md5sum | md5sum | cut -d' ' -f1)
                LINK=\$(find . -type l -printf '%p -> %l\n' | sort | md5sum | cut -d' ' -f1)
                echo "\$COUNT \$META \$DATA \$LINK"
              }
              echo "--- verifying"
              S=\$(d /src)
              D=\$(d /dst)
              echo "src: \$S"
              echo "dst: \$D"
              if [ "\$S" != "\$D" ]; then
                echo "MISMATCH - destination does not match source"
                exit 1
              fi
              echo "COPY_VERIFIED_OK"
          volumeMounts:
            - { name: src, mountPath: /src }
            - { name: dst, mountPath: /dst }
      volumes:
        - name: src
          persistentVolumeClaim:
            claimName: ${CLAIM}
        - name: dst
          persistentVolumeClaim:
            claimName: ${TMP_CLAIM}
EOF

# Not `wait --for=condition=complete` alone: that hangs for the full timeout on
# a failed job instead of reporting it.
for _ in $(seq 1 240); do
  C=$(kc get job "$JOB" -o jsonpath='{.status.succeeded}')
  F=$(kc get job "$JOB" -o jsonpath='{.status.failed}')
  [ "${C:-0}" != "0" ] && [ -n "${C:-}" ] && break
  if [ -n "${F:-}" ] && [ "${F:-0}" != "0" ]; then
    kc logs "job/$JOB" --tail=50 || true
    echo "REFUSING: copy job failed - source untouched" >&2
    exit 1
  fi
  sleep 5
done

kc logs "job/$JOB" --tail=20
if ! kc logs "job/$JOB" | grep -q COPY_VERIFIED_OK; then
  echo "REFUSING: COPY_VERIFIED_OK not in job log - source untouched" >&2
  exit 1
fi
say "copy verified"

# ------------------------------------------------------------- 4. rebind
# The new PV keeps the data; both claims are deleted so the original NAME can be
# recreated against it. Both PVs are Retain, so nothing is destroyed here.
LH_PV=$(kc get pvc "$TMP_CLAIM" -o jsonpath='{.spec.volumeName}')
say "rebinding $LH_PV to the original name $CLAIM"

$KEEP_JOB || kc delete job "$JOB"
kc delete pvc "$TMP_CLAIM"
kc delete pvc "$CLAIM"

# Released -> Available. A PV still carrying a claimRef will not accept a new
# claim, even one naming it explicitly.
kubectl patch pv "$LH_PV" --type=json -p '[{"op":"remove","path":"/spec/claimRef"}]'

kc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${CLAIM}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  # Pre-bound by name: this is the volume the data was just copied onto. The
  # field is generated and cluster-specific, so it cannot live in git - which is
  # why the ArgoCD app needs ignoreDifferences on /spec/volumeName plus
  # RespectIgnoreDifferences=true.
  volumeName: ${LH_PV}
  resources:
    requests:
      storage: ${SIZE}
EOF
kc wait --for=jsonpath='{.status.phase}'=Bound "pvc/${CLAIM}" --timeout=300s

# ------------------------------------------------------------- 5. bring it back
say "scaling $WORKLOAD back up"
kc scale "$WORKLOAD" --replicas=1
kc rollout status "$WORKLOAD" --timeout=300s

say "done - verify the APPLICATION, not just the pod"
kc get pvc "$CLAIM" -o custom-columns='NAME:.metadata.name,SC:.spec.storageClassName,STATUS:.status.phase,VOL:.spec.volumeName'
echo "old hostpath PV left as rollback: $SRC_PV ($(kubectl get pv "$SRC_PV" -o jsonpath='{.spec.hostPath.path}'))"
