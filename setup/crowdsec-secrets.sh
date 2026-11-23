#!/usr/bin/env bash
# Secrets for the crowdsec connector. Any cloud; needs kubectl and openssl. Run it once, before Enable.
# Re-runnable: an existing secret is never replaced.
#
#   crowdsec/crowdsec-lapi-shared  csLapiSecret (signs LAPI login tokens), registrationToken (AppSec registration)
#
# Why: without an external Secret the chart generates both values on every render. Under Argo CD that changed the
# LAPI Deployment's checksum on every sync, so the Local API restarted each time Argo CD woke up (revision 52 by
# 2026-11-24) and every agent and bouncer token became invalid.
#
# Upgrading an install that ran without this Secret: the chart-made Secret crowdsec-lapi-secrets is copied, so the
# Local API keeps its signing secret and connected agents and bouncers are not signed out. Argo CD then prunes it.
set -euo pipefail
NS=crowdsec
NAME=crowdsec-lapi-shared
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null
exists() { kubectl -n "$NS" get secret "$1" >/dev/null 2>&1; }
key() { kubectl -n "$NS" get secret "$1" -o "jsonpath={.data.$2}" | base64 -d; }

if exists "$NAME"; then
  echo "$NAME exists: kept"
else
  if exists crowdsec-lapi-secrets && [ -n "$(key crowdsec-lapi-secrets csLapiSecret)" ]; then
    key crowdsec-lapi-secrets csLapiSecret > "$tmp/csLapiSecret"
    key crowdsec-lapi-secrets registrationToken > "$tmp/registrationToken"
    from="copied from crowdsec-lapi-secrets"
  else
    openssl rand -hex 40 | tr -d '\n' > "$tmp/csLapiSecret"          # 80 chars; the chart needs > 64
    openssl rand -hex 32 | tr -d '\n' > "$tmp/registrationToken"     # 64 chars; the chart needs > 48
    from="generated"
  fi
  kubectl -n "$NS" create secret generic "$NAME" \
    --from-file=csLapiSecret="$tmp/csLapiSecret" --from-file=registrationToken="$tmp/registrationToken" >/dev/null
  echo "$NAME created ($from)"
fi
