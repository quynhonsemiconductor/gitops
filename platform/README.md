# platform/

Cluster bootstrap. Applied **once per cluster**, before any product.

Everything here is the platform's own plumbing, not a product — so it is not
rendered by the chart and does not go through §11's promotion. It is installed at
cluster creation and upgraded on §2b's quarterly cadence.

```
policy/        ValidatingAdmissionPolicy + bindings — §10 without a policy engine
namespaces/    labels that three separate mechanisms select on
eso/           External Secrets Operator — the operator only (§8)
alloy/         the two-tier collector — and the part §9b named but did not specify
clamd/         the shared antivirus daemon — §4c, task 2.7. Deployed but UNUSED
               until task 3.1 repoints qnsc-kb off its sidecar; not dead code
argocd/        ArgoCD's Helm values (§5b) and the cluster-registration Secrets so
               appsets/products.yaml's destination.name dev/prod resolves
```

## Apply order

```
1  namespaces/          the labels must exist before anything selects on them
2  policy/              admission.yaml THEN bindings.yaml — a policy with no
                        binding enforces nothing, and nothing says so
3  eso/                 operator
4  alloy/               gateway first, then agent — the agent resolves the
                        gateway's DNS at startup
5  gateway/             THE CLUSTER'S INGRESS, and it was missing from this list
                        entirely — the two components that let the cluster serve
                        traffic had no place in the order that installs everything
                        else.
   5a  gateway-api CRDs   kubectl apply the v1.6.2 standard-install manifest. The
                        Gateway and GatewayClass are CRs; without the CRDs
                        `kubectl apply` fails with "no matches for kind".
   5b  helm install envoy-gateway --namespace platform -f gateway/values-envoy.yaml
                        NOT the chart's default `envoy-gateway-system`. Envoy
                        Gateway runs its proxies in the controller's namespace, and
                        gateway/service.yaml selects those pods — a Service selects
                        only its OWN namespace, so proxies elsewhere give a Service
                        with no endpoints and a 502 nobody can place.
   5c  gateway/gateway.yaml + gateway/service.yaml
                        the Gateway, then the stable address the tunnel dials.

6  cloudflared/         needs `qnsc/<env>/platform/cloudflared-token`, which
                        `infra/live/cluster-<env>` now creates and fills from the
                        tunnel it owns. AFTER gateway/, because the connector's
                        ingress rule resolves gateway.platform.svc.cluster.local at
                        connect time and a connector that starts first reports ready
                        while 502-ing every request.

7  clamd/               a plain workload, so it needs only its namespace (step 1)
                        and a schedulable node (step 0). Placed AFTER alloy so the
                        freshness exporter has a collector to be scraped by, and
                        BEFORE ArgoCD's takeover because it is bootstrap plumbing,
                        not a reconciled product. Idle until task 3.1 — see clamd/
8  argocd/              ArgoCD's OWN install and the credentials it needs to work:
   8a  helm install argo-cd -f argocd/values.yaml   (creates the argocd namespace)
   8c  argocd/clusters.yaml   the dev + prod cluster Secrets. AFTER 8a, because a
                        cluster Secret lives in the argocd namespace and ArgoCD must
                        exist to read it, and BEFORE 9, because products.yaml's
                        destination.name dev/prod resolves against these — install
                        root.yaml first and every Application reports
                        "Cluster not found" until these land
9  gitops/apps/root.yaml   ArgoCD takes over
```

## Scheduling

There is no node-class concept any more: the `karpenter.sh/capacity-type` selectors (Spot / on-demand) and the chart's `capacity` setting were removed
with EKS, because no k3s node carries that label and a pod that selects it stays `Pending`. The architecture is amd64 (the on-prem host,
Ryzen 9 9950X): the chart default is `defaults.arch: amd64`, no platform pod pins arm64 any more, and product images must be built `linux/amd64`
(multi-arch with arm64 while ECS still runs on Graviton).

## The thing §9b named but did not specify

§9b says tail sampling *"needs every span of a trace to reach the same
collector"*, and that a DaemonSet cannot offer that. Correct — **and running the
gateway with two replicas behind an ordinary ClusterIP does not fix it either.**
Spans of one trace still land on whichever replica the connection picked.

The fix is in `alloy/agent.alloy`:

```alloy
otelcol.exporter.loadbalancing "gateway" {
  routing_key = "traceID"
  resolver { dns { hostname = "alloy-gateway.platform.svc.cluster.local" } }
}
```

with the gateway Service **headless**, so DNS returns every pod address.

**Without `routing_key = "traceID"` the gateway samples on fragments of traces and
fails quietly** — the output looks correct and is meaningless. It is the same
failure shape as §4d's gRPC argument arriving somewhere else: a normal Service
balances per connection, which is wrong whenever the thing being balanced has
affinity.

## Things that look wrong and are not

```
a CPU limit is FORBIDDEN     policy/admission.yaml rejects one. CFS quota throttles
                             on 100 ms bursts rather than averages, so an IO-bound
                             service is throttled at 20% average CPU — and it
                             presents as latency with no OOMKill and no alarm (§15d)

no ClusterSecretStore        §8 — one compromised namespace would read every
                             product's secrets. The per-namespace SecretStore is
                             rendered by the CHART, beside the workloads using it

the `platform` namespace is  the admission policies bind to qnsc.vn/tenant=product,
exempt from the policies     so ArgoCD, ESO and Alloy — upstream charts this estate
                             does not control — are not held to rules written for
                             our own services. Holding them would mean forking them

Loki gets FOUR labels        {cluster, namespace, app, level} and nothing else.
                             High-cardinality Loki labels are the single most
                             common way a small team turns a $50 bill into a
                             four-figure one (§9d)
```

## Before this is applied

Two placeholders must be replaced, and they are placeholders because §7c cannot
derive them — Identity Center and the cluster name mangle role ARNs:

```
eso/values.yaml          qnsc-ENV-external-secrets
argocd/clusters.yaml     DEV_CLUSTER_ENDPOINT  and  DEV_CLUSTER_CA_DATA — from
                         infra/live/cluster-dev, NOT a sed of ENV. The endpoint is
                         the existing `cluster_endpoint` output; the CA is NOT an
                         output yet and MUST be added (see below). The prod Secret
                         is in-cluster and needs no substitution.
```

And `versions.yaml` at the repo root pins every chart version here. **Verify each
one before the first install** — they were written 2026-09-15 and releases move.
