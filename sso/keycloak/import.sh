#!/usr/bin/env bash
# Creates or updates the tool clients in Keycloak realm "aio" from sso/keycloak/clients/*.json and adds the
# client roles aio-admin and aio-business to each. Needs kcadm.sh (Keycloak admin CLI) and an admin login:
#   kcadm.sh config credentials --server https://profile.sarvaikam.com --realm master --user <admin>
# Prints nothing secret. Read each generated client secret from the Keycloak console (Clients > <id> > Credentials)
# and store it in the matching Kubernetes Secret (see sso/README.md).
set -euo pipefail
REALM="${REALM:-aio}"
DIR="$(cd "$(dirname "$0")" && pwd)/clients"
for f in "$DIR"/*.json; do
  id=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["clientId"])' "$f")
  body=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));d.pop("x-aio-roles",None);print(json.dumps(d))' "$f")
  uuid=$(kcadm.sh get clients -r "$REALM" -q clientId="$id" --fields id --format csv --noquotes | head -1)
  if [ -z "$uuid" ]; then
    echo "$body" | kcadm.sh create clients -r "$REALM" -f - >/dev/null
    uuid=$(kcadm.sh get clients -r "$REALM" -q clientId="$id" --fields id --format csv --noquotes | head -1)
    echo "created $id"
  else
    echo "$body" | kcadm.sh update "clients/$uuid" -r "$REALM" -f - >/dev/null
    echo "updated $id"
  fi
  for role in aio-admin aio-business; do
    kcadm.sh get "clients/$uuid/roles/$role" -r "$REALM" >/dev/null 2>&1 ||
      kcadm.sh create "clients/$uuid/roles" -r "$REALM" -s name="$role" >/dev/null
  done
done
