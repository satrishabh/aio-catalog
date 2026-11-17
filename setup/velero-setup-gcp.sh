#!/usr/bin/env bash
# Backup storage for the Velero connector on GKE. Re-runnable.
#   1. creates a private GCS bucket (uniform access, public access prevented, versioning off, 30-day hard delete)
#   2. lets the velero/velero-server Kubernetes service account use that bucket through Workload Identity
#      (no service-account key is created)
#   3. creates the BackupStorageLocation "default", once the connector is enabled (its CRDs must exist)
# Run it before or after enabling Velero on the Connectors page; run it again after enabling if step 3 was skipped.
# Requires CLOUD_PROVIDER=gke on the platform so values-gke.yaml (no credentials secret) is applied.
# Limitation of direct Workload Identity access: "velero backup logs" / "describe --details" need signed URLs and
# do not work; backups, schedules and restores do. Read logs with kubectl -n velero logs deploy/velero instead.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
LOCATION="${LOCATION:-asia-south1}"
REGION="${LOCATION%-[a-z]}"
BUCKET="${VELERO_BUCKET:-${PROJECT_ID}-aio-velero}"
NAMESPACE=velero
KSA=velero-server

[ -n "$PROJECT_ID" ] || { echo "Set PROJECT_ID" >&2; exit 1; }
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
PRINCIPAL="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/${NAMESPACE}/sa/${KSA}"

echo "==> bucket gs://$BUCKET ($REGION)"
if ! gcloud storage buckets describe "gs://$BUCKET" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://$BUCKET" --project "$PROJECT_ID" --location "$REGION" \
    --uniform-bucket-level-access --public-access-prevention
fi
# Velero deletes expired backups itself (ttl 14 days); this rule only removes leftovers
cat > /tmp/velero-lifecycle.json <<'JSON'
{"rule": [{"action": {"type": "Delete"}, "condition": {"age": 30}}]}
JSON
gcloud storage buckets update "gs://$BUCKET" --lifecycle-file=/tmp/velero-lifecycle.json >/dev/null
rm -f /tmp/velero-lifecycle.json

echo "==> Workload Identity access for $NAMESPACE/$KSA"
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" --member "$PRINCIPAL" \
  --role roles/storage.objectAdmin >/dev/null
# Velero lists buckets' metadata to validate the location
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" --member "$PRINCIPAL" \
  --role roles/storage.legacyBucketReader >/dev/null

echo "==> BackupStorageLocation default"
if kubectl get crd backupstoragelocations.velero.io >/dev/null 2>&1; then
  kubectl apply -f - <<YAML
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: default
  namespace: $NAMESPACE
spec:
  provider: velero.io/gcp
  default: true
  objectStorage:
    bucket: $BUCKET
    prefix: aio
YAML
  echo "Done. Check: kubectl -n $NAMESPACE get backupstoragelocation default (PHASE should become Available)"
else
  echo "Velero is not enabled yet: enable it on the Connectors page, then run this script again for the location."
fi
