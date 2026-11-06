# VLSI workspaces (Coder): runbook

Design: product-docs `projects/vlsi-platform/00_DESIGN.md`. GitOps:
`platform/coder` (control plane, database, TLS), `platform/vlsi-ws` (quota,
isolation), `platform/coder/templates/vlsi-workspace` (template).

## Alert: VlsiWsQuotaNearFull

`limits.memory` or `pods` is above 85% of the `vlsi-ws` ResourceQuota for 15
minutes. New workspaces will fail to schedule on vlsi-01.

1. `kubectl -n vlsi-ws describe resourcequota vlsi-ws` — which resource is full.
2. `kubectl -n vlsi-ws get pods` — stop idle workspaces (`coder stop <workspace>`
   from a WARP-connected laptop).
3. If ten engineers regularly need more than eight concurrent workspaces, the
   node is undersized: re-measure and change `platform/vlsi-ws/quota.yaml` and
   design §7 together, not one without the other.

## Quota cannot be met / PVCs Pending

`local-path` writes to vlsi-01's container root (40 GB) until F mounts the
300 GB data disk (`sdb`). Until then the 100 GiB PVC quota cannot be satisfied.
Check `kubectl -n vlsi-ws get pvc` for `Pending` homes and confirm the mount
with `lsblk` on vlsi-01 before assuming a storage bug.

## Workspace does not connect

1. `kubectl -n vlsi-ws logs <pod> -c workspace` — agent URL/token errors.
2. From a workspace pod: `getent hosts coder.qnsc.vn` must return the
   `coder.coder.svc` address (CoreDNS override in
   `platform/vlsi-ws/coredns-coder.yaml`). If it resolves publicly, the
   override did not apply: `kubectl -n kube-system get configmap coredns-custom -o yaml`.
3. `kubectl -n coder logs deploy/coder` — OIDC/allowed-groups failures name the
   claim (`CODER_OIDC_GROUP_FIELD=groups`).

## Template push

`scripts/coder-push-template.sh` (CODER_URL/CODER_TOKEN from the environment).
The UI copy is never the source; a hand edit is overwritten on the next push.

## TLS: staging test, then prod

`tls.yaml` issues from **letsencrypt-prod** by default. The staging Issuer stays
defined to test the DNS-01 wiring (Cloudflare token, zone, solver) without
spending prod validity:

1. Point `Certificate.spec.issuerRef.name` at `letsencrypt-staging`, commit, sync.
2. `kubectl -n coder get certificate coder-tls -w` until Ready; the secret is
   untrusted by browsers, which is expected.
3. Point it back at `letsencrypt-prod`, sync. cert-manager re-issues in place.
   Delete a staging-issued `coder-tls` only after the prod one is Ready.

## Storage gate before the first workspace (vlsi-01)

`local-path` enforces NO size: a PVC larger than the filesystem provisions
anyway and the pod fails or fills the disk. vlsi-01's 300 GB data disk (`sdb`)
is mounted by F in the #428 window. **Do not push the template or start a pilot
until this passes on vlsi-01:**

```sh
ssh <vlsi-01> "findmnt -rno SOURCE,FSTYPE,TARGET --target /var/lib/rancher/k3s/storage"
# must show /dev/sdb (or a partition of it) as SOURCE
```

`scripts/coder-push-template.sh` refuses to push unless `VLSI_NODE_SSH` answers
that check with sdb.

