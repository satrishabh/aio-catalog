#!/usr/bin/env bash
# Secrets for the gitea connector. Any cloud; needs kubectl and openssl. Run it once, before Enable.
# Re-runnable: existing secrets are never replaced (Gitea keeps the first SECRET_KEY in app.ini and needs it to read
# stored credentials; a new JWT secret would sign out every user and break OAuth tokens).
#
#   gitea/gitea-secrets  SECRET_KEY, INTERNAL_TOKEN, JWT_SECRET, LFS_JWT_SECRET (see values/gitea/values.yaml)
#   gitea/gitea-admin    username, password of the local admin (user gitea_admin)
#   gitea/gitea-oidc     only with OIDC_CLIENT_SECRET set: Keycloak client id and secret for a site overlay
#
# Keycloak login (site overlay, e.g. sarvaikam): after sso/keycloak/import.sh, copy the client secret of aio-gitea
# from Keycloak and run:
#   OIDC_CLIENT_SECRET='<secret>' bash setup/gitea-secrets.sh
# Members of client role aio-admin (client aio-gitea) become Gitea admins, aio-business restricted users.
set -euo pipefail
NS=gitea
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null
exists() { kubectl -n "$NS" get secret "$1" >/dev/null 2>&1; }
jwt_secret() { openssl rand 32 | openssl base64 -A | tr '+/' '-_' | tr -d '='; }   # 32 bytes, base64 RawURL

if exists gitea-secrets; then
  echo "gitea-secrets exists: kept"
else
  openssl rand -hex 32 | tr -d '\n' > "$tmp/SECRET_KEY"
  openssl rand -hex 48 | tr -d '\n' > "$tmp/INTERNAL_TOKEN"
  jwt_secret > "$tmp/JWT_SECRET"
  jwt_secret > "$tmp/LFS_JWT_SECRET"
  kubectl -n "$NS" create secret generic gitea-secrets \
    --from-file=SECRET_KEY="$tmp/SECRET_KEY" \
    --from-file=INTERNAL_TOKEN="$tmp/INTERNAL_TOKEN" \
    --from-file=JWT_SECRET="$tmp/JWT_SECRET" \
    --from-file=LFS_JWT_SECRET="$tmp/LFS_JWT_SECRET" >/dev/null
  echo "gitea-secrets created"
fi

if exists gitea-admin; then
  echo "gitea-admin exists: kept"
else
  printf '%s' gitea_admin > "$tmp/username"           # "admin" is a reserved name in Gitea
  printf '%s' "$(openssl rand -hex 12)Aa1" > "$tmp/password"
  kubectl -n "$NS" create secret generic gitea-admin \
    --from-file=username="$tmp/username" --from-file=password="$tmp/password" >/dev/null
  echo "gitea-admin created"
fi

if [ -n "${OIDC_CLIENT_SECRET:-}" ]; then
  printf '%s' "${OIDC_CLIENT_ID:-aio-gitea}" > "$tmp/key"
  printf '%s' "$OIDC_CLIENT_SECRET" > "$tmp/secret"
  kubectl -n "$NS" create secret generic gitea-oidc --from-file=key="$tmp/key" --from-file=secret="$tmp/secret" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "gitea-oidc written (restart Gitea if it is running: kubectl -n $NS rollout restart deploy/gitea)"
fi

echo
echo "Admin login (user gitea_admin): kubectl -n $NS get secret gitea-admin -o jsonpath='{.data.password}' | base64 -d"
