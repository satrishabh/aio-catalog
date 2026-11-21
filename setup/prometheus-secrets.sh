#!/usr/bin/env bash
# Secrets for the prometheus connector (Prometheus + Grafana). Any cloud; needs kubectl and openssl. Run it once,
# before Enable. Re-runnable: an existing secret is never replaced.
#
#   monitoring/grafana-admin  admin-user, admin-password of Grafana's local admin
#   monitoring/grafana-oidc   only with OIDC_CLIENT_SECRET set: client secret of Keycloak client aio-grafana (site overlay)
#
# Why: without an existing Secret the Grafana chart generates a new admin password on every render. Under Argo CD
# that changes the Deployment's checksum on every sync, so Grafana restarted (and got a new password) each time
# Argo CD woke up (2026-11-21).
#
# Keycloak login (site overlay, e.g. sarvaikam): after sso/keycloak/import.sh, copy the client secret of aio-grafana
# from Keycloak and run:
#   OIDC_CLIENT_SECRET='<secret>' bash setup/prometheus-secrets.sh
set -euo pipefail
NS=monitoring
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null
exists() { kubectl -n "$NS" get secret "$1" >/dev/null 2>&1; }

if exists grafana-admin; then
  echo "grafana-admin exists: kept"
else
  printf '%s' admin > "$tmp/admin-user"
  openssl rand -hex 20 | tr -d '\n' > "$tmp/admin-password"
  kubectl -n "$NS" create secret generic grafana-admin \
    --from-file=admin-user="$tmp/admin-user" --from-file=admin-password="$tmp/admin-password" >/dev/null
  echo "grafana-admin created"
fi

if [ -n "${OIDC_CLIENT_SECRET:-}" ]; then
  printf '%s' "$OIDC_CLIENT_SECRET" > "$tmp/client-secret"
  kubectl -n "$NS" create secret generic grafana-oidc --from-file=client-secret="$tmp/client-secret" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "grafana-oidc written (restart Grafana if it is running: kubectl -n $NS rollout restart deploy/kps-grafana)"
fi

echo
echo "Admin login (user admin): kubectl -n $NS get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d"
