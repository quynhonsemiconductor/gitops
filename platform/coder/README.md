# platform/coder: Coder OSS for the VLSI workspaces

Design: product-docs `projects/vlsi-platform/00_DESIGN.md` §3, §5, §8, §9.
Owner decision 2026-11-02: option A, cloud-native; **go** (2026-11-06).

## What this Application owns

| File | Object |
|---|---|
| `values.yaml` | the Coder chart values (OCI `ghcr.io/coder/chart/coder`, 2.38.1) |
| `database.yaml` | `pg-coder` CNPG cluster, its three role Secrets, Coder's env Secret, the barman ObjectStore + nightly base backup |
| `dump.yaml` | nightly `pg_dump` to R2 `dumps/…/coder-YYYY-MM-DD.dump` |
| `restore-test.yaml` | the on-demand restore test (recover from the archive, sanity-check, delete) |
| `tls.yaml` | namespaced ACME Issuers (staging + prod) and the wildcard Certificate |
| `networkpolicy.yaml` | control-plane ingress (cloudflared only) and bounded egress |
| `../../apps/platform-coder.yaml` | the Application itself, sync wave 3 |

The namespace `coder` is declared in `../namespaces/onprem.yaml` with
`qnsc.vn/env: platform` (so its ExternalSecrets reach `kv-qnsc-platform`) and PSA
`baseline`.

## Version pin

2.38.1 (2026-10-20) is the newest patch of the stable 2.38 line that is older
than this repo's two-week age floor. 2.39.0 / 2.38.6 / 2.37.10 were all
published 2026-11-03. The OCI manifest digest
(`sha256:4c2be43f…`) is recorded in `versions.yaml`; Renovate can bump the tag,
the digest line is the cross-check.

## Owner prerequisites (values never in Git)

Create these plain-string secrets in **kv-qnsc-platform**:

| Key | Value |
|---|---|
| `coder-oidc-issuer-url` | `https://login.microsoftonline.com/<tenant>/v2.0` |
| `coder-oidc-client-id` | F's Coder app (client) id |
| `coder-oidc-client-secret` | that app's client secret |
| `coder-oidc-allowed-groups` | the `grp-qnsc-vlsi` object id |
| `coder-db-migrator` | hex password for `coder_migrator` — the role Coder connects as (DB owner, migrations) |
| `coder-db-readonly` | hex password for `coder_readonly` |
| `coder-r2-backup-access-key-id` / `-secret-access-key` | R2 token, bucket `qnsc-backups`, object read+write (barman) |
| `coder-r2-dump-access-key-id` / `-secret-access-key` | R2 token, `qnsc-backups`, object read+write (dump) |
| `coder-r2-ro-access-key-id` / `-secret-access-key` | R2 token, `qnsc-backups`, object read (restore test) |
| `coder-cloudflare-dns-api-token` | Cloudflare token, zone `qnsc.vn`, **DNS:Edit only** (ACME DNS-01) |

The Coder app's redirect URI must be `https://coder.qnsc.vn/api/v2/oauth2/callback`
(OIDC), and its group claim must carry `grp-qnsc-vlsi`; the allowed-groups value
above is the group object id.

## TLS

`tls.yaml` issues `coder.qnsc.vn` and `*.coder.qnsc.vn` through DNS-01 with the
**prod** issuer: one certificate for two names is far below Let's Encrypt's
rate limits, and a staging certificate is untrusted. The **staging** Issuer
stays defined for a manual end-to-end test of the DNS-01 wiring before the
first prod issuance — see `runbooks/vlsi.md`. A staging-issued Secret is never
the steady state; re-point `issuerRef` to `letsencrypt-prod` and sync.

A namespaced `Issuer` is used instead of a `ClusterIssuer`: the latter resolves
its API-token Secret in the cert-manager namespace, which would put the
Cloudflare token (and thereby the platform vault) in front of cert-manager. Same
DNS-01 mechanism, smaller blast radius.

## Reachability — still open (infra PR)

Coder must be reachable **only over WARP**, via the private route for
`coder.qnsc.vn` and `*.coder.qnsc.vn` in `infra live/edge` (design §10). This
PR does not add that tunnel rule. Until it lands the Service is ClusterIP and
`networkpolicy.yaml` admits only the
`platform/cloudflared` pods, so there is no path in and no public listener.

## Restore test

```sh
kubectl -n coder create job --from=cronjob/pg-coder-restore-test rt-$(date +%s)
kubectl -n coder logs -f job/<job>
kubectl -n coder get cm pg-coder-restore-test-result -o yaml
```

Use `REQUIRE_DATA=1` (patch the Job env) once real workspaces exist, so an
empty database cannot pass.

## Not here yet

- the workspace namespace, quota and NetworkPolicy (`vlsi-ws`, separate PR);
- the workspace template and its push job (separate PR);
- the quota alert (with `vlsi-ws`);
- the pg-coder restore test schedule: it stays suspended until the first manual
  PASS, like pg-rova's.
