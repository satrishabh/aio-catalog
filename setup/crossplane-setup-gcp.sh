#!/usr/bin/env bash
# GCP provider for the crossplane connector on GKE (GKE Workload Identity, no key file). Re-runnable.
#   1. creates the Google service account aio-crossplane and grants it, on the project, exactly the roles in
#      GCP_ROLES (required; e.g. GCP_ROLES="roles/storage.admin roles/cloudsql.admin"; GCP_ROLES=none grants
#      nothing). No other role is granted; nothing is granted on the organization or folders.
#   2. lets only the Kubernetes service account crossplane-system/provider-gcp act as it
#      (roles/iam.workloadIdentityUser on that one Google service account)
#   3. once the connector is enabled (Crossplane's CRDs exist): a DeploymentRuntimeConfig "aio-gcp" that runs the
#      provider pods as that Kubernetes service account, the provider family
#      xpkg.crossplane.io/crossplane-contrib/provider-family-gcp (pinned) and the resource providers in PROVIDERS
#      (e.g. PROVIDERS="storage sql"; each is a pod of its own, ~256Mi)
#   4. the ClusterProviderConfig (namespaced API, *.gcp.m.upbound.io) and ProviderConfig (cluster API,
#      *.gcp.upbound.io) "default", both InjectedIdentity on project PROJECT_ID
# Run it after enabling Crossplane on the Connectors page (before that it stops after step 2).
# The cluster needs Workload Identity (GKE_METADATA on the node pools; always on in Autopilot).
# Not done here: enabling the APIs of the services you create (e.g. gcloud services enable sqladmin.googleapis.com).
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
PROVIDERS="${PROVIDERS:-}"             # resource providers to add, e.g. "storage sql"
VERSION=v3.1.0                         # crossplane-contrib/provider-upjet-gcp, released 2026-10-08
REGISTRY=xpkg.crossplane.io/crossplane-contrib
NAMESPACE=crossplane-system
KSA=provider-gcp
GSA_NAME=aio-crossplane
[ -n "$PROJECT_ID" ] || { echo "Set PROJECT_ID" >&2; exit 1; }
[ -n "${GCP_ROLES:-}" ] || {
  echo "Set GCP_ROLES to the project roles Crossplane may use, e.g. GCP_ROLES=\"roles/storage.admin\"" >&2
  echo "(or GCP_ROLES=none to grant nothing now)." >&2
  exit 1
}
GSA="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "==> APIs: IAM, IAM Service Account Credentials"
gcloud services enable iam.googleapis.com iamcredentials.googleapis.com --project "$PROJECT_ID" >/dev/null

echo "==> Google service account $GSA"
gcloud iam service-accounts describe "$GSA" --project "$PROJECT_ID" >/dev/null 2>&1 ||
  gcloud iam service-accounts create "$GSA_NAME" --project "$PROJECT_ID" \
    --display-name "AIO Crossplane provider (GKE Workload Identity)" >/dev/null
if [ "$GCP_ROLES" != none ]; then
  for role in $GCP_ROLES; do
    echo "    project role $role"
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member "serviceAccount:$GSA" --role "$role" \
      --condition=None >/dev/null
  done
fi
gcloud iam service-accounts add-iam-policy-binding "$GSA" --project "$PROJECT_ID" \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${KSA}]" >/dev/null

if ! kubectl get crd providers.pkg.crossplane.io deploymentruntimeconfigs.pkg.crossplane.io >/dev/null 2>&1; then
  echo "Crossplane is not enabled yet: enable it on the Connectors page, then run this script again."
  exit 0
fi

echo "==> provider runtime aio-gcp (service account $NAMESPACE/$KSA -> $GSA)"
kubectl apply -f - >/dev/null <<YAML
apiVersion: pkg.crossplane.io/v1beta1
kind: DeploymentRuntimeConfig
metadata:
  name: aio-gcp
spec:
  serviceAccountTemplate:
    metadata:
      name: $KSA
      annotations:
        iam.gke.io/gcp-service-account: "$GSA"
  deploymentTemplate:
    spec:
      selector: {}
      template:
        spec:
          containers:
            - name: package-runtime
              resources:
                requests: { cpu: 50m, memory: 256Mi }
                limits: { memory: 1Gi }
YAML

echo "==> providers: family${PROVIDERS:+ + $PROVIDERS} ($VERSION)"
for p in family $PROVIDERS; do
  name=provider-gcp-$p; [ "$p" = family ] && name=provider-family-gcp
  kubectl apply -f - >/dev/null <<YAML
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: $name
spec:
  package: $REGISTRY/$name:$VERSION
  runtimeConfigRef:
    name: aio-gcp
YAML
done
kubectl wait provider.pkg.crossplane.io/provider-family-gcp --for=condition=Healthy --timeout=10m >/dev/null
kubectl wait crd/clusterproviderconfigs.gcp.m.upbound.io crd/providerconfigs.gcp.upbound.io \
  --for=condition=Established --timeout=2m >/dev/null

echo "==> ClusterProviderConfig and ProviderConfig default (InjectedIdentity, project $PROJECT_ID)"
for api in gcp.m.upbound.io/v1beta1:ClusterProviderConfig gcp.upbound.io/v1beta1:ProviderConfig; do
  kubectl apply -f - >/dev/null <<YAML
apiVersion: ${api%%:*}
kind: ${api##*:}
metadata:
  name: default
spec:
  projectID: "$PROJECT_ID"
  credentials:
    source: InjectedIdentity
YAML
done
echo "Done. Check: kubectl get providers (INSTALLED/HEALTHY True). The provider can do what GCP_ROLES allow:"
echo "${GCP_ROLES}"
