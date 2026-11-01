# platform/alloy

The **one** in-cluster collector for the on-prem cluster (ONPREM-PLAN §12,
PLT-H2). Not the product chart, not promoted by §11: it is platform plumbing.

```
k8s-monitoring.values.yaml   grafana/k8s-monitoring chart values (chart 4.5.3,
                             pinned in ../../versions.yaml)
../../apps/platform-observability.yaml   the Application, wave −1
```

The AWS-era files that lived here (`agent.alloy`, `values-agent.yaml`) were the
ECS two-tier agent + gateway design. Both are deleted: on-prem is one Alloy that
receives OTLP *and* scrapes *and* tails logs. `platform/clamd` comments still
mention the old allowlist in `agent.alloy`; that comment is now historical.

## What it does

| Signal | Where it comes from | Destination |
|---|---|---|
| Traces | apps' OTel SDK → OTLP `http://alloy-receiver.platform.svc:4318` (already set in the product chart base values; gRPC 4317 too) | Grafana Cloud Tempo |
| Metrics — apps | the same OTLP export | Grafana Cloud Mimir |
| Metrics — cluster | kube-state-metrics + kubelet/cadvisor (chart `clusterMetrics`) | Mimir |
| Metrics — node | node-exporter (chart `hostMetrics`, `job="node"` kept for the existing alert rules) | Mimir |
| Metrics — CNPG | operator PodMonitor (CNPG `monitoring.podMonitorEnabled`, flipped in this PR) via `prometheusOperatorObjects` | Mimir |
| Metrics — Valkey | redis_exporter sidecars on 9121 (extra Alloy config: pod discovery; the port is on no Service) | Mimir |
| Metrics — ArgoCD | the four metrics Services (controller, repo-server, server, applicationset), enabled in `platform/argocd/values.yaml`; scraped by port name `http-metrics` via endpoints discovery | Mimir |
| Metrics — ESO | its `prometheus.io/*` annotations, read by `annotationAutodiscovery` (remapped to the `prometheus.io` annotation names) | Mimir |
| Metrics — cert-manager | controller pod port `http-metrics` (9402), pod discovery; `certmanager_*` allowlist | Mimir |
| Metrics — cloudflared | the two tunnel connectors on port 2000 (no Service, no annotation); `cloudflared_*` allowlist | Mimir |
| Logs | pod logs from the product/ai/platform namespaces via `/var/log/pods` (containerd) | Grafana Cloud Loki |

The receiver Service is `alloy-receiver` in `platform` — release name `alloy` +
`extraService.name: receiver`, with ports 4317/4318 from the `otel-receiver`
preset. **The apps need no change**: the chart base values already point
`OTEL_EXPORTER_OTLP_ENDPOINT` at that name.

## Credentials — the owner fills these, never Git

Secret `platform/grafana-cloud` (ExternalSecret ← Key Vault
`kv-qnsc-platform/platform-grafana-alloy`, a JSON object). Keys:

| Key | Value |
|---|---|
| `GRAFANA_TOKEN` | ONE access-policy token with scopes **`metrics:write`, `logs:write`, `traces:write`** on the `qnsc` stack (no admin/billing scopes) |
| `GRAFANA_PROM_URL` | Prometheus remote-write URL of the stack (`…/api/prom/push`) |
| `GRAFANA_PROM_USER` | metrics instance ID (numeric) |
| `GRAFANA_LOKI_URL` | Loki push URL |
| `GRAFANA_LOKI_USER` | logs instance / user id |
| `GRAFANA_TEMPO_URL` | Tempo URL as Grafana shows it (`https://tempo-….grafana.net/tempo`); the config pushes OTLP/gRPC to the same host on `:443` |
| `GRAFANA_TEMPO_USER` | traces tenant / user id |

`GRAFANA_PYROSCOPE_*` are no longer read (profiling is not enabled). Nothing
stack-specific is in this repository: the URLs come through `envFrom` and every
destination uses `sys.env(...)` in its Alloy config.

## Sizing (single node, 36 GB)

| Piece | Requests | Limits |
|---|---|---|
| Alloy (DaemonSet, one pod) | 250m / 512Mi | 1Gi memory |
| alloy-operator (Deployment) | ~50m / 128Mi | — |
| kube-state-metrics | ~100m / 256Mi | — |
| node-exporter | ~50m / 64Mi | — |

≈ 300m / 1.1 Gi steady state, the §5.7 line. The DaemonSet tolerates every
taint (the AI node's pool taint included) — otherwise half the estate's logs
and node metrics silently disappear.

## Cardinality guard

The collector drops, at the metrics destination, the labels carried only by the
**old** OpenTelemetry semconv generation (`http_method`, `http_status_code`,
`http_flavor`, `http_scheme`, `net_host_name`, `net_host_port`) plus the churn
labels `service_version` and `service_instance_id` (per-deploy and per-restart
cardinality). `instance` is deliberately kept: the existing node/`up`/CNPG
alert rules read it. The Adaptive Metrics keep-label rules (infra#213) still
aggregate the app metrics downstream; scrapers use the chart's strict
allowlists (node-exporter and KSM defaults), and the two extra scrapes above
are likewise allowlisted (`redis_*`, `argocd_*`, `up`).

## Verify after the sync (the SA runs this)

```bash
kubectl -n platform get ds,pods -l app.kubernetes.io/instance=alloy
kubectl -n platform get svc alloy-receiver          # 4317 + 4318 present
kubectl -n platform logs -l app.kubernetes.io/name=alloy --tail=20 | grep -i error
```

In Grafana Cloud:

```promql
up{cluster="qnsc-onprem", job="node"}                              # 1 per node
count by (job) ({cluster="qnsc-onprem", job=~"integrations/kubernetes/.*"})
cnpg_collector_up{cluster="qnsc-onprem"}                           # once pg-* exist
```

Loki — one line from a product:
`{cluster="qnsc-onprem", namespace="opshub-dev"} |= "api"` (Explore, last 15m).

Tempo — one real request: `{ resource.service.name = "rova-api" }` after a
request to rova-dev. An OTLP smoke test from a debug pod in a product
namespace:

```bash
kubectl -n kb-dev run otlp-probe --rm -it --restart=Never \
  --image=curlimages/curl:8.22.0 -- \
  curl -sv -X POST http://alloy-receiver.platform.svc:4318/v1/traces \
  -H 'content-type: application/json' \
  -d '{"resourceSpans":[]}'
```

## Alerts

The collector produces the series the on-prem rules in infra's
`live/observability-alerting` expect. Those rules stay gated by
`onprem_alerts_enabled` until this Application is Healthy on the live cluster;
the fast-track uptime checks are independent of them.
