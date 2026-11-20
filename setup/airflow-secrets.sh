#!/usr/bin/env bash
# Secrets for the airflow connector. Any cloud; needs kubectl and openssl. Run it once, before Enable.
# Re-runnable: existing secrets are never replaced (a new fernet key would make every stored connection and
# variable unreadable).
#
#   airflow/airflow-secrets  fernet-key, api-secret-key, webserver-secret-key, jwt-secret, admin-password
#   airflow/airflow-oidc     only with OIDC_CLIENT_SECRET set: Keycloak client secret for a site overlay
#
# Keycloak login (site overlay, e.g. sarvaikam): after sso/keycloak/import.sh, copy the client secret of aio-airflow
# from Keycloak and run:
#   OIDC_CLIENT_SECRET='<secret>' bash setup/airflow-secrets.sh
# Members of client role aio-admin (client aio-airflow) become Airflow Admins, aio-business Viewers.
set -euo pipefail
NS=airflow
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null
exists() { kubectl -n "$NS" get secret "$1" >/dev/null 2>&1; }

if exists airflow-secrets; then
  echo "airflow-secrets exists: kept"
else
  openssl rand -base64 32 | tr '+/' '-_' | tr -d '\n' > "$tmp/fernet-key"   # url-safe base64 of 32 bytes
  openssl rand -hex 32 | tr -d '\n' > "$tmp/api-secret-key"
  openssl rand -hex 32 | tr -d '\n' > "$tmp/webserver-secret-key"
  openssl rand -hex 64 | tr -d '\n' > "$tmp/jwt-secret"
  openssl rand -hex 16 | tr -d '\n' > "$tmp/admin-password"
  kubectl -n "$NS" create secret generic airflow-secrets \
    --from-file=fernet-key="$tmp/fernet-key" \
    --from-file=api-secret-key="$tmp/api-secret-key" \
    --from-file=webserver-secret-key="$tmp/webserver-secret-key" \
    --from-file=jwt-secret="$tmp/jwt-secret" \
    --from-file=admin-password="$tmp/admin-password" >/dev/null
  echo "airflow-secrets created"
fi

if [ -n "${OIDC_CLIENT_SECRET:-}" ]; then
  printf '%s' "$OIDC_CLIENT_SECRET" > "$tmp/client-secret"
  kubectl -n "$NS" create secret generic airflow-oidc --from-file=client-secret="$tmp/client-secret" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "airflow-oidc written (restart the api-server if it is running: kubectl -n $NS rollout restart deploy/airflow-api-server)"
fi

echo
echo "Admin login (user admin): kubectl -n $NS get secret airflow-secrets -o jsonpath='{.data.admin-password}' | base64 -d"
