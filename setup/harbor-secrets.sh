#!/usr/bin/env bash
# Secrets for the harbor connector. Any cloud; needs kubectl, openssl and a bcrypt tool (htpasswd from
# apache2-utils/httpd-tools, or python3 with the bcrypt module). Run it once, before Enable. Re-runnable:
# existing secrets are never replaced (a new secretKey would make Harbor's stored credentials unreadable).
#
#   harbor/harbor-secrets  internal secrets, the admin password and the registry login (see values/harbor/values.yaml)
#   harbor/harbor-token    key pair that signs registry tokens (10 years)
#   harbor/harbor-oidc     only with OIDC_CLIENT_SECRET set: Keycloak login settings for a site overlay
#
# Keycloak login (site overlay, e.g. sarvaikam): after sso/keycloak/import.sh, copy the client secret of aio-harbor
# from Keycloak and run:
#   OIDC_CLIENT_SECRET='<secret>' OIDC_ENDPOINT=https://profile.sarvaikam.com/realms/aio bash setup/harbor-secrets.sh
# Members of client role aio-admin (client aio-harbor) become Harbor admins; other users can sign in and see
# only the projects they are added to.
set -euo pipefail
NS=harbor
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null
exists() { kubectl -n "$NS" get secret "$1" >/dev/null 2>&1; }
rand() { openssl rand -hex "$1" | head -c "$2"; }

bcrypt() {  # bcrypt hash of $1, as htpasswd expects
  if command -v htpasswd >/dev/null 2>&1; then
    htpasswd -nbB harbor_registry_user "$1" | cut -d: -f2- | tr -d '\n'
  elif python3 -c 'import bcrypt' >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c 'import bcrypt,sys;print(bcrypt.hashpw(sys.stdin.read().encode(),bcrypt.gensalt(10)).decode(),end="")'
  else
    echo "Need htpasswd (apache2-utils / httpd-tools) or python3 with bcrypt (pip install bcrypt)" >&2
    exit 1
  fi
}

if exists harbor-secrets; then
  echo "harbor-secrets exists: kept"
else
  registry_pw=$(rand 16 32)
  printf '%s' "$(rand 8 16)" > "$tmp/secret"
  printf '%s' "$(rand 16 32)" > "$tmp/CSRF_KEY"
  printf '%s' "$(rand 8 16)" > "$tmp/JOBSERVICE_SECRET"
  printf '%s' "$(rand 8 16)" > "$tmp/REGISTRY_HTTP_SECRET"
  printf '%s' "$(rand 8 16)" > "$tmp/secretKey"                  # exactly 16 characters
  printf '%s' "$(rand 12 24)Aa1" > "$tmp/HARBOR_ADMIN_PASSWORD"   # Harbor wants upper, lower and a digit
  printf '%s' "$registry_pw" > "$tmp/REGISTRY_PASSWD"
  printf 'harbor_registry_user:%s' "$(bcrypt "$registry_pw")" > "$tmp/REGISTRY_HTPASSWD"
  kubectl -n "$NS" create secret generic harbor-secrets \
    $(for k in secret CSRF_KEY JOBSERVICE_SECRET REGISTRY_HTTP_SECRET secretKey HARBOR_ADMIN_PASSWORD REGISTRY_PASSWD REGISTRY_HTPASSWD; do
        printf -- '--from-file=%s=%s ' "$k" "$tmp/$k"; done) >/dev/null
  echo "harbor-secrets created"
fi

if exists harbor-token; then
  echo "harbor-token exists: kept"
else
  openssl req -x509 -newkey rsa:4096 -nodes -days 3650 -subj "/CN=harbor-token-ca" \
    -keyout "$tmp/tls.key" -out "$tmp/tls.crt" >/dev/null 2>&1
  kubectl -n "$NS" create secret tls harbor-token --cert "$tmp/tls.crt" --key "$tmp/tls.key" >/dev/null
  echo "harbor-token created"
fi

if [ -n "${OIDC_CLIENT_SECRET:-}" ]; then
  : "${OIDC_ENDPOINT:?set OIDC_ENDPOINT, e.g. https://profile.sarvaikam.com/realms/aio}"
  OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-aio-harbor}" OIDC_ENDPOINT="$OIDC_ENDPOINT" python3 - "$tmp/config" <<'PY'
import json, os, sys
json.dump({
    "auth_mode": "oidc_auth",
    "primary_auth_mode": True,
    "oidc_name": "AIO",
    "oidc_endpoint": os.environ["OIDC_ENDPOINT"],
    "oidc_client_id": os.environ["OIDC_CLIENT_ID"],
    "oidc_client_secret": os.environ["OIDC_CLIENT_SECRET"],
    "oidc_scope": "openid,profile,email",
    "oidc_verify_cert": True,
    "oidc_auto_onboard": True,
    "oidc_user_claim": "preferred_username",
    "oidc_groups_claim": "groups",
    "oidc_admin_group": "aio-admin",
}, open(sys.argv[1], "w"))
PY
  kubectl -n "$NS" create secret generic harbor-oidc --from-file=config="$tmp/config" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "harbor-oidc written (restart harbor-core if it is running: kubectl -n $NS rollout restart deploy/harbor-core)"
fi

echo
echo "Admin login (user admin): kubectl -n $NS get secret harbor-secrets -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d"
