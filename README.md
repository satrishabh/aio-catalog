# aio-catalog

This is the catalog of open-source tools that AIO offers as managed services. Each tool has one file here: what it is, its license and governing foundation, pinned chart versions, values per cloud and per installation, single sign-on mode, and health probes.

AIO reads the built catalog from a tagged release of this repo and installs tools through Argo CD. Adding or upgrading a tool is a pull request here, and the AIO code stays unchanged.

```
catalog/<category>/<id>.yaml     one entry per tool (core | managed | planned)
values/<id>/values.yaml          Helm values (common), values-<cloud>.yaml, site-<site>.yaml overlays
extras/                          plain manifests synced with a chart, or applied once by an admin
bindings/<id>.yaml               manifest templates a project gets when it attaches a connector (binding)
sso/                             Keycloak clients and the single sign-on setup
dist/catalog.yaml                GENERATED: everything AIO reads
deploy/connectors-project.yaml   GENERATED: the Argo CD guardrail project
tools/                           pin.py, validate.py, build.py, gen_sso.py
```

## Using it from AIO

Set on the platform:

| Setting | Example | Meaning |
| --- | --- | --- |
| `CONNECTORS_REPO` | `https://github.com/satrishabh/aio-catalog.git` | this repo (values and extras are read from it by Argo CD) |
| `CONNECTORS_REVISION` | `v2026.11.1` | tag to use. Pin a tag: moving it is how catalog changes reach production. |
| `CLOUD_PROVIDER` | `aks` | selects `values-<cloud>.yaml` overlays and hides tools not supported on that cloud |
| `CONNECTORS_SITE` | `sarvaikam` | selects `site-<site>.yaml` overlays (domains, issuer, ingress) |

Then apply `deploy/connectors-project.yaml` once, and again whenever it changes.

## Workflow

```bash
python tools/pin.py                 # which charts have newer versions (14+ days old)
python tools/validate.py            # rules (CI runs this on every PR)
python tools/validate.py --render   # also render every managed tool at both versions
python tools/build.py               # regenerate dist/ and deploy/ (CI fails if stale)
python tools/gen_sso.py             # regenerate Keycloak client definitions
```

Release: merge to `main`, tag `vYYYY.MM.N`, and move `CONNECTORS_REVISION` to the tag.

## Bindings (Project → Services)

An entry may have a `binding:` block: how a project uses the connector once an admin has switched it on. In AIO,
Project → Services attaches it per environment and writes the result into that project's values files
(`services:`), so the values file alone runs the app. Entries without a binding are not offered there. Schema and
platform side: AIO `docs/architecture/PROJECT-SERVICES.md`.

| `scope` | The app gets | Bindings |
| --- | --- | --- |
| `instance` | its own copy in its namespace from `manifests` (`bindings/<id>.yaml`, multi-document YAML) | cloudnative-pg, strimzi, opensearch |
| `shared` | the connector's single service; `copySecret` copies one Secret into the app namespace | valkey (dev, staging), langfuse, milvus |
| `config` | only `env` and/or `podAnnotations` | opentelemetry-collector, temporal, dapr |

Placeholders, plain string substitution by the platform: `${app}` project name, `${env}`, `${namespace}` (the app
namespace, today the same as the env), `${name}` = `${app}-<connector id>`, `${opt.<id>}` an option's value.
Anything else in `${...}` is an error. App namespaces are shared by every project, so every object, Secret and copied
Secret name contains `${name}` or `${app}`. Kubernetes expands `$(VAR)` in an env value from an env var defined
before it (e.g. `REDIS_URL` from `VALKEY_PASSWORD`); the platform keeps the listed order.

`validate.py` checks the block (scope, envs, options with string choices, env entries with `value` or
`secret` + `key`, `copySecret` only with `shared`, known placeholders) and renders `manifests` with sample values
(`shop`, `dev`, option defaults) into valid YAML whose documents each have apiVersion, kind and a `metadata.name`
containing the app. `build.py` inlines the template as `binding.manifestsText` in `dist/catalog.yaml`.

