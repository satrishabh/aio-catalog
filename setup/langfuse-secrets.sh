#!/usr/bin/env bash
# Secrets for the langfuse connector. Any cloud; needs kubectl, openssl and python3. Run it once, before Enable.
# Re-runnable: existing secrets are never replaced (a new SALT or ENCRYPTION_KEY would make stored API keys and
# encrypted settings unreadable; new store passwords would lock Langfuse out of its own data).
#
#   langfuse/langfuse-secrets     salt, encryption-key, nextauth-secret, admin-email, admin-password,
#                                 project-public-key, project-secret-key (API keys of project "AIO")
#   langfuse/langfuse-clickhouse  password (ClickHouse user langfuse)
#   langfuse/langfuse-redis-auth  default (Valkey password of user default)
#   langfuse/langfuse-s3-auth     accessKey, secretKey, seaweedfs_s3_config (SeaweedFS S3 identity)
#   langfuse/langfuse-oidc        only with OIDC_CLIENT_SECRET set: Keycloak client secret for a site overlay
# The PostgreSQL password (Secret langfuse-db-app) is created by CloudNativePG.
#
# LANGFUSE_ADMIN_EMAIL (default admin@langfuse.local) is the e-mail of the admin user created at first start.
# With Keycloak login, set it to the admin's e-mail in Keycloak: that login is then linked to this admin.
#
# Keycloak login (site overlay, e.g. sarvaikam): after sso/keycloak/import.sh, copy the client secret of aio-langfuse
# from Keycloak and run:
#   LANGFUSE_ADMIN_EMAIL=<admin e-mail> OIDC_CLIENT_SECRET='<secret>' bash setup/langfuse-secrets.sh
set -euo pipefail
NS=langfuse
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null
exists() { kubectl -n "$NS" get secret "$1" >/dev/null 2>&1; }
rand() { openssl rand -hex "$1"; }

if exists langfuse-secrets; then
  echo "langfuse-secrets exists: kept"
else
  printf '%s' "$(rand 32)" > "$tmp/salt"
  printf '%s' "$(rand 32)" > "$tmp/encryption-key"          # 64 hex characters, as Langfuse requires
  printf '%s' "$(rand 32)" > "$tmp/nextauth-secret"
  printf '%s' "${LANGFUSE_ADMIN_EMAIL:-admin@langfuse.local}" > "$tmp/admin-email"
  printf '%s' "$(rand 16)Aa1#" > "$tmp/admin-password"   # letters, digit and a symbol
  printf 'pk-lf-%s' "$(rand 16)" > "$tmp/project-public-key"
  printf 'sk-lf-%s' "$(rand 16)" > "$tmp/project-secret-key"
  kubectl -n "$NS" create secret generic langfuse-secrets \
    $(for k in salt encryption-key nextauth-secret admin-email admin-password project-public-key project-secret-key; do
        printf -- '--from-file=%s=%s ' "$k" "$tmp/$k"; done) >/dev/null
  echo "langfuse-secrets created"
fi

if exists langfuse-clickhouse; then
  echo "langfuse-clickhouse exists: kept"
else
  printf '%s' "$(rand 24)" > "$tmp/ch"
  kubectl -n "$NS" create secret generic langfuse-clickhouse --from-file=password="$tmp/ch" >/dev/null
  echo "langfuse-clickhouse created"
fi

if exists langfuse-redis-auth; then
  echo "langfuse-redis-auth exists: kept"
else
  printf '%s' "$(rand 24)" > "$tmp/redis"
  kubectl -n "$NS" create secret generic langfuse-redis-auth --from-file=default="$tmp/redis" >/dev/null
  echo "langfuse-redis-auth created"
fi

if exists langfuse-s3-auth; then
  echo "langfuse-s3-auth exists: kept"
else
  printf '%s' langfuse > "$tmp/accessKey"
  printf '%s' "$(rand 24)" > "$tmp/secretKey"
  python3 - "$tmp" <<'PY'
import json, os, sys
d = sys.argv[1]
key, secret = (open(os.path.join(d, f)).read() for f in ("accessKey", "secretKey"))
json.dump({"identities": [{"name": key, "credentials": [{"accessKey": key, "secretKey": secret}],
                           "actions": ["Admin", "Read", "Write", "List", "Tagging"]}]},
          open(os.path.join(d, "seaweedfs_s3_config"), "w"))
PY
  kubectl -n "$NS" create secret generic langfuse-s3-auth \
    --from-file=accessKey="$tmp/accessKey" --from-file=secretKey="$tmp/secretKey" \
    --from-file=seaweedfs_s3_config="$tmp/seaweedfs_s3_config" >/dev/null
  echo "langfuse-s3-auth created"
fi

if [ -n "${OIDC_CLIENT_SECRET:-}" ]; then
  printf '%s' "$OIDC_CLIENT_SECRET" > "$tmp/oidc"
  kubectl -n "$NS" create secret generic langfuse-oidc --from-file=client-secret="$tmp/oidc" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "langfuse-oidc written (restart Langfuse web if it is running: kubectl -n $NS rollout restart deploy/langfuse-web)"
fi

echo
echo "Admin login (no site overlay): kubectl -n $NS port-forward svc/langfuse-web 3000:3000, then http://localhost:3000"
echo "  e-mail:   kubectl -n $NS get secret langfuse-secrets -o jsonpath='{.data.admin-email}' | base64 -d"
echo "  password: kubectl -n $NS get secret langfuse-secrets -o jsonpath='{.data.admin-password}' | base64 -d"
echo "Project AIO API keys: keys project-public-key / project-secret-key of the same Secret."
