#!/usr/bin/env bash
# Admin password for one app's OpenSearch cluster (opensearch connector = the OpenSearch operator).
# Any cloud; needs kubectl and openssl. Run it once per cluster, before applying the OpenSearchCluster manifest
# (example in values/opensearch/values.yaml). Re-runnable: an existing secret is never replaced.
#
#   bash setup/opensearch-cluster-secrets.sh <namespace> <cluster name>
#   -> <namespace>/<cluster>-admin-credentials  username admin, password random (meets the security plugin policy:
#      upper, lower, digit, special character)
#
# Reference it as spec.security.config.adminCredentialsSecret.name. The operator hashes it into the security config
# and passes it as OPENSEARCH_INITIAL_ADMIN_PASSWORD; it uses these credentials for its own API calls.
# To change it later, update the Secret: the operator updates the admin user's hash.
set -euo pipefail
NS=${1:?usage: $0 <namespace> <cluster name>}
CLUSTER=${2:?usage: $0 <namespace> <cluster name>}
SECRET=$CLUSTER-admin-credentials
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null

if kubectl -n "$NS" get secret "$SECRET" >/dev/null 2>&1; then
  echo "$SECRET exists: kept"
else
  printf '%s' admin > "$tmp/username"
  printf '%s' "$(openssl rand -base64 30 | tr -dc 'A-Za-z0-9' | head -c 24)-Aa1" > "$tmp/password"
  kubectl -n "$NS" create secret generic "$SECRET" \
    --from-file=username="$tmp/username" --from-file=password="$tmp/password" >/dev/null
  echo "$SECRET created"
fi

echo
echo "Admin login (user admin): kubectl -n $NS get secret $SECRET -o jsonpath='{.data.password}' | base64 -d"
