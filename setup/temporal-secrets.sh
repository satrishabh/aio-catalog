#!/usr/bin/env bash
# Secrets for the temporal connector. Any cloud; needs kubectl. Re-runnable.
#
# The in-cluster install needs no secret from this script: the database password is Secret temporal-db-app, written
# by CloudNativePG, and Temporal has no admin user (the UI and API have no login of their own).
#
#   temporal/temporal-oidc  only with OIDC_CLIENT_SECRET set: Keycloak client secret for the Web UI login of a site
#                           overlay (key TEMPORAL_AUTH_CLIENT_SECRET). Updated when run again with a new secret.
#
# Keycloak login (site overlay, e.g. sarvaikam): after sso/keycloak/import.sh, copy the client secret of aio-temporal
# from Keycloak and run, before Enable:
#   OIDC_CLIENT_SECRET='<secret>' bash setup/temporal-secrets.sh
# The site ingress is also behind the AIO SSO gate: only users with client role aio-admin of aio-tools-sso get in.
set -euo pipefail
NS=temporal
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null

if [ -n "${OIDC_CLIENT_SECRET:-}" ]; then
  printf '%s' "$OIDC_CLIENT_SECRET" > "$tmp/TEMPORAL_AUTH_CLIENT_SECRET"
  kubectl -n "$NS" create secret generic temporal-oidc \
    --from-file=TEMPORAL_AUTH_CLIENT_SECRET="$tmp/TEMPORAL_AUTH_CLIENT_SECRET" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "temporal-oidc written (restart the UI if it is running: kubectl -n $NS rollout restart deploy/temporal-web)"
else
  echo "OIDC_CLIENT_SECRET not set: nothing to do (only a site overlay with Keycloak login needs temporal-oidc)"
fi

echo
echo "Web UI without a site overlay: kubectl -n $NS port-forward svc/temporal-web 8080:8080 (no login)"
echo "CLI: kubectl -n $NS exec deploy/temporal-admintools -- temporal operator namespace list"
