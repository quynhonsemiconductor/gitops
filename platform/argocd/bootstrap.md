# Bootstrap — who installs the installer

§13 lists this as an unresolved unknown: *"ArgoCD's own bootstrap — the
chicken-and-egg: who installs the installer."* This is the answer, and it exists
so §13's rebuild rehearsal has a path to follow and time.

```bash
# 0. prerequisites — the residency answer (§18), then:
#    infra/live/runtime-{dev,prod}   subnets /20 + prefix delegation
#    infra/live/cluster-prod         FIRST, it outputs argocd_role_arn
#    infra/live/cluster-dev          consumes it

# 1. the platform's own plumbing, in order
kubectl apply -f ../namespaces/
kubectl apply -f ../policy/admission.yaml
kubectl apply -f ../policy/bindings.yaml       # a policy with no binding enforces
                                               # nothing, and nothing says so

helm upgrade --install external-secrets external-secrets/external-secrets \
  -n platform -f ../eso/values.yaml --version "$ESO_VERSION"

kubectl apply -f ../cloudflared/deployment.yaml

# the platform's OWN credentials — Alloy CrashLoopBackOffs without them, and
# cloudflared connects to nothing while the cluster looks healthy
sed -i "s/ENV/${ENV}/g" ../secrets/*.yaml
kubectl apply -f ../secrets/

helm upgrade --install alloy-agent grafana/alloy -n platform \
  -f ../alloy/values-agent.yaml --set-file alloy.configMap.content=../alloy/agent.alloy
  # NOTE: the EKS-era alloy-gateway tier was removed 2026-10-20 (ONPREM-PLAN §13).
  # On-prem this whole file is superseded by ONPREM-PLAN §14 (bootstrap) and the
  # onprem platform PR (M-2), which replaces the two-tier collector with one
  # Alloy from the k8s-monitoring chart.

# 2. ArgoCD — the last thing installed by hand
helm upgrade --install argocd argo/argo-cd \
  -n argocd --create-namespace -f values.yaml --version "$ARGOCD_VERSION"

# 3. register the dev cluster, so ArgoCD can reach it (§5b)
argocd cluster add <dev-context> --name dev

# 4. hand over. THE LAST MANUAL COMMAND.
kubectl apply -f ../../apps/root.yaml
```

From step 4 onward ArgoCD manages the AppProject, both ApplicationSets, every
product — and its own upgrades.

## Then time it, and write the number down

§13: *"**delete the dev cluster and rebuild it from git. Time it. Write the number
in this document.**"*

Until that has been done, §13's RTO figures are estimates and the document says so.
The rehearsal is also the only way to find what is NOT in git — and §13 lists what
to look for:

```
ArgoCD's own bootstrap     the steps above. Now written down, not yet timed
Secrets                    values live in Secrets Manager, correctly — but ESO must
                           be installed and its IRSA role must exist BEFORE
                           anything syncs, which is why step 1 precedes step 2
cluster-scoped resources   CRDs, the admission policies, StorageClasses
PersistentVolumeClaims     none. §13's rule is no PVCs anywhere, which is what
                           lets Velero stay out of the design
```

## The ordering that is not arbitrary

```
namespaces before policy    the bindings select on qnsc.vn/tenant
policy before workloads     a workload admitted before the policy exists is not
                            re-checked when it appears
ESO before ArgoCD           ArgoCD's own OIDC secret is synced by ESO
cluster-prod before dev     dev's access entry needs prod's argocd_role_arn
```
