#!/usr/bin/env bash
# Secrets for the erpnext connector. Any cloud; needs kubectl and openssl. Run it once, before Enable.
# Re-runnable: existing keys are never replaced (MariaDB keeps the root password it was first started with, and
# the site job creates user Administrator with the first admin password).
#
#   erpnext/erpnext  mariadb-root-password  MariaDB root
#                    admin-password         ERPNext user "Administrator"
#                    site-url               only with SITE_URL set, e.g. https://erpnext.tools.sarvaikam.com
#                                           (ERPNext host_name; set by the site job at the next sync)
#
# Site overlay (sarvaikam):  SITE_URL=https://erpnext.tools.sarvaikam.com bash setup/erpnext-secrets.sh
# Keycloak login is set up inside ERPNext afterwards: see values/erpnext/site-sarvaikam.yaml.
set -euo pipefail
NS=erpnext
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null

if kubectl -n "$NS" get secret erpnext >/dev/null 2>&1; then
  echo "erpnext exists: passwords kept"
else
  openssl rand -hex 24 | tr -d '\n' > "$tmp/mariadb-root-password"
  openssl rand -hex 16 | tr -d '\n' > "$tmp/admin-password"
  kubectl -n "$NS" create secret generic erpnext \
    --from-file=mariadb-root-password="$tmp/mariadb-root-password" \
    --from-file=admin-password="$tmp/admin-password" >/dev/null
  echo "erpnext created"
fi

if [ -n "${SITE_URL:-}" ]; then
  # Not a secret, but kept in the same Secret so the site job needs one object. Only this key is changed.
  printf '{"data":{"site-url":"%s"}}' "$(printf '%s' "$SITE_URL" | base64 | tr -d '\n')" > "$tmp/patch.json"
  kubectl -n "$NS" patch secret erpnext --type merge --patch-file "$tmp/patch.json" >/dev/null
  echo "site-url set to $SITE_URL (applied at the next sync of connector-erpnext)"
fi

echo
echo "Admin login (user Administrator): kubectl -n $NS get secret erpnext -o jsonpath='{.data.admin-password}' | base64 -d"
