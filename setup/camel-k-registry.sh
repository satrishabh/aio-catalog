#!/usr/bin/env bash
# Container registry for the camel-k connector (optional: only needed to build integrations in the cluster; images
# that the AIO pipeline already built run without it). Any cloud; needs kubectl and python3. Run after Enable.
# Re-runnable: existing Secrets are never replaced (delete one first to rotate it).
#
#   camel-k/camel-k-registry      push/pull login for the registry (kubernetes.io/dockerconfigjson)
#   camel-k/camel-k               IntegrationPlatform that points the operator at the registry
#   <ns>/camel-k-registry         pull copy in each namespace of PULL_NAMESPACES (default: dev staging prod);
#                                 Camel K adds it to integration pods as imagePullSecret
#
# The registry must be reachable over HTTPS from the nodes (the kubelet pulls from it), so not a *.svc address.
# With the Harbor connector on a site: create project camel-k and a robot account with push and pull on it, then
#   printf '%s' '<robot secret>' > /dev/shm/robot && chmod 600 /dev/shm/robot
#   REGISTRY_ADDRESS=harbor.tools.sarvaikam.com REGISTRY_USER='robot$camel-k+builder' \
#     REGISTRY_PASSWORD_FILE=/dev/shm/robot bash setup/camel-k-registry.sh && rm /dev/shm/robot
# ACR / Artifact Registry / ECR work the same with a token or service-principal login; images are pushed to
# <REGISTRY_ADDRESS>/<REGISTRY_ORGANIZATION>/kit-<hash>.
set -euo pipefail
NS=camel-k
SECRET=camel-k-registry
: "${REGISTRY_ADDRESS:?set REGISTRY_ADDRESS, e.g. harbor.tools.sarvaikam.com}"
: "${REGISTRY_USER:?set REGISTRY_USER}"
: "${REGISTRY_PASSWORD_FILE:?set REGISTRY_PASSWORD_FILE to a file holding the password or token}"
REGISTRY_ORGANIZATION="${REGISTRY_ORGANIZATION:-camel-k}"
PULL_NAMESPACES="${PULL_NAMESPACES:-dev staging prod}"
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

kubectl get namespace "$NS" >/dev/null 2>&1 || { echo "Enable the camel-k connector first (namespace $NS missing)" >&2; exit 1; }
[ -r "$REGISTRY_PASSWORD_FILE" ] || { echo "cannot read $REGISTRY_PASSWORD_FILE" >&2; exit 1; }

# Docker config JSON built from the password file (never passed on a command line).
REGISTRY_ADDRESS="$REGISTRY_ADDRESS" REGISTRY_USER="$REGISTRY_USER" \
  python3 - "$REGISTRY_PASSWORD_FILE" "$tmp/.dockerconfigjson" <<'PY'
import base64, json, os, sys
pw = open(sys.argv[1]).read().strip()
user = os.environ["REGISTRY_USER"]
auth = base64.b64encode(f"{user}:{pw}".encode()).decode()
json.dump({"auths": {os.environ["REGISTRY_ADDRESS"]: {"username": user, "password": pw, "auth": auth}}},
          open(sys.argv[2], "w"))
PY

put_secret() {  # $1 namespace
  if kubectl -n "$1" get secret "$SECRET" >/dev/null 2>&1; then
    echo "$1/$SECRET exists: kept"
  else
    kubectl -n "$1" create secret generic "$SECRET" --type=kubernetes.io/dockerconfigjson \
      --from-file=.dockerconfigjson="$tmp/.dockerconfigjson" >/dev/null
    echo "$1/$SECRET created"
  fi
}

put_secret "$NS"
for ns in $PULL_NAMESPACES; do
  if kubectl get namespace "$ns" >/dev/null 2>&1; then put_secret "$ns"; else echo "namespace $ns missing: skipped"; fi
done

# Only the registry fields are owned by this script (server-side apply), so re-running never drops other settings.
kubectl apply --server-side --field-manager=aio-camel-k-setup -f - >/dev/null <<EOF
apiVersion: camel.apache.org/v1
kind: IntegrationPlatform
metadata:
  name: camel-k
  namespace: $NS
spec:
  build:
    registry:
      address: $REGISTRY_ADDRESS
      organization: $REGISTRY_ORGANIZATION
      secret: $SECRET
EOF
echo "IntegrationPlatform $NS/camel-k points at $REGISTRY_ADDRESS/$REGISTRY_ORGANIZATION"
echo "Check: kubectl -n $NS get integrationplatform camel-k -o jsonpath='{.status.phase}'   (expect Ready)"
