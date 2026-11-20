#!/usr/bin/env bash
# Secrets for the appsmith connector. Any cloud; needs kubectl and openssl. Run it once, before Enable.
# Re-runnable: an existing secret is never replaced (new encryption values would make every datasource credential
# stored in Appsmith unreadable).
#
#   appsmith/appsmith-secrets  APPSMITH_ENCRYPTION_PASSWORD, APPSMITH_ENCRYPTION_SALT (see values/appsmith/values.yaml)
#
# Keep a copy of both values with your backups: an Appsmith backup (appsmithctl backup) cannot be restored without them.
set -euo pipefail
NS=appsmith
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null

if kubectl -n "$NS" get secret appsmith-secrets >/dev/null 2>&1; then
  echo "appsmith-secrets exists: kept"
else
  openssl rand -hex 32 | tr -d '\n' > "$tmp/APPSMITH_ENCRYPTION_PASSWORD"
  openssl rand -hex 32 | tr -d '\n' > "$tmp/APPSMITH_ENCRYPTION_SALT"
  kubectl -n "$NS" create secret generic appsmith-secrets \
    --from-file=APPSMITH_ENCRYPTION_PASSWORD="$tmp/APPSMITH_ENCRYPTION_PASSWORD" \
    --from-file=APPSMITH_ENCRYPTION_SALT="$tmp/APPSMITH_ENCRYPTION_SALT" >/dev/null
  echo "appsmith-secrets created"
fi

echo
echo "Appsmith has no preset admin password: the first account created on the sign-up page becomes the administrator."
echo "Encryption values (for backups): kubectl -n $NS get secret appsmith-secrets -o jsonpath='{.data.APPSMITH_ENCRYPTION_PASSWORD}' | base64 -d"
