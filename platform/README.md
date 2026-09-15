# platform/

Cluster bootstrap. Applied **once per cluster**, before any product.

Everything here is the platform's own plumbing, not a product — so it is not
rendered by the chart and does not go through §11's promotion. It is installed at
cluster creation and upgraded on §2b's quarterly cadence.

```
policy/        ValidatingAdmissionPolicy + bindings — §10 without a policy engine
namespaces/    labels that three separate mechanisms select on
eso/           External Secrets Operator — the operator only (§8)
keda/          KEDA + the TriggerAuthentication every SQS trigger needs (§4b)
alloy/         the two-tier collector — and the part §9b named but did not specify
```

## Apply order

```
1  namespaces/          the labels must exist before anything selects on them
2  policy/              admission.yaml THEN bindings.yaml — a policy with no
                        binding enforces nothing, and nothing says so
3  eso/ keda/           operators
4  alloy/               gateway first, then agent — the agent resolves the
                        gateway's DNS at startup
5  gitops/apps/root.yaml   ArgoCD takes over
```

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
eso/values.yaml     qnsc-ENV-external-secrets
keda/values.yaml    qnsc-ENV-keda
```

And `versions.yaml` at the repo root pins every chart version here. **Verify each
one before the first install** — they were written 2026-09-15 and releases move.
