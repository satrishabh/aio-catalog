# Catalog policy

Every tool in this catalog, whatever its origin, passes the same rules before it becomes `managed`. `tools/validate.py` enforces the mechanical ones in CI.

## License

- **Allowed:** OSI-approved licenses only. Apache-2.0, MIT, BSD, MPL-2.0, ISC, EPL-2.0, LGPL, GPL and AGPL are all accepted.
- **AGPL-3.0** tools (Grafana, Loki, Renovate) are fine to run unmodified as a managed service. If we ever modify one and offer it to customers over a network, we must publish those changes.
- **Rejected:** source-available licenses that only look open: BUSL/BSL (Vault, Terraform), SSPL (MongoDB), Elastic License (Elasticsearch, Kibana), FSL (Sentry), Sustainable Use (n8n), RSAL (Redis 7.4–7.x). Use the open alternatives: OpenBao, OpenSearch, Valkey, GlitchTip.

## Versions

- Charts are pinned to exact versions, never `latest` or a range.
- A version must have been released at least 14 days ago (`tools/pin.py`). Where the chart index cannot prove the age, the entry records how it was checked in `pinNote`.
- Each managed entry keeps a `previousVersion` as its rollback target, and both versions must render (`validate.py --render`).

## Supply chain

- **Governance:** prefer projects under a neutral foundation (CNCF, Apache, Linux Foundation, OpenSSF). Single-vendor projects are allowed when they have an active community and a clear license; `foundation` records which applies.
- **Images:** they must come from the project's official registry (Docker Hub official org, ghcr.io, quay.io, registry.k8s.io, the vendor's own registry). Before promotion, check that the default values do not pull from personal or mirror registries.
- **Origin:** `origin` is recorded for transparency only (for example, many excellent Apache and CNCF projects started in China). It never changes the bar: the same license, version, image and review rules apply to every project.
- **Secrets:** nothing secret is ever committed. Values reference existing Kubernetes Secrets, which an admin creates.

## Promotion: planned → managed

1. A values file, sized for the smallest supported cluster.
2. Cloud overlays where needed (`cloudValues`) and an install overlay where needed (`siteValues`).
3. Probes that prove the tool works, not only that a pod runs.
4. An SSO mode: `oidc` (own Keycloak client), `proxy` (oauth2-proxy gate) or none.
5. A dry run on a real cluster, at both versions, before the first Enable.
