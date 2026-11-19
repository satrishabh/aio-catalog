#!/usr/bin/env bash
# GCP Secret Manager for the external-secrets connector on GKE. Re-runnable.
#   1. enables the Secret Manager API
#   2. lets the operator's Kubernetes service account external-secrets/external-secrets read secrets through
#      Workload Identity (roles/secretmanager.secretAccessor; no service-account key is created)
#   3. once the connector is enabled (its CRDs exist): creates the ClusterSecretStore "gcp-secret-manager"
# Run it before or after enabling External Secrets on the Connectors page; run it again after enabling for step 3.
# The cluster needs Workload Identity (GKE_METADATA on the node pools; always on in Autopilot).
# Access is project-wide by default. Narrower: grant it on named secrets only (SCOPE=secrets SECRETS="a b").
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
NAMESPACE=external-secrets
KSA=external-secrets
[ -n "$PROJECT_ID" ] || { echo "Set PROJECT_ID" >&2; exit 1; }
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
PRINCIPAL="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/${NAMESPACE}/sa/${KSA}"

echo "==> Secret Manager API"
gcloud services enable secretmanager.googleapis.com --project "$PROJECT_ID" >/dev/null

echo "==> read access for $NAMESPACE/$KSA"
if [ "${SCOPE:-project}" = "secrets" ]; then
  for s in ${SECRETS:?set SECRETS to the secret names}; do
    gcloud secrets add-iam-policy-binding "$s" --project "$PROJECT_ID" --member "$PRINCIPAL" \
      --role roles/secretmanager.secretAccessor >/dev/null
  done
else
  gcloud projects add-iam-policy-binding "$PROJECT_ID" --member "$PRINCIPAL" \
    --role roles/secretmanager.secretAccessor --condition=None >/dev/null
fi

if ! kubectl get crd clustersecretstores.external-secrets.io >/dev/null 2>&1; then
  echo "External Secrets is not enabled yet: enable it on the Connectors page, then run this script again."
  exit 0
fi

echo "==> ClusterSecretStore gcp-secret-manager"
kubectl apply -f - <<YAML
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: gcp-secret-manager
spec:
  provider:
    gcpsm:
      projectID: "$PROJECT_ID"
YAML
echo "Done. Check: kubectl get clustersecretstore gcp-secret-manager (STATUS Valid, READY True)"
