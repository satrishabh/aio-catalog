#!/usr/bin/env bash
# Secrets for the pulsar connector (JWT token authentication). Any cloud; needs kubectl and openssl.
# Run it once before Enable. Re-runnable: existing secrets are never replaced (a new key pair would invalidate
# every token already handed out).
#
#   pulsar/pulsar-token-asymmetric-key  PRIVATEKEY / PUBLICKEY: RS256 signing key pair (DER, as Pulsar expects);
#                                       the broker mounts only PUBLICKEY
#   pulsar/pulsar-token-admin           TOKEN: super-user token (subject "admin"); the broker uses it for its own
#                                       admin client, operators use it with pulsar-admin
#
# A token for an app (role = APP_ROLE), stored as Secret pulsar-token-<role> (key TOKEN) in the app's namespace:
#   APP_ROLE=shop APP_NAMESPACE=dev bash setup/pulsar-secrets.sh
# Then give the role a tenant (see values/pulsar/values.yaml). Tokens have no expiry; to revoke one, remove the
# role from the tenant / namespace permissions (pulsar-admin namespaces revoke-permission ...).
set -euo pipefail
NS=pulsar
RELEASE=pulsar
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null
exists() { kubectl -n "$1" get secret "$2" >/dev/null 2>&1; }
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# token <subject> <private key (DER, PKCS#8)> > file: an RS256 JWT {"sub": subject}, like `pulsar tokens create`
token() {
  case "$1" in *[!A-Za-z0-9._-]*|'') echo "invalid role name: $1" >&2; exit 1;; esac
  openssl pkey -inform DER -in "$2" -out "$tmp/sign.pem"
  local head body sig
  head=$(printf '%s' '{"alg":"RS256"}' | b64url)
  body=$(printf '{"sub":"%s"}' "$1" | b64url)
  sig=$(printf '%s.%s' "$head" "$body" | openssl dgst -sha256 -sign "$tmp/sign.pem" -binary | b64url)
  printf '%s.%s.%s' "$head" "$body" "$sig"
}

key=$RELEASE-token-asymmetric-key
if exists "$NS" "$key"; then
  echo "$key exists: kept"
else
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tmp/key.pem" 2>/dev/null
  openssl pkcs8 -topk8 -nocrypt -in "$tmp/key.pem" -outform DER -out "$tmp/PRIVATEKEY"
  openssl pkey -in "$tmp/key.pem" -pubout -outform DER -out "$tmp/PUBLICKEY"
  kubectl -n "$NS" create secret generic "$key" \
    --from-file=PRIVATEKEY="$tmp/PRIVATEKEY" --from-file=PUBLICKEY="$tmp/PUBLICKEY" >/dev/null
  echo "$key created"
fi

# The signing key as stored in the cluster (also when it existed before this run)
kubectl -n "$NS" get secret "$key" -o jsonpath='{.data.PRIVATEKEY}' | openssl base64 -d -A > "$tmp/private.der"

if exists "$NS" "$RELEASE-token-admin"; then
  echo "$RELEASE-token-admin exists: kept"
else
  token admin "$tmp/private.der" > "$tmp/TOKEN"
  kubectl -n "$NS" create secret generic "$RELEASE-token-admin" --from-file=TOKEN="$tmp/TOKEN" >/dev/null
  echo "$RELEASE-token-admin created"
fi

if [ -n "${APP_ROLE:-}" ]; then
  : "${APP_NAMESPACE:?set APP_NAMESPACE, the namespace of the app that uses role $APP_ROLE}"
  case "$APP_ROLE" in admin|broker-admin|proxy-admin) echo "APP_ROLE $APP_ROLE is a super-user role" >&2; exit 1;; esac
  kubectl get namespace "$APP_NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$APP_NAMESPACE" >/dev/null
  if exists "$APP_NAMESPACE" "pulsar-token-$APP_ROLE"; then
    echo "$APP_NAMESPACE/pulsar-token-$APP_ROLE exists: kept"
  else
    token "$APP_ROLE" "$tmp/private.der" > "$tmp/APPTOKEN"
    kubectl -n "$APP_NAMESPACE" create secret generic "pulsar-token-$APP_ROLE" --from-file=TOKEN="$tmp/APPTOKEN" >/dev/null
    echo "$APP_NAMESPACE/pulsar-token-$APP_ROLE created (role $APP_ROLE)"
  fi
fi

echo
echo "Admin token: kubectl -n $NS get secret $RELEASE-token-admin -o jsonpath='{.data.TOKEN}' | base64 -d"
