#!/usr/bin/env bash
# Secrets for the jitsi-meet connector. Any cloud; needs kubectl and openssl. Run it once, before Enable.
# Re-runnable: existing secrets are never replaced.
#
#   jitsi-meet/jitsi-meet-jicofo-auth  JICOFO_AUTH_PASSWORD              Jicofo's XMPP login (component focus)
#   jitsi-meet/jitsi-meet-jvb-auth     JVB_AUTH_USER, JVB_AUTH_PASSWORD  the video bridge's XMPP login
#
# Prosody reads both at start and registers these accounts; Jicofo and the bridge log in with them. They are internal
# to the namespace: nobody types them. To rotate, delete both secrets, run this script again and restart all pods:
#   kubectl -n jitsi-meet rollout restart statefulset/jitsi-meet-prosody deploy/jitsi-meet-jicofo deploy/jitsi-meet-jvb-0
set -euo pipefail
NS=jitsi-meet
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null
exists() { kubectl -n "$NS" get secret "$1" >/dev/null 2>&1; }

if exists jitsi-meet-jicofo-auth; then
  echo "jitsi-meet-jicofo-auth exists: kept"
else
  openssl rand -hex 24 | tr -d '\n' > "$tmp/JICOFO_AUTH_PASSWORD"
  kubectl -n "$NS" create secret generic jitsi-meet-jicofo-auth \
    --from-file=JICOFO_AUTH_PASSWORD="$tmp/JICOFO_AUTH_PASSWORD" >/dev/null
  echo "jitsi-meet-jicofo-auth created"
fi

if exists jitsi-meet-jvb-auth; then
  echo "jitsi-meet-jvb-auth exists: kept"
else
  printf 'jvb' > "$tmp/JVB_AUTH_USER"                 # must match jvb.xmpp.user in values/jitsi-meet/values.yaml
  openssl rand -hex 24 | tr -d '\n' > "$tmp/JVB_AUTH_PASSWORD"
  kubectl -n "$NS" create secret generic jitsi-meet-jvb-auth \
    --from-file=JVB_AUTH_USER="$tmp/JVB_AUTH_USER" \
    --from-file=JVB_AUTH_PASSWORD="$tmp/JVB_AUTH_PASSWORD" >/dev/null
  echo "jitsi-meet-jvb-auth created"
fi

echo
echo "Jitsi Meet has no admin account: anyone who reaches the page (behind the SSO gate on a site) can open a room."
