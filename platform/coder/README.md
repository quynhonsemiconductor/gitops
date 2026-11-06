# platform/coder: Coder OSS for the VLSI workspaces

Design: product-docs `projects/vlsi-platform/00_DESIGN.md` §3, §5, §8, §9.
Owner decision 2026-11-02: option A, cloud-native; **go** (2026-11-06).

## What this Application owns

| File | Object |
|---|---|
| `values.yaml` | the Coder chart values (OCI `ghcr.io/coder/chart/coder`, 2.38.1) |
| `database.yaml` | Coder's env Secret (`CODER_PG_CONNECTION_URL`, OIDC) |
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

`pg-coder.yaml` also carries the two role password ExternalSecrets, read from
kv-qnsc-prod like every other prod database's.

The namespace `coder` is declared in `../namespaces/onprem.yaml` with
`qnsc.vn/env: prod` (SA decision 2026-11-06: Coder is a production service for
the VLSI team, so its ExternalSecrets read `kv-qnsc-prod`, the same vault as its
database) and PSA `baseline`.

## Version pin

2.38.1 (2026-10-20) is the newest patch of the stable 2.38 line that is older
than this repo's two-week age floor. 2.39.0 / 2.38.6 / 2.37.10 were all
published 2026-11-03. The OCI manifest digest
(`sha256:4c2be43f…`) is recorded in `versions.yaml`; Renovate can bump the tag,
the digest line is the cross-check.

## Owner prerequisites (values never in Git)

Create these plain-string secrets in **kv-qnsc-prod**:

| Key | Value |
|---|---|
| `coder-oidc-issuer-url` | `https://login.microsoftonline.com/<tenant>/v2.0` |
| `coder-oidc-client-id` | F's Coder app (client) id |
| `coder-oidc-client-secret` | that app's client secret |
| `coder-oidc-allowed-groups` | the `grp-qnsc-vlsi` object id |
| `coder-db-migrator` | hex password for `coder_migrator` — the role Coder connects as (DB owner, migrations) |
| `coder-db-readonly` | hex password for `coder_readonly` |
| `coder-cloudflare-dns-api-token` | Cloudflare token, zone `qnsc.vn`, **DNS:Edit only** (ACME DNS-01) |

**Seven secrets, not fourteen, all in one vault.** There are no `coder-r2-*`
keys: pg-coder lives in data-prod, so barman, the dump and the restore test read
the prod R2 credentials that already exist there (`r2-backup-rw` / `r2-dump-rw`
/ `r2-backup-ro`). The two DB passwords are here too, read by the cluster's own
ExternalSecrets in data-prod. Nothing is copied between vaults and rotating any
of them touches one place.

The owner script (`secrets.sh --product coder --env prod --vault-app
kv-qnsc-prod`) creates the seven; the earlier `kv-qnsc-platform` copies are
deleted after they sync.

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
Cloudflare token (and thereby the prod vault's read path) in front of
cert-manager. Same DNS-01 mechanism, smaller blast radius.

## Reachability — still open (infra PR)

Coder must be reachable **only over WARP**, via the private route for
`coder.qnsc.vn` and `*.coder.qnsc.vn` in `infra live/edge` (design §10). This
PR does not add that tunnel rule. Until it lands the Service is ClusterIP and
`networkpolicy.yaml` admits only the
`platform/cloudflared` pods, so there is no path in and no public listener.

## Workspace template

`templates/vlsi-workspace/main.tf` is the template: one pod on `pool=vlsi`,
the `qnsc-eda` digest, a 10 GiB `/home` PVC on `local-path-retain`, request
0.5 CPU / 1.5 GiB and limit 4 CPU / 6 GiB (the `vlsi-ws` quota), TTL 2 h with
the agent's activity bump. Apps: VS Code (`code-server`, browser) and Surfer
web (`surver` on 8080); KasmVNC is deliberately absent.

The image is `ghcr.io/quynhonsemiconductor/qnsc-eda` pinned by digest
(`sha256:e3ad00a1…`, E's build on main, 2026-11-06; amd64/linux, `USER 1001`).
The package is PUBLIC — anonymous `docker manifest inspect` was verified — so
no pull secret is needed; a new digest is a reviewed edit of `main.tf`.

Pushed from Git, never edited in the UI:

```sh
export CODER_URL=https://coder.qnsc.vn          # over WARP
export CODER_TOKEN=...                          # coder tokens create; vault/ESO, never Git
./scripts/coder-push-template.sh
```

The script runs the pinned `ghcr.io/coder/coder:2.38.1` CLI in Docker, pushes
the directory, activates the version and sets the TTL metadata. A CI job can
call the same script with the token delivered by ESO; the token is read from
the environment, never argv or output.

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
