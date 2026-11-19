#!/usr/bin/env bash
# Azure Key Vault for the external-secrets connector on AKS (Microsoft Entra Workload ID, no keys). Re-runnable.
#   1. checks the cluster's OIDC issuer and Workload ID (ENABLE_WORKLOAD_ID=1 turns them on; a cluster update)
#   2. creates a Key Vault in RBAC mode with purge protection, or uses KEYVAULT_NAME if it already exists
#   3. creates the managed identity aio-external-secrets with "Key Vault Secrets User" (read secrets) on that
#      vault only, federated with the Kubernetes service account external-secrets/aio-keyvault
#   4. creates that service account, annotated with the identity. The operator's own service account gets no
#      Azure access: the store below asks for tokens of aio-keyvault only.
#   5. once the connector is enabled (its CRDs exist): creates the ClusterSecretStore "azure-keyvault"
# Run it before or after enabling External Secrets on the Connectors page; run it again after enabling for step 5.
# Secrets are added to the vault by an admin (az keyvault secret set); nothing secret passes through this script.
set -euo pipefail

RG="${RG:-creative}"
AKS="${AKS:-creative}"
LOCATION="${LOCATION:-southindia}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
TENANT_ID="$(az account show --query tenantId -o tsv)"
# Key Vault names: 3-24 letters, digits and hyphens, globally unique
KEYVAULT="${KEYVAULT_NAME:-aio-kv-$(echo -n "$SUBSCRIPTION_ID" | md5sum | cut -c1-8)}"
IDENTITY=aio-external-secrets
NAMESPACE=external-secrets
KSA=aio-keyvault

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

echo "==> Key Vault $KEYVAULT"
if ! az keyvault show -n "$KEYVAULT" >/dev/null 2>&1; then
  az keyvault create -g "$RG" -n "$KEYVAULT" -l "$LOCATION" --enable-rbac-authorization true \
    --enable-purge-protection true --retention-days 30 >/dev/null
fi
VAULT_ID=$(az keyvault show -n "$KEYVAULT" --query id -o tsv)
VAULT_URL=$(az keyvault show -n "$KEYVAULT" --query properties.vaultUri -o tsv)

echo "==> managed identity $IDENTITY (read-only on $KEYVAULT)"
az identity show -g "$RG" -n "$IDENTITY" >/dev/null 2>&1 || az identity create -g "$RG" -n "$IDENTITY" -l "$LOCATION" >/dev/null
CLIENT_ID=$(az identity show -g "$RG" -n "$IDENTITY" --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show -g "$RG" -n "$IDENTITY" --query principalId -o tsv)
az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" --scope "$VAULT_ID" >/dev/null 2>&1 || true
az identity federated-credential show -g "$RG" --identity-name "$IDENTITY" -n "$KSA" >/dev/null 2>&1 ||
  az identity federated-credential create -g "$RG" --identity-name "$IDENTITY" -n "$KSA" \
    --issuer "$ISSUER" --subject "system:serviceaccount:${NAMESPACE}:${KSA}" \
    --audiences api://AzureADTokenExchange >/dev/null

echo "==> service account $NAMESPACE/$KSA"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $KSA
  namespace: $NAMESPACE
  annotations:
    azure.workload.identity/client-id: "$CLIENT_ID"
    azure.workload.identity/tenant-id: "$TENANT_ID"
YAML

if ! kubectl get crd clustersecretstores.external-secrets.io >/dev/null 2>&1; then
  echo "External Secrets is not enabled yet: enable it on the Connectors page, then run this script again."
  exit 0
fi

echo "==> ClusterSecretStore azure-keyvault"
kubectl apply -f - <<YAML
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: azure-keyvault
spec:
  provider:
    azurekv:
      authType: WorkloadIdentity
      vaultUrl: "$VAULT_URL"
      tenantId: "$TENANT_ID"
      serviceAccountRef:
        name: $KSA
        namespace: $NAMESPACE
YAML
echo "Done. Check: kubectl get clustersecretstore azure-keyvault (STATUS Valid, READY True)"
echo "Add a secret (needs Key Vault Secrets Officer): az keyvault secret set --vault-name $KEYVAULT -n NAME --file FILE"
