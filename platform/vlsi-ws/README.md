# platform/vlsi-ws: the VLSI workspace namespace

Design `product-docs/projects/vlsi-platform/00_DESIGN.md` §3, §5.1, §7, §8.
The namespace is declared in `../namespaces/onprem.yaml` (no `qnsc.vn/env`
label, so no ESO store admits it). This directory adds the policy.

| File | Object |
|---|---|
| `quota.yaml` | `ResourceQuota` cap + `LimitRange` defaults/ceiling |
| `networkpolicy.yaml` | no ingress; egress DNS + Coder + internet minus RFC 1918 |
| `prometheusrule.yaml` | `VlsiWsQuotaNearFull` (limits.memory or pods over 85% for 15 min) |
| `../../apps/platform-vlsi-ws.yaml` | the Application (wave 2) |

## Sizing (vlsi-01 at 16 GiB, ~14 GiB usable)

Per workspace: **request 0.5 CPU / 1.5 GiB, limit 4 CPU / 6 GiB** (template
defaults). What the quota allows:

| Bound | Quota | Fits |
|---|---|---|
| memory requests | 12 GiB | **8 concurrent workspaces** (8 x 1.5 GiB) |
| memory limits | 14 GiB | **2 concurrent heavy builds** (2 x 6 GiB + tooling) |
| pods | 10 | 10 |
| CPU requests | 4 | 8 x 0.5 |
| CPU limits | 24 | 6 x 4 at the busiest |
| PVC | **10 x 10 GiB = 100 GiB** | local-path-retain; one home per engineer |

Ten engineers each get a PVC that survives the workspace. Ten CONCURRENT
workspaces do not fit the node's memory: eight do by request, and the ninth
waits for an idle one to stop (TTL ~2 h). A failed schedule is visible and
reversible, unlike overcommitting the node. Re-measure after two weeks and
adjust here (design §7 is the one place the numbers live).

**Storage:** local-path writes to the container root by default. vlsi-01's
300 GB data disk (`sdb`) is NOT mounted yet; F will mount it. Until then only
the 40 GB root exists, so the 100 GiB quota cannot be met. The quota is sized
against the 300 GB data disk: 100 GiB of homes, the rest for images/scratch.

## Network

- **Ingress: none.** The Coder agent connects out; app proxying, `coder ssh`
  and port-forward ride that connection.
- **Egress:** kube-dns; the Coder server pod (`app.kubernetes.io/name: coder`)
  in the `coder` namespace on 80/443/8080/8443; the public internet minus 10/8,
  172.16/12, 192.168/16, 100.64/10 and 169.254/16. GitHub and package mirrors
  are public; the LAN, the nodes and the data/product namespaces are not
  reachable.

## Alert

`VlsiWsQuotaNearFull` (P2, warning) fires when `limits.memory` or `pods` is
above 85% of the ResourceQuota for 15 minutes. Routing labels mirror
`platform/clamd` (`product: vlsi`, `env: platform`, `component: coder`,
`runbook_url`). The KSM `kube_resourcequota` family is added to the Alloy
allowlist in `platform/alloy/k8s-monitoring.values.yaml` in this same PR —
without it the series never reached Mimir and the alert could not fire. It adds
one series per (namespace, resource, type); at ~6.3k series target this is a
negligible addition, to be confirmed on the first scrape after merge.

## Owner check

```sh
kubectl -n vlsi-ws describe resourcequota vlsi-ws
kubectl -n vlsi-ws get limitrange vlsi-ws -o yaml
kubectl -n vlsi-ws get networkpolicy vlsi-ws-isolation -o yaml
```
