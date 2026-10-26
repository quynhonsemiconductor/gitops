# Bootstrap — who installs the installer

§13 lists this as an unresolved unknown: *"ArgoCD's own bootstrap — the
chicken-and-egg: who installs the installer."* This is the answer, and it exists
so §13's rebuild rehearsal has a path to follow and time.

**Rehearsed 2026-10-26** on a local k3s (k3d, k3s 1.33, arm64 Mac) following
exactly these steps. What the rehearsal found, and where each fix landed:

```
products.yaml was not appliable   per-generator templates failed CRD
                                  validation; chart pins named a version that
                                  does not exist      → gitops PR #39 (fixed)
PreSync hook deadlock             the migrator Job hook ran before the chart's
                                  ServiceAccounts existed — into an empty
                                  namespace the hook can never start
                                                      → chart fix (PR, chart
                                                        v0.11.2): ServiceAccounts
                                                        are PreSync hooks on
                                                        wave -1
Alloy could not be applied        HOSTNAME duplicated the chart's default env;
                                  SSA rejects duplicates → gitops PR #41 (fixed)
Alloy could not schedule          platform namespace PSS restricted rejects the
                                  agent (hostPath /varlog, ebpf caps)
                                                      → gitops PR #43 (fixed)
CNPG ImageCatalog reference       `imageName: postgresql/18` is rejected by
                                  operator 1.30.1; use imageCatalogRef
                                                      → fixed in cnpg/imagecatalog.yaml
monitoring CRDs are bootstrap     the chart renders PrometheusRule; without the
                                  prometheus-operator CRDs (k8s-monitoring, M-2)
                                  every product sync fails at discovery
                                                      → gap, see step 7
```

Timings are at the bottom. This document now describes the ON-PREM bootstrap
(ONPREM-PLAN §14; the EKS-era procedure it replaces is at the bottom).

```bash
# 0. prerequisites — one k3s node per env (runbooks/server-setup.md), then:

# 1. namespaces + policy
kubectl apply -f ../namespaces/            # includes namespaces/onprem.yaml
kubectl apply -f ../policy/admission.yaml
kubectl apply -f ../policy/bindings.yaml   # a policy with no binding enforces
                                           # nothing, and nothing says so

# 2. ESO — the operator, then the stores
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n platform -f ../eso/values.yaml --version "$ESO_VERSION"
kubectl apply -f ../eso/stores-onprem.yaml # the four ClusterSecretStores. The
                                           # Azure stores go Valid only once the
                                           # hand-applied SP certificate Secrets
                                           # exist (§14 step 2 — see
                                           # stores-onprem.yaml's header for the
                                           # exact kubectl commands); cnpg-ca
                                           # stays NotReady until the clusters
                                           # exist, which is expected

# 3. cert-manager (before the barman plugin — its mTLS), then CNPG
helm upgrade --install cert-manager cert-manager/cert-manager \
  -n cert-manager --create-namespace \
  -f ../cert-manager/values.yaml --version "$CERT_MANAGER_VERSION"
helm upgrade --install cnpg cnpg/cloudnative-pg \
  -n platform -f ../cnpg/operator.yaml --version "$CNPG_VERSION"
kubectl apply -f ../cnpg/imagecatalog.yaml # data-prod and data-dev catalogs
#   ...and the first clusters themselves are NOT in git yet: the Cluster
#   manifests (pg-rova, pg-dev) are step §14-2's hand-applied Secrets' first
#   consumers and land with the dev cutover PR. The rehearsal used a minimal
#   dev Cluster with imageCatalogRef: {apiGroup: postgresql.cnpg.io,
#   kind: ImageCatalog, name: postgresql, major: 18}.

# 4. the data plane
kubectl apply -f ../valkey/
kubectl apply -f ../networkpolicy/

# 5. collectors + ingress connector
helm upgrade --install alloy-agent grafana/alloy \
  -n platform -f ../alloy/values-agent.yaml \
  --set-file alloy.configMap.content=../alloy/agent.alloy
#   REQUIRES step 1's platform namespace to be PSS-privileged (PR #43): the
#   agent mounts /var/log and needs the ebpf capabilities. The platform's own
#   credentials (../secrets/) must exist first — "Alloy CrashLoopBackOffs
#   without them, and cloudflared connects to nothing while the cluster looks
#   healthy":
sed -i "s/ENV/${ENV}/g" ../secrets/*.yaml   # .yaml ONLY — the directory also
                                            # carries this file's neighbours'
                                            # READMEs
kubectl apply -f ../secrets/
kubectl apply -f ../cloudflared/deployment.yaml   # the tunnel token is synced
                                                  # by ESO (§8) from the
                                                  # platform vault; until the
                                                  # store is Valid the pods sit
                                                  # in CreateContainerConfigError

# 6. ArgoCD — the last thing installed by hand
helm upgrade --install argocd argo/argo-cd \
  -n argocd --create-namespace -f values.yaml --version "$ARGOCD_VERSION"

# 7. cluster registration + monitoring CRDs — ArgoCD's dependencies, in its
#    namespace but applied by hand (see argocd/clusters.yaml for the dev/prod
#    Secrets; the dev endpoint and CA come from infra outputs, NOT a sed):
kubectl apply -f clusters.yaml
#   THE REHEARSAL GAP: nothing in git yet brings the prometheus-operator CRDs.
#   Every chart Application renders a PrometheusRule, and ArgoCD refuses to
#   sync when the API group cannot be discovered:
#     failed to discover server resources for group version
#     monitoring.coreos.com/v1: the server could not find the requested resource
#   On the EKS side these arrived with the metrics stack; on-prem they are
#   k8s-monitoring's (ONPREM-PLAN §12, M-2). Until M-2 lands, bootstrap needs
#   `prometheus-community/prometheus-operator-crds` installed at this step —
#   add it to THIS file when M-2 defines the real owner.

# 8. hand over. THE LAST MANUAL COMMANDS:
kubectl apply -f ../../appsets/products.yaml   # the generator. apps/root.yaml
                                               # DELIBERATELY excludes appsets/
                                               # (see root.yaml's comment), so
                                               # nothing else ever installs it
kubectl apply -f ../../apps/root.yaml          # the app of apps
```