## Scope and schedule

78 tools: 10 core, 46 managed, 22 planned. See `dist/catalog.yaml`, and [POLICY.md](POLICY.md) for the license and supply-chain rules (OSI-approved only; Apache, CNCF and Chinese-origin projects held to the same bar).

Each wave is gated on cluster capacity. Add the AKS spot node pool before wave 5.

| Phase / wave | Dates | Tools |
| --- | --- | --- |
| 1-3 | 2026-11-17 → 12-19 | Prometheus + Grafana; Trivy Operator, OpenCost, Goldilocks, kube-green; Velero, Renovate, KEDA, Descheduler |
| 4 | 2026-12-21 → 2027-01-08 | **SSO**: oauth2-proxy gate + Keycloak clients; Grafana and Argo CD on Keycloak. **Managed (catalog `phase: 4`)**: node autoprovisioning (AKS, GKE), Loki, Tempo, OpenTelemetry Collector, External Secrets Operator, Gatus; activation in AIO `docs/architecture/CONNECTORS.md` |
| 5 | 2027-01 | CrowdSec + edge protection (optional, see below; live on sarvaikam). **Managed (catalog `phase: 5`)**: CloudNativePG, Valkey, Harbor (database on CloudNativePG, secrets from `setup/harbor-secrets.sh`). **Core**: Biome as the CI `lint` step (AIO `tekton/tasks/lint-biome.yaml`). Karpenter when AIO runs on EKS. Activation in AIO `docs/architecture/CONNECTORS.md` |
| 6 | 2027-02 | **Managed (catalog `phase: 6`)**: Strimzi (Kafka operator), Crossplane (+ `setup/crossplane-setup-azure.sh` / `-gcp.sh`), OpenKruise; Dependency-Track, Falco, OpenBao (`setup/openbao-init.sh`); Airflow, Superset (databases on CloudNativePG); Appsmith (Community Edition, behind the SSO gate), APISIX (standalone, routes in Git); Milvus (standalone), Langfuse. Every setup step is in `setup/<id>-*.sh`. **Core**: Podman / Buildah as a CI build strategy (AIO `tekton/tasks/build-image.yaml`). **Stay planned**: Dragonfly and Koordinator (both change every node; little gain on 2 nodes), Jaeger (Grafana + Tempo already cover it). Phase 6 needs about 2.1 CPU and 9.5 GiB of requests, more than the 2-node reference cluster has free: enable one at a time. Activation in AIO `docs/architecture/CONNECTORS.md` |
| 7 | 2027-03 onwards | **Managed (catalog `phase: 7`)**: Gitea, SonarQube (Community Build, behind the SSO gate); Dapr, Temporal, Camel K, Volcano; operators for Spark, Flink, OpenSearch, TiDB and Doris (apps create their own clusters), Pulsar standalone; ERPNext (MariaDB on the official image), Jitsi Meet (group calls need a UDP load balancer: sarvaikam overlay). Setup steps in `setup/<id>-*.sh`. **Stay planned**: Odoo, SuiteCRM, MediaWiki, Answer, DolphinScheduler (no official https Helm chart), ShardingSphere (unmaintained), Backstage and GitLab CE (would replace AIO parts), SkyWalking, HertzBeat, OpenNMS (overlap the observability stack), Nacos, Seata, Higress, Karmada, KubeEdge (niche here), vLLM (GPU). Phase 7 needs about 1.9 CPU and 8.5 GiB. Activation in AIO `docs/architecture/CONNECTORS.md` |

A tool moves from planned to managed by pull request, following POLICY.md.

## Rate limiting and DDoS protection (optional)

Off by default. [extras/edge-protection](extras/edge-protection/README.md) has three layers that can be turned on
one at a time: an edge flood guard in Traefik (per-IP request and connection limits for every site), CrowdSec bans
at the edge (the `crowdsec` connector plus a Traefik bouncer), and tighter per-app limits from the app chart's
`rateLimit` values.
