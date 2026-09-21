# platform/

Cluster bootstrap. Applied **once per cluster**, before any product.

Everything here is the platform's own plumbing, not a product — so it is not
rendered by the chart and does not go through §11's promotion. It is installed at
cluster creation and upgraded on §2b's quarterly cadence.

```
compute/       NodeClass + NodePools — §2's node pools, which nothing created
policy/        ValidatingAdmissionPolicy + bindings — §10 without a policy engine
namespaces/    labels that three separate mechanisms select on
eso/           External Secrets Operator — the operator only (§8)
keda/          KEDA + the TriggerAuthentication every SQS trigger needs (§4b)
alloy/         the two-tier collector — and the part §9b named but did not specify
clamd/         the shared antivirus daemon — §4c, task 2.7. Deployed but UNUSED
               until task 3.1 repoints qnsc-kb off its sidecar; not dead code
argocd/        ArgoCD's Helm values (§5b), the two cluster-registration Secrets so
               appsets/products.yaml's destination.name dev/prod resolves, and the
               ECR credential refresher that keeps the chart registry authenticated
               past the 12-hour token expiry (§11c)
```

## Apply order

```
0  compute/             BEFORE EVERYTHING, including ArgoCD. Nothing schedules
                        without it — see below
1  namespaces/          the labels must exist before anything selects on them
2  policy/              admission.yaml THEN bindings.yaml — a policy with no
                        binding enforces nothing, and nothing says so
3  eso/ keda/           operators
4  alloy/               gateway first, then agent — the agent resolves the
                        gateway's DNS at startup
5  clamd/               a plain workload, so it needs only its namespace (step 1)
                        and a schedulable node (step 0). Placed AFTER alloy so the
                        freshness exporter has a collector to be scraped by, and
                        BEFORE ArgoCD's takeover because it is bootstrap plumbing,
                        not a reconciled product. Idle until task 3.1 — see clamd/
6  argocd/              ArgoCD's OWN install and the credentials it needs to work:
   6a  helm install argo-cd -f argocd/values.yaml   (creates the argocd namespace)
   6b  argocd/ecr-credential.yaml   the repository Secret + refresher CronJob. Can
                        go on immediately — the Secret is seeded empty and the
                        CronJob fills it within 6h; nothing syncs before 6c anyway
   6c  argocd/clusters.yaml   the dev + prod cluster Secrets. AFTER 6a, because a
                        cluster Secret lives in the argocd namespace and ArgoCD must
                        exist to read it, and BEFORE 7, because products.yaml's
                        destination.name dev/prod resolves against these — install
                        root.yaml first and every Application reports
                        "Cluster not found" until these land
7  gitops/apps/root.yaml   ArgoCD takes over
```

## Step 0 is not a preference

`infra/live/cluster-{dev,prod}` enable EKS Auto Mode with
`node_pools = ["general-purpose"]`. AWS documents that built-in pool as **amd64
only, on-demand only, and not modifiable** — you can enable or disable it, nothing
else. `system` supports arm64 but carries a `CriticalAddonsOnly` taint and §2
deliberately does not enable it.

Every pod in this directory asks for something that pool cannot provide:

```
argocd/values.yaml          karpenter.sh/capacity-type: spot
eso/values.yaml             karpenter.sh/capacity-type: spot
keda/values.yaml            karpenter.sh/capacity-type: spot
alloy/values-gateway.yaml   karpenter.sh/capacity-type: spot
gateway/values-envoy.yaml   karpenter.sh/capacity-type: spot
cloudflared/deployment.yaml arch: arm64 AND capacity-type: spot
```

So without `compute/` applied first, **ArgoCD itself never schedules** — and
`apps/root.yaml`, the one thing installed by hand, is an Application with nothing
running to reconcile it. The symptom is `Pending` with `0/N nodes are available:
node(s) didn't match Pod's node affinity/selector`, which reads like a broken
manifest rather than a missing node pool.

`ci/scripts/platform_conformance.py --only schedulable` is the guard: it fails if
any rendered `nodeSelector` in this repository has no pool that can satisfy it.

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

no ClusterTriggerAuthentication   same argument. keda-irsa exists per namespace

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
compute/nodeclass.yaml   qnsc-ENV-node  and  qnsc-platform-ENV  and
                         kubernetes.io/cluster/qnsc-ENV
compute/nodepools.yaml   (no placeholders, but the LIMITS differ per environment)
eso/values.yaml          qnsc-ENV-external-secrets
keda/values.yaml         qnsc-ENV-keda
argocd/clusters.yaml     DEV_CLUSTER_ENDPOINT  and  DEV_CLUSTER_CA_DATA — from
                         infra/live/cluster-dev, NOT a sed of ENV. The endpoint is
                         the existing `cluster_endpoint` output; the CA is NOT an
                         output yet and MUST be added (see below). The prod Secret
                         is in-cluster and needs no substitution.
argocd/ecr-credential.yaml   no string placeholders, but depends on the IRSA role
                         qnsc-prod-argocd-ecr, which infra/live/cluster-prod must
                         create (see below)
```

### Infra dependencies these introduce (not fixable in gitops)

Two things live outside this repository and must be added by whoever owns infra
before ArgoCD can manage dev or pull the chart:

```
cluster-dev CA output    argocd/clusters.yaml needs dev's API-server CA to verify
                         TLS (endpoint_public_access is false — no public cert
                         chain). infra/live/cluster-dev/outputs.tf exports
                         cluster_endpoint but NOT the CA. Add:
                           output "cluster_certificate_authority_data" {
                             value = aws_eks_cluster.this.certificate_authority[0].data
                           }
                         Until then, dev registration cannot be completed — the
                         placeholder stands and dev never syncs.

qnsc-prod-argocd-ecr     the IRSA role the ECR refresher CronJob assumes. Created
   (IAM role)            by infra/live/cluster-prod (like qnsc-prod-external-secrets
                         and qnsc-prod-keda). Trust: web-identity on the prod OIDC
                         provider, subject
                         system:serviceaccount:argocd:argocd-ecr-refresher.
                         Permissions: ecr:GetAuthorizationToken on "*" (account-
                         level), plus ecr:GetDownloadUrlForLayer, ecr:BatchGetImage,
                         ecr:BatchCheckLayerAvailability on the chart repository
                         arn:aws:ecr:ap-southeast-1:608983206583:repository/charts/qnsc-service.
```

`compute/nodeclass.yaml` has one value that is NOT derived from this estate's own
code — the cluster security group, matched on
`kubernetes.io/cluster/qnsc-ENV: owned`, which is an AWS naming convention. Verify
it before the first install, because a NodeClass whose selectors match nothing
fails at **runtime**, silently, not at admission:

```
aws ec2 describe-security-groups \
  --filters Name=tag:kubernetes.io/cluster/qnsc-ENV,Values=owned \
  --query 'SecurityGroups[].{id:GroupId,name:GroupName}'
```

One result, named `eks-cluster-sg-qnsc-ENV-*`. Zero results means the tag key
differs on your cluster and no node will ever launch.

And `versions.yaml` at the repo root pins every chart version here. **Verify each
one before the first install** — they were written 2026-09-15 and releases move.