From step 8 onward ArgoCD manages the AppProject, both ApplicationSets, every
product — and its own upgrades. (The ApplicationSet object itself is
hand-owned, like root: an app-of-apps that also manages the generators that
manage it is a cycle nobody enjoys debugging at 2am. Re-apply products.yaml by
hand after editing it.)

## What the rehearsal could NOT verify locally

```
Azure Key Vault stores   the SP certificate Secrets are operator stdin, and the
                         vaults exist only in the real tenant. The rehearsal
                         proved the ESO sync path with the provider's Fake
                         backend instead; the store shapes themselves are
                         validated against the CRDs only
remote telemetry         Alloy was installed with a local file sink and
                         cloudflared was dry-run validated, never started — a
                         rehearsal must not open a real tunnel or write to the
                         shared Grafana
rova/prod                a single node played both clusters; the prod generator
                         rows were created but never exercised
```

## Then time it, and write the number down

§13: *"**delete the dev cluster and rebuild it from git. Time it. Write the
number in this document.**"*

Rehearsal timing, 2026-10-26 (local k3d, images already cached — the real
figure is pull-bound and will be higher):

```
namespaces + policy                 instant
ESO + stores                        <1 min to Running
cert-manager + CNPG operator        ~2 min (webhook certs via cert-manager)
pg-dev Cluster to Ready             ~4 min (initdb on local-path storage)
valkey-dev                          <1 min
alloy                               <1 min after the PSS fix
argocd                              ~1 min to all pods Running
first product sync                  blocked by the hook deadlock until the
                                    ServiceAccounts existed; healthy path after
                                    the chart fix is hook (3s) + rollout (<2 min)
```

Until the rebuild has been done on the real node, §13's RTO figures remain
estimates and the document says so. The rehearsal also found what is NOT in git
— the list from §13, updated:

```
ArgoCD's own bootstrap     steps above, now rehearsed. Two of them failed as
                           written (appsets validation, chart pins) — fixes in
                           gitops PR #39
Secrets                    ESO first is what makes the ordering in steps 1-2
                           non-negotiable; the rehearsal confirmed ESO syncs
                           end-to-end once a store is Valid
cluster-scoped resources   CRDs, admission policies — and now KNOWN to include
                           the prometheus-operator CRDs (step 7, M-2 gap) and
                           cert-manager's CRDs (chart-managed, kept on
                           uninstall)
PersistentVolumeClaims     none in the chart; CNPG clusters DO create PVCs
                           (storage.size) — §13's "no PVCs anywhere" refers to
                           the app chart; pg backups/restore stay with the
                           barman plugin
```

## The ordering that is not arbitrary

```
namespaces before policy    the bindings select on qnsc.vn/tenant
policy before workloads     a workload admitted before the policy exists is not
                            re-checked when it appears
ESO before everything       ArgoCD's own OIDC secret is synced by ESO, and the
                            cloudflared token and grafana-cloud credentials are
                            ExternalSecrets — nothing that envFrom's a Secret
                            may start before a store is Valid
cert-manager before CNPG    the barman plugin's mTLS certificates
clusters.yaml before root   products.yaml's destination.name dev/prod resolves
                            against those Secrets; root first and every
                            Application reports "Cluster not found"
products.yaml before root   the generator must exist before the app-of-apps
                            reconciles, or the first reconcile finds an empty
                            project; both are one kubectl command apart
```

---

## The EKS-era procedure (superseded, kept for the AWS-exit window)

Replaced by everything above. Recorded so the AWS-exit PRs
([aws-exit track]) can delete the last references knowingly:

```bash
# infra/live/runtime-{dev,prod}   subnets /20 + prefix delegation
# infra/live/cluster-prod         FIRST, it outputs argocd_role_arn
# infra/live/cluster-dev          consumes it
argocd cluster add <dev-context> --name dev   # replaced by argocd/clusters.yaml
```

The IRSA annotations in `../eso/values.yaml`, `../secrets/` and
`../argocd/values.yaml` (the `qnsc-ENV-external-secrets` and `qnsc-prod-argocd`
roles) are inert on-prem — they are annotations nothing honours without the EKS
OIDC provider, and they come out with the identity PRs.
