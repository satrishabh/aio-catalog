#!/usr/bin/env bash
# Turns on GKE node auto-provisioning for the node-autoprovisioning connector (Standard clusters; Autopilot
# always has it). Re-runnable. The cluster update needs CONFIRM=1; without it the script only reports.
#   1. checks the cluster: Standard mode, GKE 1.30.3 or later (ComputeClass with node pool auto-creation)
#   2. enables node auto-provisioning with a cluster-wide limit (default 16 vCPU / 64 GiB, MAX_CPU / MAX_MEMORY)
#      and the optimize-utilization autoscaling profile (removes underused nodes sooner)
#   3. new node pools use NAP_SERVICE_ACCOUNT if set (recommended: a least-privileged node service account),
#      otherwise the Compute Engine default service account
# Then enable "Node autoprovisioning" on the Connectors page: it adds the ComputeClass "aio-spot" (values-gke.yaml).
#
# Turn it off again: disable the connector, then DISABLE=1 CONFIRM=1 bash setup/node-autoprovisioning-gke.sh
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
CLUSTER="${CLUSTER:?set CLUSTER to the GKE cluster name}"
LOCATION="${LOCATION:?set LOCATION to the cluster region or zone, e.g. asia-south1}"
MAX_CPU="${MAX_CPU:-16}"
MAX_MEMORY="${MAX_MEMORY:-64}"
CONFIRM="${CONFIRM:-0}"
G=(gcloud container clusters --project "$PROJECT_ID" --location "$LOCATION")

run() {
  if [ "$CONFIRM" = "1" ]; then echo "+ $*"; "$@"; else echo "would run: $*"; fi
}

if [ "${DISABLE:-0}" = "1" ]; then
  if kubectl get computeclasses.cloud.google.com aio-spot >/dev/null 2>&1; then
    echo "ComputeClass aio-spot still exists: disable the connector on the Connectors page first." >&2
    exit 1
  fi
  run "${G[@]}" update "$CLUSTER" --no-enable-autoprovisioning
  exit 0
fi

echo "==> GKE $CLUSTER ($LOCATION, project $PROJECT_ID)"
read -r AUTOPILOT VERSION NAP < <("${G[@]}" describe "$CLUSTER" \
  --format='value(autopilot.enabled, currentMasterVersion, autoscaling.enableNodeAutoprovisioning)' | tr '\t' ' ')
if [ "${AUTOPILOT,,}" = "true" ]; then
  echo "Autopilot cluster: node auto-provisioning is always on. Enable the connector on the Connectors page."
  exit 0
fi
# Compare major.minor.patch of e.g. 1.33.5-gke.1234 with 1.30.3
if [ "$(printf '%s\n' 1.30.3 "${VERSION%%-*}" | sort -V | head -1)" != "1.30.3" ]; then
  echo "GKE $VERSION is too old for ComputeClass node pool auto-creation (needs 1.30.3+). Upgrade first." >&2
  exit 1
fi

ARGS=(--enable-autoprovisioning --min-cpu 0 --max-cpu "$MAX_CPU" --min-memory 0 --max-memory "$MAX_MEMORY"
      --autoscaling-profile optimize-utilization)
[ -n "${NAP_SERVICE_ACCOUNT:-}" ] && ARGS+=(--autoprovisioning-service-account "$NAP_SERVICE_ACCOUNT")
if [ "${NAP,,}" = "true" ]; then
  echo "node auto-provisioning is already on; re-applying the limits (${MAX_CPU} vCPU, ${MAX_MEMORY} GiB)"
fi
run "${G[@]}" update "$CLUSTER" "${ARGS[@]}"

if [ "$CONFIRM" != "1" ]; then
  echo "Nothing changed. Re-run with CONFIRM=1 to apply (a cluster update; running pods are not restarted)."
  exit 0
fi
echo "Done. Enable Node autoprovisioning on the Connectors page, then check: kubectl get computeclasses"
