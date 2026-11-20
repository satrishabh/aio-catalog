#!/usr/bin/env bash
# Initialise and unseal the openbao connector. Any cloud; needs kubectl, curl and python3. Run after Enable, once
# pod openbao-0 is running (it stays NotReady while sealed; that is expected).
#
#   bash setup/openbao-init.sh
#
# First run (OpenBao not initialised yet): initialises it with KEY_SHARES unseal keys of which KEY_THRESHOLD are
# needed (default 1 and 1), writes the keys and the root token ONLY to Secret openbao/openbao-init
# (keys unseal-key-1..N, root-token, init.json), then unseals. Then:
#   1. Copy that Secret offline (password manager, or one key per person with KEY_SHARES>1) and delete it:
#        kubectl -n openbao get secret openbao-init -o json > openbao-init.json   # store safely, then
#        kubectl -n openbao delete secret openbao-init
#      While it exists, anyone who can read Secrets in namespace openbao can unseal and act as root.
#   2. Log in to the UI with the root token, set up auth methods and policies, then revoke the root token.
#
# Every later run (after any restart of openbao-0 OpenBao is sealed again): unseals with
#   - UNSEAL_KEY_FILE=<file with one unseal key per line>   (keys kept offline), or
#   - Secret openbao/openbao-init, if it is still in the cluster.
# The script never prints keys or the root token and never passes them on a command line.
set -euo pipefail
NS=openbao
POD=openbao-0
LOCAL_PORT="${LOCAL_PORT:-18200}"
KEY_SHARES="${KEY_SHARES:-1}"
KEY_THRESHOLD="${KEY_THRESHOLD:-1}"
umask 077
tmp=$(mktemp -d)
pf=""
cleanup() { [ -n "$pf" ] && kill "$pf" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT

phase=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)
[ "$phase" = Running ] || { echo "Pod $NS/$POD is not running yet (${phase:-missing}): Enable the connector and wait." >&2; exit 1; }

kubectl -n "$NS" port-forward "pod/$POD" "$LOCAL_PORT:8200" >/dev/null 2>&1 &
pf=$!
API="http://127.0.0.1:$LOCAL_PORT/v1"
for _ in $(seq 1 30); do curl -s -o /dev/null "$API/sys/seal-status" && break; sleep 1; done

status() { curl -sf "$API/sys/seal-status"; }
field() { python3 -c 'import json,sys; print(str(json.load(sys.stdin)[sys.argv[1]]).lower())' "$1"; }
status >/dev/null || { echo "Cannot reach OpenBao through port-forward" >&2; exit 1; }

if [ "$(status | field initialized)" != true ]; then
  if kubectl -n "$NS" get secret openbao-init >/dev/null 2>&1; then
    echo "OpenBao is not initialised but Secret openbao-init exists (from an earlier install?). Move it away first." >&2
    exit 1
  fi
  printf '{"secret_shares": %d, "secret_threshold": %d}' "$KEY_SHARES" "$KEY_THRESHOLD" > "$tmp/req"
  curl -sf -X PUT "$API/sys/init" --data @"$tmp/req" > "$tmp/init.json"
  python3 - "$tmp" <<'PY'
import json, os, sys
d = sys.argv[1]
init = json.load(open(os.path.join(d, "init.json")))
for i, k in enumerate(init["keys"], 1):
    open(os.path.join(d, f"unseal-key-{i}"), "w").write(k)
open(os.path.join(d, "root-token"), "w").write(init["root_token"])
open(os.path.join(d, "keys"), "w").write("\n".join(init["keys"]) + "\n")
PY
  args=(--from-file=init.json="$tmp/init.json" --from-file=root-token="$tmp/root-token")
  for f in "$tmp"/unseal-key-*; do args+=(--from-file="$(basename "$f")=$f"); done
  if ! kubectl -n "$NS" create secret generic openbao-init "${args[@]}" >/dev/null; then
    cp "$tmp/init.json" ./openbao-init.json   # the only copy of the keys: never lose it
    echo "Could not create Secret $NS/openbao-init. The keys and root token are in ./openbao-init.json (mode 600):" >&2
    echo "store it safely, then run again with UNSEAL_KEY_FILE=<file with the keys, one per line>." >&2
    exit 1
  fi
  echo "OpenBao initialised ($KEY_SHARES key share(s), threshold $KEY_THRESHOLD); keys and root token in Secret $NS/openbao-init"
  keyfile="$tmp/keys"
elif [ -n "${UNSEAL_KEY_FILE:-}" ]; then
  keyfile="$UNSEAL_KEY_FILE"
elif kubectl -n "$NS" get secret openbao-init >/dev/null 2>&1; then
  kubectl -n "$NS" get secret openbao-init -o json | python3 -c '
import base64, json, sys
data = json.load(sys.stdin)["data"]
keys = [base64.b64decode(v).decode() for k, v in sorted(data.items()) if k.startswith("unseal-key-")]
open(sys.argv[1], "w").write("\n".join(keys) + "\n")' "$tmp/keys"
  keyfile="$tmp/keys"
else
  keyfile=""
fi

if [ "$(status | field sealed)" != true ]; then
  echo "OpenBao is unsealed."
else
  [ -n "$keyfile" ] || { echo "OpenBao is sealed. Run again with UNSEAL_KEY_FILE=<file with one unseal key per line>." >&2; exit 1; }
  while IFS= read -r key || [ -n "$key" ]; do
    [ -n "$key" ] || continue
    printf '{"key": "%s"}' "$key" > "$tmp/unseal"
    curl -sf -X PUT "$API/sys/unseal" --data @"$tmp/unseal" > "$tmp/out"
    [ "$(field sealed < "$tmp/out")" = true ] || break
  done < "$keyfile"
  rm -f "$tmp/unseal"
  if [ "$(status | field sealed)" = true ]; then
    echo "Still sealed: not enough valid unseal keys (progress $(status | field progress)/$(status | field t))." >&2
    exit 1
  fi
  echo "OpenBao unsealed."
fi

if kubectl -n "$NS" get secret openbao-init >/dev/null 2>&1; then
  echo
  echo "Secret $NS/openbao-init holds the unseal key(s) and the root token. Copy it offline, then delete it:"
  echo "  kubectl -n $NS get secret openbao-init -o json > openbao-init.json && kubectl -n $NS delete secret openbao-init"
  echo "Root token (for the first UI login): kubectl -n $NS get secret openbao-init -o jsonpath='{.data.root-token}' | base64 -d"
fi
echo "UI: kubectl -n $NS port-forward svc/openbao-ui 8200:8200, then http://localhost:8200/ui"
