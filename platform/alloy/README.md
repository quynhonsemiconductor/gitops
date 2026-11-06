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
| Metrics — Proxmox host | the Proxmox host's PVE 9 OpenTelemetry metric server (OTLP/HTTP, no auth) → NodePort `alloy-otlp-host` 30418 → the same OTLP receiver; `proxmox_*` only | Mimir |
| Metrics — cluster | kube-state-metrics + kubelet/cadvisor (chart `clusterMetrics`) | Mimir |
| Metrics — node | node-exporter (chart `hostMetrics`, `job="node"` kept for the existing alert rules) | Mimir |
| Metrics — CNPG | operator PodMonitor (CNPG `monitoring.podMonitorEnabled`, flipped in this PR) via `prometheusOperatorObjects` | Mimir |
| Metrics — Valkey | redis_exporter sidecars on 9121 (extra Alloy config: pod discovery; the port is on no Service) | Mimir |
| Metrics — ArgoCD | the four metrics Services (controller, repo-server, server, applicationset), enabled in `platform/argocd/values.yaml`; scraped by port name `http-metrics` via endpoints discovery | Mimir |
| Metrics — ESO | its `prometheus.io/*` annotations, read by `annotationAutodiscovery` (remapped to the `prometheus.io` annotation names) | Mimir |
| Metrics — cert-manager | controller pod port `http-metrics` (9402), pod discovery; `certmanager_*` allowlist | Mimir |
| Metrics — cloudflared | the two tunnel connectors on port 2000 (no Service, no annotation); `cloudflared_*` allowlist | Mimir |
| Metrics — GPU | NVIDIA DCGM exporter DaemonSet on ai-01, namespace `gpu-monitoring` (port 9400, pod discovery); five `DCGM_FI_DEV_*` fields allowlisted — utilisation, memory, temperature, XID | Mimir |
| Logs | pod logs from the product/ai/platform namespaces via `/var/log/pods` (containerd) | Grafana Cloud Loki |

The receiver Service is `alloy-receiver` in `platform` — release name `alloy` +
`extraService.name: receiver`, with ports 4317/4318 from the `otel-receiver`
preset. **The apps need no change**: the chart base values already point
`OTEL_EXPORTER_OTLP_ENDPOINT` at that name.

### The host door (`alloy-otlp-host`)

The Proxmox host is not a cluster node and cannot resolve
`alloy-receiver.platform.svc`, so the same receiver is published on a NodePort:
Service `alloy-otlp-host` (`extraObjects` in the values file), `type: NodePort`,
port 4318, `nodePort: 30418`, `externalTrafficPolicy: Cluster`, selecting the
Alloy pods. OTLP/HTTP only — no gRPC NodePort (the PVE plugin posts to
`/v1/metrics`). Point PVE's metric server at
`http://<k3s node>:30418/v1/metrics` (the path is mandatory; PVE appends
nothing).

Two guards matter, because the port has no authentication:

- the chart's `applicationObservability.metrics.filters` is an **allowlist** of
  OTLP metric names for `service.name=proxmox-ve`: node `uptime`,
  `cpustat.{cpu,iowait_total,avg1}`,
  `memory.{memtotal,memused,memavailable,arcsize}`,
  `network.{receive,transmit}_total`; storage `{total,used,avail,active}`; VM
  `{uptime,cpu,mem,maxmem,(netin,netout,diskread,diskwrite)_total,pressurecpusome,pressureiosome}`.
  Counters carry `_total` in the OTLP name itself (the plugin suffixes the
  name before the exporter sees it), which is why a bare `netin` never
  matched. Everything else the PVE plugin sends is dropped — it exports the
  raw `pvestatd` hashes, and that was 843 `proxmox_*` series (mostly per-disk
  `blockstat`) before the allowlist. App metrics have other `service.name`s and
  are untouched;
- NetworkPolicy `alloy-otlp-host` admits 4318 to the Alloy pods from RFC1918
  sources. That is defense in depth, not an allowlist: `Cluster` SNATs the
  client to a node address. The real boundary is the server VLAN (upstream
  firewall, owner-managed) plus the name allowlist.

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
allowlists (node-exporter and KSM defaults), and the extra scrapes above are
likewise allowlisted (`redis_*`, `certmanager_*`, `cloudflared_*`, `argocd_*`,
`DCGM_FI_DEV_*`, `up`).

**Trimmed 2026-11-06 (observability audit).** KSM no longer scrapes
`kube_pod_info` or `kube_pod_status_phase` (no rule or dashboard in infra@main
or here reads either), and the kubelet's unprefixed `storage_operation_*` and
`rest_client_requests_total` families are dropped at the write boundary —
about 585 series, the audit's 600–700 minus the ESO conditions it listed as
unused, which the `externalsecret_status_condition;Ready;False` keep rule
already excludes. `kube_pod_status_ready` stays: the CNPG readiness rules read
it.

**Two labels are ADDED, not dropped: `deployment_environment_name` and `env`.**
OTel resource attributes never become Prometheus labels, so app series carried no
environment and a dev/prod split needed a `target_info` join on `instance`. The
`env-label` data processor copies one resource attribute
(`deployment.environment.name`, set by the products as `DEPLOYMENT_ENV=dev|prod`)
onto the datapoints of the OTLP metrics pipeline, under BOTH names:

- `deployment_environment_name` — the spelling every dashboard, SLO and alert
  rule already queries, and the one the Adaptive Metrics rules keep
  (`keep_labels` in infra `live/adaptive-metrics`). Anything else is aggregated
  away, so `env` alone left dev and prod collapsed into one unlabelled series
  and per-env queries returned nothing.
- `env` — the MCP dashboard groups on it, and no `mcp_*` rule exists, so nothing
  aggregates it away.

Two labels with the same two values add no series; they only let one set of
series be queried both ways. The narrow alternative to the destination-level
`resourceToTelemetryConversion`, which promotes every resource attribute (pod
uid, process pid, host name) at once. The same chain also puts `env` on trace
resources (visible in Tempo) and app logs. A NEW rule for a family must add both
`deployment_environment_name` and `env` to its `keep_labels` (or use only the
former and drop the dashboard's `env` grouping).

## Verify after the sync (the SA runs this)

```bash
kubectl -n platform get ds,pods -l app.kubernetes.io/instance=alloy
kubectl -n platform get svc alloy-receiver          # 4317 + 4318 present
kubectl -n platform get svc alloy-otlp-host         # NodePort 30418 -> 4318
kubectl -n platform get networkpolicy alloy-otlp-host
kubectl -n platform logs -l app.kubernetes.io/name=alloy --tail=20 | grep -i error
```

In Grafana Cloud:

```promql
count by (env, job) ({cluster="qnsc-onprem", env=~".+"})          # app series carry env=dev|prod after the env-label processor (empty = regression)
up{cluster="qnsc-onprem", job="node"}                              # 1 per node
count by (__name__) ({cluster="qnsc-onprem", __name__=~"proxmox_.*"})  # PVE 9 host series
count by (job) ({cluster="qnsc-onprem", job=~"integrations/kubernetes/.*"})
cnpg_collector_up{cluster="qnsc-onprem"}                           # once pg-* exist
cnpg_pg_settings_setting{cluster="qnsc-onprem"}                    # ONLY name="max_connections"
sum by (cnpg_cluster) (cnpg_backends_total{cluster="qnsc-onprem"})  # client backends
```

Loki, node journal (kernel AppArmor denials only; empty is normal):
`{cluster="qnsc-onprem", job="integrations/kubernetes/journal"}`. Any line
that is NOT `apparmor="DENIED"` there means the filter regressed.

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
