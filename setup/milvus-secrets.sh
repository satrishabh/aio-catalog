#!/usr/bin/env bash
# Secret for the milvus connector. Any cloud; needs kubectl and openssl. Run it once, before Enable.
# Re-runnable: an existing secret is never replaced.
#
#   milvus/milvus-root  password: the root password Milvus sets at its first start (instead of the default "Milvus")
#
# Milvus reads it only when it creates the root user, i.e. on the first start with an empty disk. To change the
# password later use the SDK (e.g. pymilvus utility.reset_password / MilvusClient.update_password) and then update
# this Secret to match, so the hint below stays right.
set -euo pipefail
NS=milvus
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null

if kubectl -n "$NS" get secret milvus-root >/dev/null 2>&1; then
  echo "milvus-root exists: kept"
else
  printf '%s' "$(openssl rand -hex 16)Aa1" > "$tmp/password"   # Milvus: 6-72 characters
  kubectl -n "$NS" create secret generic milvus-root --from-file=password="$tmp/password" >/dev/null
  echo "milvus-root created"
fi

echo
echo "Root login (user root): kubectl -n $NS get secret milvus-root -o jsonpath='{.data.password}' | base64 -d"
