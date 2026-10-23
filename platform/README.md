# platform/

Cluster bootstrap. Applied **once per cluster**, before any product.

Everything here is the platform's own plumbing, not a product — so it is not
rendered by the chart and does not go through §11's promotion. It is installed at
cluster creation and upgraded on §2b's quarterly cadence.

```
policy/        ValidatingAdmissionPolicy + bindings — §10 without a policy engine
namespaces/    labels that three separate mechanisms select on
eso/           External Secrets Operator — the operator only (§8);
               stores-onprem.yaml adds the FOUR on-prem ClusterSecretStores
               (§7.1): three Azure Key Vault vaults + the `cnpg-ca` stores
cert-manager/  on-prem chart values — required by the barman plugin's mTLS (§5.1)
cnpg/          on-prem CloudNativePG operator values + the Postgres 18.6
               ImageCatalog, pinned by digest (§6.3)
valkey/        the three on-prem StatefulSets — two caches, one broker (§6.4)
networkpolicy/ THE one on-prem NetworkPolicy: data-prod's ingress boundary (§6.2)
namespaces/onprem.yaml   the on-prem namespace set with `qnsc.vn/env` labels (§6.2)
alloy/         the host-side collector config — ONPREM-PLAN §12 replaces the
               EKS two-tier collector with one Alloy from the k8s-monitoring
               chart (platform PR, M-2)
clamd/         the shared antivirus daemon — §4c, task 2.7. Deployed but UNUSED
               until task 3.1 repoints qnsc-kb off its sidecar; not dead code
argocd/        ArgoCD's Helm values (§5b) and the cluster-registration Secrets so
               appsets/products.yaml's destination.name dev/prod resolves
```

## On-prem apply order (ONPREM-PLAN §14; supersedes the list below on-prem)

The order below is the EKS-era bootstrap. On the single k3s node the order is:

```
1  namespaces/onprem.yaml  the qnsc.vn/env labels select the ClusterSecretStores
2  policy/                 admission.yaml THEN bindings.yaml
3  eso/                    operator, then stores-onprem.yaml — the three Azure
                           stores go Valid only once the hand-applied SP
                           certificate Secrets exist (§14 step 2); cnpg-ca stays
                           NotReady until the clusters exist, which is expected
4  cert-manager/           before the barman plugin (its mTLS)
5  cnpg/                   operator + plugin, then imagecatalog.yaml
6  valkey/ + networkpolicy/  the data plane, bounded from day one
7  argocd/                 ArgoCD itself (§14 step 3)
8  gitops/apps/root.yaml   ArgoCD takes over; waves per §11.2

The CNPG CA is NOT a chart step: it is generated once and hand-applied with the
bootstrap Secrets (§14 step 2) — see cnpg/ca.md. There is no Reloader and no
ca-sync: the CA is static (2026-10-23 review, plan §5.6).
```

## EKS-era apply order (superseded on-prem)

```
1  namespaces/          the labels must exist before anything selects on them
2  policy/              admission.yaml THEN bindings.yaml — a policy with no
                        binding enforces nothing, and nothing says so
3  eso/                 operator
4  alloy/               one collector; nothing resolves another tier's DNS
                        (the gateway layer was removed 2026-10-20, ONPREM-PLAN §13)

5  cloudflared/         needs the tunnel token secret (on-prem:
                        `platform-cloudflared-qnsc-apps`, from kv-qnsc-platform,
                        ONPREM-PLAN §7.1). Ingress rules are REMOTELY MANAGED in
                        the Tunnel config owned by infra/live/onprem (§5.3) — the
                        connector only runs `tunnel run`; there is no Gateway
                        (removed 2026-10-20, ONPREM-PLAN §13) and nothing to
                        resolve in-cluster first.

6  clamd/               a plain workload, so it needs only its namespace (step 1)
                        and a schedulable node (step 0). Placed AFTER alloy so the
                        freshness exporter has a collector to be scraped by, and
                        BEFORE ArgoCD's takeover because it is bootstrap plumbing,
                        not a reconciled product. Idle until task 3.1 — see clamd/
7  argocd/              ArgoCD's OWN install and the credentials it needs to work:
   7a  helm install argo-cd -f argocd/values.yaml   (creates the argocd namespace)
   7c  argocd/clusters.yaml   the dev + prod cluster Secrets. AFTER 8a, because a
                        cluster Secret lives in the argocd namespace and ArgoCD must
                        exist to read it, and BEFORE 8, because products.yaml's
                        destination.name dev/prod resolves against these — install
                        root.yaml first and every Application reports
                        "Cluster not found" until these land
8  gitops/apps/root.yaml   ArgoCD takes over
```

## Scheduling

There is no node-class concept any more: the `karpenter.sh/capacity-type` selectors (Spot / on-demand) and the chart's `capacity` setting were removed
with EKS, because no k3s node carries that label and a pod that selects it stays `Pending`. The architecture is amd64 (the on-prem host,
Ryzen 9 9950X): the chart default is `defaults.arch: amd64`, no platform pod pins arm64 any more, and product images must be built `linux/amd64`
(multi-arch with arm64 while ECS still runs on Graviton).

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
