# One login for every tool (Keycloak)

Every tool that AIO manages uses the existing Keycloak, realm `aio`, at `https://profile.sarvaikam.com`. People sign in once, and the same roles as the AIO portal decide what they can do:

| Role (client role) | Tool access |
| --- | --- |
| `aio-admin` | full access to every tool UI |
| `aio-business` | read-only where the tool supports it (Grafana: Viewer) |
| anyone else | no access |

Tools connect in one of two ways, set per catalog entry in `sso.mode`:

| Mode | How | Tools today |
| --- | --- | --- |
| `oidc` | The tool has its own OIDC login and gets its own Keycloak client (`aio-<tool>`). | Grafana, Argo CD, Harbor, Airflow, Superset, Backstage, Gitea, Dependency-Track (public client: browser login with PKCE, no secret) |
| `proxy` | The tool has no login. Traefik sends each request to oauth2-proxy first, which redirects to Keycloak. | OpenCost, Goldilocks, Jaeger, Prometheus, Alertmanager, Appsmith (Community Edition has no OIDC; users still sign in to Appsmith behind the gate) |
| none | No UI, or the UI is reached with `kubectl` only. | operators (KEDA, Velero, kube-green, ...) |

Tool UIs live under `https://<tool>.tools.sarvaikam.com`. The login callback for proxied tools is `https://auth.tools.sarvaikam.com`.

## One-time setup (admin)

1. **DNS.** Add a wildcard A record `*.tools.sarvaikam.com` → `52.140.55.184` (Traefik). Certificates come from cert-manager (`letsencrypt-azure`).
2. **Keycloak clients.** Generate the client definitions, then import them into realm `aio`:
   ```bash
   python tools/gen_sso.py                 # writes sso/keycloak/clients/*.json from the catalog
   bash sso/keycloak/import.sh             # needs kcadm.sh logged in as a realm admin
   ```
   Assign the client roles `aio-admin` / `aio-business` of `aio-tools-sso` and of each `aio-<tool>` client to the same users or groups that have them on the portal. A Keycloak group with these role mappings keeps that to one place.
3. **Secrets** (never in Git). Copy each client secret from Keycloak (Clients → `<id>` → Credentials):
   ```bash
   kubectl create namespace oauth2-proxy
   kubectl -n oauth2-proxy create secret generic oauth2-proxy \
     --from-literal=client-id=aio-tools-sso --from-literal=client-secret='<secret>' \
     --from-literal=cookie-secret="$(openssl rand -base64 32 | head -c 32)"
   kubectl create namespace monitoring
   kubectl -n monitoring create secret generic grafana-oidc --from-literal=client-secret='<aio-grafana secret>'
   ```
4. **Traefik middleware**, applied once (it lives in the ingress namespace, which the connectors project cannot write to):
   ```bash
   kubectl apply -f extras/oauth2-proxy-traefik/middleware.yaml
   ```
5. Run the platform with `CONNECTORS_SITE=sarvaikam`, so the `site-sarvaikam.yaml` overrides (issuer, domains, ingress) are applied. Then enable **oauth2-proxy (SSO gate)** on the Connectors page.

## Putting a tool behind the gate

Give the tool's Ingress (in its `site-<site>.yaml`) the annotation:
```yaml
traefik.ingress.kubernetes.io/router.middlewares: aio-ingress-sso@kubernetescrd
```
Unauthenticated requests are redirected to Keycloak; signed-in requests continue with `X-Auth-Request-User` and `X-Auth-Request-Email` headers.

## Argo CD

Argo CD already uses Dex with GitHub login. To move it to Keycloak as well, add an `oidc.config` for client `aio-argocd` to `argocd-cm` and map the `aio-admin` role to `role:admin` in `argocd-rbac-cm`. Change this in a maintenance window: a mistake locks out the UI. The platform's API account is not affected.
