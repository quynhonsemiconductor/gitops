# Namespace labels are load-bearing

Three separate mechanisms select on them, and each fails SILENTLY if a label is
missing — which is the reason they are created here rather than by `CreateNamespace=true`.

```
pod-security.kubernetes.io/enforce: restricted   §10 — Pod Security Standards
qnsc.vn/tenant: product                          §4b — what `expose: cluster`
                                                 NetworkPolicies select on, and
                                                 what binds the admission policies
kubernetes.io/metadata.name                      set by Kubernetes. The DNS and
                                                 gateway NetworkPolicies use it
```

A namespace without `qnsc.vn/tenant: product` gets **no admission policy and no
cross-namespace ingress**. Nothing errors; the workload simply runs unguarded and
cannot be reached from `platform`. That is a bad failure mode, so the labels are
declared, not inherited.
