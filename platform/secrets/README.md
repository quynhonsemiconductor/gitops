# platform/secrets

The platform's own credentials, as ExternalSecrets on the `kv-qnsc-platform`
ClusterSecretStore (ONPREM-PLAN §7.1). The platform is not a product, so these live
here and not in the chart.

```
grafana-cloud   <- platform-grafana-alloy (JSON; keys are Alloy's env var names).
                   Missing, Alloy CrashLoopBackOffs on a nil endpoint and no
                   telemetry exists
cloudflared     <- platform-cloudflared-qnsc-apps (plain string, the tunnel token).
                   Missing, cloudflared starts, connects to nothing, and every
                   route 502s with the cluster looking healthy
```

Ordering: the store goes Valid only after the hand-applied ESO service-principal
Secret exists (ONPREM-PLAN §14 step 2). Nothing that envFrom's these Secrets may
start before that.

The cluster name Alloy stamps on every series is a literal in
`../alloy/values-agent.yaml` (one cluster, no ENV substitution, no ConfigMap).
