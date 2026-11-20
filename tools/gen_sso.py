#!/usr/bin/env python3
"""Writes sso/keycloak/clients/<client>.json for every catalog entry with sso.mode == oidc, plus the shared
oauth2-proxy client. Import into realm "aio" with sso/keycloak/import.sh. Re-run after adding a tool.
Redirect URIs follow https://<id>.<TOOLS_DOMAIN>/... (TOOLS_DOMAIN defaults to tools.sarvaikam.com)."""
import glob
import json
import os

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOMAIN = os.environ.get("TOOLS_DOMAIN", "tools.sarvaikam.com")
OUT = os.path.join(ROOT, "sso", "keycloak", "clients")

# Where each tool expects the OIDC callback (path on its own host)
CALLBACK = {
    "aio-grafana": "/login/generic_oauth", "aio-argocd": "/auth/callback", "aio-harbor": "/c/oidc/callback",
    "aio-airflow": "/auth/oauth-authorized/keycloak", "aio-superset": "/oauth-authorized/keycloak",
    "aio-backstage": "/api/auth/oidc/handler/frame",
    "aio-gitea": "/user/oauth2/aio/callback", "aio-langfuse": "/api/auth/callback/keycloak", "aio-dependency-track": "/static/oidc-callback.html",
}
HOST = {"aio-grafana": "grafana", "aio-argocd": "argocd"}
# Tools that read roles from a flat "groups" claim (Harbor: oidc_groups_claim / oidc_admin_group) get a mapper
# that puts this client's roles (aio-admin, aio-business) into "groups".
GROUPS_CLAIM = {"aio-harbor", "aio-dependency-track", "aio-airflow", "aio-superset"}
# Tools whose login runs in the browser (authorization code + PKCE, no client secret): public Keycloak clients.
PUBLIC = {"aio-dependency-track"}


def groups_mapper(client_id):
    return {
        "name": "client roles as groups",
        "protocol": "openid-connect",
        "protocolMapper": "oidc-usermodel-client-role-mapper",
        "config": {
            "usermodel.clientRoleMapping.clientId": client_id,
            "claim.name": "groups",
            "jsonType.label": "String",
            "multivalued": "true",
            "id.token.claim": "true",
            "access.token.claim": "true",
            "userinfo.token.claim": "true",
        },
    }


def client(client_id, host, callback, description):
    return {
        "clientId": client_id,
        "name": description,
        "protocol": "openid-connect",
        "publicClient": False,
        "standardFlowEnabled": True,
        "directAccessGrantsEnabled": False,
        "implicitFlowEnabled": False,
        "serviceAccountsEnabled": False,
        "redirectUris": [f"https://{host}.{DOMAIN}{callback}"],
        "webOrigins": [f"https://{host}.{DOMAIN}"],
        "attributes": {"pkce.code.challenge.method": "S256", "post.logout.redirect.uris": f"https://{host}.{DOMAIN}/*"},
        # Same role names as the AIO portal; assign them to users or groups in realm "aio"
        "defaultClientScopes": ["openid", "email", "profile", "roles"],
        "x-aio-roles": ["aio-admin", "aio-business"],
    }


def main():
    os.makedirs(OUT, exist_ok=True)
    written = []
    for path in sorted(glob.glob(os.path.join(ROOT, "catalog", "**", "*.yaml"), recursive=True)):
        e = yaml.safe_load(open(path, encoding="utf-8"))
        sso = e.get("sso") or {}
        if sso.get("mode") != "oidc":
            continue
        cid = sso["clientId"]
        c = client(cid, HOST.get(cid, e["id"]), CALLBACK.get(cid, "/oauth2/callback"), f"{e['name']} (AIO managed)")
        if cid in PUBLIC:
            c["publicClient"] = True
        if cid in GROUPS_CLAIM:
            c["protocolMappers"] = [groups_mapper(cid)]
        json.dump(c, open(os.path.join(OUT, cid + ".json"), "w", encoding="utf-8", newline="\n"), indent=2)
        written.append(cid)
    proxy = client("aio-tools-sso", "auth", "/oauth2/callback", "oauth2-proxy gate for tool UIs")
    proxy["redirectUris"] = [f"https://auth.{DOMAIN}/oauth2/callback"]
    proxy["webOrigins"] = [f"https://*.{DOMAIN}"]
    json.dump(proxy, open(os.path.join(OUT, "aio-tools-sso.json"), "w", encoding="utf-8", newline="\n"), indent=2)
    print("clients:", ", ".join(written + ["aio-tools-sso"]))


if __name__ == "__main__":
    main()
