# platform/secrets

The platform's own credentials. **BUG FOUND IN REVIEW:** `platform/` referenced
three things nothing created, and each would have failed differently and
confusingly on first apply.

```
grafana-cloud   Alloy's agent and gateway both read it via envFrom. Missing, the
                pods CrashLoopBackOff on a nil endpoint and no telemetry exists —
                which is the 2026-09-06 blackout arriving on day one
cloudflared     the tunnel token. Missing, cloudflared starts, connects to
                nothing, and every route 502s with the cluster looking healthy
cluster-info    a ConfigMap, not a secret. Alloy stamps `cluster` as an external
                label from it; without it every metric from dev and prod lands
                under the same series
```

These are the platform's own, so they live here rather than in the chart — which
renders a `SecretStore` and `ExternalSecret` per PRODUCT namespace (§8), and the
platform is not a product.

## The bootstrap ordering this creates

ESO must be installed **and** its IRSA role must exist before these sync, and Alloy
must not start before they exist. `platform/argocd/bootstrap.md` already orders it
that way; §13 lists this exact trap among the things a rebuild rehearsal is meant
to find:

> "Secrets — values live in Secrets Manager, correctly — but ESO must be installed
> and its IRSA role must exist before anything syncs."
