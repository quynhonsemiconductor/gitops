# platform/coder: Coder OSS for the VLSI workspaces

Design: product-docs `projects/vlsi-platform/00_DESIGN.md` §3, §5, §8, §9.
Owner decision 2026-11-02: option A, cloud-native; **go** (2026-11-06).

## What this Application owns

| File | Object |
|---|---|
| `values.yaml` | the Coder chart values (OCI `ghcr.io/coder/chart/coder`, 2.38.1) |
| `database.yaml` | the two role password Secrets (from kv-qnsc-platform, mirrored into data-prod) and Coder's env Secret (`CODER_PG_CONNECTION_URL`, OIDC) |
| `tls.yaml` | namespaced ACME Issuers (staging + prod) and the wildcard Certificate |
| `networkpolicy.yaml` | control-plane ingress (cloudflared only) and bounded egress (incl. pg-coder in data-prod) |
| `../../apps/platform-coder.yaml` | the Application itself, sync wave 3 |

The database is **not** in this namespace. `pg-coder` runs in data-prod with
pg-rova/pg-opshub/pg-kb (SA decision 2026-11-06, R2 token audit), deployed by
`apps/platform-data-coder-prod.yaml` from `../data/coder-prod/`:

| File (data-prod) | Object |
|---|---|
| `pg-coder.yaml` | the CNPG cluster: 5 Gi + 2 Gi WAL on `local-path-retain`, roles `coder_migrator` (database owner, no CREATEROLE/SUPERUSER) and `coder_readonly` (`pg_read_all_data`, the dump role) |
| `pg-coder-backup.yaml` | barman-cloud ObjectStore -> `s3://qnsc-backups/pg-coder/` and the nightly base backup (19:45 UTC) |
| `pg-coder-dump.yaml` | nightly `pg_dump -Fc` to `dumps/…/coder-YYYY-MM-DD.dump`, uploading with the SHARED data-prod dump Secret `pg-dump-r2` |
| `restore-test-coder.yaml` | the on-demand restore test in namespace `restore-test` (recover, sanity-check, delete) |
| `role-secrets.yaml` | copies of the two role Secrets from namespace `coder` through the `coder-db-secrets` kubernetes store (narrow RBAC) |

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
| `coder-cloudflare-dns-api-token` | Cloudflare token, zone `qnsc.vn`, **DNS:Edit only** (ACME DNS-01) |

**Seven secrets, not fourteen.** There are no `coder-r2-*` keys: pg-coder lives
in data-prod, so barman, the dump and the restore test read the prod R2
credentials that already exist there (`r2-backup-rw` / `r2-dump-rw` /
`r2-backup-ro` in kv-qnsc-prod). One token per role, rotated in one vault.

The two DB passwords stay here (the platform vault) because namespace `coder`
assembles `CODER_PG_CONNECTION_URL` from them; `platform/data/coder-prod/role-secrets.yaml`
mirrors the same Secrets into data-prod for CNPG through a kubernetes-provider
store whose RBAC is limited to those two Secret names — one source of truth, no
second vault copy.

### Owner step: the database CA

Before `platform-data-coder-prod` syncs, create the shared prod CA for this
cluster (same one every prod database uses):

```sh
./platform/bootstrap/cluster.sh --env prod --pg-cluster pg-coder   # pg-coder-ca / pg-coder-ca-pub in data-prod
```

Without it the Cluster cannot issue certificates and never becomes Ready.

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
kubectl -n restore-test create job --from=cronjob/pg-coder-restore-test rt-$(date +%s)
kubectl -n restore-test logs -f job/<job>          # ends RESTORE-TEST: PASS|FAIL
kubectl -n restore-test get cm pg-coder-restore-test-result -o yaml
```

Use `REQUIRE_DATA=1` (patch the Job env) once real workspaces exist, so an
empty database cannot pass. The Job restores into `restore-test`, never into
data-prod, and deletes the throwaway cluster on exit.

## Not here yet

- the workspace namespace, quota and NetworkPolicy (`vlsi-ws`, separate PR);
- the workspace template and its push job (separate PR);
- the quota alert (with `vlsi-ws`);
- the pg-coder restore test schedule: it stays suspended until the first manual
  PASS, like pg-rova's.
