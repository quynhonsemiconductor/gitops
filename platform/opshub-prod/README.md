# opshub production: enabled (go-live 2026-11-04)

Mirror of the rova prod layer. The two Applications live in `apps/platform-opshub-prod.yaml`
(root syncs `apps/*.yaml`), so pg-opshub, valkey-opshub, the backup/dump CronJobs and the restore test
sync wave 3. The app itself is the enabled `{ product: opshub, env: prod, chartVersion: "0.19.1" }`
row in `appsets/products.yaml`; the EKS-era file this replaced was only `env: prod`.

State at go-live: identity applied (the two Entra client ids are in values/opshub/prod.yaml), the 12
kv-qnsc-prod secrets and the Exchange scope exist, `pg-opshub-ca`/`pg-opshub-ca-pub` are mirrored,
the 14-day WAL lock is in infra, pg-opshub is Healthy (first backup complete,
ContinuousArchiving=True), valkey-opshub is Running, and every data-prod ExternalSecret is
SecretSynced. tags.prod pins release v0.4.8 for api/worker/migrator and its web image
(sha-7aa5e92036e9), one release commit.

| File | What |
|---|---|
| `pg-opshub.yaml` | CNPG cluster `pg-opshub` in data-prod (one instance, 500m/2Gi, 20+8 Gi on `local-path-retain`), managed roles opshub_app / opshub_worker / opshub_migrator (owner, NOCREATEROLE) / opshub_readonly, passwords from kv-qnsc-prod, role timeouts (app 30/60 s, worker 120/180 s) |
| `pg-opshub-backup.yaml` | barman-cloud ObjectStore -> `s3://qnsc-backups/pg-opshub/`, WAL archiving (serverName `pg-opshub-g1`), nightly base backup 19:15 UTC |
| `pg-opshub-dump.yaml` | nightly `pg_dump -Fc` as opshub_readonly -> `dumps/daily|weekly|monthly/pg-opshub-<date>.dump`, write-once, 20:30 UTC |
| `valkey-opshub.yaml` | dedicated prod cache with an ACL (user `opshub`, derived from ONE kv secret) |
| `restore-test-opshub.yaml` | on-demand restore test (suspended CronJob in `restore-test`), same checks as rova's |
| `apps/platform-opshub-prod.yaml` (repo root) | the two Applications (data, restore test) |

Shared platform files already carry the prep (inert until pods exist): namespace `opshub-prod`
(platform/namespaces/onprem.yaml), the products-project destination (apps/project.yaml), the
`pg-opshub-ca-pub` name in the cnpg-ca-prod store's RBAC (platform/eso/stores-onprem.yaml), and the
narrow `data-prod-opshub-*` ingress policies (platform/networkpolicy/data-prod-opshub.yaml).

## Enablement record
1. **Owner** (DONE): `platform/bootstrap/secrets.sh --product opshub --env prod --vault-app kv-qnsc-prod --skip-site`
   (the DB passwords incl. readonly, cookie/csrf/better-auth and the Valkey URL; Entra client secret; the R2 token on
   `opshub-prod-attachments`); the certificate `opshub-prod-graph-cert` is the identity lane's. The Entra apps
   "OpsHub Prod" and "OpsHub Prod Service" are applied and their ids are in values/opshub/prod.yaml.
2. **Infra** (DONE): the 14-day lock rule for `pg-opshub/pg-opshub-g1/wals/` in `live/onprem/backups.tf`; Exchange mailbox
   `noreply-opshub@qnsc.vn` and its scope; tunnel route + Access for `opshub.qnsc.vn`.
3. **SA** (DONE): `cluster.sh --env prod --pg-cluster pg-opshub` created `pg-opshub-ca` / `pg-opshub-ca-pub` in data-prod.
4. **Data layer** (DONE, gitops#254): `apps/platform-opshub-prod.yaml`; pg-opshub Healthy, a backup completed,
   ContinuousArchiving=True.
5. **Go live** (this PR): the opshub prod row enabled at chart 0.19.1, tags.prod on v0.4.8 + its web digest
   (sha-7aa5e92036e9). Unblocks the C4-C9 cutover: PreSync migrator on the empty DB, then api/worker/web, the tunnel
   ingress and the edge apply. `prune: false`: a prune must never delete prod objects.
