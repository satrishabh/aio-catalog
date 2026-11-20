#!/usr/bin/env bash
# Secrets for the superset connector. Any cloud; needs kubectl and openssl. Run it once, before Enable.
# Re-runnable: existing secrets are never replaced (a new SUPERSET_SECRET_KEY would make the stored passwords of
# every database connection unreadable).
#
#   superset/superset-secrets  SUPERSET_SECRET_KEY, SUPERSET_ADMIN_PASSWORD (UI user "admin")
#   superset/superset-oidc     only with OIDC_CLIENT_SECRET set: Keycloak client secret for a site overlay
#
# Keycloak login (site overlay, e.g. sarvaikam): after sso/keycloak/import.sh, copy the client secret of aio-superset
# from Keycloak and run:
#   OIDC_CLIENT_SECRET='<secret>' bash setup/superset-secrets.sh
# Members of client role aio-admin (client aio-superset) become Superset Admins, aio-business Gamma users.
set -euo pipefail
NS=superset
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null
exists() { kubectl -n "$NS" get secret "$1" >/dev/null 2>&1; }

if exists superset-secrets; then
  echo "superset-secrets exists: kept"
else
  openssl rand -base64 42 | tr -d '\n' > "$tmp/SUPERSET_SECRET_KEY"
  openssl rand -hex 16 | tr -d '\n' > "$tmp/SUPERSET_ADMIN_PASSWORD"
  kubectl -n "$NS" create secret generic superset-secrets \
    --from-file=SUPERSET_SECRET_KEY="$tmp/SUPERSET_SECRET_KEY" \
    --from-file=SUPERSET_ADMIN_PASSWORD="$tmp/SUPERSET_ADMIN_PASSWORD" >/dev/null
  echo "superset-secrets created"
fi

if [ -n "${OIDC_CLIENT_SECRET:-}" ]; then
  printf '%s' "$OIDC_CLIENT_SECRET" > "$tmp/OIDC_CLIENT_SECRET"
  kubectl -n "$NS" create secret generic superset-oidc --from-file=OIDC_CLIENT_SECRET="$tmp/OIDC_CLIENT_SECRET" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "superset-oidc written (restart Superset if it is running: kubectl -n $NS rollout restart deploy/superset)"
fi

echo
echo "Admin login (user admin): kubectl -n $NS get secret superset-secrets -o jsonpath='{.data.SUPERSET_ADMIN_PASSWORD}' | base64 -d"
