# platform/coder: Coder OSS for the VLSI workspaces

Design: product-docs `projects/vlsi-platform/00_DESIGN.md` §3, §5, §8, §9.
Owner decision 2026-11-02: option A, cloud-native; **go** (2026-11-06).

## What this Application owns

| File | Object |
|---|---|
| `values.yaml` | the Coder chart values (OCI `ghcr.io/coder/chart/coder`, 2.38.6) |
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

2.38.6 (2026-11-03) is the newest patch of the stable 2.38 line (2.39 is
mainline). It is younger than this repo's 14-day release-age floor, but the
bump is deliberate: the release carries the gomarkdown GHSA-cv23-7vc5-jfh7
fix, CSRF exemption-pattern anchoring, org-scoped OIDC group sync and a
go-jose bump. `coder server --help` and the chart's default values are
identical between 2.38.1 and 2.38.6, and there are no new database migrations.
The OCI manifest digest (`sha256:b38e8746…`) is recorded in `versions.yaml`;
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

### First sign-in (the Owner)

Entra OIDC is the ONLY listed provider: `CODER_OAUTH2_GITHUB_DEFAULT_PROVIDER_ENABLE=false`
and `CODER_EXTERNAL_AUTH_GITHUB_DEFAULT_PROVIDER_ENABLE=false` remove the GitHub OAuth2 app and
the default GitHub external-auth provider that the 2.38 line otherwise
injects, and `CODER_DISABLE_PASSWORD_AUTH=true` closes password accounts. Steps:

1. Open `https://coder.qnsc.vn` over WARP and click **Sign in with Microsoft**
   (the OIDC button; `CODER_OIDC_SIGN_IN_TEXT`).
2. Sign in with an Entra account whose groups claim carries `grp-qnsc-vlsi`
   (`CODER_OIDC_ALLOWED_GROUPS` + `CODER_OIDC_GROUP_FIELD=groups`). The email is
   read from the `upn` claim and must end in `@qnsc.vn` (`CODER_OIDC_EMAIL_FIELD`,
   `CODER_OIDC_EMAIL_DOMAIN`), and `email_verified` is ignored because Entra v2
   tokens do not carry it (`CODER_OIDC_IGNORE_EMAIL_VERIFIED`, Coder's documented
   Microsoft setting). A guest/B2B identity fails both the domain and the group
   checks.
3. **The first successful sign-in becomes the Owner.** No extra env or command:
   `coderd/userauth.go` assigns `rbac.RoleOwner()` when `userCount == 0` (the
   same branch that creates the OIDC user; verified on 2.38.1 and unchanged in
   2.38.6). After that, `/setup` is gone and
   every further OIDC sign-in is a normal member unless promoted.
4. Promote the second owner: as the first owner, `coder` CLI or the UI adds the
   `owner` role to the next account (the group claim already gates who may sign in).

### Break-glass

`CODER_DISABLE_PASSWORD_AUTH=true` refuses **every** password login in the 2.38
line, Owner included — verified on 2.38.1 and the check is unchanged in 2.38.6
(`POST /api/v2/users/login` for the break-glass Owner
returns "Password authentication is disabled."; the `--help` sentence that implies
Owners are exempt does not hold). The account and the password are therefore useless
until the flag is flipped, so the procedure is:

1. Entra/OIDC unusable or no Owner can sign in →
   **merge a one-line PR setting `CODER_DISABLE_PASSWORD_AUTH=false`**
   (the flag's value in `values.yaml`; nothing else changes).
2. Sign in as the break-glass account (`coder-breakglass`) with the mailbox and
   password from the 1Password item **`Coder - break-glass owner`**. Only this
   account has a password; OIDC users are `login_type=oidc` and cannot use one.
3. Fix the problem, promote/link the real owner, then **merge the revert PR**
   (`true` again) immediately. Two PRs are opened together for exactly this.

The account was created directly in the database with the pinned image's own
subcommand, inside the running pod, so the password was prompted on stdin and never
landed in argv or shell history:

```sh
kubectl -n coder exec -i deploy/coder -- \
  coder server create-admin-user \
    --postgres-url "$CODER_PG_CONNECTION_URL" \
    --email <break-glass mailbox> --username coder-breakglass
```

Do not re-enable password auth as a steady state.

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

`templates/vlsi-workspace/main.tf` is the template: one pod on `qnsc.vn/pool=vlsi`,
the `qnsc-eda` digest, a 10 GiB `/home` PVC on `local-path-retain`, request
0.5 CPU / 1.5 GiB and limit 4 CPU / 6 GiB (the `vlsi-ws` quota), TTL 2 h with
the agent's activity bump. Apps: VS Code (`code-server`, browser) and Surfer
**web** — the project's static WASM bundle from the image (`/opt/surfer-web`),
served on 127.0.0.1:8080 by `python3 -m http.server`; the image's `surver` is a
waveform *server* needing file arguments, not a web UI, so it is not started
(KasmVNC absent by design).

Opening waveforms: the served copy carries a `waves -> $HOME` symlink, so from
the Surfer app a user opens `?load_url=waves/sim/foo.fst` and the browser loads
`~/sim/foo.fst`. Only that copy is proxied; the rest of `$HOME` is reachable
only through the `waves` link. `surver` stays available for large files a user
chooses to serve by hand.

VS Code Desktop and "Connect via SSH" appear on the agent because Coder
advertises them: both tunnel through the workspace agent (Coder's own SSH, not
node SSH), so they are left enabled; access still needs a Coder session and the
workspace ACL.

The image is `ghcr.io/quynhonsemiconductor/qnsc-eda` pinned by digest
(`sha256:97480692…`, E's main build after qnsc-eda#4, 2026-11-07;
amd64/linux, code-server 4.145.0, `/opt/surfer-web`, `USER 1001:1001`,
`HOME=/home/coder`). The PVC, the explicit `HOME` env and code-server's
`?folder=` all use `/home/coder`. The package is PUBLIC — anonymous
`docker manifest inspect` was verified — so no pull secret is needed; a new
digest is a reviewed edit of `main.tf`.

Pushed from Git, never edited in the UI:

```sh
export CODER_URL=https://coder.qnsc.vn          # over WARP
export CODER_SESSION_TOKEN=...                  # coder tokens create; vault/ESO, never Git
                                                # (CODER_TOKEN is accepted as an alias)
export VLSI_NODE_SSH=qnsc@vlsi-01               # storage gate: local-path must be on sdb
./scripts/coder-push-template.sh
```

The script runs the pinned `ghcr.io/coder/coder:2.38.6` CLI in Docker (with
`--entrypoint /opt/coder`: the image entrypoint already runs `coder server`),
pipes the directory in over stdin so nothing on the host is writable from the
container, activates the version and sets the 2 h default TTL. Provider pins come
from the committed `.terraform.lock.hcl`. There is no max-TTL on OSS 2.38.6
(`--max-ttl` is absent from `templates edit --help`), so the 2 h default plus the
agent's activity bump is the policy. A CI job can
call the same script with the token delivered by ESO; the token is read from
the environment and passed to the container by NAME (`-e CODER_SESSION_TOKEN`,
the variable the Coder CLI actually reads), never argv or output.

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
