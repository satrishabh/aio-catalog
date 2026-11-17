# aio-catalog

This is the catalog of open-source tools that AIO offers as managed services. Each tool has one file here: what it is, its license and governing foundation, pinned chart versions, values per cloud and per installation, single sign-on mode, and health probes.

AIO reads the built catalog from a tagged release of this repo and installs tools through Argo CD. Adding or upgrading a tool is a pull request here, and the AIO code stays unchanged.

```
catalog/<category>/<id>.yaml     one entry per tool (core | managed | planned)
values/<id>/values.yaml          Helm values (common), values-<cloud>.yaml, site-<site>.yaml overlays
extras/                          plain manifests synced with a chart, or applied once by an admin
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

## Scope and schedule

71 tools: 8 core, 10 managed, 53 planned. See `dist/catalog.yaml`, and [POLICY.md](POLICY.md) for the license and supply-chain rules (OSI-approved only; Apache, CNCF and Chinese-origin projects held to the same bar).

Each wave is gated on cluster capacity. Add the AKS spot node pool before wave 5.

| Phase / wave | Dates | Tools |
| --- | --- | --- |
| 1-3 | 2026-11-17 → 12-19 | Prometheus + Grafana; Trivy Operator, OpenCost, Goldilocks, kube-green; Velero, Renovate, KEDA, Descheduler |
| 4 | 2026-12-21 → 2027-01-08 | **SSO**: oauth2-proxy gate + Keycloak clients; Grafana and Argo CD on Keycloak |
| 5 | 2027-01 | Harbor, CloudNativePG, External Secrets, Loki, OpenTelemetry Collector, Valkey; Biome as a CI lint step |
| 6 | 2027-02 | Apache: Kafka (Strimzi), Airflow, Superset, APISIX. Cloud native: Dragonfly, Koordinator, OpenKruise, Crossplane. AI: Milvus, Langfuse. Low-code: Appsmith. Podman/Buildah as a CI build option |
| 7 | 2027-03 onwards | Pulsar, Spark, Flink, Doris, TiDB, ShardingSphere, SkyWalking, HertzBeat, DolphinScheduler, Higress, Nacos, Seata, Volcano, Karmada, KubeEdge, Dapr, Temporal, Camel K, Backstage, Gitea, SonarQube, Answer, OpenSearch, Jaeger, Falco, Dependency-Track, OpenBao, vLLM, Jitsi Meet, OpenNMS, MediaWiki, Odoo Community (POS) |

A tool moves from planned to managed by pull request, following POLICY.md.
