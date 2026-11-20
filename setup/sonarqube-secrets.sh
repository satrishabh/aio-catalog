#!/usr/bin/env bash
# Secrets and first-run setup for the sonarqube connector. Any cloud; needs kubectl, openssl, curl.
# Re-runnable: existing secrets are never replaced.
#
# Run 1, before Enable:
#   sonarqube/sonarqube-secrets  key monitoring-passcode (the chart's liveness probe and /api/system/health)
#   sonarqube/sonarqube-admin    keys password (random) and currentPassword (admin, SonarQube's built-in default).
#                                The chart's post-install hook changes admin/admin to "password" once SonarQube is up.
#
# Run 2, after Enable, once deploy/sonarqube is ready (the script says so if it is not yet):
#   - checks the admin password (and replaces admin/admin itself if the hook has not done it yet);
#   - creates a Global Analysis Token (can only run analyses) for the AIO pipeline:
#     sonarqube/sonarqube-ci-token  key token. The pipeline sends it as SONAR_TOKEN to
#     http://sonarqube.sonarqube.svc:9000. Copy it to the CI namespace if the pipeline cannot read this one.
#
#   bash setup/sonarqube-secrets.sh
set -euo pipefail
NS=sonarqube
SVC=sonarqube
LOCAL_PORT="${LOCAL_PORT:-19000}"
umask 077
tmp=$(mktemp -d)
pf=""
cleanup() { [ -n "$pf" ] && kill "$pf" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT

kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null
exists() { kubectl -n "$NS" get secret "$1" >/dev/null 2>&1; }

if exists sonarqube-secrets; then
  echo "sonarqube-secrets exists: kept"
else
  openssl rand -hex 24 | tr -d '\n' > "$tmp/passcode"
  kubectl -n "$NS" create secret generic sonarqube-secrets --from-file=monitoring-passcode="$tmp/passcode" >/dev/null
  echo "sonarqube-secrets created"
fi

if exists sonarqube-admin; then
  echo "sonarqube-admin exists: kept"
else
  printf '%sAa1!' "$(openssl rand -hex 16)" > "$tmp/pw"        # SonarQube wants upper, lower, digit, special, 12+
  printf 'admin' > "$tmp/old"
  kubectl -n "$NS" create secret generic sonarqube-admin \
    --from-file=password="$tmp/pw" --from-file=currentPassword="$tmp/old" >/dev/null
  echo "sonarqube-admin created"
fi

ready=$(kubectl -n "$NS" get deploy "$SVC" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
if [ "${ready:-0}" -lt 1 ]; then
  echo
  echo "SonarQube not running/ready yet: Enable the connector, wait until it is ready (first start creates the"
  echo "schema, a few minutes), then run this script again to check the admin password and create the CI token."
  echo "Admin login (user admin): kubectl -n $NS get secret sonarqube-admin -o jsonpath='{.data.password}' | base64 -d"
  exit 0
fi

kubectl -n "$NS" port-forward "svc/$SVC" "$LOCAL_PORT:9000" >/dev/null 2>&1 &
pf=$!
API="http://127.0.0.1:$LOCAL_PORT/api"
for _ in $(seq 1 30); do curl -sf "$API/system/status" 2>/dev/null | grep -q '"status":"UP"' && break; sleep 2; done
curl -sf "$API/system/status" | grep -q '"status":"UP"' || { echo "SonarQube is not UP through port-forward" >&2; exit 1; }

kubectl -n "$NS" get secret sonarqube-admin -o jsonpath='{.data.password}' | base64 -d > "$tmp/pw"
# curl config files keep the credentials out of the process list
printf 'user = "admin:%s"\n' "$(cat "$tmp/pw")" > "$tmp/auth"
printf 'user = "admin:admin"\n' > "$tmp/default"
valid() { curl -s -K "$1" "$API/authentication/validate" | grep -q '"valid":true'; }

if valid "$tmp/auth"; then
  echo "admin password in sonarqube-admin works"
elif valid "$tmp/default"; then
  code=$(curl -s -o /dev/null -w '%{http_code}' -K "$tmp/default" -X POST "$API/users/change_password" \
    --data-urlencode login=admin --data-urlencode previousPassword=admin --data-urlencode "password@$tmp/pw")
  [ "$code" = 204 ] || [ "$code" = 200 ] || { echo "Changing admin/admin failed (HTTP $code)" >&2; exit 1; }
  echo "admin/admin replaced with the password in sonarqube-admin"
else
  echo "Neither the stored admin password nor admin/admin works: the password was changed by hand." >&2
  echo "Put the current one in Secret $NS/sonarqube-admin (key password) and run this script again." >&2
  exit 1
fi

if exists sonarqube-ci-token; then
  echo "sonarqube-ci-token exists: kept"
else
  name="aio-ci-$(date +%Y%m%d%H%M%S)"
  curl -sf -K "$tmp/auth" -X POST "$API/user_tokens/generate" \
    --data-urlencode "name=$name" --data-urlencode type=GLOBAL_ANALYSIS_TOKEN > "$tmp/out" \
    || { echo "Token creation failed" >&2; exit 1; }
  sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "$tmp/out" | tr -d '\n' > "$tmp/token"
  [ -s "$tmp/token" ] || { echo "No token in SonarQube's answer" >&2; exit 1; }
  kubectl -n "$NS" create secret generic sonarqube-ci-token --from-file=token="$tmp/token" >/dev/null
  echo "sonarqube-ci-token created (SonarQube token name $name, owner admin; revoke it under My Account > Security)"
fi

echo
echo "Admin login (user admin): kubectl -n $NS get secret sonarqube-admin -o jsonpath='{.data.password}' | base64 -d"
