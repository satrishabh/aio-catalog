#!/usr/bin/env bash
# Azure provider for the crossplane connector on AKS (Microsoft Entra Workload ID, no keys). Re-runnable.
#   1. checks the cluster's OIDC issuer and Workload ID (ENABLE_WORKLOAD_ID=1 turns them on; a cluster update)
#   2. creates the resource group XP_RG (default aio-crossplane): the only place Crossplane may create or change
#      Azure resources
#   3. creates the managed identity aio-crossplane with role XP_ROLE (default Contributor) on XP_RG only (no
#      subscription-wide role, no right to grant roles), federated with the Kubernetes service account
#      crossplane-system/provider-azure
#   4. once the connector is enabled (Crossplane's CRDs exist): a DeploymentRuntimeConfig "aio-azure" that runs the
#      provider pods as that service account with the Workload ID label, the provider family
#      xpkg.crossplane.io/crossplane-contrib/provider-family-azure (pinned) and the resource providers in PROVIDERS
#      (e.g. PROVIDERS="storage dbforpostgresql"; each is a pod of its own, ~256Mi)
#   5. the ClusterProviderConfig (namespaced API, *.azure.m.upbound.io) and ProviderConfig (cluster API,
#      *.azure.upbound.io) "default", both OIDCTokenFile with the identity above
# Run it after enabling Crossplane on the Connectors page (before that it stops after step 3).
# Not done here: registering Azure resource providers on the subscription (the provider skips registration), e.g.
#   az provider register -n Microsoft.DBforPostgreSQL   (needs subscription rights; once per subscription)
set -euo pipefail

RG="${RG:-creative}"                   # resource group of the AKS cluster (the identity lives here)
AKS="${AKS:-creative}"
LOCATION="${LOCATION:-southindia}"
XP_RG="${XP_RG:-aio-crossplane}"       # resource group Crossplane manages
XP_ROLE="${XP_ROLE:-Contributor}"      # role on XP_RG only
PROVIDERS="${PROVIDERS:-}"             # resource providers to add, e.g. "storage dbforpostgresql"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
TENANT_ID="$(az account show --query tenantId -o tsv)"
VERSION=v2.8.0                         # crossplane-contrib/provider-upjet-azure, released 2026-10-08
REGISTRY=xpkg.crossplane.io/crossplane-contrib
IDENTITY=aio-crossplane
NAMESPACE=crossplane-system
KSA=provider-azure

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

echo "==> resource group $XP_RG (the only scope Crossplane gets)"
az group show -n "$XP_RG" >/dev/null 2>&1 || az group create -n "$XP_RG" -l "$LOCATION" >/dev/null
SCOPE=$(az group show -n "$XP_RG" --query id -o tsv)

echo "==> managed identity $IDENTITY ($XP_ROLE on $XP_RG)"
az identity show -g "$RG" -n "$IDENTITY" >/dev/null 2>&1 || az identity create -g "$RG" -n "$IDENTITY" -l "$LOCATION" >/dev/null
CLIENT_ID=$(az identity show -g "$RG" -n "$IDENTITY" --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show -g "$RG" -n "$IDENTITY" --query principalId -o tsv)
if [ -z "$(az role assignment list --assignee "$PRINCIPAL_ID" --role "$XP_ROLE" --scope "$SCOPE" --query '[].id' -o tsv)" ]; then
  # a new identity can take a minute to reach Entra ID replicas
  for i in 1 2 3 4 5 6; do
    az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
      --role "$XP_ROLE" --scope "$SCOPE" >/dev/null && break
    [ "$i" = 6 ] && { echo "role assignment failed" >&2; exit 1; }
    sleep 20
  done
fi
az identity federated-credential show -g "$RG" --identity-name "$IDENTITY" -n "$KSA" >/dev/null 2>&1 ||
  az identity federated-credential create -g "$RG" --identity-name "$IDENTITY" -n "$KSA" \
    --issuer "$ISSUER" --subject "system:serviceaccount:${NAMESPACE}:${KSA}" \
    --audiences api://AzureADTokenExchange >/dev/null

if ! kubectl get crd providers.pkg.crossplane.io deploymentruntimeconfigs.pkg.crossplane.io >/dev/null 2>&1; then
  echo "Crossplane is not enabled yet: enable it on the Connectors page, then run this script again."
  exit 0
fi

echo "==> provider runtime aio-azure (service account $NAMESPACE/$KSA, Workload ID)"
kubectl apply -f - >/dev/null <<YAML
apiVersion: pkg.crossplane.io/v1beta1
kind: DeploymentRuntimeConfig
metadata:
  name: aio-azure
spec:
  serviceAccountTemplate:
    metadata:
      name: $KSA
      annotations:
        azure.workload.identity/client-id: "$CLIENT_ID"
        azure.workload.identity/tenant-id: "$TENANT_ID"
  deploymentTemplate:
    spec:
      selector: {}
      template:
        metadata:
          labels:
            azure.workload.identity/use: "true"
        spec:
          containers:
            - name: package-runtime
              resources:
                requests: { cpu: 50m, memory: 256Mi }
                limits: { memory: 1Gi }
YAML

echo "==> providers: family${PROVIDERS:+ + $PROVIDERS} ($VERSION)"
for p in family $PROVIDERS; do
  name=provider-azure-$p; [ "$p" = family ] && name=provider-family-azure
  kubectl apply -f - >/dev/null <<YAML
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: $name
spec:
  package: $REGISTRY/$name:$VERSION
  runtimeConfigRef:
    name: aio-azure
YAML
done
kubectl wait provider.pkg.crossplane.io/provider-family-azure --for=condition=Healthy --timeout=10m >/dev/null
kubectl wait crd/clusterproviderconfigs.azure.m.upbound.io crd/providerconfigs.azure.upbound.io \
  --for=condition=Established --timeout=2m >/dev/null

echo "==> ClusterProviderConfig and ProviderConfig default (OIDCTokenFile, identity $IDENTITY)"
for api in azure.m.upbound.io/v1beta1:ClusterProviderConfig azure.upbound.io/v1beta1:ProviderConfig; do
  kubectl apply -f - >/dev/null <<YAML
apiVersion: ${api%%:*}
kind: ${api##*:}
metadata:
  name: default
spec:
  credentials:
    source: OIDCTokenFile
  clientID: "$CLIENT_ID"
  tenantID: "$TENANT_ID"
  subscriptionID: "$SUBSCRIPTION_ID"
YAML
done
echo "Done. Check: kubectl get providers (INSTALLED/HEALTHY True). Create resources only in resource group $XP_RG"
echo "(spec.forProvider.resourceGroupName: $XP_RG); anything else is denied by Azure."
