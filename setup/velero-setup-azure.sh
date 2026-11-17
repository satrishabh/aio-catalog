#!/usr/bin/env bash
# Backup storage for the Velero connector on AKS (Microsoft Entra Workload ID, no keys). Re-runnable.
#   1. checks the cluster's OIDC issuer and Workload ID (ENABLE_WORKLOAD_ID=1 turns them on; that is a cluster
#      update, so it is never done silently)
#   2. creates a private storage account (no public blob access, TLS 1.2+, shared-key access disabled) and the
#      container "velero"
#   3. creates the managed identity aio-velero, grants it "Storage Blob Data Contributor" on that account only,
#      and federates it with the Kubernetes service account velero/velero-server
#   4. creates the non-secret "velero-credentials" Secret (subscription, resource group, cloud name)
#   5. once Velero is enabled (its CRDs exist): annotates the service account with the identity's client ID,
#      restarts Velero so the token is injected, and creates the BackupStorageLocation "default"
# Run it before enabling Velero on the Connectors page, then again after enabling. The platform must run with
# CLOUD_PROVIDER=aks so values-aks.yaml (Workload ID pod labels) is applied.
set -euo pipefail

RG="${RG:-creative}"
AKS="${AKS:-creative}"
LOCATION="${LOCATION:-southindia}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
# Storage account names: 3-24 lowercase letters/digits, globally unique
STORAGE_ACCOUNT="${VELERO_STORAGE_ACCOUNT:-aiovelero$(echo -n "$SUBSCRIPTION_ID" | md5sum | cut -c1-8)}"
CONTAINER=velero
IDENTITY=aio-velero
NAMESPACE=velero
KSA=velero-server

echo "==> AKS $AKS ($RG): OIDC issuer and Workload ID"
read -r OIDC_ENABLED WI_ENABLED < <(az aks show -g "$RG" -n "$AKS" \
  --query "[oidcIssuerProfile.enabled, securityProfile.workloadIdentity.enabled]" -o tsv | tr '\n' ' ')
if [ "$OIDC_ENABLED" != "true" ] || [ "$WI_ENABLED" != "true" ]; then
  if [ "${ENABLE_WORKLOAD_ID:-0}" = "1" ]; then
    az aks update -g "$RG" -n "$AKS" --enable-oidc-issuer --enable-workload-identity >/dev/null
  else
    echo "Workload ID is off (oidc=$OIDC_ENABLED, workloadIdentity=$WI_ENABLED). Re-run with ENABLE_WORKLOAD_ID=1" >&2
    echo "to turn it on (an AKS update; running pods are not restarted)." >&2
    exit 1
  fi
fi
ISSUER=$(az aks show -g "$RG" -n "$AKS" --query oidcIssuerProfile.issuerUrl -o tsv)

echo "==> storage account $STORAGE_ACCOUNT / container $CONTAINER"
if ! az storage account show -g "$RG" -n "$STORAGE_ACCOUNT" >/dev/null 2>&1; then
  az storage account create -g "$RG" -n "$STORAGE_ACCOUNT" -l "$LOCATION" --sku Standard_LRS --kind StorageV2 \
    --min-tls-version TLS1_2 --allow-blob-public-access false --allow-shared-key-access false \
    --https-only true >/dev/null
fi
ACCOUNT_ID=$(az storage account show -g "$RG" -n "$STORAGE_ACCOUNT" --query id -o tsv)
az storage container create --account-name "$STORAGE_ACCOUNT" -n "$CONTAINER" --auth-mode login >/dev/null
# Velero deletes expired backups itself (ttl 14 days); this policy only removes leftovers after 30 days
az storage account management-policy create -g "$RG" --account-name "$STORAGE_ACCOUNT" --policy '{
  "rules": [{"enabled": true, "name": "velero-leftovers", "type": "Lifecycle",
    "definition": {"actions": {"baseBlob": {"delete": {"daysAfterModificationGreaterThan": 30}}},
                   "filters": {"blobTypes": ["blockBlob"], "prefixMatch": ["velero/"]}}}]}' >/dev/null

echo "==> managed identity $IDENTITY"
az identity show -g "$RG" -n "$IDENTITY" >/dev/null 2>&1 || az identity create -g "$RG" -n "$IDENTITY" -l "$LOCATION" >/dev/null
CLIENT_ID=$(az identity show -g "$RG" -n "$IDENTITY" --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show -g "$RG" -n "$IDENTITY" --query principalId -o tsv)
az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" --scope "$ACCOUNT_ID" >/dev/null 2>&1 || true
az identity federated-credential show -g "$RG" --identity-name "$IDENTITY" -n velero-server >/dev/null 2>&1 ||
  az identity federated-credential create -g "$RG" --identity-name "$IDENTITY" -n velero-server \
    --issuer "$ISSUER" --subject "system:serviceaccount:${NAMESPACE}:${KSA}" \
    --audiences api://AzureADTokenExchange >/dev/null

echo "==> secret $NAMESPACE/velero-credentials (identifiers only, no keys)"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NAMESPACE" create secret generic velero-credentials --dry-run=client -o yaml \
  --from-literal=cloud="AZURE_SUBSCRIPTION_ID=${SUBSCRIPTION_ID}
AZURE_RESOURCE_GROUP=${RG}
AZURE_CLOUD_NAME=AzurePublicCloud
AZURE_CLIENT_ID=${CLIENT_ID}" | kubectl apply -f - >/dev/null

if ! kubectl get crd backupstoragelocations.velero.io >/dev/null 2>&1; then
  echo "Velero is not enabled yet: enable it on the Connectors page, then run this script again."
  exit 0
fi

echo "==> service account annotation, restart, BackupStorageLocation"
kubectl -n "$NAMESPACE" annotate serviceaccount "$KSA" "azure.workload.identity/client-id=${CLIENT_ID}" --overwrite >/dev/null
kubectl -n "$NAMESPACE" rollout restart deployment/velero daemonset/node-agent >/dev/null
kubectl apply -f - <<YAML
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: default
  namespace: $NAMESPACE
spec:
  provider: velero.io/azure
  default: true
  objectStorage:
    bucket: $CONTAINER
    prefix: aio
  config:
    resourceGroup: $RG
    storageAccount: $STORAGE_ACCOUNT
    subscriptionId: $SUBSCRIPTION_ID
    useAAD: "true"
YAML
echo "Done. Check: kubectl -n $NAMESPACE get backupstoragelocation default (PHASE should become Available)"
