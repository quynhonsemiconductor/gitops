# opshub production: data layer enabled, app not yet

Mirror of the rova prod layer. The two Applications now live in `apps/platform-opshub-prod.yaml`
(root syncs `apps/*.yaml`), so pg-opshub, valkey-opshub, the backup/dump CronJobs and the restore test
sync wave 3. The app itself is still off: the opshub prod row in `appsets/products.yaml` is a comment
until the go-live PR.

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

## To enable (order)
1. **Owner**: `platform/bootstrap/secrets.sh --product opshub --env prod --vault-app kv-qnsc-prod --skip-site`
   (generates the DB passwords incl. readonly, cookie/csrf/better-auth and the Valkey URL; prompts for the Entra client
   secret and the R2 token on `opshub-prod-attachments`); the certificate `opshub-prod-graph-cert` is the identity lane's.
   Create the Entra apps "OpsHub Prod" and "OpsHub Prod Service" and replace both `<OPSHUB_PROD_...>` ids in values/opshub/prod.yaml.
2. **Infra** (F lane): add the 14-day lock rule for `pg-opshub/pg-opshub-g1/wals/` to `live/onprem/backups.tf` BEFORE the first
   backup; Exchange mailbox `noreply-opshub@qnsc.vn` and its scope; tunnel route + Access for `opshub.qnsc.vn`.
3. **SA**: `cluster.sh --env prod --pg-cluster pg-opshub` creates `pg-opshub-ca` / `pg-opshub-ca-pub` in data-prod from the
   same kv-qnsc-prod CA the rova cluster uses.
4. **PR (data layer, DONE 2026-11-04)**: `git mv platform/opshub-prod/application.yaml.disabled apps/platform-opshub-prod.yaml`.
   Wait for pg-opshub Healthy, run a backup and the restore test (REQUIRE_DATA=0, then 1 after the data load).
5. **PR (go live)**: uncomment the opshub row in appsets/products.yaml (the placeholder gate must pass) and set the image tag.
