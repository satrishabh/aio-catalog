#!/usr/bin/env bash
# Secrets and first-run setup for the dependency-track connector. Any cloud; needs kubectl, openssl, curl, python3.
# Re-runnable: existing secrets are never replaced.
#
# Run 1, before Enable:
#   dependency-track/dependency-track-kek   key "kek": 32 random bytes (base64) that encrypt the secrets DT stores in
#                                           its database. Never replace or lose it (Velero backs up the namespace).
#
# Run 2, after Enable, once deploy/dependency-track-api-server is ready (the script says so if it is not yet):
#   - replaces the built-in admin/admin password with a random one, kept in Secret dependency-track-admin
#     (key password); DT asks for no further change because the script uses DT's own forced-change endpoint;
#   - creates team "Viewers" (VIEW_PORTFOLIO, VIEW_VULNERABILITY, VIEW_POLICY_VIOLATION) and maps the Keycloak
#     roles from the flat "groups" claim: aio-admin -> Administrators, aio-business -> Viewers. Harmless without SSO.
#
#   bash setup/dependency-track-secrets.sh
set -euo pipefail
NS=dependency-track
SVC=dependency-track-api-server
LOCAL_PORT="${LOCAL_PORT:-18080}"
umask 077
tmp=$(mktemp -d)
pf=""
cleanup() { [ -n "$pf" ] && kill "$pf" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT

kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null
exists() { kubectl -n "$NS" get secret "$1" >/dev/null 2>&1; }

if exists dependency-track-kek; then
  echo "dependency-track-kek exists: kept"
else
  openssl rand -base64 32 | tr -d '\n' > "$tmp/kek"
  kubectl -n "$NS" create secret generic dependency-track-kek --from-file=kek="$tmp/kek" >/dev/null
  echo "dependency-track-kek created"
fi

ready=$(kubectl -n "$NS" get deploy "$SVC" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
if [ "${ready:-0}" -lt 1 ]; then
  echo
  echo "API server not running/ready yet: Enable the connector, wait until it is ready (first start runs the"
  echo "schema migration, a few minutes), then run this script again to set the admin password and the SSO teams."
  exit 0
fi

kubectl -n "$NS" port-forward "svc/$SVC" "$LOCAL_PORT:8080" >/dev/null 2>&1 &
pf=$!
API="http://127.0.0.1:$LOCAL_PORT/api"
for _ in $(seq 1 30); do curl -sf "$API/version" >/dev/null 2>&1 && break; sleep 1; done
curl -sf "$API/version" >/dev/null || { echo "Cannot reach the API server through port-forward" >&2; exit 1; }

# --- admin password -------------------------------------------------------------------------------------------
if exists dependency-track-admin; then
  echo "dependency-track-admin exists: kept"
  kubectl -n "$NS" get secret dependency-track-admin -o jsonpath='{.data.password}' | base64 -d > "$tmp/pw"
else
  printf 'admin' > "$tmp/old"
  printf '%sAa1!' "$(openssl rand -hex 16)" > "$tmp/pw"
  code=$(curl -s -o "$tmp/out" -w '%{http_code}' -X POST "$API/v1/user/forceChangePassword" \
    --data-urlencode username=admin --data-urlencode "password@$tmp/old" \
    --data-urlencode "newPassword@$tmp/pw" --data-urlencode "confirmPassword@$tmp/pw")
  if [ "$code" != 200 ]; then
    echo "admin/admin no longer works (HTTP $code): the password was already changed by hand. Nothing stored." >&2
    echo "To let this script map the SSO teams, create Secret $NS/dependency-track-admin (key password) with the" >&2
    echo "current admin password, then run it again." >&2
    exit 1
  fi
  kubectl -n "$NS" create secret generic dependency-track-admin --from-literal=username=admin \
    --from-file=password="$tmp/pw" >/dev/null
  echo "admin password replaced and stored in dependency-track-admin"
fi

# --- teams for Keycloak roles ---------------------------------------------------------------------------------
curl -sf -X POST "$API/v1/user/login" --data-urlencode username=admin --data-urlencode "password@$tmp/pw" \
  > "$tmp/jwt" || { echo "Login as admin failed (password in dependency-track-admin is stale?)" >&2; exit 1; }
printf 'header = "Authorization: Bearer %s"\n' "$(cat "$tmp/jwt")" > "$tmp/auth"   # curl config file: token not in argv

API="$API" AUTH="$tmp/auth" python3 - <<'PY'
import json, os, subprocess

API, AUTH = os.environ["API"], os.environ["AUTH"]

def call(method, path, body=None, ok=(200, 201, 204, 304, 409)):
    cmd = ["curl", "-s", "-K", AUTH, "-X", method, "-w", "\n%{http_code}", API + path]
    if body is not None:
        cmd += ["-H", "Content-Type: application/json", "-d", json.dumps(body)]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    text, code = out.rsplit("\n", 1)
    if int(code) not in ok:
        raise SystemExit(f"{method} {path}: HTTP {code} {text[:200]}")
    return json.loads(text) if text.strip().startswith(("{", "[")) else None

teams = {t["name"]: t["uuid"] for t in call("GET", "/v1/team")}
if "Viewers" not in teams:
    teams["Viewers"] = call("PUT", "/v1/team", {"name": "Viewers"})["uuid"]
    print("team Viewers created")
for perm in ("VIEW_PORTFOLIO", "VIEW_VULNERABILITY", "VIEW_POLICY_VIOLATION"):
    call("POST", f"/v1/permission/{perm}/team/{teams['Viewers']}")

groups = {g["name"]: g["uuid"] for g in call("GET", "/v1/oidc/group")}
for group, team in (("aio-admin", "Administrators"), ("aio-business", "Viewers")):
    if group not in groups:
        groups[group] = call("PUT", "/v1/oidc/group", {"name": group})["uuid"]
    mapped = {t["uuid"] for t in call("GET", f"/v1/oidc/group/{groups[group]}/team")}
    if teams[team] not in mapped:
        call("PUT", "/v1/oidc/mapping", {"team": teams[team], "group": groups[group]})
    print(f"OIDC group {group} -> team {team}")
PY

echo
echo "Admin login (user admin): kubectl -n $NS get secret dependency-track-admin -o jsonpath='{.data.password}' | base64 -d"
