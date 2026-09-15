# cloudflared

The tunnel. §3.

## The one rule, and it never changes

Configure this once in the Cloudflare dashboard (or Terraform in `infra/live/edge`)
and then leave it:

```
hostname   *                          catch-all
service    http://qnsc-gateway.platform.svc.cluster.local:8080
```

**That is the entire tunnel configuration.** An earlier draft of §3 put per-product
routing here, and records why that was wrong:

> "seven products' routes in one ConfigMap makes ingress a **shared mutable file**,
> which is the opposite of the per-namespace ownership everything else here depends
> on — and it puts half the routing in Cloudflare rather than in the repository
> ArgoCD reconciles."

So routing lives in HTTPRoutes, in product namespaces, in git. The tunnel just
carries bytes to the Gateway.

## Why this also makes preview environments possible

§11's preview environments need a hostname per pull request. With routing here,
that would be a Cloudflare config edit per PR. With the catch-all plus a wildcard
DNS record:

```
*.preview.qnsc.vn  →  the tunnel  →  the Gateway  →  an HTTPRoute in the
                                                      preview namespace
```

**No per-PR tunnel edit.** §3 calls this "the second problem Gateway API solves,
and it arrives for previews rather than for canary."

## What is deliberately absent

```
an ALB or NLB          ~$16/month each, plus LCU charges, and it would accept a
                       public internet-facing endpoint. `enable_alb = false` was
                       already a deliberate choice on both shared ALBs
cert-manager           Cloudflare terminates TLS. Certificates are not a cluster
                       concern, so there is no ACME flow and no renewal to forget
a public IP            outbound only. "No inbound surface is the strongest
                       property of the current architecture" (§3)
per-product tunnels    14 pods and ~1 GiB of proxying, for no benefit
```

## The readiness/liveness split matters here

`/ready` reports **connector** health — whether cloudflared is connected to
Cloudflare's edge. That is a dependency, so it belongs on readiness and must not
be on liveness (§9j): a Cloudflare blip would otherwise kill all three replicas
and turn a degraded edge into a total outage.

Liveness uses `/metrics`, which answers only "is the process alive".

## If the tunnel ever stops being the right answer

§3 documents `ALB → Gateway` as a good design with two concrete triggers rather
than a vague preference:

```
a PUBLIC gRPC API      an ALB terminates HTTP/2 natively; a tunnel makes it fiddly
                       (§4d)
a latency SLA          tighter than the tunnel's 5-15 ms overhead (§9j)
```

Either swap touches only what is upstream of the Gateway. **No HTTPRoute, Service
or product changes** — which is why §3 was willing to choose the less conventional
option.
