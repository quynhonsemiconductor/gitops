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
argocd/        ArgoCD's Helm values (§5b), the bootstrap procedure, and the local-admin
               ExternalSecret
```

## Bootstrap (ONPREM-PLAN §14)

Hand steps and the wave order are in `argocd/bootstrap.md`. Apart from ArgoCD itself, the
`root` Application and the hand-made Secrets (ESO service principals, CNPG CA), every directory above is synced by an
`../apps/platform-*.yaml` Application. The CNPG CA is generated once and hand-applied
(`cnpg/ca.md`); there is no Reloader and no `ca-sync`.

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

And `versions.yaml` at the repo root pins every chart version here. **Verify each
one before the first install** — they were written 2026-09-15 and releases move.
